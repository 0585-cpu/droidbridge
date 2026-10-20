/* lwIP's internal TCP state machine uses IPv4 envelopes. The packet engine
 * validates and restores IPv6 envelopes while preserving TCP stream semantics;
 * no lwIP IPv6 routing, neighbor discovery, or UDP sockets are exposed. */
#ifndef DROIDBRIDGE_LWIPOPTS_H
#define DROIDBRIDGE_LWIPOPTS_H

#define NO_SYS 1
#define SYS_LIGHTWEIGHT_PROT 0
#define LWIP_IPV4 1
#define LWIP_IPV6 0
#define LWIP_TCP 1
#define LWIP_UDP 0
#define LWIP_RAW 0
#define LWIP_ICMP 0
#define LWIP_DHCP 0
#define LWIP_DNS 0
#define LWIP_ARP 0
#define LWIP_ETHERNET 0
#define LWIP_NETIF_STATUS_CALLBACK 1
#define LWIP_NETIF_LINK_CALLBACK 1
#define LWIP_NETCONN 0
#define LWIP_SOCKET 0
#define LWIP_TIMERS 1
#define LWIP_STATS 0

#define MEM_ALIGNMENT 8   /* 64-bit: pbuf/pointer alignment */
#define MEM_SIZE (8 * 1024 * 1024) /* 128 flows x TCP_SND_BUF is 4 MiB; leave room for SYN-ACKs and ACKs */
#define MEMP_NUM_TCP_PCB 320
#define MEMP_NUM_TCP_PCB_LISTEN 260
#define MEMP_NUM_TCP_SEG 512
#define PBUF_POOL_SIZE 512

#define TCP_MSS 1440 /* IPv6 at the 1500-byte tunnel MTU; IPv4 could use 1460 */
#define TCP_WND (32 * 1024)   /* u16 window cap; 64 KiB per-flow app buffer is enforced Swift-side */
#define TCP_SND_BUF (32 * 1024)
#define TCP_SND_QUEUELEN (4 * (TCP_SND_BUF / TCP_MSS))
#define TCP_QUEUE_OOSEQ 1
#define LWIP_TCP_TIMESTAMPS 1

#define CHECKSUM_GEN_IP 1
#define CHECKSUM_GEN_TCP 1
#define CHECKSUM_CHECK_IP 1
#define CHECKSUM_CHECK_TCP 1

#define LWIP_NETIF_TX_SINGLE_PBUF 1
#define LWIP_SINGLE_NETIF 1

#endif
