/* A new native executable in the selected folder. Its own socket is loopback-only. */
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    int child = strcmp(argv[1], "--child-port") == 0;
    int replace = strcmp(argv[1], "--replace-port") == 0;
    if (!child && !replace && strcmp(argv[1], "--local-port") != 0) {
        argv[0] = "/usr/bin/curl";
        execv(argv[0], argv);
        return 2;
    }
    if (argc != 3) return 2;
    char *end;
    long port = strtol(argv[2], &end, 10);
    if (*end || port < 1 || port > 65535) return 2;
    if (child || replace) {
        char url[64];
        snprintf(url, sizeof(url), "http://127.0.0.1:%ld/", port);
        pid_t pid = replace ? 0 : fork();
        if (pid == 0) {
            execl("/usr/bin/curl", "curl", "-q", "--noproxy", "*", "--max-time", "3",
                  "-fsS", url, (char *)NULL);
            _exit(127);
        }
        int status;
        if (pid < 0 || waitpid(pid, &status, 0) != pid || !WIFEXITED(status)) return 2;
        return WEXITSTATUS(status);
    }
    struct sockaddr_in addr = {.sin_len = sizeof(addr), .sin_family = AF_INET,
                               .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return errno == EPERM || errno == EACCES ? 3 : 2;
    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    int saved = errno;
    close(fd);
    if (rc == 0) return 0;
    fprintf(stderr, "connect errno=%d\n", saved);
    if (saved == EPERM || saved == EACCES) return 3;
    if (saved == ECONNREFUSED || saved == ETIMEDOUT || saved == ECONNRESET) return 4;
    return 2;
}
