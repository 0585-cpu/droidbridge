# Parsec transport reliability design

User approved implementing the in-chat USB integrity, UDP source-port sharing, stale-session cleanup, and real-device verification plan on September 30. Existing AOA transport, DBP authentication, pairing, traffic policy, destination policy, bounded recovery, and Stop behavior remain authoritative. This spec makes that approved implementation concrete.

## USB integrity

Reproduce the observed invalid AOA magic without changing live networking. Investigate partial writes, USB request boundaries, buffered reads and descriptor/session lifetime. Add payload-free transfer/frame counters to local diagnostics where needed. Keep strict frame validation and no replay of partial writes. Fix only demonstrated defects; report any unreproduced original trigger honestly. Regression tests must cover the demonstrated failure before the fix.

## UDP association extension

Keep legacy per-destination UDP unchanged for old peers. Advertise capability bit 10 (1024), named UDP_ASSOCIATION. Add authenticated OPEN_UDP_ASSOCIATION message 0x44: four payload bytes, family (4 or 6), reserved zero, idle timeout uint16 big-endian in 30..300. Reply using existing OPEN_UDP_OK/ERROR (maximum payload remains 1232).

One authenticated association byte stream owns one unconnected cellular DatagramSocket, scoped to one tunnel session, IP family, and Mac source UDP port. Each outbound packet specifies its destination. This avoids a global Android socket pool or sharing between authenticated clients. IPv4 and IPv6 associations remain separate. Cellular generation change, Stop, USB teardown, EOF, or idle expiry closes the entire association. Old peers fall back to legacy UDP after capability negotiation.

Association packet format is a 28-byte header followed by 0..1232 payload bytes: uint16 payload length, uint8 direction (0 outbound, 1 inbound), uint8 family (4 or 6), uint32 sequence, uint16 peer port (nonzero), uint16 reserved (zero), 16-byte peer address slot (IPv4 uses first four bytes and twelve zero padding bytes). All integers are big-endian. No domains. Validate before allocation; reject truncated or wrong-direction/family frames. Reuse bounded drop-oldest queues (64 datagrams, 256 KiB maximum) and aggregate traffic shaping. The same real socket serves every destination within the association. TTL/hop policy is applied before traffic.

Android checks the existing destination policy on each outbound endpoint. Track at most 256 permitted outbound peers per association, expire peers after idle timeout, and accept inbound packets only from an unexpired endpoint previously sent to. Unknown inbound traffic is dropped. Register permission before sending; remove permission if initial send fails. Zero-length UDP is supported. Count oversized, unpermitted, and queue drops. Keep total association count bounded by existing UDP slot limit; allocations/open races must close descriptors.

Mac keeps packet-engine UDP flows per full tuple for correct return-packet construction, but groups their relay transport by original source address, port and family. Add an appended optional C callback carrying source port and source address, retaining existing callback fallback. Address bytes are normalized, not compared as text. Route inbound peer-addressed packets to the matching active flow only. Last-flow removal closes the association; generation changes clear all groups. Token/identity checks prevent delayed callbacks from removing replacements. No packet replay across replacement sessions. The C engine continues enforcing MTU and packet size limits; measure actual Parsec drops before changing those limits.

## Acceptance

Meaningful RED/GREEN tests for shared source port to two loopback UDP peers, correct replies, unsolicited third-peer rejection, different source associations, zero datagrams, malformed frames, oversized packets, close/idle/cancellation and stale callback races. Preserve legacy tests. Identical wire fixtures in Kotlin/Swift; C recognizes the new control message. Run core, Android, Shared Swift, USB Swift and helper integration checks, then signed app/APK builds.

Device update requires a verified alternate route before stopping current USB. After update compare one Mac UDP socket against several Parsec STUN endpoints; a cellular NAT may still choose destination-dependent external ports even with one Android socket, so do not promise NAT behavior. Compare Parsec against normal hotspot where available. Validate repeated reconnect and a 30-minute Parsec session with phone video use, collecting UDP drops and USB events. Do not claim completion of unavailable manual/remote-device tests.
