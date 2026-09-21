#include <string.h>
#include "droidbridge_packet.h"
#include "packet_builder.h"
#include "test_support.h"

static void assert_endpoints(const uint8_t *p, const char *src_ip, uint16_t src_port,
                             const char *dst_ip, uint16_t dst_port) {
    uint8_t want_src[4], want_dst[4];
    parse_ipv4(src_ip, want_src); parse_ipv4(dst_ip, want_dst);
    if (memcmp(p + 12, want_src, 4) != 0) FAIL_AT("src ip mismatch (%s)", src_ip);
    if (memcmp(p + 16, want_dst, 4) != 0) FAIL_AT("dst ip mismatch (%s)", dst_ip);
    uint16_t sp = ((uint16_t)p[20] << 8) | p[21];
    uint16_t dp = ((uint16_t)p[22] << 8) | p[23];
    ASSERT_EQ_INT(src_port, sp);
    ASSERT_EQ_INT(dst_port, dp);
}

static void test_syn_rewrites_destination_and_output_rewrites_source(void) {
    uint8_t syn[128];
    size_t syn_len = build_tcp_packet(syn, sizeof syn, "198.18.0.2", 50123, "93.184.216.34", 443, DB_TCP_SYN, NULL, 0);
    db_flow_mapping_t mapping = { .original = flow_key("198.18.0.2", 50123, "93.184.216.34", 443), .local_port = 20007 };

    ASSERT_EQ_INT(DB_PACKET_OK, db_rewrite_to_local(syn, syn_len, &mapping));
    assert_endpoints(syn, "198.18.0.2", 50123, "198.18.0.1", 20007);
    ASSERT_EQ_INT(1, db_ipv4_checksum_valid(syn, syn_len));
    ASSERT_EQ_INT(1, db_tcp_checksum_valid(syn, syn_len));

    uint8_t syn_ack[128];
    size_t out_len = build_tcp_packet(syn_ack, sizeof syn_ack, "198.18.0.1", 20007, "198.18.0.2", 50123, DB_TCP_SYN | DB_TCP_ACK, NULL, 0);
    ASSERT_EQ_INT(DB_PACKET_OK, db_rewrite_from_local(syn_ack, out_len, &mapping));
    assert_endpoints(syn_ack, "93.184.216.34", 443, "198.18.0.2", 50123);
    ASSERT_EQ_INT(1, db_ipv4_checksum_valid(syn_ack, out_len));
    ASSERT_EQ_INT(1, db_tcp_checksum_valid(syn_ack, out_len));
}

static void test_rewrite_rejects_wrong_ingress_source(void) {
    uint8_t p[128];
    size_t n = build_tcp_packet(p, sizeof p, "10.0.0.9", 1, "1.2.3.4", 2, DB_TCP_SYN, NULL, 0);
    db_flow_mapping_t mapping = { .original = flow_key("10.0.0.9", 1, "1.2.3.4", 2), .local_port = 20000 };
    ASSERT_EQ_INT(DB_PACKET_ERR_SOURCE, db_rewrite_to_local(p, n, &mapping));
}

static void test_rewrite_preserves_payload_and_data(void) {
    const char *body = "GET / HTTP/1.0\r\n\r\n";
    uint8_t p[128];
    size_t n = build_tcp_packet(p, sizeof p, "198.18.0.2", 40000, "93.184.216.34", 443, DB_TCP_ACK | DB_TCP_PSH, (const uint8_t *)body, strlen(body));
    db_flow_mapping_t mapping = { .original = flow_key("198.18.0.2", 40000, "93.184.216.34", 443), .local_port = 20100 };
    ASSERT_EQ_INT(DB_PACKET_OK, db_rewrite_to_local(p, n, &mapping));
    ASSERT_EQ_INT(1, db_tcp_checksum_valid(p, n));
    if (memcmp(p + 40, body, strlen(body)) != 0) FAIL_AT("payload altered by rewrite%s", "");
}

static void test_flow_table_same_source_port_two_destinations(void) {
    db_flow_table_t *table = db_flow_table_create(128);
    ASSERT_NOT_NULL(table);
    db_flow_key_t k1 = flow_key("198.18.0.2", 50123, "93.184.216.34", 443);
    db_flow_key_t k2 = flow_key("198.18.0.2", 50123, "1.1.1.1", 443);
    db_flow_mapping_t m1, m2, lookup;
    ASSERT_EQ_INT(DB_PACKET_OK, db_flow_table_get_or_create(table, &k1, &m1));
    ASSERT_EQ_INT(DB_PACKET_OK, db_flow_table_get_or_create(table, &k2, &m2));
    if (m1.local_port == m2.local_port) FAIL_AT("same source port to two remotes shared a local port%s", "");
    /* idempotent get returns the same mapping */
    ASSERT_EQ_INT(DB_PACKET_OK, db_flow_table_get_or_create(table, &k1, &lookup));
    ASSERT_EQ_INT(m1.local_port, lookup.local_port);
    ASSERT_EQ_INT(2, (int)db_flow_table_count(table));
    /* reverse lookup by local port distinguishes them */
    ASSERT_EQ_INT(DB_PACKET_OK, db_flow_table_lookup_by_local(table, m1.local_port, &lookup));
    if (memcmp(lookup.original.dst_ip, k1.dst_ip, 4) != 0) FAIL_AT("reverse lookup wrong flow%s", "");
    db_flow_table_destroy(table);
}

static void test_flow_table_pool_exhaustion_and_removal(void) {
    db_flow_table_t *table = db_flow_table_create(256);
    ASSERT_NOT_NULL(table);
    db_flow_mapping_t m;
    for (int i = 0; i < 256; i++) {
        db_flow_key_t k = flow_key("198.18.0.2", (uint16_t)(1000 + i), "9.9.9.9", 443);
        ASSERT_EQ_INT(DB_PACKET_OK, db_flow_table_get_or_create(table, &k, &m));
    }
    /* 257th flow: table full */
    db_flow_key_t overflow = flow_key("198.18.0.2", 60000, "9.9.9.9", 443);
    ASSERT_EQ_INT(DB_PACKET_ERR_TABLE_FULL, db_flow_table_get_or_create(table, &overflow, &m));
    /* removing one frees a slot and its port */
    db_flow_key_t first = flow_key("198.18.0.2", 1000, "9.9.9.9", 443);
    ASSERT_EQ_INT(DB_PACKET_OK, db_flow_table_remove(table, &first));
    ASSERT_EQ_INT(255, (int)db_flow_table_count(table));
    ASSERT_EQ_INT(DB_PACKET_OK, db_flow_table_get_or_create(table, &overflow, &m));
    ASSERT_EQ_INT(DB_PACKET_ERR_NOT_FOUND, db_flow_table_lookup(table, &first, &m));
    db_flow_table_destroy(table);
}

void run_tcp_rewrite_tests(void) {
    RUN(test_syn_rewrites_destination_and_output_rewrites_source);
    RUN(test_rewrite_rejects_wrong_ingress_source);
    RUN(test_rewrite_preserves_payload_and_data);
    RUN(test_flow_table_same_source_port_two_destinations);
    RUN(test_flow_table_pool_exhaustion_and_removal);
}
