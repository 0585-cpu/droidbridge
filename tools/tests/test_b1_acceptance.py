import json
import tempfile
import unittest
from pathlib import Path

from tools.b1_acceptance import evaluate


class B1AcceptanceTest(unittest.TestCase):
    def test_all_fourteen_criteria_require_device_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)

            def write(name: str, value: dict) -> None:
                (directory / f"{name}.json").write_text(json.dumps(value))

            write("preflight", {"passed": True, "checks": {
                "android_api_ge_26": {"passed": True},
                "app_installed": {"passed": True},
            }})
            write("functional", {"passed": True, "macPhysicalIsolation": True, "checks": {
                "dns": True, "https": True, "gitHttps": True, "sshTcp": True,
                "cellularExit": True, "androidWifiOnCellularExit": True,
            }})
            write("killswitch", {"passed": True, "scenarios": {
                name: {"passed": True, "recoveryPassed": True,
                       "recoveryRouteInterface": "utun7"}
                for name in ("usb", "relay", "cellular", "sleep")
            }})
            write("security", {"passed": True, "checks": {
                "androidRootless": True, "privateDestinationBlocked": True,
                "unauthenticatedRejected": True, "loggingScan": True,
                "forbiddenApiScan": True,
            }})
            write("stress", {"passed": True})
            write("soak", {"passed": True, "dnsHostnameVerified": True, "workload": {
                "dnsChecks": 2, "tcpConnectionCycles": 8,
            }})
            write("performance", {"passed": True})

            result = evaluate(directory)
            self.assertTrue(result["passed"])
            self.assertEqual(len(result["criteria"]), 14)

            (directory / "security.json").unlink()
            incomplete = evaluate(directory)
            self.assertFalse(incomplete["passed"])
            self.assertFalse(incomplete["criteria"][7]["passed"])

    def test_ordinary_connections_do_not_substitute_for_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            (directory / "soak.json").write_text(json.dumps({
                "passed": True,
                "dnsHostnameVerified": True,
                "workload": {"dnsChecks": 1, "tcpConnectionCycles": 10},
            }))
            (directory / "killswitch.json").write_text(json.dumps({
                "passed": True,
                "scenarios": {
                    name: {"passed": True, "recoveryPassed": True,
                           "recoveryRouteInterface": "en0" if name == "relay" else "utun7"}
                    for name in ("usb", "relay", "cellular", "sleep")
                },
            }))

            result = evaluate(directory)
            self.assertFalse(result["criteria"][10]["passed"])


if __name__ == "__main__":
    unittest.main()
