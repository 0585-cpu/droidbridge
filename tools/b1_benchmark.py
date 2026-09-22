#!/usr/bin/env python3
"""Deterministic, payload-free B1 benchmark client/server.

The operator runs ``server`` on a public host they control. Clients emit only
aggregate JSON; endpoint names and transferred bytes are never logged.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import math
import os
import re
import struct
import time
from collections.abc import Sequence

MAGIC = b"DBB1"
PING = 1
DOWNLOAD = 2
ECHO = 3
HEADER = struct.Struct("!4sBQQ")
MAX_TRANSFER = 2 * 1024 * 1024 * 1024
CHUNK = 64 * 1024


def parse_duration(value: str) -> int:
    match = re.fullmatch(r"([1-9][0-9]*)([smh])", value)
    if not match:
        raise ValueError("duration must be a positive integer followed by s, m, or h")
    amount = int(match.group(1))
    return amount * {"s": 1, "m": 60, "h": 3600}[match.group(2)]


def percentile(values: Sequence[float], percent: int) -> float:
    if not values or not 1 <= percent <= 100:
        raise ValueError("non-empty values and percentile 1...100 required")
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * percent / 100) - 1)]


def deterministic_bytes(nonce: int, offset: int, count: int) -> bytes:
    """Return a reproducible slice without retaining transferred content."""
    if offset < 0 or count < 0:
        raise ValueError("negative range")
    pattern = hashlib.shake_256(nonce.to_bytes(8, "big")).digest(4096)
    start = offset % len(pattern)
    repetitions = (start + count + len(pattern) - 1) // len(pattern)
    return (pattern * repetitions)[start : start + count]


async def _read_request(reader: asyncio.StreamReader) -> tuple[int, int, int] | None:
    try:
        raw = await reader.readexactly(HEADER.size)
    except asyncio.IncompleteReadError as error:
        if not error.partial:
            return None
        raise
    magic, operation, count, nonce = HEADER.unpack(raw)
    if magic != MAGIC or operation not in (PING, DOWNLOAD, ECHO) or count > MAX_TRANSFER:
        raise ValueError("invalid request")
    if operation == PING and count != 0:
        raise ValueError("PING count must be zero")
    return operation, count, nonce


async def _handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while request := await asyncio.wait_for(_read_request(reader), timeout=30):
            operation, count, nonce = request
            writer.write(HEADER.pack(MAGIC, operation, count, nonce))
            if operation == ECHO:
                remaining = count
                while remaining:
                    block = await reader.readexactly(min(CHUNK, remaining))
                    writer.write(block)
                    remaining -= len(block)
            elif operation == DOWNLOAD:
                offset = 0
                while offset < count:
                    size = min(CHUNK, count - offset)
                    writer.write(deterministic_bytes(nonce, offset, size))
                    offset += size
                    if writer.transport.get_write_buffer_size() >= 4 * CHUNK:
                        await writer.drain()
            await writer.drain()
    except (asyncio.IncompleteReadError, asyncio.TimeoutError, ConnectionError, ValueError):
        pass
    finally:
        writer.close()
        await writer.wait_closed()


async def serve(bind: str, port: int) -> None:
    server = await asyncio.start_server(_handle_client, bind, port, limit=2 * CHUNK)
    async with server:
        await server.serve_forever()


async def _open(host: str, port: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    return await asyncio.wait_for(asyncio.open_connection(host, port, limit=2 * CHUNK), timeout=10)


async def ping_series(host: str, port: int, samples: int = 30, warmups: int = 5) -> dict[str, float]:
    reader, writer = await _open(host, port)
    values: list[float] = []
    try:
        for index in range(samples + warmups):
            nonce = int.from_bytes(os.urandom(8), "big")
            request = HEADER.pack(MAGIC, PING, 0, nonce)
            started = time.perf_counter()
            writer.write(request)
            await writer.drain()
            response = await asyncio.wait_for(reader.readexactly(HEADER.size), timeout=10)
            elapsed = (time.perf_counter() - started) * 1000
            if response != request:
                raise RuntimeError("PING response mismatch")
            if index >= warmups:
                values.append(elapsed)
    finally:
        writer.close()
        await writer.wait_closed()
    return {
        "medianRttMs": round(percentile(values, 50), 3),
        "p95RttMs": round(percentile(values, 95), 3),
    }


async def download(host: str, port: int, count: int) -> dict[str, float | int | bool]:
    if not 0 < count <= MAX_TRANSFER:
        raise ValueError("download size out of range")
    reader, writer = await _open(host, port)
    nonce = int.from_bytes(os.urandom(8), "big")
    request = HEADER.pack(MAGIC, DOWNLOAD, count, nonce)
    started = time.perf_counter()
    verified = True
    received = 0
    try:
        writer.write(request)
        await writer.drain()
        if await asyncio.wait_for(reader.readexactly(HEADER.size), timeout=10) != request:
            raise RuntimeError("DOWNLOAD response mismatch")
        while received < count:
            block = await asyncio.wait_for(reader.readexactly(min(CHUNK, count - received)), timeout=30)
            verified = verified and block == deterministic_bytes(nonce, received, len(block))
            received += len(block)
    finally:
        writer.close()
        await writer.wait_closed()
    seconds = time.perf_counter() - started
    return {
        "bytes": received,
        "seconds": round(seconds, 3),
        "throughputMbps": round(received * 8 / seconds / 1_000_000, 3),
        "integrityVerified": verified,
    }


async def _echo_flow(host: str, port: int, count: int, hold: float) -> float:
    reader, writer = await _open(host, port)
    nonce = int.from_bytes(os.urandom(8), "big")
    body = deterministic_bytes(nonce, 0, count)
    request = HEADER.pack(MAGIC, ECHO, count, nonce)
    started = time.perf_counter()
    try:
        writer.write(request + body)
        await writer.drain()
        if await asyncio.wait_for(reader.readexactly(HEADER.size), timeout=10) != request:
            raise RuntimeError("ECHO response mismatch")
        if await asyncio.wait_for(reader.readexactly(count), timeout=10) != body:
            raise RuntimeError("ECHO body mismatch")
        await asyncio.sleep(hold)
        return (time.perf_counter() - started) * 1000
    finally:
        writer.close()
        await writer.wait_closed()


async def stress(host: str, port: int, flows: int, count: int, hold: float) -> dict[str, float | int | bool]:
    results = await asyncio.gather(
        *(_echo_flow(host, port, count, hold) for _ in range(flows)),
        return_exceptions=True,
    )
    failures = sum(isinstance(item, BaseException) for item in results)
    timings = [item for item in results if isinstance(item, float)]
    return {
        "requestedFlows": flows,
        "successfulFlows": len(timings),
        "failedFlows": failures,
        "p95FlowMs": round(percentile(timings, 95), 3) if timings else 0,
        "passed": failures == 0 and len(timings) == flows,
    }


async def soak(host: str, port: int, duration: int) -> dict[str, int | bool | float]:
    started = time.monotonic()
    next_stress = started
    operations = failures = bursts = 0
    max_rtt = 0.0
    while time.monotonic() - started < duration:
        try:
            ping = await ping_series(host, port, samples=10, warmups=1)
            max_rtt = max(max_rtt, ping["p95RttMs"])
            operations += 10
            for _ in range(4):
                await _echo_flow(host, port, 4096, 0)
                operations += 1
            await download(host, port, 8 * 1024 * 1024)
            operations += 1
            if time.monotonic() >= next_stress:
                result = await stress(host, port, 128, 4096, 1)
                operations += 128
                failures += int(result["failedFlows"])
                bursts += 1
                next_stress = time.monotonic() + 15 * 60
        except Exception:
            failures += 1
        remaining = duration - (time.monotonic() - started)
        if remaining > 0:
            await asyncio.sleep(min(30, remaining))
    elapsed = time.monotonic() - started
    return {
        "durationSeconds": round(elapsed, 3),
        "operations": operations,
        "failures": failures,
        "stressBursts": bursts,
        "maxP95RttMs": round(max_rtt, 3),
        "passed": failures == 0 and elapsed >= duration,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    server = sub.add_parser("server")
    server.add_argument("--bind", default="0.0.0.0")
    server.add_argument("--port", type=int, required=True)
    for name in ("performance", "download", "stress", "soak"):
        command = sub.add_parser(name)
        command.add_argument("--host", required=True)
        command.add_argument("--port", type=int, required=True)
        if name in ("performance", "download"):
            command.add_argument("--bytes", type=int, default=512 * 1024 * 1024)
        if name == "stress":
            command.add_argument("--flows", type=int, default=128)
            command.add_argument("--echo-bytes", type=int, default=4096)
            command.add_argument("--hold-seconds", type=float, default=10)
        if name == "soak":
            command.add_argument("--duration", default="60m")
    return parser


async def _main(args: argparse.Namespace) -> None:
    if args.command == "server":
        await serve(args.bind, args.port)
        return
    if args.command == "performance":
        result = await ping_series(args.host, args.port)
        result.update(await download(args.host, args.port, args.bytes))
    elif args.command == "download":
        result = await download(args.host, args.port, args.bytes)
    elif args.command == "stress":
        result = await stress(args.host, args.port, args.flows, args.echo_bytes, args.hold_seconds)
    else:
        result = await soak(args.host, args.port, parse_duration(args.duration))
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    asyncio.run(_main(_parser().parse_args()))
