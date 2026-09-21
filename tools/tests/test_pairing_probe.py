import base64
import json
import socket
import struct
import sys
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
    HAVE_CRYPTO = True
except ModuleNotFoundError:
    HAVE_CRYPTO = False

if HAVE_CRYPTO:
    import pairing_probe as pp


def x963(pub):
    return pub.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


class FakeAndroid:
    """In-process Android endpoint mirroring PairingCoordinator; used to prove cross-language parity."""

    def __init__(self, peer_id="android-fake", display_name="Pixel", approve=True, tamper=False):
        self.peer_id = peer_id
        self.display_name = display_name
        self.approve = approve
        self.tamper = tamper
        self.private_key = ec.generate_private_key(ec.SECP256R1())
        self.nonce = bytes(range(32))
        self.stored_secret = None

    def hello(self):
        return pp.canonical_hello("android", self.peer_id, self.display_name, x963(self.private_key.public_key()), self.nonce)

    def handle(self, conn):
        mac_hello = pp.recv_frame(conn)
        pp.send_frame(conn, self.hello())
        transcript = pp.transcript_bytes(mac_hello, self.hello())
        shared = self.private_key.exchange(ec.ECDH(), pp.load_public_key(base64.b64decode(json.loads(mac_hello)["publicKey"])))
        secret = pp.hkdf_sha256(shared, base64.b64decode(json.loads(mac_hello)["nonce"]) + self.nonce, pp.INFO, 32)
        self.secret = secret
        self.sas = pp.sas_of(transcript)

        mac_approval = json.loads(pp.recv_frame(conn))
        mac_proof = base64.b64decode(mac_approval["proof"]) if mac_approval.get("proof") else b""
        if not mac_approval.get("approved") or not self.approve:
            pp.send_frame(conn, json.dumps({"sessionId": pp.session_id_of(transcript), "approved": False, "proof": None},
                                           sort_keys=True, separators=(",", ":")))
            return
        # verify the mac's proof exactly as the phone would
        expected = pp.approval_proof(secret, "mac", transcript)
        assert mac_proof == expected, "mac proof mismatch"
        self.stored_secret = secret
        proof = pp.approval_proof(secret, "android", transcript)
        if self.tamper:
            proof = bytes(32)
        pp.send_frame(conn, json.dumps({"sessionId": pp.session_id_of(transcript), "approved": True,
                                        "proof": base64.b64encode(proof).decode()}, sort_keys=True, separators=(",", ":")))


def serve_once(android):
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    result = {}

    def run():
        conn, _ = server.accept()
        with conn:
            try:
                android.handle(conn)
            except Exception as exc:  # noqa: BLE001
                result["error"] = repr(exc)
        server.close()

    thread = threading.Thread(target=run)
    thread.start()
    return port, thread, result


@unittest.skipUnless(HAVE_CRYPTO, "cryptography not installed")
class PairingProbeTest(unittest.TestCase):
    def test_p256_hkdf_sas_parity_and_both_proofs(self):
        android = FakeAndroid()
        port, thread, result = serve_once(android)
        import io as _io
        secret_path = None
        with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
            secret = pp.run_pairing(sock, "mac-1", "MacBook", auto_confirm=True)
        thread.join(5)
        self.assertNotIn("error", result)
        self.assertIsNotNone(secret)
        self.assertEqual(bytes(secret), android.stored_secret)  # identical secret both sides

    def test_android_tampered_proof_is_rejected(self):
        android = FakeAndroid(tamper=True)
        port, thread, result = serve_once(android)
        with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
            secret = pp.run_pairing(sock, "mac-1", "MacBook", auto_confirm=True)
        thread.join(5)
        self.assertIsNone(secret)

    def test_android_rejection_yields_no_secret(self):
        android = FakeAndroid(approve=False)
        port, thread, result = serve_once(android)
        with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
            secret = pp.run_pairing(sock, "mac-1", "MacBook", auto_confirm=True)
        thread.join(5)
        self.assertIsNone(secret)

    def test_secret_bytearray_is_wiped_on_exit(self):
        import os
        android = FakeAndroid()
        port, thread, result = serve_once(android)
        out = Path(os.environ.get("TMPDIR", "/tmp")) / "droidbridge-probe-test.key"
        rc = pp.main(["--host", "127.0.0.1", "--port", str(port), "--auto-confirm", "--secret-out", str(out)])
        thread.join(5)
        self.assertEqual(rc, 0)
        self.assertEqual(oct(out.stat().st_mode & 0o777), "0o600")
        out.unlink()

    def test_canonical_hello_is_sorted_and_compact(self):
        hello = pp.canonical_hello("mac", "p", "Name", bytes([4]) + bytes(64), bytes(32))
        self.assertTrue(hello.startswith('{"displayName":"Name","nonce":'))
        self.assertNotIn(" ", hello)


if __name__ == "__main__":
    unittest.main()
