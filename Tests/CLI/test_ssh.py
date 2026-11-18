import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest


CLI = Path(__file__).resolve().parents[2] / "Tools/CLI"


class SSHProxyCommand(unittest.TestCase):
    def test_openssh_starts_connector_with_destination(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve() / "Airlock CLI"
            (root / "bin").mkdir(parents=True)
            shutil.copy2(CLI / "bin/claude", root / "bin/claude")
            shutil.copytree(CLI / "helpers", root / "helpers")
            (root / "client.json").write_text('{"port": 443, "password": "fixture"}')
            vendor = Path(folder) / ".local/bin/claude"
            vendor.parent.mkdir(parents=True)
            vendor.write_text('#!/bin/sh\nexec "$@"\n')
            vendor.chmod(0o755)
            connector = root / "ssh-connect"
            received = Path(folder) / "received"
            connector.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$RECEIVED"\n')
            connector.chmod(0o755)
            for binary, config in (("ssh", "/dev/null"),
                                   ("/usr/bin/ssh", CLI / "ssh_config.airlock")):
                for shell in (None, "", "/bin/zsh"):
                    with self.subTest(binary=binary, shell=shell):
                        received.unlink(missing_ok=True)
                        env = dict(os.environ, HOME=folder, RECEIVED=str(received))
                        if shell is None:
                            env.pop("SHELL", None)
                        else:
                            env["SHELL"] = shell
                        proc = subprocess.run(
                            [root / "bin/claude", binary, "-F", config, "-oBatchMode=yes", "-p", "2244", "127.0.0.1"],
                            env=env, capture_output=True, text=True, timeout=5,
                            stdin=subprocess.DEVNULL,
                        )
                        self.assertTrue(received.exists(), proc.stderr)
                        self.assertEqual(received.read_text().splitlines(), ["127.0.0.1", "2244"])


if __name__ == "__main__":
    unittest.main()
