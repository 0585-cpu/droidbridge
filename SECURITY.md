# Security Policy

DroidBridge routes all of a Mac's traffic through an Android device's cellular
connection. Bugs in authentication, destination policy, or fail-closed behavior
can leak traffic or expose the phone's internal network. Please report them
privately.

## Reporting

- Do **not** open a public issue for a suspected vulnerability.
- Use GitHub private vulnerability reporting on this repository, or email the
  maintainers listed in `README.md` with the subject `DroidBridge security`.
- Include: affected component (core / Android relay / macOS host / Packet
  Tunnel), reproduction steps, and impact (leak, bypass, crash, replay).
- Never include Pairing Secrets, packet payloads, DNS names, or URLs from a real
  session in a report. Use the documented all-zero test fixture secret instead.

## Response

- Acknowledgement within 3 business days.
- Fix or mitigation target: 30 days for policy/fail-closed bypasses, 90 days
  otherwise.
- Fixed versions are noted in the release manifest and tagged.

## Scope

In scope: DBP/1 parsing and HMAC handling, destination policy, fail-closed
routing, ADB forwarding setup, secret storage.

Out of scope: rooted Android devices, macOS kernel extensions, and carrier
policy circumvention (TTL/APN/DUN changes are intentionally unsupported).
