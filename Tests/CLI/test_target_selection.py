import json
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


START = Path(__file__).resolve().parents[2] / "Tools/CLI/bin/airlock-cli-start"
HOST = ["/Applications/Deus Airlock.app/Contents/MacOS/Deus Airlock", "--airlock-control"]


class TargetSelectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        self.cli = self.home / ".local/bin/claude"
        self.cli.parent.mkdir(parents=True)
        self.cli.touch()
        self.root = self.home / "CLI"
        self.root.mkdir()
        (self.root / "peer.json").write_text('{"listen_port": 42002}')
        self.main = runpy.run_path(str(START))["main"]
        self.commands = []

    def launch(self, settings, saved=(), args=(), matching_pin=True):
        (self.root / "client.json").write_text(json.dumps({"port": 42001, **settings}))

        def respond(command, **kwargs):
            if command[-1] == "targets":
                return json.dumps(list(saved))
            return "Acceptance policy present: true; connection status: 3"

        def record(command, **kwargs):
            self.commands.append(command)
            if command[len(HOST)] == "verify-cli" and not matching_pin:
                raise subprocess.CalledProcessError(1, command)

        with patch.dict(self.main.__globals__, __file__=str(self.root / "bin/airlock-cli-start")), \
                patch.object(Path, "home", return_value=self.home), \
                patch.object(sys, "argv", [str(START), *args]), \
                patch.object(subprocess, "check_output", side_effect=respond), \
                patch.object(subprocess, "run", side_effect=record):
            self.main()

    def expected_connected(self, *targets):
        return [[*HOST, "bind", *targets],
                [*HOST, "verify-cli", str(self.root / "provider.json"), "42001", "42002", *targets]]

    def test_connected_profile_verifies_its_config_without_starting_the_tunnel(self):
        self.launch({"targets": ["~/.local/bin/claude"]})
        self.assertEqual(self.commands, self.expected_connected(str(self.cli)))

    def test_connected_status_cannot_mask_a_missing_or_changed_pin(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.launch({"targets": ["~/.local/bin/claude"]}, matching_pin=False)
        self.assertEqual(self.commands, self.expected_connected(str(self.cli)))

    def test_new_terminal_profile_provisions_only_the_vendor_cli(self):
        self.launch({}, args=["--provision"])
        self.assertEqual(self.commands, [[*HOST, "provision-cli", str(self.root / "provider.json"),
                                         "42001", "42002", str(self.cli)]])

    def test_explicit_targets_bind_only_chosen_apps_even_when_other_helpers_exist(self):
        desktop = self.home / "Desktop.app"
        (desktop / "Contents/Helpers").mkdir(parents=True)
        (desktop / "Contents/Helpers/chrome-native-host").touch()
        self.launch({"targets": ["~/.local/bin/claude", str(desktop)]})
        self.assertEqual(self.commands, self.expected_connected(str(self.cli), str(desktop)))

    def test_existing_profile_keeps_saved_targets_when_client_predates_selection(self):
        selected = self.home / "Existing.app"
        selected.mkdir()
        self.launch({}, saved=[str(self.cli), str(selected)])
        self.assertEqual(self.commands, self.expected_connected(str(self.cli), str(selected)))

    def test_lost_selected_target_blocks_bind_and_start_including_on_legacy_upgrade(self):
        targets = [str(self.cli), str(self.home / "Missing.app")]
        for settings, saved in [({"targets": targets}, []), ({}, targets)]:
            with self.subTest(settings=settings), self.assertRaisesRegex(RuntimeError, "Missing.app"):
                self.launch(settings, saved=saved)
        self.assertEqual(self.commands, [])

    def test_empty_duplicate_or_malformed_selection_never_uses_defaults(self):
        for invalid in [None, [], "", ["relative"], [1], [str(self.cli), "~/.local/bin/claude"]]:
            with self.subTest(invalid=invalid), self.assertRaises((ValueError, RuntimeError)):
                self.launch({"targets": invalid})
        self.assertEqual(self.commands, [])

    def test_provisioning_the_cli_transport_requires_the_vendor_cli_selection(self):
        desktop = self.home / "Desktop.app"
        desktop.mkdir()
        with self.assertRaisesRegex((RuntimeError, ValueError), "CLI"):
            self.launch({"port": 42001, "targets": [str(desktop)]}, args=["--provision"])
        self.assertEqual(self.commands, [])

    def test_provisioning_pins_the_selected_config_and_ports_without_starting(self):
        self.launch({"port": 42001, "targets": ["~/.local/bin/claude"]}, args=["--provision"])
        self.assertEqual(self.commands, [[*HOST, "provision-cli", str(self.root / "provider.json"),
                                         "42001", "42002", str(self.cli)]])


if __name__ == "__main__":
    unittest.main()
