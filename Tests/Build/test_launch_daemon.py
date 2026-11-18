import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Tools/generate-launch-daemon.py"


class LaunchDaemonTests(unittest.TestCase):
    def run_generator(self, base, group, output):
        return subprocess.run([sys.executable, str(SCRIPT), "--base", base,
                               "--app-group", group, "--output", str(output)],
                              capture_output=True, text=True, timeout=10)

    def test_new_identity_and_group_reach_actual_launchd_payload(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "net.example.deus.helper.plist"
            result = self.run_generator("net.example.deus", "ABCDEFGHIJ.net.example.deus", output)
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = plistlib.loads(output.read_bytes())
            self.assertEqual(payload.get("Label"), "net.example.deus.helper")
            self.assertEqual(payload.get("MachServices"), {"ABCDEFGHIJ.net.example.deus.helper": True})
            self.assertEqual(payload.get("AssociatedBundleIdentifiers"), ["net.example.deus.standalone"])
            self.assertEqual(payload.get("BundleProgram"), "Contents/Helpers/RootHelper")

    def test_foreign_group_does_not_replace_existing_output(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "existing.plist"
            output.write_bytes(b"preserve-existing")
            result = self.run_generator("net.example.deus", "ABCDEFGHIJ.net.other.app", output)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_bytes(), b"preserve-existing")

    def test_invalid_bundle_id_is_rejected_without_output(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output.plist"
            result = self.run_generator("../deus", "ABCDEFGHIJ.../deus", output)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
