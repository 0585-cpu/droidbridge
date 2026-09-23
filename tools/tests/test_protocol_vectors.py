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

    def test_extension_vectors(self) -> None:
        import hashlib, hmac, struct
        document = json.loads((ROOT / "protocol/test-vectors/dbp-extensions.json").read_text())
        self.assertEqual(document["schema"], "dbp-extensions-v1")
        secret = bytes.fromhex(document["secret_hex"])
        for vector in document["vectors"]:
            packet = bytes.fromhex(vector["packet_hex"])
            self.assertEqual(packet[32:64], hmac.new(secret, packet[:32] + bytes(32) + packet[64:], hashlib.sha256).digest())
        caps = next(v for v in document["vectors"] if v["name"] == "capabilities_response")
        self.assertEqual(len(bytes.fromhex(caps["payload_hex"])), 61)
        for frame in document["datagrams"]:
            wire = bytes.fromhex(frame["wire_hex"])
            self.assertEqual(struct.unpack("!H", wire[:2])[0], len(wire) - 8)
            self.assertLessEqual(len(wire) - 8, 1232)

if __name__ == "__main__":
    unittest.main()
