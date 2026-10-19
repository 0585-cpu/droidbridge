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
import ipaddress
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

EXTENSION_MESSAGE_TYPES = {
    "CAPABILITIES": 0x32, "CAPABILITIES_RESPONSE": 0x33,
    "OPEN_UDP": 0x40, "OPEN_UDP_OK": 0x41, "OPEN_UDP_ERROR": 0x42, "UDP_CLOSE": 0x43, "OPEN_UDP_ASSOCIATION": 0x44,
    "ICMP_ECHO": 0x60, "ICMP_RESPONSE": 0x61, "ICMP_ERROR": 0x62,
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
    message_type = (MESSAGE_TYPES | EXTENSION_MESSAGE_TYPES)[message]
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
POLICY_PATH = ROOT / "protocol/test-vectors/destination-policy.json"
POLICY_C_PATH = ROOT / "core/tests/policy_cases_generated.h"

# --- destination policy (spec §10). Single source for JSON and C fixture. ----

BLOCKED_CIDRS = [
    ("0.0.0.0/8", "RESERVED"),
    ("10.0.0.0/8", "PRIVATE"),
    ("100.64.0.0/10", "SHARED"),
    ("127.0.0.0/8", "LOOPBACK"),
    ("169.254.0.0/16", "LINK_LOCAL"),
    ("172.16.0.0/12", "PRIVATE"),
    ("192.0.0.0/24", "RESERVED"),
    ("192.0.2.0/24", "DOCUMENTATION"),
    ("192.168.0.0/16", "PRIVATE"),
    ("198.18.0.0/15", "BENCHMARK"),
    ("198.51.100.0/24", "DOCUMENTATION"),
    ("203.0.113.0/24", "DOCUMENTATION"),
    ("224.0.0.0/4", "MULTICAST"),
    ("240.0.0.0/4", "RESERVED"),
]
POLICY_RESULTS = {"ALLOW": 0, "PRIVATE": 1, "SHARED": 2, "LOOPBACK": 3, "LINK_LOCAL": 4,
                  "RESERVED": 5, "DOCUMENTATION": 6, "BENCHMARK": 7, "MULTICAST": 8}


def ip_to_int(address: str) -> int:
    return int.from_bytes(bytes(int(p) for p in address.split(".")), "big")


def int_to_ip(value: int) -> str:
    return ".".join(str(b) for b in value.to_bytes(4, "big"))


def classify(value: int) -> str:
    for cidr, reason in BLOCKED_CIDRS:
        network, bits = cidr.split("/")
        mask = (0xFFFFFFFF << (32 - int(bits))) & 0xFFFFFFFF
        if (value & mask) == ip_to_int(network):
            return reason
    return "ALLOW"


def build_policy_document() -> dict:
    candidates: set[int] = {ip_to_int("93.184.216.34")}
    for cidr, _ in BLOCKED_CIDRS:
        network, bits = cidr.split("/")
        first = ip_to_int(network)
        last = first + (1 << (32 - int(bits))) - 1
        candidates.update(v for v in (first - 1, first, last, last + 1) if 0 <= v <= 0xFFFFFFFF)
    cases = [{"address": int_to_ip(v), "expected": classify(v)} for v in sorted(candidates)]
    return {
        "schema": "destination-policy-v1",
        "blocked_cidrs": [{"cidr": c, "reason": r} for c, r in BLOCKED_CIDRS],
        "results": POLICY_RESULTS,
        "cases": cases,
    }


def render_policy_c_header(document: dict) -> str:
    lines = ["/* Generated by tools/generate_protocol_vectors.py. Do not edit. */",
             "#ifndef POLICY_CASES_GENERATED_H", "#define POLICY_CASES_GENERATED_H",
             "#include <stdint.h>", "",
             "typedef struct { uint8_t ip[4]; int expected; const char *address; } policy_case_generated_t;", "",
             "static const policy_case_generated_t policy_cases_generated[] = {"]
    for case in document["cases"]:
        octets = ", ".join(case["address"].split("."))
        lines.append(f'    {{{{{octets}}}, {POLICY_RESULTS[case["expected"]]}, "{case["address"]}"}},')
    lines += ["};", "", "#endif"]
    return "\n".join(lines) + "\n"


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


def build_extension_document() -> dict:
    ipv6 = ipaddress.ip_address("2606:4700:4700::1111").packed
    prefix = ipaddress.ip_address("64:ff9b::").packed
    caps = struct.pack("!BQQBBBIIIHQB16s", 1, 0x27f, 42, 65, 65, 3, 131072, 262144, 65536, 7, 9, 96, prefix)
    assert len(caps) == 59
    v4 = open_tcp_ipv4("1.1.1.1", 443)
    v6 = struct.pack("!BHB", 2, 443, 16) + ipv6
    echo = b"droidbridge"
    echo4 = bytes([1,1,1,1]) + bytes(12)
    entries = [
        ("capabilities", "CAPABILITIES", b""),
        ("capabilities_response", "CAPABILITIES_RESPONSE", struct.pack("!H",len(caps))+caps),
        ("open_tcp_ipv6", "OPEN_TCP", v6),
        ("open_udp_ipv4", "OPEN_UDP", v4 + struct.pack("!H",120)),
        ("open_udp_ipv6", "OPEN_UDP", v6 + struct.pack("!H",120)),
        ("open_udp_ok", "OPEN_UDP_OK", struct.pack("!IHH",7,120,1472)),
        ("open_udp_error", "OPEN_UDP_ERROR", struct.pack("!HH",14,0)),
        ("udp_close", "UDP_CLOSE", b""),
        ("open_udp_association4", "OPEN_UDP_ASSOCIATION", bytes.fromhex("04000078")),
        ("open_udp_association6", "OPEN_UDP_ASSOCIATION", bytes.fromhex("06000078")),
        ("icmp_echo4", "ICMP_ECHO", struct.pack("!BBHI",4,65,len(echo),7)+echo4+echo),
        ("icmp_echo6", "ICMP_ECHO", struct.pack("!BBHI",6,65,len(echo),8)+ipv6+echo),
        ("icmp_response", "ICMP_RESPONSE", struct.pack("!IBBHQ",7,4,64,len(echo),12345)+echo4+echo),
        ("icmp_error", "ICMP_ERROR", struct.pack("!IH",7,14)),
    ]
    frames = [("empty", b"", 0, 0), ("max_inbound", bytes(range(256))*4+bytes(range(208)), 1, 0xffffffff)]
    return {
        "associations": [
            {"name": "ipv4_outbound", "wire_hex": "000300041234567808ae0000c0000201000000000000000000000000616263"},
            {"name": "ipv6_zero_inbound", "wire_hex": "00000106ffffffff01bb000020010db8000000000000000000000001"},
        ],
        "schema": "dbp-extensions-v1", "header_size": HEADER_SIZE, "secret_hex": SECRET.hex(),
        "vectors": [vector(name, kind, payload, server_nonce=SERVER_NONCE) for name,kind,payload in entries],
        "datagrams": [{"name": name, "payload_hex": payload.hex(), "inbound": bool(flags), "sequence": sequence,
            "wire_hex": (struct.pack("!HBBI",len(payload),flags,0,sequence)+payload).hex()} for name,payload,flags,sequence in frames],
    }


OUTPUTS = {
    ROOT / "protocol/test-vectors/dbp-extensions.json": lambda: render(build_extension_document()),
    ROOT / "macos/Shared/Sources/DroidBridgeShared/Resources/dbp-extensions.json": lambda: render(build_extension_document()),
    ROOT / "core/tests/dbp_extensions_generated.h": lambda: render_c_header(build_extension_document()).replace("DBP_VECTORS", "DBP_EXTENSION_VECTORS").replace("dbp_vector", "dbp_extension_vector"),
    VECTORS_PATH: lambda: render(build_document()),
    C_HEADER_PATH: lambda: render_c_header(build_document()),
    POLICY_PATH: lambda: render(build_policy_document()),
    POLICY_C_PATH: lambda: render_policy_c_header(build_policy_document()),
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
