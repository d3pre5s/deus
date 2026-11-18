import runpy
from pathlib import Path
import unittest
from unittest.mock import patch

import egress_probe


CONNECTOR = Path(__file__).resolve().parents[2] / "Tools/CLI/ssh-connect"


class ConnectResponse(unittest.TestCase):
    def test_http_200_opens_the_stream(self):
        validate = runpy.run_path(str(CONNECTOR))["validate_response"]
        for line in (b"HTTP/1.0 200 OK", b"HTTP/1.1 200 Connection established"):
            validate(line + b"\r\nProxy-Agent: test\r\n\r\n")

    def test_unexpected_status_never_opens_the_stream(self):
        validate = runpy.run_path(str(CONNECTOR))["validate_response"]
        for line in (b"invalid 200 OK", b"HTTP/1.1 407 Auth required", b"HTTP/1.1 502 Bad gateway",
                     b"HTTP/1.1 2000 Invalid", b"HTTP/1.1 403 Denied\r\nTest: 200 OK"):
            with self.subTest(line=line), self.assertRaises(OSError):
                validate(line + b"\r\n\r\n")


class SSHOutageEvidence(unittest.TestCase):
    def test_outage_requires_transport_evidence(self):
        closed = "Connection closed by UNKNOWN port 65535"
        cases = [
            ("/bin/sh: exec: exec: not found", False),
            ("Airlock SSH: certificate verify failed", False),
            ("Airlock SSH: proxy status 407", False),
            ("", False),
            ("Airlock SSH: proxy status 502", True),
            ("Airlock SSH: proxy connection refused", True),
            ("Airlock SSH: remote stream closed", True),
            ("Airlock SSH: proxy stream reset after CONNECT", True),
            ("Airlock SSH: [Errno 32] Broken pipe", False),
        ]
        for diagnostic, outage in cases:
            with self.subTest(diagnostic=diagnostic), patch.object(
                egress_probe, "run", return_value=(255, "", diagnostic + "\n" + closed)
            ):
                result = egress_probe.ssh("ssh")
                self.assertEqual(result == egress_probe.NO_NET, outage)
                if not outage:
                    self.assertIn(egress_probe.ERROR, result)


if __name__ == "__main__":
    unittest.main()
