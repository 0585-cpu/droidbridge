# AOA stream framing, version 2

The 16-byte USB frame header remains `DBAM`, version, type, service, reserved,
stream ID (u32 big endian), payload length (u32 big endian). Version is now **2**.
Both Mac and Android apps must be updated together; version 1 is rejected before
dispatch rather than interpreting additive credit as cumulative credit. DBP
authentication inside each logical stream is unchanged.

OPEN, OPEN_OK, DATA, FIN, CLOSE, RESET, RESET_OK, PING and PONG retain their existing
layout. DATA is at most 16,384 bytes. RESET's 16-byte nonce separates sessions;
stream IDs and counters start fresh after RESET. WINDOW (type 6) changes to an
8-byte big-endian cumulative count of bytes consumed by the receiving loopback
socket, in the inclusive range 0 through 2^63-1.

Each direction starts with a 65,536-byte window. A sender tracks total bytes sent
and the largest accepted consumed count. A newer count restores available credit
to `65,536 - (sent - consumed)`. Duplicate and older counts have no effect. Counts
greater than total bytes sent are protocol errors, as are negative signed values.
No credit is returned before the receiving socket consumes DATA.

WINDOW is sent on local consumption and repeated every two seconds for each open
stream with a nonzero consumed count, including idle streams. A later cumulative
count covers lost intermediate updates. Repetition cannot inflate the window.
The usual heartbeat and bounded queue checks remain active.

This change repairs a demonstrated credit leak: stream 2715 on 2026-10-13 had
147,619,246 matching bytes on both sides, Android send credit 0, and Mac receive
credit 65,536 with zero pending writes. The accompanying IPv4 download stalled.
It does **not** retransmit missing DATA or repair arbitrary frame corruption;
the independently recorded raw USB chunk omission remains a separate issue.

Checks cover lost-update refresh on both real loopback bridges, missing multiple
updates, duplicate/stale updates, future-count rejection, 32-bit rollover, literal
Mac/Android wire agreement, version mismatch, bulk data and half-close behavior.


## Reliable physical USB channel (DBR3LINK)

The deployed host and accessory now carry the AOA v2 byte stream inside reliable records. Both applications must be updated together. There is no legacy fallback; a peer without the channel handshake fails with an update-both-apps error. DBP authentication and application TLS remain unchanged. This channel protects against accidental transport loss, not malicious peers.

Each record has an 80-byte header, followed by 0–16384 body bytes. All integers are big-endian; sequence/ACK values are limited to 0…2^63−1.

| Offset | Length | Field |
| --- | --- | --- |
| 0 | 8 | ASCII DBR3LINK |
| 8 | 1 | 1 HELLO, 2 HELLO_ACK, 3 DATA, 4 ACK |
| 9 | 3 | Reserved zero |
| 12 | 4 | Body length |
| 16 | 16 | Random host session epoch |
| 32 | 8 | DATA sequence, starting at 1; controls use 0 |
| 40 | 8 | Last contiguous received DATA sequence; HELLO/HELLO_ACK use 0 |
| 48 | 16 | First 16 bytes of SHA-256(body) |
| 64 | 16 | First 16 bytes of SHA-256(header bytes 0…63) |
| 80 | variable | Body; DATA must be nonempty, controls empty |

The decoder validates the header digest before trusting its length, then validates the body. On damage it scans for the next verified header, retaining at most a maximum record plus one bounded read chunk. It never forwards unverified payload.

Each direction retains at most 32 DATA records (512 KiB). ACKs cumulatively release records; stale/repeated ACKs do not expand capacity and future ACKs fail the session. Only the next contiguous sequence is delivered. Duplicates/gaps repeat the current ACK. Eligible DATA carries the current ACK to avoid starvation by reverse traffic; otherwise the dedicated writer emits a coalesced standalone ACK. The reader never performs a raw write.

Unacknowledged records retry after 500 ms. No ACK progress for 60 seconds fails the session; Android additionally monitors raw write deadlines (also 60 seconds) on a separate thread. The window outlasts observed vendor app freezes (~45 s) with USB attached. Inner AOA heartbeat deadlines are 70 seconds so this bounded recovery can finish first. Writers may pack several queued AOA frames into one record of at most 16,304 bytes; receivers already parse frames as a byte stream. The host retries HELLO until acknowledged. An active Android channel rejects a different epoch and closes before acknowledging it; recovery reopens a fresh descriptor/session. Physical disconnects or a new epoch retire existing network flows. This does not preserve TCP across unplugging.

Validation evidence and remaining device limitations: `docs/superpowers/plans/2026-10-13-reliable-usb.md` and `build/evidence/2026-10-13-window-recovery-device/`.
