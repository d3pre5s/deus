import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest


@unittest.skipUnless(Path("/usr/bin/sandbox-exec").exists(), "requires macOS Seatbelt")
class TerminalIsolation(unittest.TestCase):
    def test_only_configured_port_survives_exec_and_empty_environment(self):
        source = Path(__file__).resolve().parents[2] / "Tools/CLI/bin/claude"
        with tempfile.TemporaryDirectory() as folder, socket.socket() as allowed, socket.socket() as forbidden:
            root = Path(folder).resolve()
            launcher = root / "bin/claude"
            launcher.parent.mkdir()
            shutil.copy2(source, launcher)
            for listener in (allowed, forbidden):
                listener.bind(("127.0.0.1", 0))
                listener.listen()
            good, bad = [s.getsockname()[1] for s in (allowed, forbidden)]
            (root / "client.json").write_text(json.dumps({"port": good, "password": "fixture"}))
            vendor = root / ".local/bin/claude"
            vendor.parent.mkdir(parents=True)
            vendor.write_text('#!/bin/sh\nexec /usr/bin/env -i /usr/bin/python3 -I "$@"\n')
            vendor.chmod(0o755)
            probe = (
                "import errno, socket, sys\n"
                "def connect(port):\n"
                "    with socket.socket() as s: return s.connect_ex(('127.0.0.1', int(port)))\n"
                "assert connect(sys.argv[1]) == 0\n"
                "assert connect(sys.argv[2]) in (errno.EACCES, errno.EPERM)\n"
            )
            subprocess.run([str(launcher), "-c", probe, str(good), str(bad)],
                           env=dict(os.environ, HOME=str(root)), check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
