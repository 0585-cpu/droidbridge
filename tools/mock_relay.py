#!/usr/bin/env python3
"""Loopback mock of the Android DBP/1 relay for probe, macOS and Android tests.

Behaviour: authenticates HELLO, enforces replay/timestamp rules, applies the
IPv4 destination policy, echoes raw bytes after OPEN_OK, answers every DNS A
query with 93.184.216.34, and reports READY on HEALTH. It never opens a real
outbound socket.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dbp_wire import (  # noqa: E402
    AuthenticationError,
    NonceCache,
    ProtocolError,
    build_frame,
    read_frame,
)
from generate_protocol_vectors import (  # noqa: E402
    ERROR_CODES,
    HEALTH_STATUS,
    MESSAGE_TYPES,
    classify,
    dns_message,
    dns_response_packet,
    health_response,
    ip_to_int,
    open_error,
)

T = MESSAGE_TYPES


def parse_dns_name(packet: bytes) -> str:
    labels, offset = [], 12
    while True:
        length = packet[offset]
        if length == 0:
            return ".".join(labels)
        labels.append(packet[offset + 1: offset + 1 + length].decode("ascii"))
        offset += 1 + length


class MockRelay:
    def __init__(self, secret: bytes, maximum_sessions: int = 128) -> None:
        self.secret = secret
        self.maximum_sessions = maximum_sessions
        self.port = 0
        self._server: asyncio.AbstractServer | None = None
        self._nonces = NonceCache()
        self._next_server_nonce = 0x1112131415161718
        self.active_sessions = 0

    async def start(self, host: str = "127.0.0.1", port: int = 27183) -> None:
        self._server = await asyncio.start_server(self._handle, host, port)
        self.port = self._server.sockets[0].getsockname()[1]

    async def close(self) -> None:
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()

    async def serve_forever(self) -> None:
        assert self._server is not None
        async with self._server:
            await self._server.serve_forever()

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            await self._session(reader, writer)
        except (ProtocolError, AuthenticationError, asyncio.IncompleteReadError, ConnectionError, TimeoutError):
            pass  # fail closed: silent close, no error detail to the peer
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass

    async def _session(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        # ponytail: single handshake timeout; a real relay also needs idle timeouts on the raw stream
        hello = await asyncio.wait_for(read_frame(reader, self.secret, {T["HELLO"]}), timeout=10)
        if hello.server_nonce != 0 or not self._nonces.check_and_add(hello.client_nonce):
            raise AuthenticationError("replay")
        server_nonce = self._next_server_nonce
        self._next_server_nonce += 1
        client_nonce, now = hello.client_nonce, hello.unix_time

        def send(message: str, payload: bytes = b"") -> None:
            writer.write(build_frame(T[message], client_nonce, server_nonce, now, payload, self.secret))

        send("HELLO_OK")
        await writer.drain()

        request = await read_frame(reader, self.secret, {T["OPEN_TCP"], T["DNS_QUERY"], T["HEALTH"]},
                                   expect_server_nonce=server_nonce)
        if request.client_nonce != client_nonce:
            raise AuthenticationError("client nonce changed")

        if request.message_type == T["HEALTH"]:
            send("HEALTH_RESPONSE", health_response(HEALTH_STATUS["READY"], self.active_sessions,
                                                    self.maximum_sessions, 0, 0, "MockCarrier"))
            await writer.drain()
            return

        if request.message_type == T["DNS_QUERY"]:
            packet = request.payload[2:]
            txid = struct.unpack("!H", packet[:2])[0]
            send("DNS_RESPONSE", dns_message(dns_response_packet(parse_dns_name(packet), "93.184.216.34", txid=txid)))
            await writer.drain()
            return

        # OPEN_TCP: policy check on IPv4; domains resolve to the fixed public address.
        address_type, _port, _length = struct.unpack("!BHB", request.payload[:4])
        if address_type == 1 and classify(ip_to_int(".".join(map(str, request.payload[4:8])))) != "ALLOW":
            send("OPEN_ERROR", open_error(ERROR_CODES["POLICY_DENIED"]))
            await writer.drain()
            return
        if self.active_sessions >= self.maximum_sessions:
            send("OPEN_ERROR", open_error(ERROR_CODES["SESSION_LIMIT"]))
            await writer.drain()
            return
        send("OPEN_OK")
        await writer.drain()
        self.active_sessions += 1
        try:
            while chunk := await reader.read(65536):  # raw stream: echo
                writer.write(chunk)
                await writer.drain()
        finally:
            self.active_sessions -= 1


def secret_from_env() -> bytes:
    value = os.environ.get("DROIDBRIDGE_TEST_SECRET", "")
    try:
        secret = bytes.fromhex(value)
    except ValueError:
        secret = b""
    if len(secret) != 32:
        raise SystemExit("DROIDBRIDGE_TEST_SECRET must be 64 hex characters")
    return secret


async def _main(port: int) -> None:
    relay = MockRelay(secret_from_env())
    await relay.start("127.0.0.1", port)
    print(f"mock relay listening on 127.0.0.1:{relay.port}", flush=True)
    await relay.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=27183)
    try:
        asyncio.run(_main(parser.parse_args().port))
    except KeyboardInterrupt:
        pass
