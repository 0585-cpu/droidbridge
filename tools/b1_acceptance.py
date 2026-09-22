#!/usr/bin/env python3
"""Combine redacted B1 device evidence into the 14-criterion release gate."""
from __future__ import annotations

import json
import sys
from pathlib import Path

try:
    from tools.evidence import write_evidence
except ModuleNotFoundError:  # direct execution: python3 tools/b1_acceptance.py
    from evidence import write_evidence


def _read(directory: Path, name: str) -> dict:
    path = directory / f"{name}.json"
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def evaluate(directory: Path) -> dict:
    preflight = _read(directory, "preflight")
    functional = _read(directory, "functional")
    killswitch = _read(directory, "killswitch")
    security = _read(directory, "security")
    stress = _read(directory, "stress")
    soak = _read(directory, "soak")
    performance = _read(directory, "performance")
    f = functional.get("checks", {})
    s = security.get("checks", {})
    p = preflight.get("checks", {})
    workload = soak.get("workload", {})
    fault_scenarios = killswitch.get("scenarios", {})
    all_faults = all(
        fault_scenarios.get(name, {}).get("passed") is True
        for name in ("usb", "relay", "cellular", "sleep")
    )
    all_recoveries = all(
        fault_scenarios.get(name, {}).get("recoveryPassed") is True
        and str(fault_scenarios.get(name, {}).get("recoveryRouteInterface", "")).startswith("utun")
        for name in ("usb", "relay", "cellular", "sleep")
    )

    criteria = [
        (1, "signed device preflight", bool(preflight.get("passed"))),
        (2, "rootless Android API 26+ app", bool(
            s.get("androidRootless") and p.get("android_api_ge_26", {}).get("passed")
            and p.get("app_installed", {}).get("passed")
        )),
        (3, "DNS HTTPS Git SSH", all(bool(f.get(key)) for key in ("dns", "https", "gitHttps", "sshTcp"))),
        (4, "cellular public exit", bool(f.get("cellularExit"))),
        (5, "Android Wi-Fi does not capture relay", bool(f.get("androidWifiOnCellularExit"))),
        (6, "Mac physical-network isolation", bool(functional.get("macPhysicalIsolation"))),
        (7, "four fail-closed fault scenarios", bool(killswitch.get("passed") and all_faults)),
        (8, "private destination denied", bool(s.get("privateDestinationBlocked"))),
        (9, "unauthenticated relay denied", bool(s.get("unauthenticatedRejected"))),
        (10, "128-flow stress and cleanup", bool(stress.get("passed"))),
        (11, "one-hour integrity DNS plus post-fault reconnects", bool(
            soak.get("passed") and soak.get("dnsHostnameVerified") is True
            and workload.get("dnsChecks", 0) > 0
            and workload.get("tcpConnectionCycles", 0) > 0 and all_recoveries
        )),
        (12, "performance release thresholds", bool(performance.get("passed"))),
        (13, "sensitive logging scan", bool(s.get("loggingScan"))),
        (14, "no tethering or traffic-spoof API", bool(s.get("forbiddenApiScan"))),
    ]
    items = [{"criterion": number, "name": name, "passed": passed}
             for number, name, passed in criteria]
    return {"test": "b1-acceptance", "passed": all(item["passed"] for item in items),
            "criteria": items}


def main(argv: list[str]) -> int:
    directory = Path(argv[1]) if len(argv) > 1 else Path("build/evidence")
    result = evaluate(directory)
    write_evidence(result, directory / "acceptance.json")
    for item in result["criteria"]:
        print(f"[{'PASS' if item['passed'] else 'FAIL'}] {item['criterion']:02d} {item['name']}")
    print("B1 acceptance:", "PASS" if result["passed"] else "FAIL",
          "->", directory / "acceptance.json")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
