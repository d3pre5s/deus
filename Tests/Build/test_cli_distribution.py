import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


REPO = Path(__file__).resolve().parents[2]
LABEL = "io.github.d3pre5s.deusairlock.cli-peer"


def build_payload(test, root):
    # Run the standalone target's real resource phase as Xcode would before signing.
    project = subprocess.check_output(["/usr/bin/plutil", "-convert", "json", "-o", "-",
                                       REPO / "sing-box.xcodeproj/project.pbxproj"])
    objects = json.loads(project)["objects"]
    target = next(value for value in objects.values()
                  if value.get("isa") == "PBXNativeTarget" and value["name"] == "SFM.System")
    phases = [objects[key] for key in target["buildPhases"]]
    matches = [phase for phase in phases if "AirlockCLI" in str(phase.get("outputPaths", []))]
    test.assertEqual(len(matches), 1, "Standalone Release has no terminal resource build phase")
    checkout = root / "work tree"
    shutil.copytree(REPO / "Tools/CLI", checkout / "Tools/CLI")
    shutil.copy2(REPO / "Tools/bundle-airlock-cli.sh", checkout / "Tools")
    (checkout / "Tools/CLI/provider.json").write_text('{"private":"fixture"}')
    resources = "Deus Airlock.app/Contents/Resources"
    env = dict(os.environ, SRCROOT=str(checkout), TARGET_BUILD_DIR=str(root / "export"),
               UNLOCALIZED_RESOURCES_FOLDER_PATH=resources, MARKETING_VERSION="1.2.3",
               CURRENT_PROJECT_VERSION="17")
    subprocess.run([matches[0]["shellPath"], "-c", matches[0]["shellScript"]],
                   env=env, check=True, timeout=15)
    return root / "export" / resources / "AirlockCLI"


class Services:
    """Stand-ins for the macOS login domain and the signed Network Extension host."""

    def __init__(self):
        self.loaded = False
        self.bindings = []
        self.loads = 0
        self.fail_bootstrap = False
        self.fail_after_load = False
        self.fail_provision = False

    def run(self, command, **options):
        command = [str(arg) for arg in command]
        if command[0] == "/bin/launchctl":
            action = command[1]
            if action == "print":
                return subprocess.CompletedProcess(command, 0 if self.loaded else 113, "", "")
            if action == "bootstrap":
                if self.fail_bootstrap:
                    self.fail_bootstrap = False
                    raise subprocess.CalledProcessError(5, command)
                with open(command[3], "rb") as file:
                    arguments = plistlib.load(file)["ProgramArguments"]
                assert Path(arguments[0]).is_file()
                self.loads += 1
                self.loaded = True
                if self.fail_after_load:
                    self.fail_after_load = False
                    raise subprocess.TimeoutExpired(command, 20)
            elif action == "bootout":
                assert self.loaded, "bootout of absent relay"
                self.loaded = False
            else:
                raise AssertionError(action)
        else:
            assert command[1:] == ["--provision"] and Path(command[0]).name == "airlock-cli-start"
            assert self.loaded, "onboarding must follow successful local provisioning"
            root = Path(command[0]).resolve().parents[1]
            data = json.loads((root / "provider.json").read_bytes())
            assert next(i for i in data["inbounds"] if i["type"] != "tun")["type"] == "http"
            if self.fail_provision:
                raise subprocess.CalledProcessError(1, command)
            self.bindings.append(json.loads((root / "client.json").read_bytes())["targets"])
        return subprocess.CompletedProcess(command, 0, "", "")


@unittest.skipUnless(sys.platform == "darwin", "requires macOS packaging tools and Seatbelt")
class TerminalDistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name).resolve()
        self.bundle = build_payload(self, self.work)
        self.home = self.work / "Login Profile"
        self.home.mkdir()
        self.cli = self.home / "Library/Application Support/Deus Airlock/CLI"
        self.plist = self.home / f"Library/LaunchAgents/{LABEL}.plist"
        self.rc = self.home / ".zshrc"
        self.ssh = self.home / ".ssh/config"
        self.services = Services()
        self.source = self.work / "private onboarding"
        self.source.mkdir()
        cert = self.source / "proxy.crt"
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048",
                        "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
                        "-keyout", str(self.work / "fixture.key"), "-out", str(cert)],
                       check=True, capture_output=True, timeout=20)
        self.client = {"port": 33441, "password": "test-only", "targets": ["~/.local/bin/claude"]}
        self.peer = {"server": "192.0.2.20", "server_port": 443, "listen_port": 33442}
        self.provider = {"inbounds": [{"type": "tun"}, {
            "type": "mixed", "listen": "127.0.0.1", "listen_port": 33441,
            "users": [{"username": "airlock", "password": "test-only"}],
            "tls": {"enabled": True, "certificate": cert.read_text(),
                    "key": (self.work / "fixture.key").read_text()}}],
            "outbounds": [{"type": "vless", "server": "127.0.0.1", "server_port": 33442}]}
        self.save_inputs()
        self.setup = runpy.run_path(str(self.bundle / "airlock-setup"))["configure"]

    def save_inputs(self):
        for name, contents in [("client", self.client), ("peer", self.peer), ("provider", self.provider)]:
            (self.source / f"{name}.json").write_text(json.dumps(contents, indent=2))

    def install(self):
        self.setup(self.home, self.bundle, self.source, run=self.services.run)

    def rollback(self, **options):
        self.setup(self.home, self.bundle, None, run=self.services.run, **options)

    def test_standalone_resource_payload_excludes_private_and_unversioned_files(self):
        files = {str(p.relative_to(self.bundle)) for p in self.bundle.rglob("*") if p.is_file()}
        self.assertEqual(files, {"bin/claude", "bin/airlock-cli-start", "helpers/ssh", "peer-relay",
                                 "ssh-connect", "ssh_config.airlock", "airlock-setup", "README.md", "VERSION"})
        self.assertIn("1.2.3", (self.bundle / "VERSION").read_text())
        self.assertIn("17", (self.bundle / "VERSION").read_text())
        for name in ("bin/claude", "bin/airlock-cli-start", "helpers/ssh", "peer-relay", "ssh-connect", "airlock-setup"):
            self.assertTrue(os.access(self.bundle / name, os.X_OK), name)

    def test_unsigned_distribution_pkg_contains_the_verified_cli_payload(self):
        app = self.bundle.parents[2]
        contents = app / "Contents"
        (contents / "MacOS").mkdir()
        shutil.copy("/usr/bin/true", contents / "MacOS/Deus Airlock")
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Deus Airlock", "CFBundleIdentifier": "io.github.d3pre5s.deusairlock.standalone",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "17"}))
        component = self.work / "component-arm64.pkg"
        product = self.work / "Deus-Airlock-Apple.pkg"
        subprocess.run(["/bin/bash", str(REPO / "Tools/build-airlock-component.sh"), str(app.parent), str(component)],
                       capture_output=True, check=True, timeout=20)
        subprocess.run(["/usr/bin/productbuild", "--distribution", str(REPO / "SFM.System/distribution-arm64.xml"),
                        "--package-path", str(self.work), "--resources", str(REPO / "SFM.System/Resources"),
                        str(product)], capture_output=True, check=True, timeout=20)
        expanded = self.work / "expanded"
        subprocess.run(["/usr/sbin/pkgutil", "--expand-full", str(product), str(expanded)],
                       capture_output=True, check=True, timeout=20)
        component_info = ET.parse(next(expanded.glob("*/PackageInfo"))).getroot()
        distribution = ET.parse(expanded / "Distribution")
        references = [element for element in distribution.iter("pkg-ref")
                      if element.get("id") == "io.github.d3pre5s.deusairlock.standalone" and (element.text or "").strip()]
        self.assertEqual([component_info.get("version"), *[ref.get("version") for ref in references]],
                         ["1.2.3.17", "1.2.3.17"])
        packed = list(expanded.glob("*/Payload/Deus Airlock.app/Contents/Resources/AirlockCLI"))
        self.assertEqual(len(packed), 1)
        verify = ["/bin/bash", str(REPO / "Tools/bundle-airlock-cli.sh"), "verify", str(packed[0])]
        subprocess.run(verify, check=True, timeout=10)
        (packed[0] / "VERSION").write_text("1.2.3 (16)\n")
        stale = subprocess.run(verify, capture_output=True, timeout=10)
        self.assertNotEqual(stale.returncode, 0)

    def test_clean_install_login_lookup_and_idempotent_rollback_preserve_other_edits(self):
        self.ssh.parent.mkdir()
        self.ssh.write_bytes(b"Host work\n    User developer")
        self.rc.write_bytes(b"# user shell without final newline")
        self.rc.chmod(0o640)
        self.install()
        active = self.cli.resolve()
        self.assertEqual(self.services.bindings, [self.client["targets"]])
        self.assertEqual(json.loads((self.source / "provider.json").read_bytes()), self.provider)
        staged = copy.deepcopy(self.provider)
        staged["inbounds"][1]["type"] = "http"
        self.assertEqual(json.loads((self.cli / "provider.json").read_bytes()), staged)
        for name in ("client.json", "proxy.crt", "peer.json"):
            self.assertEqual((self.cli / name).read_bytes(), (self.source / name).read_bytes())
        self.assertEqual(stat.S_IMODE((self.cli / "provider.json").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.rc.stat().st_mode), 0o640)
        self.assertIn(str(self.cli.resolve() / "proxy.crt"), (self.cli / ".curlrc").read_text())
        payload = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(payload["Label"], LABEL)
        self.assertTrue(payload["RunAtLoad"] and payload["KeepAlive"])
        self.assertEqual(Path(payload["ProgramArguments"][0]).resolve(), self.cli.resolve() / "peer-relay")
        env = dict(HOME=str(self.home), ZDOTDIR=str(self.home), PATH="/usr/bin:/bin", TERM="dumb")
        resolved = subprocess.check_output(["/bin/zsh", "-dic", "whence -p claude"], env=env, text=True)
        self.assertEqual(resolved.strip(), str(self.cli / "bin/claude"))
        nested_path = subprocess.check_output(["/bin/zsh", "-dic", 'source "$ZDOTDIR/.zshrc"; print -r -- "$PATH"'],
                                              env=env, text=True)
        self.assertEqual(nested_path.strip().split(":").count(str(self.cli / "bin")), 1)
        ssh = ["/usr/bin/ssh", "-F", str(self.ssh), "-G", "work"]
        inactive = subprocess.check_output(ssh, env=env, text=True, stderr=subprocess.DEVNULL)
        self.assertIn("user developer", inactive.splitlines())
        self.assertFalse(any(line.startswith("proxycommand ") for line in inactive.splitlines()))
        child = subprocess.check_output(ssh, env=dict(env, AIRLOCK_CLI_ACTIVE="1"),
                                        text=True, stderr=subprocess.DEVNULL)
        self.assertIn('proxycommand "$airlock_ssh_connect" %h %p', child.lower().splitlines())
        installed_rc, installed_ssh = self.rc.read_bytes(), self.ssh.read_bytes()
        self.install()
        self.assertEqual(self.cli.resolve(), active)
        self.assertEqual(self.services.loads, 1)
        self.assertEqual(self.rc.read_bytes(), installed_rc)
        self.assertEqual(self.ssh.read_bytes(), installed_ssh)
        self.rc.write_bytes(installed_rc + b"\n# later edit\n")
        self.ssh.write_bytes(installed_ssh + b"\n# later edit\n")
        self.rollback()
        self.rollback()
        self.assertFalse(self.services.loaded or self.cli.exists() or self.plist.exists())
        self.assertFalse(active.exists())
        self.assertEqual(self.rc.read_bytes(), b"# user shell without final newline\n# later edit\n")
        self.assertEqual(self.ssh.read_bytes(), b"Host work\n    User developer\n# later edit\n")

    def test_failed_bootstrap_after_submission_does_not_leave_loaded_job(self):
        self.services.fail_after_load = True
        with self.assertRaises(subprocess.TimeoutExpired):
            self.install()
        self.assertFalse(self.services.loaded or self.cli.exists() or self.plist.exists())
        self.install()
        self.assertTrue(self.services.loaded)

    def test_upgrade_can_change_ssh_fragment_and_rollback_uses_earlier_one(self):
        self.install()
        first = self.cli.resolve()
        fragment = self.bundle / "ssh_config.airlock"
        fragment.write_bytes(b"# updated fragment\n" + fragment.read_bytes())
        self.install()
        self.assertNotEqual(self.cli.resolve(), first)
        self.assertIn(b"# updated fragment", (self.cli / "ssh_config.airlock").read_bytes())
        self.rollback()
        self.assertEqual(self.cli.resolve(), first)
        self.assertNotIn(b"# updated fragment", (self.cli / "ssh_config.airlock").read_bytes())

    def test_relay_rejects_changed_peer_before_opening_a_socket(self):
        self.install()
        arguments = plistlib.loads(self.plist.read_bytes())["ProgramArguments"]
        peer = self.cli / "peer.json"
        self.assertEqual(arguments[1:], ["--peer-sha256", hashlib.sha256(peer.read_bytes()).hexdigest()])
        self.peer["server"] = "192.0.2.53"
        peer.write_text(json.dumps(self.peer))
        result = subprocess.run(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                                 *arguments], text=True, capture_output=True, timeout=4)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("peer.json changed", result.stderr)

    def test_vendor_cannot_read_retired_credentials_or_edit_relay_registration(self):
        self.install()
        old = self.cli.resolve()
        self.peer["server"] = "192.0.2.55"
        self.save_inputs()
        self.install()
        vendor = self.home / ".local/bin/claude"
        vendor.parent.mkdir(parents=True)
        vendor.write_text("""#!/usr/bin/python3 -I
import json, sys
from pathlib import Path
answer = []
for operation, name in zip(["r", "r", "r", "r", "w", "w"], sys.argv[1:]):
    try:
        with open(name, operation):
            pass
        answer.append("allowed")
    except PermissionError:
        answer.append("denied")
print(json.dumps(answer))
""")
        vendor.chmod(0o700)
        result = subprocess.run([str(self.cli / "bin/claude"), old / "provider.json", old / "client.json",
                                 self.cli / "provider.json", self.cli / "proxy.crt", self.plist, old / "peer.json"],
                                env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"}, capture_output=True,
                                check=True, text=True, timeout=10)
        self.assertEqual(json.loads(result.stdout), ["denied", "denied", "denied", "allowed", "denied", "denied"])

    def test_changed_provider_rollback_requires_explicit_pin_and_failed_repin_restores_newer_files(self):
        self.install()
        old = self.cli.resolve()
        self.provider["route"] = {"auto_detect_interface": False}
        self.save_inputs()
        self.install()
        new = self.cli.resolve()
        with self.assertRaisesRegex(ValueError, "restore-policy"):
            self.rollback()
        self.assertEqual(self.cli.resolve(), new)
        self.services.fail_provision = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.rollback(restore_policy=True)
        self.assertEqual(self.cli.resolve(), new)
        self.assertTrue(self.services.loaded)
        self.services.fail_provision = False
        self.rollback(restore_policy=True)
        self.assertEqual(self.cli.resolve(), old)
        self.assertTrue(self.services.loaded)

    def test_migration_preserves_manual_tree_and_job_on_failure_then_succeeds_from_original_inputs(self):
        for name in ("bin/claude", "bin/airlock-cli-start", "helpers/ssh", "peer-relay", "ssh-connect"):
            path = self.cli / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.bundle / name, path)
        for item in self.source.iterdir():
            shutil.copy2(item, self.cli)
        (self.cli / "personal-note").write_bytes(b"keep this")
        self.plist.parent.mkdir(parents=True)
        original_plist = plistlib.dumps({"Label": LABEL, "ProgramArguments": [str(self.cli / "peer-relay")],
                                         "KeepAlive": True, "RunAtLoad": True, "StandardErrorPath": "/dev/null"})
        self.plist.write_bytes(original_plist)
        self.services.loaded = True
        self.ssh.parent.mkdir()
        self.ssh.write_bytes(b"# old qualification block and my SSH settings")
        self.rc.write_bytes(b"# existing shell PATH")
        self.services.fail_provision = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.setup(self.home, self.bundle, self.cli, run=self.services.run, migrate=True)
        self.assertTrue(self.services.loaded)
        self.assertFalse(self.cli.is_symlink())
        self.assertEqual((self.cli / "personal-note").read_bytes(), b"keep this")
        self.assertEqual(self.plist.read_bytes(), original_plist)
        self.services.fail_provision = False
        self.setup(self.home, self.bundle, self.cli, run=self.services.run, migrate=True)
        self.assertTrue(self.cli.is_symlink())
        current = self.cli.resolve()
        self.setup(self.home, self.bundle, self.cli, run=self.services.run, migrate=True)
        self.assertEqual(self.cli.resolve(), current)
        with self.assertRaisesRegex(ValueError, "legacy"):
            self.rollback()
        self.assertTrue(self.cli.is_symlink())
        self.assertEqual((self.cli.parent / "Terminal Releases/legacy-v12/CLI/personal-note").read_bytes(), b"keep this")
        # An explicitly restored, matching qualification host is checked before changing
        # the managed installation. A distribution host cannot accept this rollback.
        def legacy_run(command, **options):
            if command[0] == "/usr/bin/plutil":
                return subprocess.CompletedProcess(command, 0, "12\n", "")
            if "--airlock-acceptance" in command:
                self.assertEqual(list(command[1:]), ["--airlock-acceptance", "status"])
                return subprocess.CompletedProcess(command, 0, "Acceptance policy present: true; connection status: 1\n", "")
            return self.services.run(command, **options)
        def busy_host(command, **options):
            if "--airlock-acceptance" in command:
                return subprocess.CompletedProcess(command, 0, "Acceptance policy present: true; connection status: 3\n", "")
            return legacy_run(command, **options)
        with self.assertRaisesRegex(ValueError, "disconnected policy"):
            self.setup(self.home, self.bundle, None, run=busy_host, restore_legacy=True)
        self.assertEqual(self.cli.resolve(), current)
        self.setup(self.home, self.bundle, None, run=legacy_run, restore_legacy=True)
        self.assertTrue(self.services.loaded)
        self.assertFalse(self.cli.is_symlink())
        self.assertEqual((self.cli / "personal-note").read_bytes(), b"keep this")
        self.assertEqual(self.plist.read_bytes(), original_plist)
        self.assertEqual(self.ssh.read_bytes(), b"# old qualification block and my SSH settings")
        self.assertEqual(self.rc.read_bytes(), b"# existing shell PATH")

    def test_registration_failure_cleanup_can_retry_with_clean_home(self):
        self.services.fail_bootstrap = True
        with self.assertRaises(Exception):
            self.install()
        self.assertFalse(self.cli.exists() or self.plist.exists() or self.ssh.exists() or self.rc.exists())
        self.assertEqual(self.services.bindings, [])
        self.install()
        self.assertTrue(self.services.loaded)
        self.rollback()
        self.assertFalse(self.ssh.exists() or self.rc.exists())

    def test_failed_update_restores_working_relay_and_explicit_rollback_restores_earlier_release(self):
        self.install()
        old = self.cli.resolve()
        self.peer["server"] = "192.0.2.21"
        self.save_inputs()
        self.services.fail_provision = True
        with self.assertRaises(Exception):
            self.install()
        self.assertEqual(self.cli.resolve(), old)
        self.assertTrue(self.services.loaded)
        self.assertEqual(json.loads((self.cli / "peer.json").read_bytes())["server"], "192.0.2.20")
        self.services.fail_provision = False
        self.install()
        self.assertNotEqual(self.cli.resolve(), old)
        nbindings = len(self.services.bindings)
        self.rollback()
        self.assertEqual(self.cli.resolve(), old)
        self.assertTrue(self.services.loaded)
        self.assertEqual(len(self.services.bindings), nbindings, "local rollback must not rewrite OS policy")
        self.rollback()
        self.assertFalse(self.services.loaded or self.cli.exists())

    def test_conflicting_inputs_and_unmanaged_files_are_rejected_before_any_activation(self):
        self.client["password"] = "mismatch"
        self.save_inputs()
        with self.assertRaisesRegex(ValueError, "credential|password"):
            self.install()
        self.assertFalse(self.cli.exists() or self.plist.exists() or self.rc.exists())
        self.client["password"] = "test-only"
        self.save_inputs()
        self.cli.mkdir(parents=True)
        old = self.cli / "existing-qualification"
        old.write_bytes(b"preserve")
        with self.assertRaisesRegex(ValueError, "manage|existing|owned"):
            self.install()
        self.assertEqual(old.read_bytes(), b"preserve")
        self.assertEqual(self.services.loads, 0)


if __name__ == "__main__":
    unittest.main()
