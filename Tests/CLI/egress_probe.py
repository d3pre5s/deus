"""Child probes invoked from a real Claude Code Setup hook."""
from concurrent.futures import ThreadPoolExecutor
import errno
import ipaddress
import json
from pathlib import Path
import re
import os
import select
import socket
import subprocess
import sys
from urllib.parse import urlsplit


def run(argv, timeout=13, **kwargs):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL, **kwargs)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"


TRACE = "https://1.1.1.1/cdn-cgi/trace"
NO_NET = "Нет сети"
ERROR = "Ошибка проверки"


def trace(argv, url=TRACE):
    code, out, _ = run([*argv, "-fsS", "--max-time", "9", url])
    if code in (5, 6, 7, 28, 52, 55, 56):
        return NO_NET
    if code:
        return f"{ERROR} (curl {code})"
    fields = dict(s.split("=", 1) for s in out.splitlines() if "=" in s)
    try:
        return str(ipaddress.ip_address(fields["ip"])) + " " + fields["loc"]
    except (KeyError, ValueError):
        return ERROR


def ssh(binary):
    code, _, err = run([binary, "-v", "-T", "-oBatchMode=yes", "-oConnectTimeout=7",
                        "-oStrictHostKeyChecking=yes", "-oUserKnownHostsFile=/dev/null",
                        "-oGlobalKnownHostsFile=/dev/null", "-oIdentityAgent=none",
                        "-oPreferredAuthentications=none", "-p443", "git@ssh.github.com"],
                       env=dict(os.environ, AIRLOCK_SSH_PROBE="1"))
    if "Remote protocol version" in err:
        return "SSH banner"
    diagnostics = set(err.splitlines())
    transport_errors = {
        "Airlock SSH: proxy connection refused",
        "Airlock SSH: remote stream closed",
        "Airlock SSH: proxy status 502",
        "Airlock SSH: proxy status 503",
        "Airlock SSH: proxy status 504",
    }
    if code == 255 and diagnostics.intersection(transport_errors):
        return NO_NET
    return f"{ERROR} (ssh {code})"


def git():
    code, out, err = run(["/usr/bin/git", "-c", "credential.helper=", "ls-remote",
                          "https://github.com/d3pre5s/deus-airlock.git", "HEAD"])
    if not code and re.fullmatch(r"[0-9a-f]{40,64}\s+HEAD\s*", out):
        return "HEAD"
    if code == 128 and any(s in err.lower() for s in
        ("timed out", "connection reset", "connection refused", "failed to connect")):
        return NO_NET
    return f"{ERROR} (git {code})"


def sentinel(argv, url):
    # A fresh, random loopback port that is outside the configured Airlock proxy.
    code, out, err = run([*argv, "-q", "--noproxy", "*", "-fsS", "--max-time", "3", url])
    if code == 0 and out == "airlock-local-control":
        return "Доступен контрольный порт"
    if code == 7:
        return "Закрыто"
    return f"{ERROR} (control {code})"


def native_control(binary, url):
    code, _, _ = run([binary, "--local-port", str(urlsplit(url).port)])
    return {0: "Доступен контрольный порт", 3: "Закрыто"}.get(code, f"{ERROR} (native {code})")


def sockets():
    result = {}
    for family, destination in ((socket.AF_INET, "192.0.2.1"), (socket.AF_INET6, "2001:db8::1")):
        for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
            key = f"{family.name}/{kind.name}"
            with socket.socket(family, kind) as sock:
                sock.settimeout(0.4)
                try:
                    sock.connect((destination, 443))
                    if kind == socket.SOCK_DGRAM:
                        sock.send(b"a")
                    result[key] = "Разрешено"
                except OSError as exc:
                    result[key] = "Запрещено ядром" if exc.errno in (errno.EACCES, errno.EPERM) else ERROR
    return result


def main(folder, binary, url):
    jobs = {
        "curl": lambda: trace(["/usr/bin/curl"]),
        "shell → новый бинарник из папки": lambda: trace(["/bin/sh", "-c", 'exec "$@"', "sh", binary]),
        "ssh": lambda: ssh("ssh"),
        "/usr/bin/ssh": lambda: ssh("/usr/bin/ssh"),
        "git → git-remote-https": git,
        "контрольный порт из Claude": lambda: native_control(binary, url),
        "проверка ядра": sockets,
    }
    with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        pending = {key: pool.submit(check) for key, check in jobs.items()}
        values = {key: item.result() for key, item in pending.items()}
    (Path(folder) / "hook.json").write_text(json.dumps(values, ensure_ascii=False))


def hold_channel(work):
    work = Path(work)
    cmd = [os.environ["AIRLOCK_SSH_CONNECT"], "ssh.github.com", "443"]
    with subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, bufsize=0) as proc:
        try:
            if not select.select([proc.stdout], [], [], 12)[0] or not proc.stdout.readline().startswith(b"SSH-"):
                raise RuntimeError("Нет SSH-баннера")
            (work / "ready").touch()
            if not select.select([proc.stdout], [], [], 20)[0] or proc.stdout.read(1) != b"":
                raise RuntimeError("Канал не закрылся")
            (work / "eof").touch()
        finally:
            proc.terminate()


if __name__ == "__main__":
    if sys.argv[1] == "--hold":
        hold_channel(sys.argv[2])
    else:
        main(*sys.argv[1:])
