#ifndef DB_PACKET_BUILDER_H
#define DB_PACKET_BUILDER_H

#include <stddef.h>
#include <stdint.h>
#include "droidbridge_packet.h"

/* Builds a complete IPv4+TCP packet with valid checksums. Returns total length, or 0 on error. */
size_t build_tcp_packet(uint8_t *out, size_t capacity,
                        const char *src_ip, uint16_t src_port,
                        const char *dst_ip, uint16_t dst_port,
                        uint8_t flags, const uint8_t *payload, size_t payload_length);

/* Full variant that sets seq/ack (needed to build valid handshake ACKs). */
size_t build_tcp_packet_full(uint8_t *out, size_t capacity,
                             const char *src_ip, uint16_t src_port,
                             const char *dst_ip, uint16_t dst_port,
                             uint8_t flags, uint32_t seq, uint32_t ack,
                             const uint8_t *payload, size_t payload_length);

/* Builds an IPv4/UDP DNS query packet. Returns total length. */
size_t build_udp_dns_query(uint8_t *out, size_t capacity, const char *src_ip, uint16_t src_port,
                           const char *dst_ip, uint16_t dst_port, uint16_t txid, const char *qname);

db_flow_key_t flow_key(const char *src_ip, uint16_t src_port, const char *dst_ip, uint16_t dst_port);
int parse_ipv4(const char *text, uint8_t out[4]);

#endif
