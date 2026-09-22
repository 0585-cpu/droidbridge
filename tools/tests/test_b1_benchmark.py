import unittest

from tools.b1_benchmark import (
    _handle_client,
    deterministic_bytes,
    download,
    parse_duration,
    percentile,
    ping_series,
    stress,
)


class B1BenchmarkUnitTest(unittest.TestCase):
    def test_duration_parser(self) -> None:
        self.assertEqual(parse_duration("90s"), 90)
        self.assertEqual(parse_duration("15m"), 900)
        self.assertEqual(parse_duration("1h"), 3600)
        with self.assertRaises(ValueError):
            parse_duration("0m")

    def test_deterministic_download_stream_is_chunk_independent(self) -> None:
        whole = deterministic_bytes(7, 0, 100)
        split = deterministic_bytes(7, 0, 37) + deterministic_bytes(7, 37, 63)
        self.assertEqual(whole, split)
        self.assertNotEqual(whole, deterministic_bytes(8, 0, 100))

    def test_percentile_uses_nearest_rank(self) -> None:
        self.assertEqual(percentile([1.0, 2.0, 3.0, 4.0], 50), 2.0)
        self.assertEqual(percentile([1.0, 2.0, 3.0, 4.0], 95), 4.0)


class B1BenchmarkProtocolTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        import asyncio

        self.server = await asyncio.start_server(_handle_client, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]

    async def asyncTearDown(self) -> None:
        self.server.close()
        await self.server.wait_closed()

    async def test_ping_download_and_concurrent_echo(self) -> None:
        ping = await ping_series("127.0.0.1", self.port, samples=3, warmups=1)
        self.assertGreaterEqual(ping["medianRttMs"], 0)
        transfer = await download("127.0.0.1", self.port, 100_000)
        self.assertTrue(transfer["integrityVerified"])
        self.assertEqual(transfer["bytes"], 100_000)
        flows = await stress("127.0.0.1", self.port, 8, 1024, 0)
        self.assertTrue(flows["passed"])


if __name__ == "__main__":
    unittest.main()
