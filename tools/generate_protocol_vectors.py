#!/usr/bin/env python3
"""Canonical DBP/1 test-vector generator.

This file is the source of truth for the wire encoding. C, Kotlin and Swift
implementations consume the JSON it writes. It must be deterministic: no system
time, no randomness, no environment-dependent output.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VECTORS_PATH = ROOT / "protocol/test-vectors/dbp-v1.json"

HEADER = struct.Struct("!4sBBHQQQ32s")
HEADER_SIZE = 64
MAGIC = b"DBP1"
SECRET = bytes.fromhex("00" * 31 + "01")
UNIX_TIME = 1_700_000_000
CLIENT_NONCE = 0x0102030405060708
SERVER_NONCE = 0x1112131415161718

MESSAGE_TYPES = {
    "HELLO": 0x01,
    "HELLO_OK": 0x02,
    "OPEN_TCP": 0x10,
    "OPEN_OK": 0x11,
    "OPEN_ERROR": 0x12,
    "DNS_QUERY": 0x20,
    "DNS_RESPONSE": 0x21,
    "HEALTH": 0x30,
    "HEALTH_RESPONSE": 0x31,
}

ERROR_CODES = {
    "AUTH_FAILED": 1,
    "VERSION_UNSUPPORTED": 2,
    "POLICY_DENIED": 3,
    "CELLULAR_UNAVAILABLE": 4,
    "DNS_FAILED": 5,
    "CONNECT_TIMEOUT": 6,
    "CONNECT_REFUSED": 7,
    "SESSION_LIMIT": 8,
    "INTERNAL_ERROR": 9,
}

ADDRESS_IPV4 = 1
ADDRESS_DOMAIN = 3
MAX_DOMAIN_LENGTH = 253
DNS_MIN, DNS_MAX = 12, 4096
HEALTH_MIN, HEALTH_MAX = 22, 85
MAX_SESSIONS = 256
HEALTH_STATUS = {"NOT_READY": 0, "READY": 1, "CELLULAR_UNAVAILABLE": 2}


# --- header / hmac -----------------------------------------------------------

def encode_header(message_type: int, flags: int, client_nonce: int,
                  server_nonce: int, unix_time: int, mac: bytes) -> bytes:
    return HEADER.pack(MAGIC, message_type, flags, HEADER_SIZE,
                       client_nonce, server_nonce, unix_time, mac)


def compute_hmac(message_type: int, flags: int, client_nonce: int,
                 server_nonce: int, unix_time: int, payload: bytes,
                 secret: bytes = SECRET) -> bytes:
    zero_header = encode_header(message_type, flags, client_nonce,
                                server_nonce, unix_time, bytes(32))
    return hmac.new(secret, zero_header + payload, hashlib.sha256).digest()


# --- payload builders (each asserts the limits documented in dbp-v1.md) ------

def open_tcp_ipv4(address: str, port: int) -> bytes:
    octets = bytes(int(part) for part in address.split("."))
    assert len(octets) == 4 and 1 <= port <= 65535
    return struct.pack("!BHB", ADDRESS_IPV4, port, 4) + octets


def open_tcp_domain(domain: str, port: int) -> bytes:
    wire = domain.encode("ascii")
    assert 1 <= len(wire) <= MAX_DOMAIN_LENGTH and 1 <= port <= 65535
    return struct.pack("!BHB", ADDRESS_DOMAIN, port, len(wire)) + wire


def open_error(code: int) -> bytes:
    assert code in ERROR_CODES.values()
    return struct.pack("!B", code)


def dns_message(packet: bytes) -> bytes:
    assert DNS_MIN <= len(packet) <= DNS_MAX
    return struct.pack("!H", len(packet)) + packet


def health_response(status: int, active: int, maximum: int, uploaded: int,
                    downloaded: int, carrier: str) -> bytes:
    name = carrier.encode("utf-8")
    name.decode("utf-8")  # must round-trip as valid UTF-8
    assert status in HEALTH_STATUS.values()
    assert 0 <= active <= maximum <= MAX_SESSIONS
    assert len(name) <= 63
    payload = struct.pack("!BHHQQB", status, active, maximum, uploaded,
                          downloaded, len(name)) + name
    assert HEALTH_MIN <= len(payload) <= HEALTH_MAX
    return payload


def dns_name(name: str) -> bytes:
    return b"".join(bytes([len(label)]) + label.encode("ascii")
                    for label in name.split(".")) + b"\x00"


def dns_query_packet(name: str, qtype: int = 1, txid: int = 0x1234) -> bytes:
    return struct.pack("!HHHHHH", txid, 0x0100, 1, 0, 0, 0) + dns_name(name) + struct.pack("!HH", qtype, 1)


def dns_response_packet(name: str, address: str, ttl: int = 300, txid: int = 0x1234) -> bytes:
    rdata = bytes(int(part) for part in address.split("."))
    answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, ttl, len(rdata)) + rdata
    return (struct.pack("!HHHHHH", txid, 0x8180, 1, 1, 0, 0)
            + dns_name(name) + struct.pack("!HH", 1, 1) + answer)


# --- vectors -----------------------------------------------------------------

def vector(name: str, message: str, payload: bytes, *, server_nonce: int = 0,
           description: str = "", fields: dict | None = None) -> dict:
    message_type = MESSAGE_TYPES[message]
    mac = compute_hmac(message_type, 0, CLIENT_NONCE, server_nonce, UNIX_TIME, payload)
    header = encode_header(message_type, 0, CLIENT_NONCE, server_nonce, UNIX_TIME, mac)
    return {
        "name": name,
        "description": description,
        "message_type": message_type,
        "message_name": message,
        "flags": 0,
        "client_nonce": f"{CLIENT_NONCE:016x}",
        "server_nonce": f"{server_nonce:016x}",
        "unix_time": UNIX_TIME,
        "fields": fields or {},
        "payload_hex": payload.hex(),
        "hmac_hex": mac.hex(),
        "header_hex": header.hex(),
        "packet_hex": (header + payload).hex(),
    }


def build_document() -> dict:
    query = dns_query_packet("example.com")
    response = dns_response_packet("example.com", "93.184.216.34")
    vectors = [
        vector("hello", "HELLO", b"", description="client greeting, server nonce zero"),
        vector("hello_ok", "HELLO_OK", b"", server_nonce=SERVER_NONCE,
               description="server accepts; carries server nonce in header"),
        vector("open_ipv4_443", "OPEN_TCP", open_tcp_ipv4("93.184.216.34", 443),
               server_nonce=SERVER_NONCE,
               fields={"address_type": ADDRESS_IPV4, "address": "93.184.216.34", "port": 443}),
        vector("open_domain_443", "OPEN_TCP", open_tcp_domain("example.com", 443),
               server_nonce=SERVER_NONCE,
               fields={"address_type": ADDRESS_DOMAIN, "domain": "example.com", "port": 443}),
        vector("open_ok", "OPEN_OK", b"", server_nonce=SERVER_NONCE,
               description="after this message the socket is a raw byte stream"),
        vector("open_error_policy_denied", "OPEN_ERROR", open_error(ERROR_CODES["POLICY_DENIED"]),
               server_nonce=SERVER_NONCE,
               fields={"error_code": ERROR_CODES["POLICY_DENIED"], "error_name": "POLICY_DENIED"}),
        vector("dns_query", "DNS_QUERY", dns_message(query), server_nonce=SERVER_NONCE,
               fields={"name": "example.com", "qtype": 1, "transaction_id": 0x1234,
                       "dns_packet_hex": query.hex()}),
        vector("dns_response", "DNS_RESPONSE", dns_message(response), server_nonce=SERVER_NONCE,
               fields={"name": "example.com", "answer": "93.184.216.34", "ttl": 300,
                       "transaction_id": 0x1234, "dns_packet_hex": response.hex()}),
        vector("health", "HEALTH", b"", server_nonce=SERVER_NONCE),
        vector("health_response_ready", "HEALTH_RESPONSE",
               health_response(HEALTH_STATUS["READY"], 3, 128, 1_048_576, 8_388_608, "TestCarrier"),
               server_nonce=SERVER_NONCE,
               fields={"status": 1, "status_name": "READY", "active_sessions": 3,
                       "maximum_sessions": 128, "uploaded_bytes": 1_048_576,
                       "downloaded_bytes": 8_388_608, "carrier_name": "TestCarrier"}),
    ]
    return {
        "schema": "dbp-vectors-v1",
        "header_size": HEADER_SIZE,
        "magic_hex": MAGIC.hex(),
        "secret_hex": SECRET.hex(),
        "hmac": "HMAC-SHA256 over header (hmac field zeroed) || payload",
        "timestamp_tolerance_seconds": 120,
        "nonce_replay_window_seconds": 300,
        "nonce_replay_window_entries": 1024,
        "message_types": MESSAGE_TYPES,
        "error_codes": ERROR_CODES,
        "health_status": HEALTH_STATUS,
        "limits": {
            "max_domain_length": MAX_DOMAIN_LENGTH,
            "dns_packet_min": DNS_MIN,
            "dns_packet_max": DNS_MAX,
            "health_response_min": HEALTH_MIN,
            "health_response_max": HEALTH_MAX,
            "max_sessions": MAX_SESSIONS,
        },
        "vectors": vectors,
    }


def render(document: dict) -> str:
    return json.dumps(document, indent=2, sort_keys=True) + "\n"


C_HEADER_PATH = ROOT / "core/tests/dbp_vectors_generated.h"


def render_c_header(document: dict) -> str:
    """Same fixture as the JSON, as C arrays, so CTest needs no JSON parser."""
    lines = ["/* Generated by tools/generate_protocol_vectors.py. Do not edit. */",
             "#ifndef DBP_VECTORS_GENERATED_H", "#define DBP_VECTORS_GENERATED_H",
             "#include <stddef.h>", "#include <stdint.h>", "",
             "typedef struct { const char *name; uint8_t message_type; uint64_t client_nonce;",
             "                 uint64_t server_nonce; uint64_t unix_time; const uint8_t *packet;",
             "                 size_t packet_size; } dbp_vector_t;", ""]
    for v in document["vectors"]:
        packet = bytes.fromhex(v["packet_hex"])
        body = ", ".join(f"0x{b:02x}" for b in packet)
        lines.append(f"static const uint8_t dbp_vector_{v['name']}_bytes[] = {{{body}}};")
    lines += ["", "static const dbp_vector_t dbp_vectors[] = {"]
    for v in document["vectors"]:
        lines.append(f'    {{"{v["name"]}", 0x{v["message_type"]:02x}, UINT64_C(0x{v["client_nonce"]}), '
                     f'UINT64_C(0x{v["server_nonce"]}), UINT64_C({v["unix_time"]}), '
                     f'dbp_vector_{v["name"]}_bytes, sizeof dbp_vector_{v["name"]}_bytes}},')
    lines += ["};", "", "#endif"]
    return "\n".join(lines) + "\n"


OUTPUTS = {
    VECTORS_PATH: lambda: render(build_document()),
    C_HEADER_PATH: lambda: render_c_header(build_document()),
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="generate in memory and fail if committed files differ")
    args = parser.parse_args(argv)
    changed = []
    for path, builder in OUTPUTS.items():
        text = builder()
        current = path.read_text() if path.exists() else None
        if args.check:
            if current != text:
                changed.append(path.relative_to(ROOT))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            print(f"wrote {path.relative_to(ROOT)}")
    if changed:
        print("protocol vectors: CHANGED " + ", ".join(map(str, changed)), file=sys.stderr)
        return 1
    if args.check:
        print("protocol vectors: unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
