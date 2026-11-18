from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import patch

import check_egress
import egress_probe


START = Path(__file__).resolve().parents[2] / "Tools/CLI/bin/airlock-cli-start"


class TunnelReadiness(unittest.TestCase):
    def simulate(self, states, **kwargs):
        start = runpy.run_path(str(START))
        responses = [f"Acceptance policy present: true; connection status: {state}" for state in states]
        with patch.object(subprocess, "check_output", side_effect=responses), \
             patch.object(subprocess, "run") as request, patch("time.sleep"):
            start["wait_connected"](["host"], ["profile", "app"], **kwargs)
        return [call.args[0] for call in request.call_args_list]

    def test_start_requested_once_and_connection_confirmed(self):
        self.assertEqual(self.simulate([5, 1, 1, 2, 3]), [["host", "start", "profile", "app"]])

    def test_inflight_connection_finishes_without_duplicate_start(self):
        self.assertEqual(self.simulate([2, 4, 3]), [])

    def test_failed_start_never_reports_success(self):
        with self.assertRaisesRegex(RuntimeError, "invalid"):
            self.simulate([1, 0])
        with patch("time.monotonic", side_effect=[0, 0, 0, 31]):
            with self.assertRaisesRegex(RuntimeError, "Timed out"):
                self.simulate([2])


class OutageResults(unittest.TestCase):
    def test_process_timeouts_are_inconclusive(self):
        timeout = (124, "", "timed out")
        with patch.object(egress_probe, "run", return_value=timeout):
            self.assertIn(egress_probe.ERROR, egress_probe.git())
        with patch.object(check_egress, "run", return_value=timeout):
            self.assertIn(egress_probe.ERROR, check_egress.api({}, Path(".")))

    def test_transport_refusal_still_reports_no_network(self):
        with patch.object(egress_probe, "run", return_value=(128, "", "Connection refused")):
            self.assertEqual(egress_probe.git(), egress_probe.NO_NET)

    def test_tls_handshake_error_is_inconclusive(self):
        with patch.object(egress_probe, "run", return_value=(35, "", "TLS error")):
            self.assertIn(egress_probe.ERROR, egress_probe.trace(["curl"]))


if __name__ == "__main__":
    unittest.main()
