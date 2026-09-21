#!/usr/bin/env python3
"""DroidBridge pairing probe: the Mac side of the DBP/1 pairing handshake.

Mirrors android PairingProtocol/PairingCoordinator byte-for-byte: P-256 ECDH, HKDF-SHA256
(salt = macNonce||androidNonce, info = "DroidBridge DBP/1 Pairing"), a six-digit SAS from the
transcript hash, and HMAC approval proofs. The derived Pairing Secret is held only in a bytearray
that is wiped on exit; it is never printed.

Requires the `cryptography` package (see tools/requirements-dev.txt); exits with install guidance if
it is missing rather than silently changing behaviour.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import socket
import struct
import sys
import tempfile

try:
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
except ModuleNotFoundError:
    sys.stderr.write("pairing_probe requires 'cryptography'. Install: pip install -r tools/requirements-dev.txt\n")
    raise SystemExit(2)

PREFIX = b"DROIDBRIDGE-PAIR-1"
INFO = b"DroidBridge DBP/1 Pairing"
MAX_FRAME = 8192
PAIRING_PORT = 27184


def canonical_hello(role: str, peer_id: str, display_name: str, public_key: bytes, nonce: bytes) -> str:
    """Sorted-key, whitespace-free JSON identical to the Kotlin Json.encode output."""
    return json.dumps(
        {
            "version": 1,
            "role": role,
            "peerId": peer_id,
            "displayName": display_name,
            "publicKey": base64.b64encode(public_key).decode(),
            "nonce": base64.b64encode(nonce).decode(),
        },
        sort_keys=True,
        separators=(",", ":"),
    )


def public_key_x963(public_key: ec.EllipticCurvePublicKey) -> bytes:
    return public_key.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def load_public_key(x963: bytes) -> ec.EllipticCurvePublicKey:
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), x963)


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, previous, counter = b"", b"", 1
    while len(out) < length:
        previous = hmac.new(prk, previous + info + bytes([counter]), hashlib.sha256).digest()
        out += previous
        counter += 1
    return out[:length]


def transcript_bytes(mac_hello: str, android_hello: str) -> bytes:
    return PREFIX + mac_hello.encode() + android_hello.encode()


def sas_of(transcript: bytes) -> str:
    digest = hashlib.sha256(transcript).digest()
    value = struct.unpack(">I", digest[:4])[0]
    return f"{value % 1_000_000:06d}"


def session_id_of(transcript: bytes) -> str:
    return hashlib.sha256(transcript).hexdigest()[:32]


def approval_proof(secret: bytes, role: str, transcript: bytes) -> bytes:
    return hmac.new(secret, role.encode() + b"\x00" + hashlib.sha256(transcript).digest(), hashlib.sha256).digest()


class PairingParty:
    """Mac side. Generates an ephemeral key, derives the shared secret, verifies the SAS and proofs."""

    def __init__(self, peer_id: str, display_name: str) -> None:
        self.role = "mac"
        self.peer_id = peer_id
        self.display_name = display_name
        self.private_key = ec.generate_private_key(ec.SECP256R1())
        self.nonce = secrets.token_bytes(32)
        self.hello = canonical_hello(self.role, peer_id, display_name, public_key_x963(self.private_key.public_key()), self.nonce)

    def derive(self, android_hello_json: str) -> tuple[bytearray, str, bytes]:
        android = json.loads(android_hello_json)
        if android.get("version") != 1 or android.get("role") != "android":
            raise ValueError("bad android hello")
        android_pub = load_public_key(base64.b64decode(android["publicKey"]))
        android_nonce = base64.b64decode(android["nonce"])
        # re-serialize android hello canonically so the transcript matches the phone's bytes exactly
        android_hello = canonical_hello("android", android["peerId"], android.get("displayName", ""),
                                        public_key_x963(android_pub), android_nonce)
        transcript = transcript_bytes(self.hello, android_hello)
        shared = self.private_key.exchange(ec.ECDH(), android_pub)
        secret = bytearray(hkdf_sha256(shared, self.nonce + android_nonce, INFO, 32))
        return secret, sas_of(transcript), transcript


# --- framing -----------------------------------------------------------------

def send_frame(sock: socket.socket, text: str) -> None:
    data = text.encode()
    if len(data) > MAX_FRAME:
        raise ValueError("frame too large")
    sock.sendall(struct.pack(">I", len(data)) + data)


def recv_frame(sock: socket.socket) -> str:
    header = recv_exactly(sock, 4)
    (length,) = struct.unpack(">I", header)
    if length <= 0 or length > MAX_FRAME:
        raise ValueError("bad frame length")
    return recv_exactly(sock, length).decode()


def recv_exactly(sock: socket.socket, n: int) -> bytes:
    chunks = b""
    while len(chunks) < n:
        chunk = sock.recv(n - len(chunks))
        if not chunk:
            raise ConnectionError("peer closed")
        chunks += chunk
    return chunks


def run_pairing(sock: socket.socket, peer_id: str, display_name: str, auto_confirm: bool) -> bytearray | None:
    party = PairingParty(peer_id, display_name)
    send_frame(sock, party.hello)
    android_hello = recv_frame(sock)
    secret, sas, transcript = party.derive(android_hello)
    try:
        print(f"Pairing SAS: {sas}")
        if not auto_confirm:
            answer = input("Does this match the code on the Android screen? [y/N] ").strip().lower()
            if answer != "y":
                send_frame(sock, json.dumps({"sessionId": session_id_of(transcript), "approved": False, "proof": None},
                                            sort_keys=True, separators=(",", ":")))
                return None
        session_id = session_id_of(transcript)
        proof = approval_proof(secret, "mac", transcript)
        send_frame(sock, json.dumps({"sessionId": session_id, "approved": True,
                                     "proof": base64.b64encode(proof).decode()}, sort_keys=True, separators=(",", ":")))
        android_approval = json.loads(recv_frame(sock))
        if not android_approval.get("approved") or android_approval.get("proof") is None:
            print("Android rejected pairing", file=sys.stderr)
            return None
        android_proof = base64.b64decode(android_approval["proof"])
        if not hmac.compare_digest(android_proof, approval_proof(secret, "android", transcript)):
            print("Android proof invalid", file=sys.stderr)
            return None
        return secret
    finally:
        pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=PAIRING_PORT)
    parser.add_argument("--peer-id", default="mac-probe")
    parser.add_argument("--display-name", default="DroidBridge Probe")
    parser.add_argument("--secret-out", help="write the secret to this mode-0600 file (else a temp file)")
    parser.add_argument("--auto-confirm", action="store_true", help="skip the interactive SAS confirmation (tests only)")
    args = parser.parse_args(argv)

    with socket.create_connection((args.host, args.port), timeout=65) as sock:
        secret = run_pairing(sock, args.peer_id, args.display_name, args.auto_confirm)
    if secret is None:
        print("pairing not completed", file=sys.stderr)
        return 1
    try:
        if args.secret_out:
            fd = os.open(args.secret_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            path = args.secret_out
        else:
            fd, path = tempfile.mkstemp(prefix="droidbridge-secret-", suffix=".key")
            os.chmod(path, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(bytes(secret))
        print(f"pairing complete; secret written to {path}")
        return 0
    finally:
        for i in range(len(secret)):
            secret[i] = 0


if __name__ == "__main__":
    raise SystemExit(main())
