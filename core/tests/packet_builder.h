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

db_flow_key_t flow_key(const char *src_ip, uint16_t src_port, const char *dst_ip, uint16_t dst_port);
int parse_ipv4(const char *text, uint8_t out[4]);

#endif
