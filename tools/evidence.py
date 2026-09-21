"""Redacted evidence writer for B1 acceptance scripts.

Evidence JSON may hold only environment/version/check facts: no secrets, no
payloads, no DNS names, no URLs. Any key matching a sensitive term (case
-insensitive substring) fails the write closed, so a careless caller cannot
leak material into build/evidence/.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

__all__ = ["SensitiveEvidenceError", "write_evidence", "SENSITIVE_TERMS"]

# Case-insensitive substrings that must never appear as a key.
SENSITIVE_TERMS = (
    "secret", "token", "password", "payload", "cookie",
    "authorization", "sni", "dnsname", "url",
)

_ALLOWED_SCALARS = (str, bool, int, float, type(None))


class SensitiveEvidenceError(ValueError):
    """Raised when an evidence key looks like it carries sensitive material."""


def _check(value: Any, path: str) -> None:
    if isinstance(value, dict):
        for key, sub in value.items():
            if not isinstance(key, str):
                raise TypeError(f"{path}: non-string key {key!r}")
            low = key.lower()
            if any(term in low for term in SENSITIVE_TERMS):
                raise SensitiveEvidenceError(f"{path}.{key}: sensitive key")
            _check(sub, f"{path}.{key}")
    elif isinstance(value, (list, tuple)):
        for i, sub in enumerate(value):
            _check(sub, f"{path}[{i}]")
    elif not isinstance(value, _ALLOWED_SCALARS):
        raise TypeError(f"{path}: unsupported value type {type(value).__name__}")


def write_evidence(data: dict, path: str | Path) -> None:
    """Validate then write evidence JSON atomically. Raises before any write."""
    if not isinstance(data, dict):
        raise TypeError("evidence root must be a dict")
    _check(data, "$")
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


if __name__ == "__main__":  # pragma: no cover - self-check
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "e.json"
        write_evidence({"test": "x", "passed": True, "metrics": {"bytes": 1}}, p)
        assert json.loads(p.read_text())["passed"] is True
        for bad in ({"apiToken": "x"}, {"n": {"cookieJar": 1}}):
            try:
                write_evidence(bad, p)
            except SensitiveEvidenceError:
                pass
            else:
                raise AssertionError(f"should have rejected {bad}")
    print("evidence self-check ok")
