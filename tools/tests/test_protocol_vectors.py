from pathlib import Path
import json
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ProtocolVectorTest(unittest.TestCase):
    def test_fixture_is_reproducible(self) -> None:
        subprocess.run(
            [sys.executable, str(ROOT / "tools/generate_protocol_vectors.py"), "--check"],
            cwd=ROOT,
            check=True,
        )
        document = json.loads((ROOT / "protocol/test-vectors/dbp-v1.json").read_text())
        self.assertEqual(document["schema"], "dbp-vectors-v1")
        self.assertEqual(document["header_size"], 64)
        self.assertEqual(
            {item["name"] for item in document["vectors"]},
            {
                "hello",
                "hello_ok",
                "open_ipv4_443",
                "open_domain_443",
                "open_ok",
                "open_error_policy_denied",
                "dns_query",
                "dns_response",
                "health",
                "health_response_ready",
            },
        )


if __name__ == "__main__":
    unittest.main()
