# UDP, profiles, IPv6 implementation contract

User requested stages 2/3/4 implemented first, with all physical acceptance last. Preserve the current Tetrd/ADB connections. No installation, live USB mode switch, network route change, or real cellular test in this implementation run. This contract supersedes earlier B1/B2 hardware prerequisites and contradictory legacy wire sketches. Base: `692a964` in the existing `codex/aoa-transport` worktree.

## Execution boundaries

Implement against the existing approved UDP/profile/dual-stack designs. Independent ownership after fixing these shared interfaces: Android subtree; C core subtree; coordinator owns Swift/helper/project, protocol fixtures and documentation. Tests first, meaningful packet/socket/policy tests, full integration checks before completion. All physical performance/soak claims remain NOT_RUN. Optional LAN bypass is outside this 2/3/4 request; preserve default fail-closed.

## DBP extensions (network byte order)

Keep all B1 encodings unchanged. New authenticated short-lived CAPABILITIES request `0x32` (empty), response `0x33`: u16 body length followed by exactly 59 bytes for version 1. Query on a separate connection; unsupported old peers return TCP4-only locally, not a changed HEALTH payload.

Body offsets: version u8 @0 (=1); flags u64 @1; cellular generation u64 @9; configured IPv4 TTL u8 @17 (0=OS default); IPv6 Hop Limit u8 @18 (0=default); policy flags u8 @19 (bit0=DNS filter, bit1=shaping); upload bytes/sec u32 @20; download bytes/sec u32 @24; burst bytes u32 @28; active UDP u16 @32; cumulative UDP drops u64 @34; NAT64 prefix length u8 @42 (0=absent); NAT64 address 16 bytes @43 (zero when absent). Unknown versions fail explicitly; bound outer length to 256 before allocation.

Capability bits: TCP4=0, UDP4=1, TCP6=2, UDP6=3, ICMP4_ECHO=4, ICMP6_ECHO=5, NAT64_PREFIX=6, NETWORK_EVENTS=7, UDP_REBIND=8, TRAFFIC_PROFILES=9. Only advertise implemented and currently usable capabilities; no event/rebind flags unless implemented. Network change retires old sockets and new flows can be opened; no seamless QUIC migration claim.

OPEN_TCP remains existing address+port payload; IPv6 adds address type 2 and length16. IPv4 type1/length4 and domain type3 remain. OPEN_UDP `0x40`: same 4-byte prefix (type, port u16, address length) + literal address (type1/4 bytes or type2/16 bytes only) + idle seconds u16 (30..300). OPEN_UDP_OK `0x41`: flow ID u32, effective idle u16, maximum payload u16 (=1232). OPEN_UDP_ERROR `0x42`: error u16, platform category u16. UDP_CLOSE `0x43` empty; after OPEN_UDP_OK, use raw datagram stream and EOF to close (no interleaved DBP headers).

Raw datagram: length u16 (0..1232), flags u8 (0 outbound, 1 inbound; all other bits rejected in v1), reserved u8=0, sequence u32; then exactly length bytes. Sequence wraps and gaps are counted without retransmission. Each direction's queue <=64 datagrams and <=256 KiB, drop oldest. Initial packet must be queued while asynchronous open completes. Idle120s default, max256 UDP, combined max512, maximum packet MTU1280, no fragmentation reassembly. Existing all-port53 DNS interception has priority.

Errors10=UDP_UNSUPPORTED,11=DATAGRAM_TOO_LARGE,12=UDP_IDLE_TIMEOUT,13=UDP_QUEUE_OVERFLOW,14=ADDRESS_FAMILY_UNAVAILABLE. Existing errors1..9 unchanged.

ICMP request `0x60`: family u8 (4/6), requested TTL u8, payload length u16 (0..1200), request ID u32, destination slot16 (v4 first4+zero12), payload. Response `0x61`: request ID u32, family u8, received hop u8 (0=unknown), payload length u16, RTT microseconds u64, source slot16, payload. Error `0x62`: request ID u32, error u16. Use ping datagram sockets through public Android APIs when supported; report unsupported capability explicitly. Policy/cellular binding applies to every socket.

## C / Swift ABI (append, preserve existing callers)

Append to db_engine_config_t:
- `open_flow_ip(context, flow, uint8_t family, const uint8_t *dst, uint16_t port)` for TCP4/6; fallback legacy open_flow for IPv4 callers.
- `open_udp(context, flow, uint8_t family, const uint8_t *dst, uint16_t port)`.
- `send_udp(context, flow, const uint8_t *data, size_t length)` returns void; length0 may have a null pointer.
- `close_udp(context, flow, db_close_reason_t reason)`.
- `send_icmp(context, request, uint8_t family, const uint8_t *dst, uint8_t ttl, const uint8_t *payload, size_t length)`.

New entry points: `db_engine_set_capabilities(engine,uint64_t flags)`, `db_engine_on_udp_data(engine,flow,data,length)`, `db_engine_on_udp_closed(engine,flow)`, `db_engine_on_icmp_response(engine,request,payload,length)` (echo payload only, original packet metadata retained in C), `db_engine_on_icmp_failed(engine,request)`, `db_engine_udp_flow_count(engine)`, `db_engine_udp_drop_count(engine)`. APIs return existing status enum except setter void and counters size_t/uint64_t. Additive `db_engine_set_nat64_prefix(engine,const uint8_t prefix[16],uint8_t length)` status API sets the validated learned prefix (0 clears), before capabilities. Initial flags TCP4 only, until authenticated capability query. C selects family4/6 with dst length4/16, emits complete IP packets. No buffer pointer retained across callbacks. C engine remains serialized. All stale responses target their original engine/session generation.

## Profiles and IPv6

Android settings snapshot at relay start: nullable TTL/HopLimit1..255, DNS suffix filters default empty/off, upload/download rate default0=off, shared direction token buckets with bounded burst. Running settings cannot change. Apply cellular bind then options then connect; explicit option failure closes socket. DNS UDP and TCP fallback obey profile too. UI states actual configured/effective profile and aggregate stats without destinations or payload logs.

IPv6 route captured even when cellular IPv6 unavailable, then dropped fail-closed. IPv6 UDP checksum mandatory, extension parsing bounded4 headers/256 bytes; fragments with MF/offset rejected. Block nonpublic destinations incl mapped IPv4, ULA/link-local/multicast, special documentation/discard/ORCHID, and private embedded IPv4 in allowed NAT64 prefixes. Prefer capability reporting over guessing raw socket support. Gate IPv6 AAAA answers on IPv6 usability. Preserve DBP authentication, cellular-only sockets, pf/configd protections, and MTU1280.
