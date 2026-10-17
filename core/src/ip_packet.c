#include "droidbridge_packet.h"
#include <string.h>
static uint16_t r16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static void w16(uint8_t *p, size_t x) {
    p[0] = (uint8_t)(x >> 8);
    p[1] = (uint8_t)x;
}
static uint32_t sum(const uint8_t *p, size_t n) {
    uint32_t s = 0;
    while (n > 1) {
        s += r16(p);
        p += 2;
        n -= 2;
    }
    if (n)
        s += (uint32_t)*p << 8;
    return s;
}
static uint16_t finish(uint32_t s) {
    while (s >> 16)
        s = (s & 0xffff) + (s >> 16);
    return (uint16_t)~s;
}
db_packet_status_t db_ip_parse(const uint8_t *p, size_t n, db_ip_view_t *v) {
    if (!p || !v)
        return DB_PACKET_ERR_ARGUMENT;
    if (n < 1)
        return DB_PACKET_ERR_TRUNCATED;
    memset(v, 0, sizeof *v);
    v->family = p[0] >> 4;
    if (v->family == 4) {
        db_ipv4_view_t ip;
        db_packet_status_t r = db_ipv4_parse(p, n, &ip);
        if (r)
            return r;
        if (ip.total_length != n)
            return DB_PACKET_ERR_LENGTH;
        if (!db_ipv4_checksum_valid(p, n))
            return DB_PACKET_ERR_CHECKSUM;
        /* Reserved flag must be zero; fragmented traffic never reaches a transport. */
        if (p[6] & 0x80)
            return DB_PACKET_ERR_FRAGMENT;
        memcpy(v->src, ip.src, 4);
        memcpy(v->dst, ip.dst, 4);
        v->protocol = ip.protocol;
        v->ttl = p[8];
        v->total_length = n;
        v->transport_offset = ip.header_length;
        v->transport_length = n - ip.header_length;
        return DB_PACKET_OK;
    }
    if (v->family != 6)
        return DB_PACKET_ERR_VERSION;
    if (n < 40)
        return DB_PACKET_ERR_TRUNCATED;
    if ((size_t)r16(p + 4) + 40 != n)
        return DB_PACKET_ERR_LENGTH;
    memcpy(v->src, p + 8, 16);
    memcpy(v->dst, p + 24, 16);
    v->ttl = p[7];
    v->total_length = n;
    uint8_t next = p[6];
    size_t off = 40, bytes = 0;
    unsigned count = 0;
    while (next == 0 || next == 43 || next == 44 || next == 60) {
        if (++count > 4 || off + 8 > n)
            return DB_PACKET_ERR_LENGTH;
        size_t size = next == 44 ? 8 : ((size_t)p[off + 1] + 1) * 8;
        if (size > n - off || size > 256 - bytes)
            return DB_PACKET_ERR_LENGTH;
        if (next == 44 && (r16(p + off + 2) != 0 || p[off + 1] != 0))
            return DB_PACKET_ERR_FRAGMENT;
        if (next == 43 && p[off + 3] != 0)
            return DB_PACKET_ERR_PROTOCOL; /* never execute source routing */
        if (next == 0 && off != 40)
            return DB_PACKET_ERR_PROTOCOL;
        if (next == 0 || next == 60) {
            size_t at = off + 2, end = off + size;
            while (at < end) {
                uint8_t kind = p[at];
                if (kind == 0) {
                    at++;
                    continue;
                }
                if (at + 2 > end || p[at + 1] > end - at - 2)
                    return DB_PACKET_ERR_LENGTH;
                if (kind != 1)
                    return DB_PACKET_ERR_PROTOCOL; /* only padding is transparent */
                at += 2 + p[at + 1];
            }
        }
        next = p[off];
        off += size;
        bytes += size;
    }
    if (next != 6 && next != 17 && next != 58)
        return DB_PACKET_ERR_PROTOCOL;
    v->protocol = next;
    v->transport_offset = off;
    v->transport_length = n - off;
    return DB_PACKET_OK;
}
uint16_t db_transport_checksum(const db_ip_view_t *v, const uint8_t *p, size_t n) {
    if (!v || (!p && n) || n > 65535)
        return 1;
    uint32_t s = sum(p, n);
    if (!(v->family == 4 && v->protocol == 1)) {
        s += sum(v->src, v->family == 4 ? 4 : 16) + sum(v->dst, v->family == 4 ? 4 : 16) + (uint32_t)n +
             v->protocol;
    }
    return finish(s);
}
size_t db_ip_build(uint8_t family, uint8_t protocol, const uint8_t *src, const uint8_t *dst, const uint8_t *t,
                   size_t n, uint8_t *out, size_t cap) {
    size_t h = family == 4 ? 20 : 40;
    if (!src || !dst || !out || (!t && n) || (family != 4 && family != 6) || n > 1280 - h || cap < h + n)
        return 0;
    memset(out, 0, h);
    out[0] = family == 4 ? 0x45 : 0x60;
    if (family == 4) {
        w16(out + 2, h + n);
        out[8] = 64;
        out[9] = protocol;
        memcpy(out + 12, src, 4);
        memcpy(out + 16, dst, 4);
        w16(out + 10, db_ipv4_header_checksum(out, h));
    } else {
        w16(out + 4, n);
        out[6] = protocol;
        out[7] = 64;
        memcpy(out + 8, src, 16);
        memcpy(out + 24, dst, 16);
    }
    if (n)
        memcpy(out + h, t, n);
    return h + n;
}
