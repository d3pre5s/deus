"""Qualify an installed native filter using only a private loopback listener."""
import argparse
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time

from check_egress import folder_checks

HOST = "/Applications/Deus Airlock.app/Contents/MacOS/Deus Airlock"
ROOTS = [Path.home() / ".local/share/claude/versions",
         Path.home() / "Library/Application Support/Claude/claude-code"]


class Control(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.delivered += 1
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"airlock-local-control")

    def log_message(self, *args):
        pass


class Listener(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        import sys
        if not isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            super().handle_error(request, client_address)

    def get_request(self):
        sock, addr = super().get_request()
        self.accepted += 1
        return sock, addr


def matrix(server, binaries, filtered):
    passed = True
    for label, binary, in_root in binaries:
        for flag in ("--local-port", "--child-port", "--replace-port"):
            payload_before = server.delivered
            before = server.accepted
            result = subprocess.run([binary, flag, str(server.server_port)], capture_output=True, timeout=7)
            time.sleep(.1)
            received = server.accepted > before
            delivered = server.delivered > payload_before
            expected = not (filtered and in_root)
            if expected:
                ok = received and result.returncode == 0
                if flag != "--local-port":
                    ok = ok and result.stdout == b"airlock-local-control"
            else:
                # Count only a real network rejection. A dead executable or helper is not a pass.
                ok = not received and result.returncode in ((3, 4) if flag == "--local-port" else (7, 28, 52, 56))
            diagnostic = result.stderr.decode(errors="replace").strip() if flag == "--local-port" else ""
            print(label, flag, "http=" + str(delivered), diagnostic, "accepted=" + str(received), "rc=" + str(result.returncode),
                  "PASS" if ok else "FAIL", flush=True)
            passed = passed and ok
    return passed


def installed_code_helpers(work, port, filtered):
    # Use a system binary outside both protected roots to exercise inheritance.
    sets = [sorted(f for f in ROOTS[0].iterdir() if f.is_file() and f.name[:1].isdigit()),
            sorted(ROOTS[1].glob("*/claude.app/Contents/MacOS/claude"))]
    passed = True
    for versions in sets:
        results = folder_checks(work, Path("/usr/bin/curl"), f"http://127.0.0.1:{port}/", versions, http=True)
        outside = results.pop("новый Mach-O")
        print("signed CLI helpers", results, flush=True)
        passed = passed and outside == "Доступен контрольный порт" and bool(results)
        expected = "Закрыто" if filtered else "Доступен контрольный порт"
        passed = passed and all(value == expected for value in results.values())
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--enable-filter", action="store_true", help="enable the test port and remove the filter afterwards")
    args = parser.parse_args()
    with ExitStack() as cleanup:
        scratch = Path(cleanup.enter_context(tempfile.TemporaryDirectory()))
        control = scratch / "folder-fixture"
        subprocess.run(["/usr/bin/clang", "-Wall", "-Wextra", "-Werror",
                        str(Path(__file__).with_name("directory_helper.c")), "-o", control], check=True)
        binaries = [("outside", control, False)]
        for directory in ROOTS:
            subdir = Path(cleanup.enter_context(tempfile.TemporaryDirectory(prefix=".airlock-qualify-", dir=directory)))
            fixture = subdir / control.name
            shutil.copy(control, fixture)
            binaries.append((str(directory.relative_to(Path.home())), fixture, True))
        server = cleanup.enter_context(Listener(("127.0.0.1", 0), Control))
        server.accepted = 0
        server.delivered = 0
        threading.Thread(target=server.serve_forever, daemon=True).start()
        cleanup.callback(server.shutdown)
        print("Baseline", flush=True)
        if not matrix(server, binaries, False):
            return 1
        if args.enable_filter:
            if not installed_code_helpers(scratch, server.server_port, False):
                return 1
            if not 49152 <= server.server_port <= 65535:
                raise RuntimeError("Loopback listener outside qualification port range")
            command = [HOST, "--airlock-acceptance"]
            try:
                subprocess.run([*command, "folder-filter-on", str(server.server_port)], check=True)
                # Preference readback precedes the first callback on some macOS versions.
                for _ in range(15):
                    ready = subprocess.run([binaries[1][1], "--local-port", str(server.server_port)],
                                           capture_output=True, timeout=7)
                    if ready.returncode in (3, 4):
                        break
                    time.sleep(.5)
                print("Filter active test", flush=True)
                passed = matrix(server, binaries, True)
                real_helpers = installed_code_helpers(scratch, server.server_port, True)
                passed = passed and real_helpers
            finally:
                subprocess.run([*command, "folder-filter-off"], check=True)
            print("After removal", flush=True)
            return 0 if matrix(server, binaries, False) and passed else 1
    return 0


if __name__ == "__main__":
    def interrupted(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())
