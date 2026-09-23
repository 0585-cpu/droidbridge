/* Packet fixtures use an independent checksum implementation to detect bad synthesis. */
#include "droidbridge_core.h"
#include "droidbridge_packet.h"
#include "droidbridge_policy.h"
#include "droidbridge_protocol.h"
#include "test_support.h"
#include <arpa/inet.h>
#include <string.h>
static void w16(uint8_t *p, unsigned v) {
    p[0] = v >> 8;
    p[1] = v;
}
static void w32(uint8_t *p, uint32_t v) {
    p[0] = v >> 24;
    p[1] = v >> 16;
    p[2] = v >> 8;
    p[3] = v;
}
static unsigned r16(const uint8_t *p) { return (p[0] << 8) | p[1]; }
static uint32_t r32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static unsigned sum(const uint8_t *p, size_t n) {
    unsigned s = 0;
    for (size_t i = 0; i < n; i += 2)
        s += (p[i] << 8) | (i + 1 < n ? p[i + 1] : 0);
    return s;
}
static unsigned folded(unsigned s) {
    while (s >> 16)
        s = (s & 65535) + (s >> 16);
    return (~s) & 65535;
}
static unsigned transport_ck(const uint8_t *p, size_t n) {
    int v = p[0] >> 4;
    size_t h = v == 4 ? 20 : 40;
    unsigned proto = p[v == 4 ? 9 : 6];
    if (proto == 1)
        return folded(sum(p + h, n - h));
    return folded(sum(p + (v == 4 ? 12 : 8), v == 4 ? 8 : 32) + proto + (unsigned)(n - h) +
                  sum(p + h, n - h));
}
static size_t packet(uint8_t *p, int v, int proto, unsigned sport, unsigned dport, const uint8_t *data,
                     size_t len) {
    size_t h = v == 4 ? 20 : 40, th = proto == 6 ? 20 : 8, n = h + th + len;
    memset(p, 0, n);
    p[0] = v == 4 ? 0x45 : 0x60;
    if (v == 4) {
        w16(p + 2, n);
        p[8] = 64;
        p[9] = proto;
        inet_pton(AF_INET, "198.18.0.2", p + 12);
        inet_pton(AF_INET, "8.8.8.8", p + 16);
        w16(p + 10, folded(sum(p, 20)));
    } else {
        w16(p + 4, n - 40);
        p[6] = proto;
        p[7] = 64;
        inet_pton(AF_INET6, "fd00::2", p + 8);
        inet_pton(AF_INET6, "2606:4700:4700::1111", p + 24);
    }
    uint8_t *t = p + h;
    if (proto == 17) {
        w16(t, sport);
        w16(t + 2, dport);
        w16(t + 4, 8 + len);
    } else if (proto == 6) {
        w16(t, sport);
        w16(t + 2, dport);
        w32(t + 4, 1000);
        t[12] = 0x50;
        t[13] = 2;
        w16(t + 14, 32000);
    } else {
        t[0] = v == 4 ? 8 : 128;
        w16(t + 4, sport);
        w16(t + 6, dport);
    }
    if (len)
        memcpy(t + th, data, len);
    size_t c = proto == 17 ? 6 : proto == 6 ? 16 : 2;
    w16(t + c, transport_ck(p, n));
    return n;
}
typedef struct {
    db_engine_t *e;
    unsigned opens, sends, closes, dns, icmp;
    uint8_t family, dst[16], payload[1300], out[1500];
    size_t len, outlen;
    db_flow_id_t id;
    uint32_t now;
} state;
static void emit(void *c, const uint8_t *p, size_t n) {
    state *s = c;
    memcpy(s->out, p, n);
    s->outlen = n;
}
static void open_ip(void *c, db_flow_id_t id, uint8_t f, const uint8_t *p, uint16_t port) {
    state *s = c;
    (void)port;
    s->opens++;
    s->id = id;
    s->family = f;
    memcpy(s->dst, p, f == 4 ? 4 : 16);
}
static void oldopen(void *c, db_flow_id_t id, const uint8_t *p, uint16_t port) { open_ip(c, id, 4, p, port); }
static long send_tcp(void *c, db_flow_id_t id, const uint8_t *p, size_t n) {
    state *s = c;
    (void)id;
    s->sends++;
    s->len = n;
    if (n)
        memcpy(s->payload, p, n);
    return n;
}
static void send_udp(void *c, db_flow_id_t id, const uint8_t *p, size_t n) { (void)send_tcp(c, id, p, n); }
static void close_cb(void *c, db_flow_id_t id, db_close_reason_t r) {
    (void)id;
    (void)r;
    ((state *)c)->closes++;
}
static void dns_cb(void *c, db_flow_id_t id, const uint8_t *p, size_t n) {
    state *s = c;
    s->dns++;
    s->id = id;
    s->len = n;
    memcpy(s->payload, p, n);
}
static void icmp_cb(void *c, db_flow_id_t id, uint8_t f, const uint8_t *p, uint8_t ttl, const uint8_t *b,
                    size_t n) {
    state *s = c;
    (void)ttl;
    open_ip(c, id, f, p, 0);
    s->icmp++;
    s->len = n;
    if (n)
        memcpy(s->payload, b, n);
}
static uint32_t now(void *c) { return ((state *)c)->now; }
static void setup(state *s) {
    memset(s, 0, sizeof *s);
    db_engine_config_t c = {.maximum_flows = 256,
                            .mtu = 1280,
                            .emit_packet = emit,
                            .open_flow = oldopen,
                            .send_flow = send_tcp,
                            .close_flow = close_cb,
                            .send_dns = dns_cb,
                            .now_ms = now,
                            .context = s,
                            .open_flow_ip = open_ip,
                            .open_udp = open_ip,
                            .send_udp = send_udp,
                            .close_udp = close_cb,
                            .send_icmp = icmp_cb};
    s->e = db_engine_create(&c);
}
static void test_udp_capability_and_payload(void) {
    state s;
    setup(&s);
    uint8_t p[1500];
    size_t n = packet(p, 4, 17, 5000, 443, (const uint8_t *)"quic", 4);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(0, s.opens);
    db_engine_set_capabilities(s.e, DB_CAP_TCP4 | DB_CAP_UDP4);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(1, s.opens);
    ASSERT_EQ_INT(1, s.sends);
    ASSERT_EQ_INT(4, s.len);
    ASSERT_TRUE(memcmp(s.payload, "quic", 4) == 0);
    db_engine_destroy(s.e);
}
static void test_udp6_capability_and_payload(void) {
    state s;
    setup(&s);
    uint8_t p[1500];
    size_t n = packet(p, 6, 17, 5000, 443, (const uint8_t *)"hello", 5);
    db_engine_set_capabilities(s.e, DB_CAP_UDP6);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(1, s.opens);
    ASSERT_EQ_INT(6, s.family);
    ASSERT_EQ_INT(5, s.len);
    db_engine_destroy(s.e);
}
static void test_icmp_capability_extracts_echo(void) {
    state s;
    setup(&s);
    uint8_t p[1500];
    size_t n = packet(p, 6, 58, 100, 101, (const uint8_t *)"ping", 4);
    db_engine_set_capabilities(s.e, DB_CAP_ICMP6_ECHO);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(1, s.icmp);
    ASSERT_EQ_INT(4, s.len);
    ASSERT_TRUE(memcmp(s.payload, "ping", 4) == 0);
    db_engine_destroy(s.e);
}
static void test_ipv6_tcp_syn_is_answered(void) {
    state s;
    setup(&s);
    uint8_t p[1500];
    size_t n = packet(p, 6, 6, 5000, 443, NULL, 0);
    db_engine_set_capabilities(s.e, DB_CAP_TCP6);
    db_engine_input_packet(s.e, p, n);
    ASSERT_TRUE(s.outlen >= 60);
    if (s.outlen) {
        ASSERT_EQ_INT(6, s.out[0] >> 4);
        ASSERT_EQ_INT(0, transport_ck(s.out, s.outlen));
        ASSERT_EQ_INT(0x12, s.out[53] & 0x12);
    }
    db_engine_destroy(s.e);
}
static void fix_transport(uint8_t *p, size_t n) {
    size_t h = (p[0] >> 4) == 4 ? 20 : 40;
    unsigned proto = p[h == 20 ? 9 : 6];
    size_t c = proto == 6 ? 16 : proto == 17 ? 6 : 2;
    w16(p + h + c, 0);
    unsigned ck = transport_ck(p, n);
    w16(p + h + c, proto == 17 && !ck ? 65535 : ck);
    if (h == 20) {
        w16(p + 10, 0);
        w16(p + 10, folded(sum(p, 20)));
    }
}
static void test_udp_roundtrip_zero_max_and_tuple_isolation(void) {
    for (int family = 4; family <= 6; family += 2) {
        state s;
        setup(&s);
        db_engine_set_capabilities(s.e, DB_CAP_UDP4 | DB_CAP_UDP6);
        uint8_t p[1500], payload[1233];
        for (size_t i = 0; i < sizeof payload; i++)
            payload[i] = (uint8_t)i;
        size_t n = packet(p, family, 17, 5000, 443, NULL, 0);
        db_engine_input_packet(s.e, p, n);
        db_flow_id_t first = s.id;
        ASSERT_EQ_INT(1, s.opens);
        ASSERT_EQ_INT(1, s.sends);
        ASSERT_EQ_INT(0, s.len);
        ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_udp_data(s.e, first, NULL, 0));
        ASSERT_EQ_INT(family == 4 ? 28 : 48, s.outlen);
        ASSERT_EQ_INT(0, transport_ck(s.out, s.outlen));
        ASSERT_EQ_INT(443, r16(s.out + (family == 4 ? 20 : 40)));
        n = packet(p, family, 17, 5000, 8443, payload, 1232);
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(2, s.opens);
        ASSERT_EQ_INT(1232, s.len);
        ASSERT_TRUE(s.id != first);
        ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_udp_data(s.e, s.id, payload, 1232));
        ASSERT_EQ_INT(family == 4 ? 1260 : 1280, s.outlen);
        ASSERT_EQ_INT(0, transport_ck(s.out, s.outlen));
        ASSERT_MEM_EQ(payload, s.out + (family == 4 ? 28 : 48), 1232);
        n = packet(p, family, 17, 5000, 443, payload, 1);
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(2, s.opens);
        ASSERT_EQ_INT(2, db_engine_udp_flow_count(s.e));
        ASSERT_EQ_INT(2, db_engine_active_flow_count(s.e));
        uint64_t drops = db_engine_udp_drop_count(s.e);
        n = packet(p, family, 17, 5000, 443, payload, 1233);
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_U64(drops + 1, db_engine_udp_drop_count(s.e));
        ASSERT_EQ_INT(DB_ENGINE_ERR_ARGUMENT, db_engine_on_udp_data(s.e, first, payload, 1233));
        ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_udp_closed(s.e, first));
        ASSERT_EQ_INT(DB_ENGINE_ERR_UNKNOWN_FLOW, db_engine_on_udp_data(s.e, first, NULL, 0));
        ASSERT_EQ_INT(1, db_engine_udp_flow_count(s.e));
        db_engine_destroy(s.e);
    }
}
static void test_udp_rejects_checksum_length_fragment_and_private(void) {
    for (int family = 4; family <= 6; family += 2) {
        state s;
        setup(&s);
        db_engine_set_capabilities(s.e, DB_CAP_UDP4 | DB_CAP_UDP6);
        uint8_t p[1500];
        size_t n = packet(p, family, 17, 5000, 443, (const uint8_t *)"x", 1), h = family == 4 ? 20 : 40;
        p[n - 1] ^= 1;
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(0, s.opens);
        n = packet(p, family, 17, 5000, 443, NULL, 0);
        w16(p + h + 4, 9);
        fix_transport(p, n);
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(0, s.opens);
        n = packet(p, family, 17, 5000, 443, NULL, 0);
        if (family == 4) {
            p[6] = 0x20;
            fix_transport(p, n);
        } else {
            p[6] = 44;
            memmove(p + 48, p + 40, 8);
            memset(p + 40, 0, 8);
            p[40] = 17;
            p[43] = 1;
            n += 8;
            w16(p + 4, n - 40);
        }
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(0, s.opens);
        n = packet(p, family, 17, 5000, 443, NULL, 0);
        inet_pton(family == 4 ? AF_INET : AF_INET6, family == 4 ? "10.1.2.3" : "fd00::1",
                  p + (family == 4 ? 16 : 24));
        fix_transport(p, n);
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(0, s.opens);
        n = packet(p, family, 17, 5000, 443, NULL, 0);
        w16(p + h + 6, 0);
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(family == 4 ? 1 : 0, s.opens);
        ASSERT_TRUE(db_engine_udp_drop_count(s.e) >= 4);
        db_engine_destroy(s.e);
    }
}
static void test_udp_idle_and_capacity_are_bounded(void) {
    state s;
    setup(&s);
    db_engine_set_capabilities(s.e, DB_CAP_UDP4);
    uint8_t p[1500];
    s.now = UINT32_MAX - 1000;
    for (unsigned i = 0; i < 257; i++) {
        size_t n = packet(p, 4, 17, 5000 + i, 443, NULL, 0);
        db_engine_input_packet(s.e, p, n);
    }
    ASSERT_EQ_INT(256, s.opens);
    ASSERT_EQ_INT(256, db_engine_udp_flow_count(s.e));
    ASSERT_EQ_INT(1, db_engine_udp_drop_count(s.e));
    s.now = 118998;
    db_engine_poll(s.e);
    ASSERT_EQ_INT(256, db_engine_udp_flow_count(s.e));
    s.now = 118999;
    db_engine_poll(s.e);
    ASSERT_EQ_INT(0, db_engine_udp_flow_count(s.e));
    ASSERT_EQ_INT(256, s.closes);
    size_t n = packet(p, 4, 17, 5000, 443, NULL, 0);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(257, s.opens);
    db_engine_set_capabilities(s.e, DB_CAP_TCP4);
    ASSERT_EQ_INT(257, s.closes);
    ASSERT_EQ_INT(0, db_engine_udp_flow_count(s.e));
    db_engine_destroy(s.e);
}
static void test_dns_priority_and_ipv6_response(void) {
    for (int family = 4; family <= 6; family += 2) {
        state s;
        setup(&s);
        db_engine_set_capabilities(s.e, DB_CAP_UDP4 | DB_CAP_UDP6);
        uint8_t p[1500], dns[12] = {0x12, 0x34, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0};
        size_t n = packet(p, family, 17, 5300, 53, dns, 12);
        inet_pton(family == 4 ? AF_INET : AF_INET6, family == 4 ? "10.0.0.1" : "fd00::1",
                  p + (family == 4 ? 16 : 24));
        fix_transport(p, n);
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(1, s.dns);
        ASSERT_EQ_INT(0, s.opens);
        ASSERT_EQ_INT(0, db_engine_udp_flow_count(s.e));
        dns[2] = 0x81;
        ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_dns_response(s.e, s.id, dns, 12));
        ASSERT_EQ_INT(0, transport_ck(s.out, s.outlen));
        ASSERT_MEM_EQ(p + (family == 4 ? 16 : 24), s.out + (family == 4 ? 12 : 8), family == 4 ? 4 : 16);
        db_engine_destroy(s.e);
    }
}
static void test_ipv6_extensions_are_bounded_and_checksummed(void) {
    state s;
    setup(&s);
    db_engine_set_capabilities(s.e, DB_CAP_UDP6);
    uint8_t p[1500], q[1500];
    size_t n = packet(p, 6, 17, 5000, 443, NULL, 0);
    for (unsigned count = 1; count <= 5; count++) {
        memcpy(q, p, 40);
        q[6] = 60;
        for (unsigned j = 0; j < count; j++) {
            memset(q + 40 + 8 * j, 0, 8);
            q[40 + 8 * j] = j + 1 == count ? 17 : 60;
        }
        memcpy(q + 40 + 8 * count, p + 40, 8);
        w16(q + 4, 8 + 8 * count);
        db_engine_input_packet(s.e, q, n + 8 * count);
        ASSERT_EQ_INT(count <= 4 ? count : 4, s.sends);
    }
    memcpy(q, p, 40);
    q[6] = 60;
    memset(q + 40, 0, 264);
    q[40] = 17;
    q[41] = 32;
    memcpy(q + 304, p + 40, 8);
    w16(q + 4, 272);
    db_engine_input_packet(s.e, q, 312);
    ASSERT_EQ_INT(4, s.sends);
    /* Atomic fragment is permitted; a nonzero offset is rejected. */
    memcpy(q, p, 40);
    q[6] = 44;
    memset(q + 40, 0, 8);
    q[40] = 17;
    memcpy(q + 48, p + 40, 8);
    w16(q + 4, 16);
    db_engine_input_packet(s.e, q, 56);
    ASSERT_EQ_INT(5, s.sends);
    q[43] = 8;
    db_engine_input_packet(s.e, q, 56);
    ASSERT_EQ_INT(5, s.sends);
    db_engine_destroy(s.e);
}
static void test_icmp_roundtrip_metadata_and_invalid_echo(void) {
    for (int family = 4; family <= 6; family += 2) {
        state s;
        setup(&s);
        uint8_t p[1500];
        size_t n = packet(p, family, family == 4 ? 1 : 58, 0xabcd, 0x1234, (const uint8_t *)"echo", 4);
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(0, s.icmp);
        db_engine_set_capabilities(s.e, DB_CAP_ICMP4_ECHO | DB_CAP_ICMP6_ECHO);
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(1, s.icmp);
        db_flow_id_t id = s.id;
        ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_icmp_response(s.e, id, (const uint8_t *)"echo", 4));
        size_t h = family == 4 ? 20 : 40;
        ASSERT_EQ_INT(family == 4 ? 0 : 129, s.out[h]);
        ASSERT_EQ_INT(0xabcd, r16(s.out + h + 4));
        ASSERT_EQ_INT(0x1234, r16(s.out + h + 6));
        ASSERT_EQ_INT(0, transport_ck(s.out, s.outlen));
        ASSERT_MEM_EQ("echo", s.out + h + 8, 4);
        ASSERT_EQ_INT(DB_ENGINE_ERR_UNKNOWN_FLOW,
                      db_engine_on_icmp_response(s.e, id, (const uint8_t *)"echo", 4));
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(DB_ENGINE_ERR_STATE, db_engine_on_icmp_response(s.e, s.id, (const uint8_t *)"fake", 4));
        p[n - 1] ^= 1;
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(2, s.icmp);
        n = packet(p, family, family == 4 ? 1 : 58, 1, 1, NULL, 0);
        p[h] = family == 4 ? 3 : 1;
        fix_transport(p, n);
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(2, s.icmp);
        db_engine_destroy(s.e);
    }
}
static void test_icmp_timeout_and_outstanding_limit(void) {
    state s;
    setup(&s);
    db_engine_set_capabilities(s.e, DB_CAP_ICMP6_ECHO);
    uint8_t p[1500];
    size_t n = packet(p, 6, 58, 1, 2, NULL, 0);
    for (unsigned i = 0; i < 65; i++)
        db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(64, s.icmp);
    db_flow_id_t expired = s.id;
    s.now = 5000;
    ASSERT_EQ_INT(DB_ENGINE_ERR_UNKNOWN_FLOW, db_engine_on_icmp_response(s.e, expired, NULL, 0));
    db_engine_poll(s.e);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(65, s.icmp);
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_icmp_failed(s.e, s.id));
    db_engine_destroy(s.e);
}
static void test_ipv6_tcp_full_stream_uses_original_tuple(void) {
    state s;
    setup(&s);
    db_engine_set_capabilities(s.e, DB_CAP_TCP6);
    uint8_t p[1500];
    size_t n = packet(p, 6, 6, 5000, 443, NULL, 0);
    db_engine_input_packet(s.e, p, n);
    ASSERT_TRUE(s.outlen >= 60);
    if (s.outlen < 60) {
        db_engine_destroy(s.e);
        return;
    }
    uint32_t seq = r32(s.out + 44) + 1;
    p[53] = 0x10;
    w32(p + 44, 1001);
    w32(p + 48, seq);
    fix_transport(p, n);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(1, s.opens);
    ASSERT_EQ_INT(6, s.family);
    ASSERT_MEM_EQ(p + 24, s.dst, 16);
    db_flow_id_t id = s.id;
    db_engine_on_relay_opened(s.e, id);
    n = packet(p, 6, 6, 5000, 443, (const uint8_t *)"GET", 3);
    p[53] = 0x18;
    w32(p + 44, 1001);
    w32(p + 48, seq);
    fix_transport(p, n);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(3, s.len);
    ASSERT_MEM_EQ("GET", s.payload, 3);
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_relay_data(s.e, id, (const uint8_t *)"OK", 2));
    ASSERT_EQ_INT(0, transport_ck(s.out, s.outlen));
    size_t th = (s.out[52] >> 4) * 4;
    ASSERT_MEM_EQ("OK", s.out + 40 + th, 2);
    ASSERT_MEM_EQ(p + 24, s.out + 8, 16);
    ASSERT_MEM_EQ(p + 8, s.out + 24, 16);
    db_engine_set_capabilities(s.e, DB_CAP_TCP4);
    ASSERT_EQ_INT(0, db_engine_active_flow_count(s.e));
    ASSERT_TRUE(s.closes > 0);
    ASSERT_EQ_INT(DB_ENGINE_ERR_UNKNOWN_FLOW, db_engine_on_relay_data(s.e, id, (const uint8_t *)"late", 4));
    db_engine_destroy(s.e);
}
static void test_ipv6_policy_and_nat64_embedded_ipv4(void) {
    static const char *blocked[] = {
        "::1",    "::ffff:8.8.8.8", "fc00::1",           "fe80::1", "ff02::1",        "2001:db8::1",
        "100::1", "2001:20::1",     "2002:0808:0808::1", "3fff::1", "64:ff9b::a00:1", "64:ff9b:1::808:808"};
    state s;
    setup(&s);
    db_engine_set_capabilities(s.e, DB_CAP_UDP6);
    uint8_t p[1500];
    for (size_t i = 0; i < sizeof blocked / sizeof blocked[0]; i++) {
        size_t n = packet(p, 6, 17, 5000, 443, NULL, 0);
        inet_pton(AF_INET6, blocked[i], p + 24);
        fix_transport(p, n);
        db_engine_input_packet(s.e, p, n);
    }
    ASSERT_EQ_INT(0, s.opens);
    uint8_t prefix[16];
    inet_pton(AF_INET6, "2001:4860:64::", prefix);
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_set_nat64_prefix(s.e, prefix, 96));
    size_t n = packet(p, 6, 17, 5000, 443, NULL, 0);
    inet_pton(AF_INET6, "2001:4860:64::a00:1", p + 24);
    fix_transport(p, n);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(0, s.opens);
    inet_pton(AF_INET6, "2001:4860:64::808:808", p + 24);
    fix_transport(p, n);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(1, s.opens);
    ASSERT_EQ_INT(DB_ENGINE_ERR_ARGUMENT, db_engine_set_nat64_prefix(s.e, prefix, 72));
    prefix[15] = 1;
    ASSERT_EQ_INT(DB_ENGINE_ERR_ARGUMENT, db_engine_set_nat64_prefix(s.e, prefix, 96));
    db_engine_destroy(s.e);
}
static void test_combined_flow_limit_512_preserves_both_transports(void) {
    state s;
    setup(&s);
    db_engine_set_capabilities(s.e, DB_CAP_TCP4 | DB_CAP_UDP4);
    uint8_t p[1500];
    for (unsigned i = 0; i < 256; i++) {
        size_t n = packet(p, 4, 17, 5000 + i, 443, NULL, 0);
        db_engine_input_packet(s.e, p, n);
        n = packet(p, 4, 6, 5000 + i, 443, NULL, 0);
        s.outlen = 0;
        db_engine_input_packet(s.e, p, n);
        ASSERT_TRUE(s.outlen >= 40);
        if (s.outlen >= 40) {
            uint32_t ack = r32(s.out + 24) + 1;
            p[33] = 0x10;
            w32(p + 24, 1001);
            w32(p + 28, ack);
            fix_transport(p, n);
            db_engine_input_packet(s.e, p, n);
        }
    }
    ASSERT_EQ_INT(512, db_engine_active_flow_count(s.e));
    ASSERT_EQ_INT(256, db_engine_udp_flow_count(s.e));
    ASSERT_EQ_INT(512, s.opens);
    size_t n = packet(p, 4, 17, 6000, 443, NULL, 0);
    db_engine_input_packet(s.e, p, n);
    n = packet(p, 4, 6, 6000, 443, NULL, 0);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(512, db_engine_active_flow_count(s.e));
    db_engine_destroy(s.e);
}
static void test_ipv6_tcp_source_tuple_isolation_and_checksum_drop(void) {
    state s;
    setup(&s);
    db_engine_set_capabilities(s.e, DB_CAP_TCP6);
    uint8_t p[1500];
    db_flow_id_t previous = 0;
    for (unsigned src = 2; src <= 3; src++) {
        size_t n = packet(p, 6, 6, 5000, 443, NULL, 0);
        p[23] = (uint8_t)src;
        fix_transport(p, n);
        p[59] ^= 1;
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(src - 2, db_engine_active_flow_count(s.e));
        p[59] ^= 1;
        db_engine_input_packet(s.e, p, n);
        ASSERT_TRUE(s.outlen >= 60);
        if (s.outlen < 60)
            break;
        uint32_t ack = r32(s.out + 44) + 1;
        p[53] = 0x10;
        w32(p + 44, 1001);
        w32(p + 48, ack);
        fix_transport(p, n);
        db_engine_input_packet(s.e, p, n);
        ASSERT_EQ_INT(src - 1, s.opens);
        ASSERT_TRUE(s.id != previous);
        previous = s.id;
    }
    ASSERT_EQ_INT(2, db_engine_active_flow_count(s.e));
    db_engine_destroy(s.e);
}
static void test_nat64_supported_prefix_lengths_reject_embedded_private(void) {
    static const unsigned bits[] = {32, 40, 48, 56, 64, 96};
    uint8_t prefix[16] = {0x20, 1, 0x48, 0x60};
    for (size_t i = 0; i < sizeof bits / sizeof bits[0]; i++) {
        uint8_t address[16];
        memcpy(address, prefix, 16);
        unsigned offset = bits[i] / 8;
        uint8_t private4[4] = {192, 168, 1, 1};
        for (unsigned j = 0; j < 4; j++) {
            if (offset == 8)
                offset++;
            address[offset++] = private4[j];
        }
        ASSERT_EQ_INT(DB_POLICY_DENY_PRIVATE, db_policy_check_ipv6_nat64(address, prefix, bits[i]));
        memcpy(address, prefix, 16);
        offset = bits[i] / 8;
        for (unsigned j = 0; j < 4; j++) {
            if (offset == 8)
                offset++;
            address[offset++] = 8;
        }
        ASSERT_EQ_INT(DB_POLICY_ALLOW, db_policy_check_ipv6_nat64(address, prefix, bits[i]));
    }
}
static void test_icmp_zero_max_size_private_and_timeout_wrap(void) {
    state s;
    setup(&s);
    db_engine_set_capabilities(s.e, DB_CAP_ICMP4_ECHO | DB_CAP_ICMP6_ECHO);
    uint8_t p[1500], payload[1201] = {0};
    s.now = UINT32_MAX - 1000;
    size_t n = packet(p, 6, 58, 1, 2, payload, 1201);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(0, s.icmp);
    n = packet(p, 6, 58, 1, 2, payload, 1200);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(1, s.icmp);
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_icmp_response(s.e, s.id, payload, 1200));
    ASSERT_EQ_INT(1248, s.outlen);
    ASSERT_EQ_INT(0, transport_ck(s.out, s.outlen));
    n = packet(p, 4, 1, 1, 2, NULL, 0);
    inet_pton(AF_INET, "192.168.1.1", p + 16);
    fix_transport(p, n);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(1, s.icmp);
    n = packet(p, 4, 1, 1, 2, NULL, 0);
    db_engine_input_packet(s.e, p, n);
    ASSERT_EQ_INT(2, s.icmp);
    s.now = 3998;
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_icmp_response(s.e, s.id, NULL, 0));
    ASSERT_EQ_INT(28, s.outlen);
    db_engine_destroy(s.e);
}

void run_dualstack_tests(void) {
    RUN(test_combined_flow_limit_512_preserves_both_transports);
    RUN(test_ipv6_tcp_source_tuple_isolation_and_checksum_drop);
    RUN(test_nat64_supported_prefix_lengths_reject_embedded_private);
    RUN(test_icmp_zero_max_size_private_and_timeout_wrap);
    RUN(test_udp_capability_and_payload);
    RUN(test_udp6_capability_and_payload);
    RUN(test_icmp_capability_extracts_echo);
    RUN(test_ipv6_tcp_syn_is_answered);
    RUN(test_udp_roundtrip_zero_max_and_tuple_isolation);
    RUN(test_udp_rejects_checksum_length_fragment_and_private);
    RUN(test_udp_idle_and_capacity_are_bounded);
    RUN(test_dns_priority_and_ipv6_response);
    RUN(test_ipv6_extensions_are_bounded_and_checksummed);
    RUN(test_icmp_roundtrip_metadata_and_invalid_echo);
    RUN(test_icmp_timeout_and_outstanding_limit);
    RUN(test_ipv6_tcp_full_stream_uses_original_tuple);
    RUN(test_ipv6_policy_and_nat64_embedded_ipv4);
}
