#include <string.h>
#include "engine_harness.h"
#include "droidbridge_core.h"
#include "droidbridge_packet.h"
#include "droidbridge_dns.h"
#include "packet_builder.h"
#include "test_support.h"

/* harness records the last DNS query via send_dns; extend it here through the engine's public API. */
static void test_udp_dns_round_trip_preserves_txid_and_source_port(void) {
    harness_t h; harness_create(&h, 128);
    uint8_t q[256];
    size_t n = build_udp_dns_query(q, sizeof q, "198.18.0.2", 53001, "198.18.0.1", 53, 0x1234, "example.com");
    ASSERT_TRUE(n > 0);
    db_engine_input_packet(h.engine, q, n);
    ASSERT_EQ_INT(1, h.dns_query_count);
    ASSERT_EQ_INT(0x1234, (int)db_dns_transaction_id(h.last_dns_query));

    /* relay answers with an A record for the same txid */
    uint8_t resp[64];
    memcpy(resp, h.last_dns_query, h.last_dns_query_len); /* echo question */
    size_t rn = h.last_dns_query_len;
    resp[2] = 0x81; resp[3] = 0x80; resp[7] = 1; /* QR, RA, ANCOUNT 1 */
    /* append a minimal A answer */
    uint8_t answer[] = {0xC0,0x0C,0,1,0,1,0,0,1,44,0,4,93,184,216,34};
    memcpy(resp + rn, answer, sizeof answer); rn += sizeof answer;

    harness_clear_emitted(&h);
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_dns_response(h.engine, h.last_query_id, resp, rn));
    ASSERT_TRUE(h.emitted_count >= 1);
    /* verify emitted UDP DNS packet: src 198.18.0.1:53 -> 198.18.0.2:53001, matching txid, valid checksums */
    const uint8_t *pkt = h.emitted[0].bytes; size_t pl = h.emitted[0].len;
    db_ipv4_view_t ip; ASSERT_EQ_INT(DB_PACKET_OK, db_ipv4_parse(pkt, pl, &ip));
    ASSERT_EQ_INT(DB_IPPROTO_UDP, ip.protocol);
    uint8_t want_src[4]={198,18,0,1}, want_dst[4]={198,18,0,2};
    if (memcmp(ip.src, want_src, 4) || memcmp(ip.dst, want_dst, 4)) FAIL_AT("dns response endpoints%s","");
    const uint8_t *udp = pkt + ip.header_length;
    uint16_t sport = ((uint16_t)udp[0]<<8)|udp[1], dport = ((uint16_t)udp[2]<<8)|udp[3];
    ASSERT_EQ_INT(53, sport); ASSERT_EQ_INT(53001, dport);
    ASSERT_EQ_INT(0x1234, (int)db_dns_transaction_id(udp + 8));
    ASSERT_EQ_INT(1, db_ipv4_checksum_valid(pkt, pl));
    harness_destroy(&h);
}

static void test_udp_dns_to_existing_resolver_is_transparently_bridged(void) {
    harness_t h; harness_create(&h, 128);
    uint8_t q[256];
    size_t n = build_udp_dns_query(q, sizeof q, "198.18.0.2", 53002,
                                   "10.227.27.245", 53, 0x5678, "example.com");
    ASSERT_TRUE(n > 0);
    db_engine_input_packet(h.engine, q, n);
    ASSERT_EQ_INT(1, h.dns_query_count);

    uint8_t resp[64];
    memcpy(resp, h.last_dns_query, h.last_dns_query_len);
    size_t rn = h.last_dns_query_len;
    resp[2] = 0x81; resp[3] = 0x80; resp[7] = 1;
    uint8_t answer[] = {0xC0,0x0C,0,1,0,1,0,0,1,44,0,4,93,184,216,34};
    memcpy(resp + rn, answer, sizeof answer); rn += sizeof answer;

    harness_clear_emitted(&h);
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_dns_response(h.engine, h.last_query_id, resp, rn));
    ASSERT_TRUE(h.emitted_count >= 1);
    db_ipv4_view_t ip;
    ASSERT_EQ_INT(DB_PACKET_OK,
                  db_ipv4_parse(h.emitted[0].bytes, h.emitted[0].len, &ip));
    uint8_t original_resolver[4] = {10,227,27,245};
    if (memcmp(ip.src, original_resolver, 4) != 0) {
        FAIL_AT("dns response must preserve the original resolver address%s", "");
    }
    harness_destroy(&h);
}

static void test_mismatched_txid_and_oversize_rejected(void) {
    harness_t h; harness_create(&h, 128);
    uint8_t q[256];
    size_t n = build_udp_dns_query(q, sizeof q, "198.18.0.2", 5000, "198.18.0.1", 53, 0xABCD, "a.test");
    db_engine_input_packet(h.engine, q, n);
    uint8_t resp[32]; memset(resp, 0, sizeof resp); resp[0]=0x99; resp[1]=0x99; /* wrong txid */
    ASSERT_TRUE(db_engine_on_dns_response(h.engine, h.last_query_id, resp, 20) != DB_ENGINE_OK);
    /* oversize */
    static uint8_t big[5000]; big[0]=0xAB; big[1]=0xCD;
    ASSERT_TRUE(db_engine_on_dns_response(h.engine, h.last_query_id, big, sizeof big) != DB_ENGINE_OK);
    harness_destroy(&h);
}

static void test_malformed_and_non_dns_udp_dropped(void) {
    harness_t h; harness_create(&h, 128);
    /* DNS < 12 bytes: IPv4(20) + UDP(8) + 0 DNS payload */
    uint8_t small[28]; memset(small, 0, sizeof small);
    small[0]=0x45; small[3]=28; small[9]=DB_IPPROTO_UDP;
    parse_ipv4("198.18.0.2", small+12); parse_ipv4("198.18.0.1", small+16);
    small[22]=0; small[23]=53; /* dst port 53 */ small[24]=0; small[25]=8; /* udp len 8, no dns */
    db_engine_input_packet(h.engine, small, sizeof small);
    ASSERT_EQ_INT(0, h.dns_query_count);
    /* non-DNS UDP (port 1234) dropped */
    uint8_t q[256];
    size_t n = build_udp_dns_query(q, sizeof q, "198.18.0.2", 5000, "198.18.0.1", 1234, 0x1, "x.test");
    db_engine_input_packet(h.engine, q, n);
    ASSERT_EQ_INT(0, h.dns_query_count);
    harness_destroy(&h);
}

static void test_dns_table_full_returns_error(void) {
    db_dns_table_t table; db_dns_table_init(&table);
    uint8_t mac[4]={198,18,0,2}; uint8_t resolver[4]={10,227,27,245}; uint32_t id;
    for (int i = 0; i < DB_DNS_MAX_QUERIES; i++) ASSERT_EQ_INT(0, db_dns_register(&table, mac, resolver, 1000, 1, 0, &id));
    ASSERT_EQ_INT(-1, db_dns_register(&table, mac, resolver, 1000, 1, 0, &id));
}

static void test_timed_out_dns_queries_release_engine_slots(void) {
    harness_t h; harness_create(&h, 128);
    uint8_t q[256];
    size_t n = build_udp_dns_query(q, sizeof q, "198.18.0.2", 53003,
                                   "10.227.27.245", 53, 0x2468, "timeout.test");
    ASSERT_TRUE(n > 0);

    for (int i = 0; i < DB_DNS_MAX_QUERIES; i++) {
        db_engine_input_packet(h.engine, q, n);
    }
    ASSERT_EQ_INT(DB_DNS_MAX_QUERIES, h.dns_query_count);

    db_engine_input_packet(h.engine, q, n);
    ASSERT_EQ_INT(DB_DNS_MAX_QUERIES, h.dns_query_count);

    h.now_ms = 5000;
    db_engine_poll(h.engine);
    db_engine_input_packet(h.engine, q, n);
    ASSERT_EQ_INT(DB_DNS_MAX_QUERIES + 1, h.dns_query_count);
    harness_destroy(&h);
}

static void test_dns_expiry_is_wrap_safe(void) {
    db_dns_table_t table; db_dns_table_init(&table);
    uint8_t mac[4]={198,18,0,2}; uint8_t resolver[4]={10,227,27,245}; uint32_t id;
    ASSERT_EQ_INT(0, db_dns_register(&table, mac, resolver, 1000, 1,
                                    UINT32_MAX - 1000u, &id));
    ASSERT_EQ_INT(0, (int)db_dns_expire(&table, 3000u));
    ASSERT_EQ_INT(1, (int)db_dns_expire(&table, 3999u));
}

void run_dns_bridge_tests(void) {
    RUN(test_udp_dns_round_trip_preserves_txid_and_source_port);
    RUN(test_udp_dns_to_existing_resolver_is_transparently_bridged);
    RUN(test_mismatched_txid_and_oversize_rejected);
    RUN(test_malformed_and_non_dns_udp_dropped);
    RUN(test_dns_table_full_returns_error);
    RUN(test_timed_out_dns_queries_release_engine_slots);
    RUN(test_dns_expiry_is_wrap_safe);
}
