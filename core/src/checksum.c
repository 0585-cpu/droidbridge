#include "droidbridge_packet.h"

/* One's-complement 16-bit checksum accumulator. */
static uint32_t sum16(const uint8_t *data, size_t length, uint32_t acc) {
    size_t i = 0;
    for (; i + 1 < length; i += 2) {
        acc += ((uint32_t)data[i] << 8) | (uint32_t)data[i + 1];
    }
    if (i < length) {
        acc += (uint32_t)data[i] << 8; /* pad final odd byte */
    }
    return acc;
}

static uint16_t fold(uint32_t acc) {
    while (acc >> 16) {
        acc = (acc & 0xFFFF) + (acc >> 16);
    }
    return (uint16_t)~acc;
}

uint16_t db_ipv4_header_checksum(const uint8_t *packet, size_t header_length) {
    /* checksum field (bytes 10..11) is treated as zero */
    uint32_t acc = 0;
    for (size_t i = 0; i + 1 < header_length; i += 2) {
        if (i == 10) continue;
        acc += ((uint32_t)packet[i] << 8) | (uint32_t)packet[i + 1];
    }
    return fold(acc);
}

uint16_t db_tcp_checksum(const uint8_t *packet, const db_ipv4_view_t *ip) {
    size_t tcp_offset = ip->header_length;
    size_t tcp_length = ip->total_length - ip->header_length;
    uint32_t acc = 0;
    /* pseudo-header: src(4) dst(4) zero+proto(2) tcp_length(2) */
    acc = sum16(ip->src, 4, acc);
    acc = sum16(ip->dst, 4, acc);
    acc += (uint32_t)ip->protocol;
    acc += (uint32_t)tcp_length;
    /* TCP header + payload with checksum field (offset 16..17) zeroed */
    for (size_t i = 0; i + 1 < tcp_length; i += 2) {
        if (i == 16) continue;
        acc += ((uint32_t)packet[tcp_offset + i] << 8) | (uint32_t)packet[tcp_offset + i + 1];
    }
    if (tcp_length & 1) {
        acc += (uint32_t)packet[tcp_offset + tcp_length - 1] << 8;
    }
    return fold(acc);
}

int db_ipv4_checksum_valid(const uint8_t *packet, size_t length) {
    db_ipv4_view_t ip;
    if (db_ipv4_parse(packet, length, &ip) != DB_PACKET_OK) return 0;
    uint16_t stored = ((uint16_t)packet[10] << 8) | (uint16_t)packet[11];
    return db_ipv4_header_checksum(packet, ip.header_length) == stored;
}

int db_tcp_checksum_valid(const uint8_t *packet, size_t length) {
    db_ipv4_view_t ip;
    if (db_ipv4_parse(packet, length, &ip) != DB_PACKET_OK) return 0;
    if (ip.protocol != DB_IPPROTO_TCP) return 0;
    size_t tcp_offset = ip.header_length;
    if (tcp_offset + 20 > ip.total_length) return 0; /* no full TCP header present */
    uint16_t stored = ((uint16_t)packet[tcp_offset + 16] << 8) | (uint16_t)packet[tcp_offset + 17];
    return db_tcp_checksum(packet, &ip) == stored;
}
