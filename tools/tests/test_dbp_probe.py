import asyncio
import struct
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dbp_probe import (  # noqa: E402
    AuthenticationError,
    ProtocolError,
    run_probe_dns,
    run_probe_health,
    run_probe_open,
)
from generate_protocol_vectors import (  # noqa: E402
    HEADER_SIZE,
    MESSAGE_TYPES,
    compute_hmac,
    encode_header,
)
from mock_relay import MockRelay  # noqa: E402

SECRET = bytes.fromhex("00" * 31 + "01")


class ProbeIntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.relay = MockRelay(secret=SECRET)
        await self.relay.start("127.0.0.1", 0)

    async def asyncTearDown(self) -> None:
        await self.relay.close()

    async def test_health_round_trip(self) -> None:
        result = await run_probe_health(self.relay.port, self.relay.secret)
        self.assertEqual(result.status, "ok")
        self.assertEqual(result.protocol, "DBP/1")
        self.assertEqual(result.maximum_sessions, 128)

    async def test_wrong_secret_is_rejected(self) -> None:
        with self.assertRaises(AuthenticationError):
            await run_probe_health(self.relay.port, bytes(32))

    async def test_timestamp_skew_is_rejected(self) -> None:
        skewed = int(time.time()) - 121
        with self.assertRaises(AuthenticationError):
            await run_probe_health(self.relay.port, SECRET, unix_time=skewed)
        # 119 seconds is inside the tolerance
        result = await run_probe_health(self.relay.port, SECRET, unix_time=int(time.time()) + 119)
        self.assertEqual(result.status, "ok")

    async def test_repeated_nonce_is_rejected(self) -> None:
        await run_probe_health(self.relay.port, SECRET, client_nonce=42)
        with self.assertRaises(AuthenticationError):
            await run_probe_health(self.relay.port, SECRET, client_nonce=42)

    async def test_open_public_destination(self) -> None:
        result = await run_probe_open(self.relay.port, SECRET, "example.com:443")
        self.assertEqual(result.status, "ok")
        self.assertEqual(result.destination, "example.com:443")
        result = await run_probe_open(self.relay.port, SECRET, "93.184.216.34:443")
        self.assertEqual(result.status, "ok")

    async def test_open_private_destination_is_policy_denied(self) -> None:
        result = await run_probe_open(self.relay.port, SECRET, "10.0.0.1:443")
        self.assertEqual(result.status, "error")
        self.assertEqual(result.error, "POLICY_DENIED")

    async def test_dns_round_trip(self) -> None:
        result = await run_probe_dns(self.relay.port, SECRET, "example.com", "A")
        self.assertEqual(result.status, "ok")
        self.assertEqual(result.answers, ["93.184.216.34"])

    async def _raw(self, payload: bytes) -> bytes:
        reader, writer = await asyncio.open_connection("127.0.0.1", self.relay.port)
        writer.write(payload)
        await writer.drain()
        writer.write_eof()  # nothing more is coming: relay must close, not hang
        try:
            return await asyncio.wait_for(reader.read(HEADER_SIZE), timeout=2)
        finally:
            writer.close()
            await writer.wait_closed()

    async def test_truncated_header_closes_connection(self) -> None:
        self.assertEqual(await self._raw(b"DBP1" + bytes(20)), b"")

    async def test_oversized_dns_payload_is_rejected(self) -> None:
        hello = MESSAGE_TYPES["HELLO"]
        now = int(time.time())
        mac = compute_hmac(hello, 0, 7, 0, now, b"", SECRET)
        reader, writer = await asyncio.open_connection("127.0.0.1", self.relay.port)
        writer.write(encode_header(hello, 0, 7, 0, now, mac))
        await writer.drain()
        hello_ok = await reader.readexactly(HEADER_SIZE)
        self.assertEqual(hello_ok[4], MESSAGE_TYPES["HELLO_OK"])
        server_nonce = struct.unpack("!Q", hello_ok[16:24])[0]
        dns = MESSAGE_TYPES["DNS_QUERY"]
        payload = struct.pack("!H", 4097) + bytes(4097)
        mac = compute_hmac(dns, 0, 7, server_nonce, now, payload, SECRET)
        writer.write(encode_header(dns, 0, 7, server_nonce, now, mac) + payload)
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(HEADER_SIZE), timeout=2), b"")
        writer.close()
        await writer.wait_closed()

    async def test_probe_rejects_bad_server_reply(self) -> None:
        async def garbage(reader, writer):
            writer.write(b"nope" + bytes(60))
            await writer.drain()
            writer.close()

        server = await asyncio.start_server(garbage, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        try:
            with self.assertRaises(ProtocolError):
                await run_probe_health(port, SECRET)
        finally:
            server.close()
            await server.wait_closed()


if __name__ == "__main__":
    unittest.main()
