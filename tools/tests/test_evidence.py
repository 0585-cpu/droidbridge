import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from evidence import SensitiveEvidenceError, write_evidence  # noqa: E402


class EvidenceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "out.json"

    def tearDown(self) -> None:
        self.dir.cleanup()

    def test_rejects_sensitive_keys_recursively(self) -> None:
        with self.assertRaises(SensitiveEvidenceError):
            write_evidence({"result": {"pairingSecret": "deadbeef"}}, self.path)

    def test_rejects_each_declared_sensitive_key(self) -> None:
        for key in ("secret", "token", "PASSWORD", "payload", "Cookie",
                    "authorization", "sni", "dnsName", "url"):
            with self.subTest(key=key):
                with self.assertRaises(SensitiveEvidenceError):
                    write_evidence({key: "x"}, self.path)

    def test_allows_only_declared_scalar_types(self) -> None:
        write_evidence({
            "test": "preflight",
            "passed": True,
            "timestamp": "2026-09-21T00:00:00Z",
            "metrics": {"latencyMs": 12.5, "bytes": 1024},
        }, self.path)
        self.assertTrue(self.path.exists())
        loaded = json.loads(self.path.read_text())
        self.assertEqual(loaded["metrics"]["bytes"], 1024)

    def test_rejects_undeclared_value_type(self) -> None:
        with self.assertRaises(TypeError):
            write_evidence({"when": object()}, self.path)


if __name__ == "__main__":
    unittest.main()
