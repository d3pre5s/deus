"""Live macOS acceptance. Exit 1 if any scope fails, including directory membership."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager, ExitStack
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

from egress_probe import ERROR, NO_NET, native_control, run, sentinel, trace

HOME = Path.home()
ROOT = HOME / "Library/Application Support/Deus Airlock/CLI"
VERSIONS = (HOME / ".local/share/claude/versions").resolve()
BUNDLED = HOME / "Library/Application Support/Claude/claude-code"
PLIST = HOME / "Library/LaunchAgents/io.github.d3pre5s.deusairlock.cli-peer.plist"
DOMAIN = f"gui/{os.getuid()}"
ENTRY = ["/bin/zsh", "-lic", 'exec claude "$@"', "airlock-check"]
PROBE = Path(__file__).with_name("egress_probe.py").resolve()


class Control(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"airlock-local-control")

    def log_message(self, *args):
        pass


def check_hook(entry, argv, env, work):
    hook = {"hooks": {"Setup": [{"matcher": "init", "hooks": [
        {"type": "command", "command": shlex.join([str(arg) for arg in argv])}]}]}}
    code, _, _ = run([*entry, "--init-only", "--setting-sources", "", "--strict-mcp-config",
                      "--settings", json.dumps(hook)], timeout=38, cwd=work, env=env)
    if code:
        raise RuntimeError(f"Claude Setup hook, код {code}")


def api(env, work):
    code, out, err = run([*ENTRY, "--bare", "-p", "ping", "--tools", "",
                          "--no-session-persistence", "--setting-sources", ""],
                         timeout=22, env=dict(env, CLAUDE_CODE_MAX_RETRIES="0"), cwd=work)
    if code == 124:
        return f"{ERROR} (тайм-аут процесса Claude)"
    if "invalid api key" in (out + err).lower():
        return "API отклонил тестовый ключ"
    if any(s in (out + err).lower() for s in
                          ("connection error", "unable to connect", "timed out", "econnreset")):
        return NO_NET
    return f"{ERROR} (API {code})"


def environment(work):
    env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "SHELL")
           if k in os.environ}
    return dict(env, CLAUDE_CONFIG_DIR=str(work / "config"), DISABLE_AUTOUPDATER="1",
                CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", GIT_TERMINAL_PROMPT="0",
                ANTHROPIC_API_KEY="sk-ant-airlock-invalid-test",
                ANTHROPIC_BASE_URL="https://api.anthropic.com")


def phase(work, fixture, url, offline, expected):
    result_file = work / "hook.json"
    result_file.unlink(missing_ok=True)
    env = environment(work)
    if offline:
        env["AIRLOCK_CHECK_OUTAGE"] = "1"
    with ThreadPoolExecutor(max_workers=2) as pool:
        api_result = pool.submit(api, env, work)
        check_hook(ENTRY, ["/usr/bin/python3", PROBE, work, fixture, url], env, work)
        checks = json.loads(result_file.read_bytes())
        checks["Claude API"] = api_result.result()
    required = {"curl": expected, "shell → новый бинарник из папки": expected,
                "ssh": "SSH banner", "/usr/bin/ssh": "SSH banner",
                "git → git-remote-https": "HEAD", "Claude API": "API отклонил тестовый ключ"}
    if offline:
        required = dict.fromkeys(required, NO_NET)
    required["контрольный порт из Claude"] = "Закрыто"
    ok = all(checks.get(key) == value for key, value in required.items())
    kernel = checks["проверка ядра"]
    return checks, ok and len(kernel) == 4 and all(v == "Запрещено ядром" for v in kernel.values())


def folder_checks(work, fixture, url, versions, *, http=False):
    # Test directory membership independently of the normal shell launcher.
    # Only the loopback canary is contacted by these requests.
    control = sentinel([str(fixture)], url) if http else native_control(str(fixture), url)
    results = {"новый Mach-O": control}
    if not versions:
        raise RuntimeError("Не найдены установленные бинарники Claude Code")
    requirement = ('anchor apple generic and identifier "com.anthropic.claude-code" '
                   'and certificate leaf[subject.OU] = "Q6L2SF6YDW"')
    for version in versions:
        name = version.name if version.name != "claude" else version.parents[3].name
        if version.is_symlink() or run(["/usr/bin/codesign", "--verify", "-R", "=" + requirement, str(version)])[0]:
            results[name] = f"{ERROR} (подпись)"
            continue
        output = work / "directory-result"
        output.unlink(missing_ok=True)
        call = "sentinel([sys.argv[3]], sys.argv[4])" if http else "native_control(sys.argv[3], sys.argv[4])"
        script = ("import sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); "
                  "from egress_probe import native_control, sentinel; "
                  f"Path(sys.argv[2]).write_text({call})")
        env = environment(work)
        env["ANTHROPIC_BASE_URL"] = url
        try:
            check_hook([str(version)], ["/usr/bin/python3", "-I", "-B", "-c", script, PROBE.parent,
                                        output, fixture, url], env, work)
            results[name + " → helper"] = output.read_text()
        except (OSError, RuntimeError) as error:
            results[name + " → helper"] = f"{ERROR} ({type(error).__name__})"
    return results


def directory_matrix(work, fixture, url, stack):
    versions = sorted(f for f in VERSIONS.iterdir() if f.is_file() and
                      re.fullmatch(r"\d+\.\d+\.\d+", f.name) and os.access(f, os.X_OK))
    cases = [("терминальный CLI", fixture, versions)]
    if BUNDLED.is_dir():
        copies = sorted(BUNDLED.glob("*/claude.app/Contents/MacOS/claude"))
        nested = stack.enter_context(tempfile.TemporaryDirectory(prefix=".airlock-check-", dir=BUNDLED))
        bundled_helper = Path(nested) / "network-helper"
        shutil.copy(fixture, bundled_helper)
        cases.append(("CLI из Claude Desktop", bundled_helper, copies))

    def check():
        results = {}
        for label, helper, binaries in cases:
            for name, value in folder_checks(work, helper, url, binaries).items():
                results[label + " / " + name] = value
        return results
    return check


def wait_ready(work, job):
    for _ in range(100):
        if (work / "ready").exists() and not job.done():
            return
        if job.done():
            job.result()
            break
        time.sleep(0.2)
    raise RuntimeError("Не удалось открыть постоянный SSH-канал")


def listener(port):
    with socket.socket() as sock:
        sock.settimeout(0.25)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def wait_for_listener(port, state):
    for _ in range(60):
        if listener(port) == state:
            return
        time.sleep(0.2)
    raise RuntimeError(f"Порт службы Airlock не перешёл в ожидаемое состояние {state}")


@contextmanager
def interrupt_relay(port):
    label = DOMAIN + "/" + PLIST.stem
    subprocess.run(["/bin/launchctl", "bootout", label], check=True)
    try:
        wait_for_listener(port, False)
        yield
    finally:
        subprocess.run(["/bin/launchctl", "bootstrap", DOMAIN, str(PLIST)], check=True)
        wait_for_listener(port, True)


def show(label, value):
    print(label, json.dumps(value, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-ip", type=ipaddress.IPv4Address, required=True)
    parser.add_argument("--outage", action="store_true", help="temporarily stop and restore the user relay")
    args = parser.parse_args()
    expected = f"{args.expected_ip} ES"
    code, out, _ = run(["/bin/zsh", "-lic", "whence -p claude"])
    if code or out.strip().splitlines()[-1:] != [str(ROOT / "bin/claude")]:
        raise RuntimeError("Команда claude в новом zsh не указывает на Airlock")
    port = json.loads((ROOT / "peer.json").read_bytes())["listen_port"]
    wait_for_listener(port, True)
    with tempfile.TemporaryDirectory() as scratch:
        work = Path(scratch).resolve()
        (work / "config").mkdir()
        with tempfile.TemporaryDirectory(prefix=".airlock-check-", dir=VERSIONS) as nested, ExitStack() as stack, \
                ThreadingHTTPServer(("127.0.0.1", 0), Control) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            url = f"http://127.0.0.1:{server.server_port}/"
            fixture = Path(nested) / "network-helper"
            subprocess.run(["/usr/bin/clang", "-Wall", "-Wextra", "-Werror",
                            str(PROBE.with_name("directory_helper.c")), "-o", str(fixture)], check=True)
            if sentinel(["/usr/bin/curl"], url) != "Доступен контрольный порт":
                raise RuntimeError("Не работает локальный контрольный порт")
            matrix = directory_matrix(work, fixture, url, stack)
            directory = matrix()
            show("Директория", directory)
            passed = all(value == "Закрыто" for value in directory.values())
            test = partial(phase, work, fixture, url, expected=expected)
            before, ok = test(offline=False)
            show("Канал включён", before)
            if not ok:
                return 1
            if args.outage:
                with ThreadPoolExecutor(max_workers=1) as pool:
                    held = pool.submit(check_hook, ENTRY, ["/usr/bin/python3", PROBE, "--hold", work],
                                       environment(work), work)
                    wait_ready(work, held)
                    with interrupt_relay(port):
                        held.result(timeout=15)
                        if not (work / "eof").exists():
                            raise RuntimeError("Нет подтверждения закрытия SSH")
                        show("Открытый SSH-канал", "Закрыт")
                        during, ok = test(offline=True)
                        show("Обрыв", during)
                        during_dir = matrix()
                        show("Директория при обрыве", during_dir)
                        passed = passed and all(value == "Закрыто" for value in during_dir.values())
                        direct = trace(["/usr/bin/curl", "-q", "--noproxy", "*"])
                        # The control must have a real, distinct egress, not just a different string.
                        try:
                            other = ipaddress.ip_address(direct.split()[0]) != args.expected_ip
                        except (ValueError, IndexError):
                            other = False
                        show("Интернет вне Airlock при обрыве", other)
                        passed = passed and ok and other
                after, ok = test(offline=False)
                show("После восстановления", after)
                passed = passed and ok
            server.shutdown()
    return 0 if passed else 1


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sys.exit(main())
