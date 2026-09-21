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

size_t build_tcp_packet(uint8_t *out, size_t capacity,
                        const char *src_ip, uint16_t src_port,
                        const char *dst_ip, uint16_t dst_port,
                        uint8_t flags, const uint8_t *payload, size_t payload_length) {
    size_t header = 20 + 20;
    size_t total = header + payload_length;
    if (total > capacity) return 0;
    memset(out, 0, total);

    /* IPv4 */
    out[0] = 0x45;                        /* version 4, IHL 5 */
    write_u16(out + 2, (uint16_t)total);  /* total length */
    out[8] = 64;                          /* TTL */
    out[9] = DB_IPPROTO_TCP;
    if (parse_ipv4(src_ip, out + 12) != 0) return 0;
    if (parse_ipv4(dst_ip, out + 16) != 0) return 0;
    write_u16(out + 10, db_ipv4_header_checksum(out, 20));

    /* TCP */
    uint8_t *tcp = out + 20;
    write_u16(tcp + 0, src_port);
    write_u16(tcp + 2, dst_port);
    tcp[4] = 0x00; tcp[5] = 0x00; tcp[6] = 0x00; tcp[7] = 0x01; /* seq */
    tcp[12] = 5 << 4;                     /* data offset 5 */
    tcp[13] = flags;
    write_u16(tcp + 14, 0xFFFF);          /* window */
    if (payload_length > 0 && payload != NULL) memcpy(tcp + 20, payload, payload_length);

    db_ipv4_view_t ip;
    if (db_ipv4_parse(out, total, &ip) != DB_PACKET_OK) return 0;
    write_u16(tcp + 16, db_tcp_checksum(out, &ip));
    return total;
}
