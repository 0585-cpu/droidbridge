# Third-Party Notices

## lwIP

DroidBridge's data plane uses lwIP (lightweight IP stack) as a pinned git submodule.

- Upstream: https://github.com/lwip-tcpip/lwip
- Version: STABLE-2_2_1_RELEASE
- Pinned commit: `77dcd25a72509eb83f72b033d219b1d40cd8eb95`
- License: BSD 3-Clause (see `core/third_party/lwip/COPYING`)

lwIP is Copyright (c) 2001-2004 Swedish Institute of Computer Science and
contributors. It is used unmodified; DroidBridge supplies only its own port
(`core/ports/`) and adapter (`core/src/lwip_adapter.c`).
