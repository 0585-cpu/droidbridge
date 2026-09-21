#include "packet_builder.h"

#include <stdio.h>
#include <string.h>

int parse_ipv4(const char *text, uint8_t out[4]) {
    unsigned a, b, c, d;
    if (sscanf(text, "%u.%u.%u.%u", &a, &b, &c, &d) != 4) return -1;
    out[0] = (uint8_t)a; out[1] = (uint8_t)b; out[2] = (uint8_t)c; out[3] = (uint8_t)d;
    return 0;
}

static void write_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }

db_flow_key_t flow_key(const char *src_ip, uint16_t src_port, const char *dst_ip, uint16_t dst_port) {
    db_flow_key_t key;
    memset(&key, 0, sizeof key);
    parse_ipv4(src_ip, key.src_ip);
    parse_ipv4(dst_ip, key.dst_ip);
    key.src_port = src_port;
    key.dst_port = dst_port;
    return key;
}

static void write_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}

size_t build_tcp_packet_full(uint8_t *out, size_t capacity,
                             const char *src_ip, uint16_t src_port,
                             const char *dst_ip, uint16_t dst_port,
                             uint8_t flags, uint32_t seq, uint32_t ack,
                             const uint8_t *payload, size_t payload_length) {
    size_t total = 40 + payload_length;
    if (total > capacity) return 0;
    memset(out, 0, total);
    out[0] = 0x45;
    write_u16(out + 2, (uint16_t)total);
    out[8] = 64;
    out[9] = DB_IPPROTO_TCP;
    if (parse_ipv4(src_ip, out + 12) != 0) return 0;
    if (parse_ipv4(dst_ip, out + 16) != 0) return 0;
    write_u16(out + 10, db_ipv4_header_checksum(out, 20));

    uint8_t *tcp = out + 20;
    write_u16(tcp + 0, src_port);
    write_u16(tcp + 2, dst_port);
    write_u32(tcp + 4, seq);
    write_u32(tcp + 8, ack);
    tcp[12] = 5 << 4;
    tcp[13] = flags;
    write_u16(tcp + 14, 0xFFFF);
    if (payload_length > 0 && payload != NULL) memcpy(tcp + 20, payload, payload_length);

    db_ipv4_view_t ip;
    if (db_ipv4_parse(out, total, &ip) != DB_PACKET_OK) return 0;
    write_u16(tcp + 16, db_tcp_checksum(out, &ip));
    return total;
}

size_t build_tcp_packet(uint8_t *out, size_t capacity,
                        const char *src_ip, uint16_t src_port,
                        const char *dst_ip, uint16_t dst_port,
                        uint8_t flags, const uint8_t *payload, size_t payload_length) {
    return build_tcp_packet_full(out, capacity, src_ip, src_port, dst_ip, dst_port,
                                 flags, 1, 0, payload, payload_length);
}
