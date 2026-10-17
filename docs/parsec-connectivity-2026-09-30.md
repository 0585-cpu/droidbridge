# Parsec connection inspection — September 30, 2026

The user reported that Parsec could no longer connect and confirmed that the
same remote PC had worked earlier that day through DroidBridge. All times below
are KST. This inspection did not change either app, network configuration, or
Parsec settings, and did not initiate remote control of the host.

## Evidence

- Mac's active default route remained `utun5` through DroidBridge. A fresh HTTPS
  request succeeded (204, 488 ms); this proves reachability, not available
  streaming bandwidth.
- Android recorded `invalid AOA magic` at 15:26:43.203 and reopened its USB
  accessory at 15:26:44.211. Mac's heartbeat expired at 15:26:51.718; its first
  automatic retry restored the USB session at 15:26:52.840 and requested an
  authenticated relay health check. These logs establish recovery of the USB
  session, not preservation of old streams or the exact internet recovery time.
- Parsec's WebSocket reset occurred at 15:26:45. Its log later recorded network
  disconnect `-12007` at 15:27:43. A new session reached client status 0 and BUD
  transport setup at 15:28:27 but ended with `-12007` at 15:29:27.
- The latest two attempts received STUN replies at 15:32:07 and 15:32:31, then
  failed with `-6023 / -11011` at 15:32:15 and 15:32:39. Successful STUN replies
  rule out blanket UDP blocking; they do not prove peer-to-peer reachability.
- A low-volume STUN binding probe sent requests from one unconnected Mac UDP
  socket to three IPv4 endpoints returned by `stun.parsec.app`, then repeated
  the first endpoint. All four succeeded in 233–275 ms. Local source port stayed
  63922. The externally observed ports were 44055, 39587, 52510, then 44055;
  the public address stayed the same. No throughput benchmark was performed.

## Interpretation

There are two observed failure modes: an actual DroidBridge USB session loss,
and subsequent Parsec peer-to-peer negotiation failures. Low bandwidth may affect
streaming, but it does not by itself explain these findings.

The STUN probe proves destination-dependent UDP mapping on the current path.
Source inspection confirms that `core/src/packet_engine.c` assigns flows by full
source/destination tuple and passes only destination and flow ID to `open_udp`.
`CellularNetworkController.connectUdp` creates and connects a separate Android
DatagramSocket for each destination. This does not preserve one external UDP
source endpoint when an application uses one Mac socket for STUN and its peer.
It can make UDP hole punching harder, although a sufficiently reachable peer
can still allow connection. The successful earlier sessions mean this behavior
must not be presented as an unconditional Parsec incompatibility or the proven
sole cause of the latest failure. Carrier NAT and the remote host's network
remain unmeasured. The initial AOA corruption cause also remains unresolved.

Parsec documents -6023 as peer-to-peer negotiation failure, and -11011 as a hint
about UPnP being disabled or unavailable. It does not prove that toggling UPnP on
the Mac would fix this cellular relay path. No explicit relevant network/UPnP
override was found in the local text/JSON configuration files inspected.

## Next discriminating checks

Compare the same remote PC over ordinary hotspot or independent Wi-Fi once an
alternate path is available. If the failure is specific to DroidBridge, reproduce
peer traffic using a controlled endpoint before changing UDP source-port mapping,
peer filtering, or protocol fields. Continue investigating AOA corruption as a
separate fault. Reconnection alone cannot preserve existing TCP/UDP sessions.

Evidence is local in `build/evidence/2026-09-30-parsec/`, including a sanitized
Parsec log excerpt, USB logs, and STUN mapping results.

Official references:

- [Parsec connectivity requirements](https://support.parsec.app/hc/en-us/articles/32381460716180-Parsec-Connectivity-Requirements)
- [Parsec errors -6023 and -6024](https://support.parsec.app/hc/en-us/articles/32381913636244-Error-Codes-6023-and-6024-Unable-To-Negotiate-A-Successful-Connection)
- [Parsec error -12007](https://support.parsec.app/hc/en-us/articles/32361439718804-Error-Codes-12007-The-Network-Connection-On-Your-Client-Computer-Was-Cutoff)
