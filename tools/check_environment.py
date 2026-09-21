#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import sys

REQUIRED = {"cmake": (3, 28), "python3": (3, 11)}


def version(command: str) -> tuple[int, int]:
    output = subprocess.check_output([command, "--version"], text=True).splitlines()[0]
    numbers = [int(part) for part in output.replace("Python ", "").split()[-1].split(".")[:2]]
    return numbers[0], numbers[1]


def main() -> int:
    failures: list[str] = []
    for command, minimum in REQUIRED.items():
        path = shutil.which(command)
        if path is None:
            failures.append(f"missing: {command}")
            continue
        actual = version(command)
        if actual < minimum:
            failures.append(f"{command} {actual[0]}.{actual[1]} < {minimum[0]}.{minimum[1]}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("environment: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
