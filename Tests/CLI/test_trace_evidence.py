import os
import unittest
from unittest.mock import patch

import egress_probe as probe


class TraceEvidence(unittest.TestCase):
    def check(self, code, out="", err="", outage=True):
        env = {"AIRLOCK_CHECK_OUTAGE": "1" if outage else "0",
               "HTTPS_PROXY": "https://airlock:fixture@127.0.0.1:9876"}
        with patch.dict(os.environ, env), patch.object(probe, "run", return_value=(code, out, err)):
            return probe.trace(["curl"])

    def test_generic_curl_failures_are_inconclusive(self):
        for code in [5, 6, 7, 28, 35, 52, 55, 56, 124]:
            for outage in [True, False]:
                with self.subTest(code=code, outage=outage):
                    self.assertIn(probe.ERROR, self.check(code, err="timed out", outage=outage))

    def test_timeout_after_contacting_another_address_is_inconclusive(self):
        self.assertIn(probe.ERROR, self.check(28, "airlock 192.0.2.8 443 200 0", "Operation timed out"))
        self.assertIn(probe.ERROR, self.check(56, "airlock 192.0.2.8 9876 200 0", "Connection reset by peer"))

    def test_only_verified_local_proxy_transport_errors_qualify(self):
        for code, status, message in [(56, 502, "CONNECT tunnel failed, response 502"),
                                      (56, 200, "Recv failure: Connection reset by peer"),
                                      (35, 200, "unexpected EOF")]:
            metrics = f"airlock 127.0.0.1 9876 {status} 0"
            self.assertEqual(probe.NO_NET, self.check(code, metrics, message))
            self.assertIn(probe.ERROR, self.check(code, metrics.replace("9876", "9877"), message))
            self.assertIn(probe.ERROR, self.check(code, metrics, message, outage=False))
        for status in [0, 403, 407]:
            self.assertIn(probe.ERROR, self.check(56, f"airlock 127.0.0.1 9876 {status} 0", "connection reset by peer"))
