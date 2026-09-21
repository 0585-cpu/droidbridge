#!/usr/bin/env python3
"""DBP/1 wire-compatibility probe. Standard library only.

Prints status, destination and latency. Never prints the secret, DNS packets or
application payload.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import secrets
import struct
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dbp_wire import (  # noqa: E402
    ERROR_NAMES,
    AuthenticationError,
    ProtocolError,
    build_frame,
    read_frame,
)
from generate_protocol_vectors import (  # noqa: E402
    HEALTH_STATUS,
    MESSAGE_TYPES,
    dns_message,
    dns_query_packet,
    open_tcp_domain,
    open_tcp_ipv4,
)

T = MESSAGE_TYPES
STATUS_NAMES = {v: k for k, v in HEALTH_STATUS.items()}
QTYPES = {"A": 1, "AAAA": 28, "CNAME": 5, "TXT": 16}


@dataclass
class HealthResult:
    status: str
    protocol: str
    relay_status: str
    active_sessions: int
    maximum_sessions: int
    uploaded_bytes: int
    downloaded_bytes: int
    carrier: str
    latency_ms: float


@dataclass
class OpenResult:
    status: str
    destination: str
    latency_ms: float
    error: str | None = None


@dataclass
class DnsResult:
    status: str
    name: str
    rcode: int
    answers: list[str] = field(default_factory=list)
    latency_ms: float = 0.0


class _Session:
    def __init__(self, host: str, port: int, secret: bytes,
                 client_nonce: int | None, unix_time: int | None) -> None:
        self.host, self.port, self.secret = host, port, secret
        self.client_nonce = secrets.randbits(64) if client_nonce is None else client_nonce
        self.unix_time = int(time.time()) if unix_time is None else unix_time
        self.server_nonce = 0

    async def __aenter__(self) -> "_Session":
        self.reader, self.writer = await asyncio.open_connection(self.host, self.port)
        self.started = time.perf_counter()
        try:
            self.send("HELLO")
            await self.writer.drain()
            hello_ok = await self.recv({T["HELLO_OK"]})
            if hello_ok.client_nonce != self.client_nonce:
                raise AuthenticationError("client nonce mismatch")
        except BaseException:
            await self.__aexit__()  # __aexit__ does not run when __aenter__ raises
            raise
        self.server_nonce = hello_ok.server_nonce
        return self

    async def __aexit__(self, *_exc) -> None:
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except ConnectionError:
            pass

    def send(self, message: str, payload: bytes = b"") -> None:
        self.writer.write(build_frame(T[message], self.client_nonce, self.server_nonce,
                                      self.unix_time, payload, self.secret))

    async def recv(self, expected: set[int]):
        return await asyncio.wait_for(
            read_frame(self.reader, self.secret, expected, expect_server_nonce=self.server_nonce or None),
            timeout=5)

    @property
    def latency_ms(self) -> float:
        return round((time.perf_counter() - self.started) * 1000, 2)


async def run_probe_health(port: int, secret: bytes, host: str = "127.0.0.1", *,
                           client_nonce: int | None = None, unix_time: int | None = None) -> HealthResult:
    async with _Session(host, port, secret, client_nonce, unix_time) as s:
        s.send("HEALTH")
        await s.writer.drain()
        frame = await s.recv({T["HEALTH_RESPONSE"]})
        status, active, maximum, up, down, name_len = struct.unpack("!BHHQQB", frame.payload[:22])
        if status not in STATUS_NAMES or active > maximum or maximum > 256:
            raise ProtocolError("invalid health response")
        try:
            carrier = frame.payload[22:22 + name_len].decode("utf-8")
        except UnicodeDecodeError:
            raise ProtocolError("carrier name not utf-8") from None
        return HealthResult("ok" if status == HEALTH_STATUS["READY"] else "degraded", "DBP/1",
                            STATUS_NAMES[status], active, maximum, up, down, carrier, s.latency_ms)


def parse_destination(destination: str) -> bytes:
    host, _, port_text = destination.rpartition(":")
    port = int(port_text)
    parts = host.split(".")
    if len(parts) == 4 and all(p.isdigit() and 0 <= int(p) <= 255 for p in parts):
        return open_tcp_ipv4(host, port)
    return open_tcp_domain(host, port)


async def run_probe_open(port: int, secret: bytes, destination: str, host: str = "127.0.0.1", *,
                         client_nonce: int | None = None, unix_time: int | None = None) -> OpenResult:
    payload = parse_destination(destination)
    async with _Session(host, port, secret, client_nonce, unix_time) as s:
        s.send("OPEN_TCP", payload)
        await s.writer.drain()
        frame = await s.recv({T["OPEN_OK"], T["OPEN_ERROR"]})
        if frame.message_type == T["OPEN_OK"]:
            return OpenResult("ok", destination, s.latency_ms)
        code = frame.payload[0]
        if code not in ERROR_NAMES:
            raise ProtocolError("unknown error code")
        return OpenResult("error", destination, s.latency_ms, ERROR_NAMES[code])


def parse_dns_answers(packet: bytes) -> tuple[int, list[str]]:
    """Minimal parser: rcode and A/AAAA answer addresses. Skips other RR types."""
    rcode = packet[3] & 0x0F
    qd, an = struct.unpack("!HH", packet[4:8])
    offset = 12

    def skip_name(pos: int) -> int:
        while True:
            length = packet[pos]
            if length == 0:
                return pos + 1
            if length & 0xC0 == 0xC0:
                return pos + 2
            pos += 1 + length

    for _ in range(qd):
        offset = skip_name(offset) + 4
    answers = []
    for _ in range(an):
        offset = skip_name(offset)
        rtype, _rclass, _ttl, rdlength = struct.unpack("!HHIH", packet[offset:offset + 10])
        offset += 10
        rdata = packet[offset:offset + rdlength]
        offset += rdlength
        if rtype == 1 and rdlength == 4:
            answers.append(".".join(map(str, rdata)))
        elif rtype == 28 and rdlength == 16:
            answers.append(":".join(f"{rdata[i] << 8 | rdata[i + 1]:x}" for i in range(0, 16, 2)))
    return rcode, answers


async def run_probe_dns(port: int, secret: bytes, name: str, qtype: str = "A", host: str = "127.0.0.1", *,
                        client_nonce: int | None = None, unix_time: int | None = None) -> DnsResult:
    txid = secrets.randbits(16)
    query = dns_query_packet(name, QTYPES[qtype.upper()], txid)
    async with _Session(host, port, secret, client_nonce, unix_time) as s:
        s.send("DNS_QUERY", dns_message(query))
        await s.writer.drain()
        frame = await s.recv({T["DNS_RESPONSE"]})
        packet = frame.payload[2:]
        if struct.unpack("!H", packet[:2])[0] != txid:
            raise ProtocolError("dns transaction id mismatch")
        rcode, answers = parse_dns_answers(packet)
        return DnsResult("ok" if rcode == 0 else "error", name, rcode, answers, s.latency_ms)


def secret_from_env() -> bytes:
    try:
        secret = bytes.fromhex(os.environ.get("DROIDBRIDGE_TEST_SECRET", ""))
    except ValueError:
        secret = b""
    if len(secret) != 32:
        raise SystemExit("DROIDBRIDGE_TEST_SECRET must be 64 hex characters")
    return secret


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--host", default="127.0.0.1")
    common.add_argument("--port", type=int, default=27183)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("health", parents=[common])
    sub.add_parser("open", parents=[common]).add_argument("--destination", required=True,
                                                          help="host:port or a.b.c.d:port")
    dns = sub.add_parser("dns", parents=[common])
    dns.add_argument("--name", required=True)
    dns.add_argument("--type", default="A", choices=sorted(QTYPES))
    args = parser.parse_args(argv)
    secret = secret_from_env()

    try:
        if args.command == "health":
            r = asyncio.run(run_probe_health(args.port, secret, args.host))
            print(f"status={r.status} protocol={r.protocol} relay={r.relay_status} "
                  f"sessions={r.active_sessions}/{r.maximum_sessions} latency_ms={r.latency_ms}")
            return 0 if r.status == "ok" else 2
        if args.command == "open":
            r = asyncio.run(run_probe_open(args.port, secret, args.destination, args.host))
            suffix = f" error={r.error}" if r.error else ""
            print(f"status={r.status} destination={r.destination} latency_ms={r.latency_ms}{suffix}")
            return 0 if r.status == "ok" else 2
        r = asyncio.run(run_probe_dns(args.port, secret, args.name, args.type, args.host))
        print(f"status={r.status} name={r.name} rcode={r.rcode} answers={','.join(r.answers) or '-'} "
              f"latency_ms={r.latency_ms}")
        return 0 if r.status == "ok" else 2
    except AuthenticationError as exc:
        print(f"status=auth_failed reason={exc}", file=sys.stderr)
        return 3
    except (ProtocolError, asyncio.TimeoutError, ConnectionError) as exc:
        print(f"status=protocol_error reason={exc}", file=sys.stderr)
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
