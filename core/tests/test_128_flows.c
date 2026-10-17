#include <string.h>
#include "engine_harness.h"
#include "droidbridge_core.h"
#include "droidbridge_packet.h"
#include "packet_builder.h"
#include "test_support.h"

#define REMOTE "93.184.216.34"

/* Finds the SYN|ACK emitted for a given Mac port and returns lwIP's ISN via *isn. */
static int find_synack_for_port(harness_t *h, uint16_t mac_port, uint32_t *isn) {
    for (int i = 0; i < h->emitted_count; i++) {
        db_ipv4_view_t ip; db_tcp_view_t t;
        if (db_ipv4_parse(h->emitted[i].bytes, h->emitted[i].len, &ip) != DB_PACKET_OK) continue;
        if (db_tcp_parse(h->emitted[i].bytes, h->emitted[i].len, &ip, &t) != DB_PACKET_OK) continue;
        if ((t.flags & DB_TCP_SYN) && (t.flags & DB_TCP_ACK) && t.dst_port == mac_port) { *isn = t.seq; return 1; }
    }
    return 0;
}

static void ingest(harness_t *h, uint16_t port, uint8_t flags, uint32_t seq, uint32_t ack,
                   const uint8_t *data, size_t len) {
    uint8_t p[2048];
    size_t n = build_tcp_packet_full(p, sizeof p, "198.18.0.2", port, REMOTE, 443, flags, seq, ack, data, len);
    db_engine_input_packet(h->engine, p, n);
}

static void test_128_flows_open_transfer_and_close(void) {
    harness_t h; harness_create(&h, 128);
    ASSERT_NOT_NULL(h.engine);

    db_flow_id_t ids[128];
    uint32_t remote_isn[128];
    uint8_t payload[4096];
    memset(payload, 'x', sizeof payload);

    for (int i = 0; i < 128; i++) {
        uint16_t port = (uint16_t)(40000 + i);
        harness_clear_emitted(&h);
        ingest(&h, port, DB_TCP_SYN, 1000, 0, NULL, 0);
        ASSERT_EQ_INT(1, find_synack_for_port(&h, port, &remote_isn[i]));
        int before = h.open_flow_count;
        ingest(&h, port, DB_TCP_ACK, 1001, remote_isn[i] + 1, NULL, 0);
        ASSERT_EQ_INT(before + 1, h.open_flow_count);
        ids[i] = h.last_flow;
        db_engine_on_relay_opened(h.engine, ids[i]);
    }
    ASSERT_EQ_INT(128, h.open_flow_count);
    ASSERT_EQ_INT(128, (int)db_engine_active_flow_count(h.engine));

    /* 129th concurrent flow -> RST, no new open */
    harness_clear_emitted(&h);
    ingest(&h, 60000, DB_TCP_SYN, 1000, 0, NULL, 0);
    ASSERT_EQ_INT(1, harness_find_flag(&h, DB_TCP_RST, NULL));
    ASSERT_EQ_INT(128, h.open_flow_count);

    /* send 4 KiB Mac->relay and relay->Mac on each flow */
    h.relay_outbound_len = 0;
    for (int i = 0; i < 128; i++) {
        ingest(&h, (uint16_t)(40000 + i), DB_TCP_ACK | DB_TCP_PSH, 1001, remote_isn[i] + 1, payload, sizeof payload);
        harness_clear_emitted(&h);
        db_engine_on_relay_data(h.engine, ids[i], payload, sizeof payload);
        /* Normal close now preserves unacknowledged data: consume each response first. */
        uint32_t ack = remote_isn[i] + 1;
        for (int step = 0; step < 16; step++) {
            uint32_t next = ack;
            for (int j = 0; j < h.emitted_count; j++) {
                db_ipv4_view_t ip; db_tcp_view_t tcp;
                if (db_ipv4_parse(h.emitted[j].bytes, h.emitted[j].len, &ip) != DB_PACKET_OK) continue;
                if (db_tcp_parse(h.emitted[j].bytes, h.emitted[j].len, &ip, &tcp) != DB_PACKET_OK) continue;
                if (tcp.payload_length && tcp.seq + tcp.payload_length > next)
                    next = tcp.seq + (uint32_t)tcp.payload_length;
            }
            harness_clear_emitted(&h);
            if (next == ack) break;
            ack = next;
            ingest(&h, (uint16_t)(40000 + i), DB_TCP_ACK, 1001, ack, NULL, 0);
        }
        ASSERT_EQ_INT(sizeof payload, ack - remote_isn[i] - 1);
    }

    /* close half with FIN (normal) and half with RST (error) via the relay side */
    int normal = 0, reset = 0;
    for (int i = 0; i < 128; i++) {
        if (i % 2 == 0) {
            db_engine_on_relay_closed(h.engine, ids[i], 0);
            ingest(&h, (uint16_t)(40000 + i), DB_TCP_FIN | DB_TCP_ACK, 1001,
                   remote_isn[i] + 2 + sizeof payload, NULL, 0);
            normal++;
        }
        else { db_engine_on_relay_closed(h.engine, ids[i], 1); reset++; }
    }
    ASSERT_EQ_INT(64, normal);
    ASSERT_EQ_INT(64, reset);
    ASSERT_EQ_INT(0, (int)db_engine_active_flow_count(h.engine));

    /* pool fully freed: a fresh flow now succeeds */
    harness_clear_emitted(&h);
    uint32_t isn;
    ingest(&h, 41000, DB_TCP_SYN, 1000, 0, NULL, 0);
    ASSERT_EQ_INT(1, find_synack_for_port(&h, 41000, &isn));
    ingest(&h, 41000, DB_TCP_ACK, 1001, isn + 1, NULL, 0);
    ASSERT_EQ_INT(1, (int)db_engine_active_flow_count(h.engine));

    harness_destroy(&h);
}

void run_128_flows_tests(void) {
    RUN(test_128_flows_open_transfer_and_close);
}
