"""Build the R16 probe and exercise direct launches as the login user."""
import argparse
import ctypes
from datetime import datetime, timezone
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time

SOURCE = Path(__file__).resolve().with_name("exec_probe.c")
LOCATIONS = ("scope-a", "scope-b", "outside")
ES_KEY = "com.apple.developer.endpoint-security.client"
BUNDLE_ID = "io.github.d3pre5s.deusairlock.standalone"
MIN_MACOS = "13.0"
CLANG = ["/usr/bin/xcrun", "clang", "-std=c17", f"-mmacosx-version-min={MIN_MACOS}", "-Wall", "-Wextra", "-Werror", "-O2"]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def build_probe(executable: Path) -> None:
    subprocess.run([*CLANG, "-D_DARWIN_C_SOURCE", "-fblocks", SOURCE, "-lEndpointSecurity",
                    "-o", executable], check=True, timeout=45)


def package_probe(output_dir: Path) -> Path:
    build_dir = Path(tempfile.mkdtemp(prefix="r16-build-", dir=output_dir.resolve(strict=True)))
    bundle = build_dir / "ExecProbe.app"
    try:
        contents = bundle / "Contents"
        binaries = contents / "MacOS"
        binaries.mkdir(parents=True)
        build_probe(binaries / "ExecProbe")
        with (contents / "Info.plist").open("xb") as info:
            plistlib.dump({
                "CFBundleExecutable": "ExecProbe",
                "CFBundleIdentifier": BUNDLE_ID,
                "CFBundleName": "ExecProbe",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.1",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": MIN_MACOS,
            }, info)
    except (OSError, subprocess.SubprocessError, KeyboardInterrupt):
        shutil.rmtree(build_dir)
        raise
    return bundle


def new_image(base, stage):
    marker = "AIRLOCK-MAIN-" + secrets.token_hex(16)
    filename = stage + "-" + secrets.token_hex(4)
    source = '#include <stdio.h>\nint main(void) { return puts("' + marker + '") < 0; }\n'
    master = base / filename
    subprocess.run([*CLANG, "-x", "c", "-", "-o", master], input=source, text=True, check=True, timeout=35)
    digest = hashlib.sha256(master.read_bytes()).hexdigest()
    paths = {}
    for name in LOCATIONS:
        directory = base / name
        if name == "scope-b":
            directory = directory / "nested"
        path = directory / filename
        shutil.copyfile(master, path)
        path.chmod(0o700)
        require(hashlib.sha256(path.read_bytes()).hexdigest() == digest, "Fixture copy differs")
        paths[name] = path
    return base, marker, digest, paths


def launches(image):
    launch_dir, marker, digest, paths = image
    attempts = {}
    for location, path in paths.items():
        attempt = {"inode": path.stat().st_ino, "path": str(path.relative_to(launch_dir))}
        try:
            result = subprocess.run([path], cwd=launch_dir, env={}, stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=4)
        except PermissionError as exc:
            require(exc.errno in (errno.EACCES, errno.EPERM), "Unexpected spawn error")
            attempt.update(result="permission-denied", errno=exc.errno)
        else:
            require(result.returncode == 0 and result.stdout == marker + "\n" and not result.stderr,
                    f"Unexpected canary result in {location}")
            attempt.update(result="reached-main", exit=0)
        attempts[location] = attempt
    return {"sha256": digest, "cwd_relative_to_run_directory": ".", "attempts": attempts}


def ran(record, location):
    return record["attempts"][location]["result"] == "reached-main"


def check_signed_client(bundle):
    bundle = bundle.resolve(strict=True)
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == BUNDLE_ID, f"Expected the Airlock App ID {BUNDLE_ID}")
    require(info.get("CFBundleExecutable") == "ExecProbe",
            "Supply the R16 diagnostic build of Airlock with the ExecProbe executable")
    team_id = os.environ.get("AIRLOCK_TEAM_ID", "")
    require(re.fullmatch(r"[A-Z0-9]{10}", team_id), "Set AIRLOCK_TEAM_ID to the expected Airlock signing team")
    requirement = f'identifier "{BUNDLE_ID}" and anchor apple generic and certificate leaf[subject.OU] = "{team_id}"'
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, bundle], check=True)
    signature = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", bundle],
                               capture_output=True, check=True)
    rights = plistlib.loads(signature.stdout)
    require(rights.get(ES_KEY) is True, "The ES entitlement is absent in the client's signature")
    profile = subprocess.check_output(["/usr/bin/security", "cms", "-D", "-i", bundle / "Contents/embedded.provisionprofile"])
    profile_data = plistlib.loads(profile)
    profile_rights = profile_data.get("Entitlements", {})
    require(profile_rights.get(ES_KEY) is True, "The embedded profile lacks the ES entitlement")
    require(team_id in profile_data.get("TeamIdentifier", []), "Unexpected provisioning team")
    app_id = rights.get("com.apple.application-identifier")
    allowed_ids = {prefix + "." + BUNDLE_ID for prefix in profile_data.get("ApplicationIdentifierPrefix", [])}
    require(app_id in allowed_ids and profile_rights.get("com.apple.application-identifier") == app_id,
            "The profile and signature must name the diagnostic client")
    expires = profile_data.get("ExpirationDate")
    require(isinstance(expires, datetime) and expires.replace(tzinfo=timezone.utc) > datetime.now(timezone.utc),
            "The provisioning profile has no valid expiry date")
    return (bundle / "Contents/MacOS/ExecProbe").resolve(strict=True)


def checked_peer(connection, executable):
    # Darwin sys/un.h: SOL_LOCAL=0, LOCAL_PEERPID=2. Obtain the peer PID from the kernel.
    pid = connection.getsockopt(0, 2)
    libc = ctypes.CDLL(None, use_errno=True)
    uid, gid = ctypes.c_uint(), ctypes.c_uint()
    rc = libc.getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid))
    require(rc == 0 and uid.value == 0, "Expected the privileged diagnostic peer")
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    path = ctypes.create_string_buffer(4096)
    require(libproc.proc_pidpath(pid, path, len(path)) > 0, "Could not identify the signed peer")
    require(Path(os.fsdecode(path.value)).resolve() == executable, "Different executable connected")
    return pid


def wait_exit(pid):
    end = time.monotonic() + 5
    while time.monotonic() < end:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        except PermissionError:
            pass  # A root-owned peer can still be alive.
        time.sleep(0.05)
    raise RuntimeError("Client process exit was not confirmed")


def compare(base, executable, report):
    # The canary launcher is independent of the ES client. The latter never spawns the canaries.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(base / "guard.sock"))
        server.listen(1)
        server.settimeout(180)
        print(f"Waiting for the signed diagnostic client. Run directory: {base}", file=sys.stderr, flush=True)
        connection, _ = server.accept()
        with connection, connection.makefile("rb") as stream:
            connection.settimeout(15)
            pid = checked_peer(connection, executable)
            status = stream.readline(80)
            require(status == b"READY\n", "AUTH_EXEC subscription was not confirmed: " + repr(status))
            active_image = new_image(base, "new-while-active")
            active = report["active"] = launches(active_image)
            connection.sendall(b"S")
            receipt = stream.readline(200).decode("ascii").split()
            require(len(receipt) == 6 and receipt[0] == "STOPPED", "No deletion and verdict receipt")
            count_a, inode_a, count_b, inode_b, unexpected = map(int, receipt[1:])
        wait_exit(pid)
        report["client_deleted_and_process_exited"] = True
    report["active_kernel_receipt"] = {"scope-a": {"denied": count_a, "inode": inode_a},
                                       "scope-b": {"denied": count_b, "inode": inode_b},
                                       "unexpected": unexpected}
    require(ran(active, "outside"), "Outside control failed during enforcement")
    require(all(not ran(active, name) for name in LOCATIONS[:2]), "Active client did not block both roots")
    require(count_a == count_b == 1 and unexpected == 0 and inode_a == active["attempts"]["scope-a"]["inode"]
            and inode_b == active["attempts"]["scope-b"]["inode"],
            "Kernel response counters or target inodes differ")
    report["after_stop_same_image"] = launches(active_image)
    fresh = report["after_stop_new_image"] = launches(new_image(base, "created-after-stop"))
    require(fresh["sha256"] != active["sha256"], "Post-stop image was not fresh")
    require(all(fresh["attempts"][n]["inode"] != active["attempts"][n]["inode"] for n in LOCATIONS),
            "Post-stop image reused an active fixture inode")
    require(ran(report["after_stop_same_image"], "outside") and ran(fresh, "outside"),
            "Outside control failed after disconnect")
    launched = sum(ran(fresh, n) for n in LOCATIONS[:2])
    if launched == 2:
        report["outcome"] = "fresh-launch-observed-both-after-stop"
    elif launched == 1:
        report["outcome"] = "fresh-launch-differs-by-root-after-stop"
    else:
        report["outcome"] = "fresh-launch-denied-both-cause-unassigned"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["package", "baseline", "compare"])
    parser.add_argument("--app", type=Path, help="Signed R16 build of Airlock standalone with the ExecProbe executable (compare only)")
    parser.add_argument("--report", type=Path, help="Create a new JSON evidence file")
    parser.add_argument("--output-dir", type=Path, help="Existing parent for a new build directory (package only)")
    args = parser.parse_args()
    require(os.geteuid() != 0, "Run canaries as the ordinary login user")
    require((args.mode == "compare") == (args.app is not None), "Use --app only and always with compare")
    if (args.mode == "package") != (args.output_dir is not None):
        parser.error("Use --output-dir only and always with package")
    os.umask(0o077)
    if args.mode == "package":
        if args.report:
            parser.error("--report is only available for baseline and compare")
        try:
            print(package_probe(args.output_dir))
        except (OSError, subprocess.SubprocessError) as exc:
            parser.exit(1, f"Could not package ExecProbe: {exc}\n")
        return 0
    if args.report and args.report.exists():
        parser.error("Report already exists")
    report = {"utc": datetime.now(timezone.utc).isoformat(timespec="seconds"), "macOS": platform.mac_ver()[0],
              "mode": args.mode, "uid": os.getuid(), "outcome": "inconclusive",
              "client_deleted_and_process_exited": None}
    try:
        executable = check_signed_client(args.app) if args.app else None
        with tempfile.TemporaryDirectory(prefix="airlock-r16-", dir="/private/tmp") as temp:
            base = Path(temp)
            for name in LOCATIONS:
                (base / name).mkdir(mode=0o700)
            (base / "scope-b/nested").mkdir(mode=0o700)
            test_client = base / "ExecProbe"
            build_probe(test_client)
            check = subprocess.run([test_client, "--check"], capture_output=True, text=True, timeout=8)
            require(check.returncode in (0, 69) and check.stdout.startswith("es_new_client="),
                    "Could not read ES registration result")
            report["local_build_preflight"] = check.stdout.strip()
            before = report["initial_no_test_client"] = launches(new_image(base, "created-without-client"))
            require(all(ran(before, name) for name in LOCATIONS), "Initial independent launch did not reach main")
            if executable is None:
                report["outcome"] = "baseline-only"
            else:
                compare(base, executable, report)
    except (OSError, RuntimeError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError) as exc:
        report["error"] = str(exc)
    output = json.dumps(report, indent=2) + "\n"
    if args.report:
        with args.report.open("x") as handle:
            handle.write(output)
    sys.stdout.write(output)
    return 1 if report["outcome"] == "inconclusive" else 0


if __name__ == "__main__":
    sys.exit(main())
