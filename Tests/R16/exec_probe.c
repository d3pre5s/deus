#include <EndpointSecurity/EndpointSecurity.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

enum { ROOTS = 2 };
static const char *const names[ROOTS] = {"scope-a", "scope-b"};
static char prefixes[ROOTS][PATH_MAX];
static size_t lengths[ROOTS];
static _Atomic unsigned denials[ROOTS], errors;
static _Atomic uint64_t last_inode[ROOTS];

static const char *registration_name(es_new_client_result_t result) {
    switch (result) {
        case ES_NEW_CLIENT_RESULT_SUCCESS: return "SUCCESS";
        case ES_NEW_CLIENT_RESULT_ERR_INVALID_ARGUMENT: return "ERR_INVALID_ARGUMENT";
        case ES_NEW_CLIENT_RESULT_ERR_INTERNAL: return "ERR_INTERNAL";
        case ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED: return "ERR_NOT_ENTITLED";
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED: return "ERR_NOT_PERMITTED";
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED: return "ERR_NOT_PRIVILEGED";
        case ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS: return "ERR_TOO_MANY_CLIENTS";
        default: return "UNKNOWN";
    }
}

/* Only a fresh private run directory immediately below /private/tmp is eligible. */
static bool configure_roots(const char *base, uid_t *owner) {
    const char *prefix = "/private/tmp/airlock-r16-";
    const char *alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_";
    char real[PATH_MAX];
    struct stat st;
    if (!realpath(base, real) || strcmp(base, real) != 0 ||
        strncmp(base, prefix, strlen(prefix)) != 0) return false;
    const char *suffix = base + strlen(prefix);
    if (strlen(suffix) != 8 || strspn(suffix, alphabet) != 8 ||
        lstat(base, &st) || !S_ISDIR(st.st_mode) || (st.st_mode & 077) || st.st_uid == 0) return false;
    *owner = st.st_uid;
    for (size_t i = 0; i < ROOTS; ++i) {
        char path[PATH_MAX];
        if (snprintf(path, sizeof(path), "%s/%s", base, names[i]) >= (int)sizeof(path) ||
            lstat(path, &st) || !S_ISDIR(st.st_mode) || (st.st_mode & 077) || st.st_uid != *owner ||
            !realpath(path, real) || strcmp(path, real) != 0) return false;
        int len = snprintf(prefixes[i], sizeof(prefixes[i]), "%s/", path);
        if (len < 0 || len >= (int)sizeof(prefixes[i])) return false;
        lengths[i] = (size_t)len;
    }
    return true;
}

static void on_exec(es_client_t *client, const es_message_t *msg) {
    if (msg->event_type != ES_EVENT_TYPE_AUTH_EXEC || msg->action_type != ES_ACTION_TYPE_AUTH) {
        ++errors;
        return;
    }
    const es_file_t *target = msg->event.exec.target->executable;
    for (size_t i = 0; i < ROOTS; ++i) {
        if (!target->path_truncated && target->path.length > lengths[i] &&
            memcmp(target->path.data, prefixes[i], lengths[i]) == 0) {
            if (es_respond_auth_result(client, msg, ES_AUTH_RESULT_DENY, false) == ES_RESPOND_RESULT_SUCCESS) {
                last_inode[i] = (uint64_t)target->stat.st_ino;
                ++denials[i];
            } else {
                ++errors;
            }
            return;
        }
    }
    /* Unexpected attribution invalidates the experiment. Spare unrelated programs. */
    ++errors;
    (void)es_respond_auth_result(client, msg, ES_AUTH_RESULT_ALLOW, false);
}

static int connect_driver(const char *base, uid_t owner) {
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (snprintf(address.sun_path, sizeof(address.sun_path), "%s/guard.sock", base) >=
        (int)sizeof(address.sun_path)) return -1;
    address.sun_len = SUN_LEN(&address);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    uid_t peer;
    gid_t group;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) ||
        connect(fd, (struct sockaddr *)&address, address.sun_len) ||
        getpeereid(fd, &peer, &group) || peer != owner) {
        close(fd);
        return -1;
    }
    return fd;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fputs("Usage: ExecProbe --check | PRIVATE_RUN_DIRECTORY\n", stderr);
        return 64;
    }
    bool check = strcmp(argv[1], "--check") == 0;
    int fd = -1;
    if (!check) {
        uid_t owner;
        if (!configure_roots(argv[1], &owner) || (fd = connect_driver(argv[1], owner)) < 0) {
            fputs("Invalid private fixture roots or driver socket\n", stderr);
            return 65;
        }
    }

    es_client_t *client = NULL;
    es_new_client_result_t result = es_new_client(&client, ^(es_client_t *c, const es_message_t *m) {
        on_exec(c, m);
    });
    if (check || result != ES_NEW_CLIENT_RESULT_SUCCESS)
        fprintf(stdout, "es_new_client=%s (%d)\n", registration_name(result), (int)result);
    if (result != ES_NEW_CLIENT_RESULT_SUCCESS) {
        if (fd >= 0) {
            dprintf(fd, "es_new_client=%s (%d)\n", registration_name(result), (int)result);
            close(fd);
        }
        return 69;
    }
    if (check) return es_delete_client(client) == ES_RETURN_SUCCESS ? 0 : 1;

    /* Target muting is per client. The ordinary system process mute set is untouched. */
    bool scoped = es_unmute_all_target_paths(client) == ES_RETURN_SUCCESS;
    for (size_t i = 0; i < ROOTS && scoped; ++i)
        scoped = es_mute_path(client, prefixes[i], ES_MUTE_PATH_TYPE_TARGET_PREFIX) == ES_RETURN_SUCCESS;
    const es_event_type_t event = ES_EVENT_TYPE_AUTH_EXEC;
    bool subscribed = scoped &&
        es_invert_muting(client, ES_MUTE_INVERSION_TYPE_TARGET_PATH) == ES_RETURN_SUCCESS &&
        es_subscribe(client, &event, 1) == ES_RETURN_SUCCESS;
    if (!subscribed) dprintf(fd, "AUTH_EXEC subscription or scope setup failed\n");
    bool stopped = false;
    if (subscribed && dprintf(fd, "READY\n") > 0) {
        char command;
        struct pollfd watch = {.fd = fd, .events = POLLIN};
        stopped = poll(&watch, 1, 90000) > 0 && read(fd, &command, 1) == 1 && command == 'S';
    }
    /* Disconnect on the registration thread, including timeout and driver exit. */
    bool deleted = es_delete_client(client) == ES_RETURN_SUCCESS;
    if (stopped && deleted) {
        dprintf(fd, "STOPPED %u %" PRIu64 " %u %" PRIu64 " %u\n",
                atomic_load(&denials[0]), atomic_load(&last_inode[0]),
                atomic_load(&denials[1]), atomic_load(&last_inode[1]), atomic_load(&errors));
    }
    close(fd);
    return subscribed && stopped && deleted && atomic_load(&errors) == 0 ? 0 : 1;
}
