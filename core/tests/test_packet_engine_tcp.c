#include <string.h>
#include "engine_harness.h"
#include "droidbridge_core.h"
#include "droidbridge_packet.h"
#include "packet_builder.h"
#include "test_support.h"

#define REMOTE "93.184.216.34"

static void check_src(const emitted_packet_t *pkt, const char *ip, uint16_t port) {
    db_ipv4_view_t v; db_tcp_view_t t;
    ASSERT_EQ_INT(DB_PACKET_OK, db_ipv4_parse(pkt->bytes, pkt->len, &v));
    ASSERT_EQ_INT(DB_PACKET_OK, db_tcp_parse(pkt->bytes, pkt->len, &v, &t));
    uint8_t want[4]; unsigned a,b,c,d; sscanf(ip, "%u.%u.%u.%u", &a,&b,&c,&d);
    want[0]=a;want[1]=b;want[2]=c;want[3]=d;
    if (memcmp(v.src, want, 4) != 0) FAIL_AT("src ip mismatch, want %s", ip);
    ASSERT_EQ_INT(port, t.src_port);
}

static void test_tcp_stream_opens_relay_and_returns_remote_bytes(void) {
    harness_t h; harness_create(&h, 128);
    ASSERT_NOT_NULL(h.engine);

    harness_ingest_syn(&h, 50123, REMOTE, 443);
    emitted_packet_t synack;
    ASSERT_EQ_INT(1, harness_take_synack(&h, &synack));
    check_src(&synack, REMOTE, 443);

    harness_clear_emitted(&h);
    harness_ingest_ack(&h, REMOTE, 443);
    ASSERT_EQ_INT(1, h.open_flow_count);
    ASSERT_EQ_INT(443, h.last_dst_port);
    uint8_t want[4]; unsigned a,b,c,d; sscanf(REMOTE,"%u.%u.%u.%u",&a,&b,&c,&d);
    want[0]=a;want[1]=b;want[2]=c;want[3]=d;
    if (memcmp(h.last_dst_ip, want, 4) != 0) FAIL_AT("open_flow dst mismatch%s", "");
    ASSERT_EQ_INT(1, (int)db_engine_active_flow_count(h.engine));

    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_relay_opened(h.engine, h.last_flow));

    const char *req = "GET / HTTP/1.0\r\n\r\n";
    harness_ingest_payload(&h, REMOTE, 443, (const uint8_t *)req, strlen(req));
    ASSERT_EQ_INT((int)strlen(req), (int)h.relay_outbound_len);
    if (memcmp(h.relay_outbound, req, strlen(req)) != 0) FAIL_AT("relay outbound mismatch%s", "");

    harness_clear_emitted(&h);
    const char *resp = "HTTP/1.0 200 OK\r\n\r\n";
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_relay_data(h.engine, h.last_flow, (const uint8_t *)resp, strlen(resp)));
    emitted_packet_t data;
    ASSERT_EQ_INT(1, harness_find_payload(&h, &data));
    check_src(&data, REMOTE, 443);
    db_ipv4_view_t v; db_tcp_view_t t;
    db_ipv4_parse(data.bytes, data.len, &v); db_tcp_parse(data.bytes, data.len, &v, &t);
    if (t.payload_length != strlen(resp) || memcmp(t.payload, resp, strlen(resp)) != 0) FAIL_AT("response payload mismatch%s", "");

    harness_destroy(&h);
}

static void test_relay_open_failure_resets(void) {
    harness_t h; harness_create(&h, 128);
    harness_ingest_syn(&h, 40000, REMOTE, 443);
    harness_take_synack(&h, NULL);
    harness_ingest_ack(&h, REMOTE, 443);
    ASSERT_EQ_INT(1, h.open_flow_count);
    harness_clear_emitted(&h);
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_relay_open_failed(h.engine, h.last_flow));
    ASSERT_EQ_INT(1, harness_find_flag(&h, DB_TCP_RST, NULL));
    ASSERT_EQ_INT(0, (int)db_engine_active_flow_count(h.engine));
    harness_destroy(&h);
}

static void test_data_before_open_is_buffered_then_flushed(void) {
    harness_t h; harness_create(&h, 128);
    harness_ingest_syn(&h, 40001, REMOTE, 443);
    harness_take_synack(&h, NULL);
    harness_ingest_ack(&h, REMOTE, 443);
    /* payload arrives before relay open: buffered, not yet delivered */
    const char *early = "early-bytes";
    harness_ingest_payload(&h, REMOTE, 443, (const uint8_t *)early, strlen(early));
    ASSERT_EQ_INT(0, (int)h.relay_outbound_len);
    /* relay opens: buffered data flushed */
    db_engine_on_relay_opened(h.engine, h.last_flow);
    ASSERT_EQ_INT((int)strlen(early), (int)h.relay_outbound_len);
    harness_destroy(&h);
}

static void test_mac_fin_half_closes(void) {
    harness_t h; harness_create(&h, 128);
    harness_ingest_syn(&h, 40002, REMOTE, 443);
    harness_take_synack(&h, NULL);
    harness_ingest_ack(&h, REMOTE, 443);
    db_engine_on_relay_opened(h.engine, h.last_flow);
    /* Mac sends FIN */
    uint8_t fin[64];
    size_t n = build_tcp_packet_full(fin, sizeof fin, "198.18.0.2", 40002, REMOTE, 443,
                                     DB_TCP_FIN | DB_TCP_ACK, h.mac_seq, h.mac_ack, NULL, 0);
    db_engine_input_packet(h.engine, fin, n);
    ASSERT_TRUE(h.close_count >= 1);
    ASSERT_EQ_INT(DB_CLOSE_NORMAL, h.last_close_reason);
    harness_destroy(&h);
}

void run_packet_engine_tcp_tests(void) {
    RUN(test_tcp_stream_opens_relay_and_returns_remote_bytes);
    RUN(test_relay_open_failure_resets);
    RUN(test_data_before_open_is_buffered_then_flushed);
    RUN(test_mac_fin_half_closes);
}
