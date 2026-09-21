"""Shared DBP/1 framing for the probe and mock relay (stdlib only).

Encoding rules come from generate_protocol_vectors.py; this module adds the
reader side: how many payload bytes each message type carries and the checks
both peers apply before trusting a frame.
"""
from __future__ import annotations

import asyncio
import hmac
import struct
import time
from collections import OrderedDict
from dataclasses import dataclass

from generate_protocol_vectors import (
    DNS_MAX,
    DNS_MIN,
    ERROR_CODES,
    HEADER,
    HEADER_SIZE,
    MAGIC,
    MAX_DOMAIN_LENGTH,
    MESSAGE_TYPES,
    compute_hmac,
    encode_header,
)

TIMESTAMP_TOLERANCE = 120
NONCE_WINDOW_SECONDS = 300
NONCE_WINDOW_ENTRIES = 1024
ERROR_NAMES = {v: k for k, v in ERROR_CODES.items()}
TYPE_NAMES = {v: k for k, v in MESSAGE_TYPES.items()}


class ProtocolError(Exception):
    """Malformed or unexpected frame from the peer."""


class AuthenticationError(Exception):
    """Peer closed the connection or rejected our credentials."""


@dataclass
class Frame:
    message_type: int
    client_nonce: int
    server_nonce: int
    unix_time: int
    payload: bytes


def build_frame(message_type: int, client_nonce: int, server_nonce: int,
                unix_time: int, payload: bytes, secret: bytes) -> bytes:
    mac = compute_hmac(message_type, 0, client_nonce, server_nonce, unix_time, payload, secret)
    return encode_header(message_type, 0, client_nonce, server_nonce, unix_time, mac) + payload


async def _read_payload(reader: asyncio.StreamReader, message_type: int) -> bytes:
    """Read exactly the payload the message type declares. Raises ProtocolError."""
    name = TYPE_NAMES[message_type]
    if name in ("HELLO", "HELLO_OK", "OPEN_OK", "HEALTH"):
        return b""
    if name == "OPEN_ERROR":
        return await reader.readexactly(1)
    if name == "OPEN_TCP":
        head = await reader.readexactly(4)
        address_type, _port, length = struct.unpack("!BHB", head)
        if address_type == 1 and length != 4:
            raise ProtocolError("ipv4 length")
        if address_type == 3 and not 1 <= length <= MAX_DOMAIN_LENGTH:
            raise ProtocolError("domain length")
        if address_type not in (1, 3):
            raise ProtocolError("address type")
        return head + await reader.readexactly(length)
    if name in ("DNS_QUERY", "DNS_RESPONSE"):
        head = await reader.readexactly(2)
        (length,) = struct.unpack("!H", head)
        if not DNS_MIN <= length <= DNS_MAX:
            raise ProtocolError("dns length")
        return head + await reader.readexactly(length)
    if name == "HEALTH_RESPONSE":
        head = await reader.readexactly(22)
        return head + await reader.readexactly(head[21])
    raise ProtocolError("unhandled type")


async def read_frame(reader: asyncio.StreamReader, secret: bytes, expected_types: set[int],
                     *, expect_server_nonce: int | None = None) -> Frame:
    """Read one frame, verify structure and HMAC. Payload is never logged."""
    try:
        raw = await reader.readexactly(HEADER_SIZE)
    except asyncio.IncompleteReadError as exc:
        if not exc.partial:
            raise AuthenticationError("connection closed") from None
        raise ProtocolError("truncated header") from None
    magic, message_type, flags, header_length, client_nonce, server_nonce, unix_time, mac = HEADER.unpack(raw)
    if magic != MAGIC:
        raise ProtocolError("bad magic")
    if header_length != HEADER_SIZE:
        raise ProtocolError("bad header length")
    if message_type not in TYPE_NAMES:
        raise ProtocolError("unknown message type")
    if flags != 0:
        raise ProtocolError("flags")
    if message_type not in expected_types:
        raise ProtocolError("unexpected message type")
    try:
        payload = await _read_payload(reader, message_type)
    except asyncio.IncompleteReadError:
        raise ProtocolError("truncated payload") from None
    expected = compute_hmac(message_type, 0, client_nonce, server_nonce, unix_time, payload, secret)
    if not hmac.compare_digest(mac, expected):
        raise AuthenticationError("hmac mismatch")
    if abs(int(time.time()) - unix_time) > TIMESTAMP_TOLERANCE:
        raise AuthenticationError("timestamp skew")
    if expect_server_nonce is not None and server_nonce != expect_server_nonce:
        raise AuthenticationError("server nonce mismatch")
    return Frame(message_type, client_nonce, server_nonce, unix_time, payload)


class NonceCache:
    """Bounded replay cache: newest 1024 nonces, each kept for 5 minutes."""

    def __init__(self) -> None:
        self._seen: OrderedDict[int, float] = OrderedDict()

    def check_and_add(self, nonce: int, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        while self._seen and next(iter(self._seen.values())) < now - NONCE_WINDOW_SECONDS:
            self._seen.popitem(last=False)
        if nonce in self._seen:
            return False
        self._seen[nonce] = now
        while len(self._seen) > NONCE_WINDOW_ENTRIES:
            self._seen.popitem(last=False)
        return True
