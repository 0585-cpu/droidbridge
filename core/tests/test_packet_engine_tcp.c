#include <string.h>
#include "engine_harness.h"
#include "droidbridge_core.h"
#include "droidbridge_packet.h"
#include "packet_builder.h"
#include "test_support.h"

#define REMOTE "93.184.216.34"

static size_t emitted_payload_bytes(const harness_t *h, uint32_t *last_ack) {
    size_t total = 0;
    uint32_t furthest = 0;
    for (int i = 0; i < h->emitted_count; i++) {
        db_ipv4_view_t ip; db_tcp_view_t tcp;
        if (db_ipv4_parse(h->emitted[i].bytes, h->emitted[i].len, &ip) != DB_PACKET_OK) continue;
        if (db_tcp_parse(h->emitted[i].bytes, h->emitted[i].len, &ip, &tcp) != DB_PACKET_OK) continue;
        total += tcp.payload_length;
        if (tcp.payload_length > 0 && tcp.seq + tcp.payload_length > furthest)
            furthest = tcp.seq + (uint32_t)tcp.payload_length;
    }
    if (last_ack) *last_ack = furthest;
    return total;
}

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

static void test_mac_fin_waits_for_buffered_request(void) {
    for (int before_open = 0; before_open < 2; before_open++) {
        harness_t h; harness_create(&h, 4);
        harness_ingest_syn(&h, 40101, REMOTE, 443);
        harness_take_synack(&h, NULL);
        harness_ingest_ack(&h, REMOTE, 443);
        if (!before_open) db_engine_on_relay_opened(h.engine, h.last_flow);
        h.send_return = DB_SEND_AGAIN;
        const uint8_t request[] = "request-tail";
        harness_ingest_payload(&h, REMOTE, 443, request, sizeof request - 1);
        uint8_t fin[64];
        size_t n = build_tcp_packet_full(fin, sizeof fin, "198.18.0.2", h.mac_port, REMOTE, 443,
            DB_TCP_FIN | DB_TCP_ACK, h.mac_seq, h.mac_ack, NULL, 0);
        db_engine_input_packet(h.engine, fin, n);
        ASSERT_EQ_INT(0, h.close_count);
        h.send_return = 0;
        if (before_open) db_engine_on_relay_opened(h.engine, h.last_flow);
        else db_engine_on_relay_writable(h.engine, h.last_flow);
        ASSERT_EQ_INT(sizeof request - 1, h.relay_outbound_len);
        ASSERT_TRUE(memcmp(request, h.relay_outbound, sizeof request - 1) == 0);
        ASSERT_EQ_INT(1, h.close_count);
        ASSERT_EQ_INT(DB_CLOSE_NORMAL, h.last_close_reason);
        db_engine_on_relay_writable(h.engine, h.last_flow);
        ASSERT_EQ_INT(1, h.close_count);
        harness_destroy(&h);
    }
}

static void test_abandoned_client_half_close_is_bounded(void) {
    harness_t h; harness_create_at_time(&h, 1, UINT32_MAX - 1000);
    harness_ingest_syn(&h, 40102, REMOTE, 443);
    harness_take_synack(&h, NULL);
    harness_ingest_ack(&h, REMOTE, 443);
    db_engine_on_relay_opened(h.engine, h.last_flow);
    uint8_t fin[64];
    size_t n = build_tcp_packet_full(fin, sizeof fin, "198.18.0.2", h.mac_port, REMOTE, 443,
        DB_TCP_FIN | DB_TCP_ACK, h.mac_seq, h.mac_ack, NULL, 0);
    db_engine_input_packet(h.engine, fin, n);
    h.now_ms += 299999; db_engine_poll(h.engine);
    ASSERT_EQ_INT(1, db_engine_active_flow_count(h.engine));
    h.now_ms += 1; db_engine_poll(h.engine);
    ASSERT_EQ_INT(0, db_engine_active_flow_count(h.engine));
    ASSERT_EQ_INT(DB_CLOSE_TIMEOUT, h.last_close_reason);
    harness_ingest_syn(&h, 40103, REMOTE, 443);
    ASSERT_EQ_INT(1, db_engine_active_flow_count(h.engine));
    harness_destroy(&h);
}

/* Either half-close must retain active traffic, and stalled tails must be bounded. */
static void test_active_half_close_refreshes_deadline(void) {
    for (int remote_first = 0; remote_first < 2; remote_first++) {
        harness_t h; harness_create(&h, 1);
        harness_ingest_syn(&h, 40104, REMOTE, 443);
        harness_take_synack(&h, NULL); harness_ingest_ack(&h, REMOTE, 443);
        db_engine_on_relay_opened(h.engine, h.last_flow);
        if (remote_first) {
            db_engine_on_relay_closed(h.engine, h.last_flow, 0);
            h.mac_ack++; harness_ingest_ack(&h, REMOTE, 443);
        } else {
            uint8_t fin[64];
            size_t n = build_tcp_packet_full(fin, sizeof fin, "198.18.0.2", h.mac_port, REMOTE, 443,
                DB_TCP_FIN | DB_TCP_ACK, h.mac_seq++, h.mac_ack, NULL, 0);
            db_engine_input_packet(h.engine, fin, n);
        }
        const uint8_t data[] = "active";
        for (int i = 0; i < 6; i++) {
            h.now_ms += 60000;
            if (remote_first) harness_ingest_payload(&h, REMOTE, 443, data, sizeof data - 1);
            else {
                db_engine_on_relay_data(h.engine, h.last_flow, data, sizeof data - 1);
                h.mac_ack += sizeof data - 1; harness_ingest_ack(&h, REMOTE, 443);
            }
            db_engine_poll(h.engine);
            ASSERT_EQ_INT(1, db_engine_active_flow_count(h.engine));
        }
        h.now_ms += 300000; db_engine_poll(h.engine);
        ASSERT_EQ_INT(0, db_engine_active_flow_count(h.engine));
        ASSERT_EQ_INT(DB_CLOSE_TIMEOUT, h.last_close_reason);
        harness_destroy(&h);
    }
}

static void test_reverse_half_close_retains_buffered_tail(void) {
    for (int client_first = 0; client_first < 2; client_first++) {
    for (int abandoned = 0; abandoned < 2; abandoned++) {
        harness_t h; harness_create(&h, 1);
        harness_ingest_syn(&h, 40105, REMOTE, 443);
        harness_take_synack(&h, NULL); harness_ingest_ack(&h, REMOTE, 443);
        db_engine_on_relay_opened(h.engine, h.last_flow);
        if (!client_first) {
            db_engine_on_relay_closed(h.engine, h.last_flow, 0);
            h.mac_ack++; harness_ingest_ack(&h, REMOTE, 443);
        }
        h.send_return = DB_SEND_AGAIN;
        const uint8_t tail[] = "upload-tail";
        harness_ingest_payload(&h, REMOTE, 443, tail, sizeof tail - 1);
        uint8_t fin[64];
        size_t n = build_tcp_packet_full(fin, sizeof fin, "198.18.0.2", h.mac_port, REMOTE, 443,
            DB_TCP_FIN | DB_TCP_ACK, h.mac_seq, h.mac_ack, NULL, 0);
        db_engine_input_packet(h.engine, fin, n); h.mac_seq++;
        if (client_first) {
            db_engine_on_relay_closed(h.engine, h.last_flow, 0);
            h.mac_ack++; harness_ingest_ack(&h, REMOTE, 443);
        }
        ASSERT_EQ_INT(1, db_engine_active_flow_count(h.engine));
        ASSERT_EQ_INT(0, h.close_count);
        if (abandoned) {
            h.now_ms += 300000; db_engine_poll(h.engine);
            ASSERT_EQ_INT(DB_CLOSE_TIMEOUT, h.last_close_reason);
        } else {
            h.send_return = 0;
            ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_relay_writable(h.engine, h.last_flow));
            ASSERT_EQ_INT(sizeof tail - 1, h.relay_outbound_len);
            ASSERT_TRUE(memcmp(tail, h.relay_outbound, sizeof tail - 1) == 0);
            ASSERT_EQ_INT(DB_CLOSE_NORMAL, h.last_close_reason);
        }
        ASSERT_EQ_INT(1, h.close_count);
        ASSERT_EQ_INT(0, db_engine_active_flow_count(h.engine));
        harness_ingest_syn(&h, 40106, REMOTE, 443);
        ASSERT_EQ_INT(1, db_engine_active_flow_count(h.engine));
        harness_destroy(&h);
    }
    }
}

/* A stalled Mac must throttle the relay, not reset the download or consume retry bytes. */
static void test_full_receive_queue_waits_then_retries_without_data_loss(void) {
    harness_t h; harness_create(&h, 4);
    harness_ingest_syn(&h, 40010, REMOTE, 443);
    harness_take_synack(&h, NULL);
    harness_ingest_ack(&h, REMOTE, 443);
    db_engine_on_relay_opened(h.engine, h.last_flow);
    harness_clear_emitted(&h);
    uint8_t chunk[16384]; memset(chunk, 0x5a, sizeof chunk);
    for (int i = 0; i < 16; i++)
        ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_relay_data(h.engine, h.last_flow, chunk, sizeof chunk));
    uint8_t tail[16384]; memset(tail, 0xa7, sizeof tail);
    db_engine_status_t full = db_engine_on_relay_data(h.engine, h.last_flow, tail, sizeof tail);
    ASSERT_TRUE(full > 0); /* retryable, no bytes consumed */
    ASSERT_EQ_INT(0, h.close_count);
    ASSERT_EQ_INT(0, harness_find_flag(&h, DB_TCP_RST, NULL));
    ASSERT_EQ_INT(1, db_engine_active_flow_count(h.engine));
    size_t delivered = 0;
    int retried = 0;
    for (int step = 0; step < 1024 && delivered < 17 * sizeof chunk; step++) {
        uint32_t ack = h.mac_ack;
        for (int i = 0; i < h.emitted_count; i++) {
            db_ipv4_view_t ip; db_tcp_view_t tcp;
            if (db_ipv4_parse(h.emitted[i].bytes, h.emitted[i].len, &ip) != DB_PACKET_OK) continue;
            if (db_tcp_parse(h.emitted[i].bytes, h.emitted[i].len, &ip, &tcp) != DB_PACKET_OK) continue;
            if (!tcp.payload_length) continue;
            ASSERT_EQ_INT(ack, tcp.seq);
            for (size_t j = 0; j < tcp.payload_length; j++)
                ASSERT_EQ_INT(delivered + j < 262144 ? 0x5a : 0xa7, tcp.payload[j]);
            delivered += tcp.payload_length;
            ack = tcp.seq + (uint32_t)tcp.payload_length;
        }
        harness_clear_emitted(&h);
        if (ack == h.mac_ack) break;
        h.mac_ack = ack;
        harness_ingest_ack(&h, REMOTE, 443);
        if (!retried && db_engine_on_relay_data(h.engine, h.last_flow, tail, sizeof tail) == DB_ENGINE_OK)
            retried = 1;
    }
    ASSERT_TRUE(retried);
    ASSERT_EQ_INT(278528, delivered);
    ASSERT_EQ_INT(0, h.close_count);
    harness_destroy(&h);
}

/* Clean remote EOF must not discard the tail still waiting for the Mac's TCP window. */
static void test_remote_fin_retransmits_and_closing_flow_retires(void) {
    harness_t h; harness_create(&h, 4);
    harness_ingest_syn(&h, 40012, REMOTE, 443);
    harness_take_synack(&h, NULL);
    harness_ingest_ack(&h, REMOTE, 443);
    db_engine_on_relay_opened(h.engine, h.last_flow);
    harness_clear_emitted(&h);
    db_engine_on_relay_closed(h.engine, h.last_flow, 0);
    ASSERT_EQ_INT(1, harness_find_flag(&h, DB_TCP_FIN, NULL));
    harness_clear_emitted(&h); /* first FIN is lost */
    for (int i = 0; i < 80 && !harness_find_flag(&h, DB_TCP_FIN, NULL); i++) {
        h.now_ms += 250;
        db_engine_poll(h.engine);
    }
    ASSERT_EQ_INT(1, harness_find_flag(&h, DB_TCP_FIN, NULL));
    ASSERT_EQ_INT(0, harness_find_flag(&h, DB_TCP_RST, NULL));
    h.mac_ack++; /* ACK the FIN and send our FIN to complete the close. */
    uint8_t packet[64];
    size_t n = build_tcp_packet_full(packet, sizeof packet, "198.18.0.2", h.mac_port, REMOTE, 443,
                                     DB_TCP_FIN | DB_TCP_ACK, h.mac_seq, h.mac_ack, NULL, 0);
    db_engine_input_packet(h.engine, packet, n);
    db_engine_poll(h.engine);
    ASSERT_EQ_INT(0, db_engine_active_flow_count(h.engine));
    harness_destroy(&h);
}

static void test_eof_waiting_for_peer_fin_is_bounded(void) {
    harness_t h; harness_create_at_time(&h, 4, UINT32_MAX - 1000);
    harness_ingest_syn(&h, 40013, REMOTE, 443);
    harness_take_synack(&h, NULL);
    harness_ingest_ack(&h, REMOTE, 443);
    db_engine_on_relay_opened(h.engine, h.last_flow);
    db_engine_on_relay_closed(h.engine, h.last_flow, 0);
    h.mac_ack++;
    harness_ingest_ack(&h, REMOTE, 443); /* Mac ACKs our FIN but never closes its half. */
    h.now_ms += 299999;
    db_engine_poll(h.engine);
    ASSERT_EQ_INT(1, db_engine_active_flow_count(h.engine));
    h.now_ms += 1;
    db_engine_poll(h.engine);
    ASSERT_EQ_INT(0, db_engine_active_flow_count(h.engine));
    ASSERT_EQ_INT(DB_CLOSE_TIMEOUT, h.last_close_reason);
    harness_destroy(&h);
}

static void test_passive_eof_close_releases_flow_after_fin_ack(void) {
    harness_t h; harness_create(&h, 4);
    harness_ingest_syn(&h, 40014, REMOTE, 443);
    harness_take_synack(&h, NULL);
    harness_ingest_ack(&h, REMOTE, 443);
    db_engine_on_relay_opened(h.engine, h.last_flow);
    uint8_t fin[64];
    size_t n = build_tcp_packet_full(fin, sizeof fin, "198.18.0.2", h.mac_port, REMOTE, 443,
                                     DB_TCP_FIN | DB_TCP_ACK, h.mac_seq, h.mac_ack, NULL, 0);
    db_engine_input_packet(h.engine, fin, n);
    h.mac_seq++;
    db_engine_on_relay_closed(h.engine, h.last_flow, 0);
    h.mac_ack++;
    harness_ingest_ack(&h, REMOTE, 443);
    ASSERT_EQ_INT(0, db_engine_active_flow_count(h.engine));
    ASSERT_EQ_INT(DB_CLOSE_COMPLETE, h.last_close_reason);
    harness_destroy(&h);
}

static void test_remote_eof_delivers_buffered_tail_before_fin(void) {
    harness_t h; harness_create(&h, 4);
    harness_ingest_syn(&h, 40011, REMOTE, 443);
    harness_take_synack(&h, NULL);
    harness_ingest_ack(&h, REMOTE, 443);
    db_engine_on_relay_opened(h.engine, h.last_flow);
    harness_clear_emitted(&h);
    uint8_t response[48 * 1024]; memset(response, 0x3c, sizeof response);
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_relay_data(h.engine, h.last_flow, response, sizeof response));
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_relay_closed(h.engine, h.last_flow, 0));
    size_t delivered = 0;
    int fin = 0;
    for (int step = 0; step < 128 && !fin; step++) {
        uint32_t ack = h.mac_ack;
        for (int i = 0; i < h.emitted_count; i++) {
            db_ipv4_view_t ip; db_tcp_view_t tcp;
            if (db_ipv4_parse(h.emitted[i].bytes, h.emitted[i].len, &ip) != DB_PACKET_OK) continue;
            if (db_tcp_parse(h.emitted[i].bytes, h.emitted[i].len, &ip, &tcp) != DB_PACKET_OK) continue;
            ASSERT_TRUE(!(tcp.flags & DB_TCP_RST));
            if (tcp.payload_length) {
                ASSERT_EQ_INT(ack, tcp.seq);
                for (size_t j = 0; j < tcp.payload_length; j++) ASSERT_EQ_INT(0x3c, tcp.payload[j]);
                delivered += tcp.payload_length;
                ack = tcp.seq + (uint32_t)tcp.payload_length;
            }
            if (tcp.flags & DB_TCP_FIN) { ASSERT_EQ_INT(sizeof response, delivered); fin = 1; }
        }
        harness_clear_emitted(&h);
        if (ack != h.mac_ack) { h.mac_ack = ack; harness_ingest_ack(&h, REMOTE, 443); }
        db_engine_poll(h.engine);
    }
    ASSERT_EQ_INT(sizeof response, delivered);
    ASSERT_TRUE(fin);
    harness_destroy(&h);
}

static void test_relay_bytes_wait_for_lwip_send_space_instead_of_dropping(void) {
    harness_t h; harness_create(&h, 128);
    harness_ingest_syn(&h, 40003, REMOTE, 443);
    harness_take_synack(&h, NULL);
    harness_ingest_ack(&h, REMOTE, 443);
    db_engine_on_relay_opened(h.engine, h.last_flow);
    harness_clear_emitted(&h);

    uint8_t response[48 * 1024];
    for (size_t i = 0; i < sizeof response; i++) response[i] = (uint8_t)(i & 0xff);
    ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_relay_data(h.engine, h.last_flow, response, sizeof response));

    uint32_t relay_ack = 0;
    size_t first_batch = emitted_payload_bytes(&h, &relay_ack);
    ASSERT_TRUE(first_batch > 0);
    ASSERT_TRUE(first_batch < sizeof response);

    size_t delivered = first_batch;
    for (int attempt = 0; attempt < 16 && delivered < sizeof response; attempt++) {
        uint8_t ack[64];
        size_t n = build_tcp_packet_full(ack, sizeof ack, "198.18.0.2", 40003, REMOTE, 443,
                                         DB_TCP_ACK, h.mac_seq, relay_ack, NULL, 0);
        db_engine_input_packet(h.engine, ack, n);
        size_t next = emitted_payload_bytes(&h, &relay_ack);
        if (next == delivered) break;
        delivered = next;
    }

    ASSERT_EQ_INT((int)sizeof response, (int)delivered);
    harness_destroy(&h);
}

static void test_reconnect_after_tcp_timers_have_started(void) {
    for (int session = 0; session < 20; session++) {
        harness_t h;
        harness_create_at_time(&h, 4, 100000000u + (uint32_t)session * 10000u);
        ASSERT_NOT_NULL(h.engine);
        harness_ingest_syn(&h, 41000, REMOTE, 443);
        // Leave SYN-ACK unacknowledged: a live TCP timer must retransmit it after reconnect.
        for (int tick = 0; tick < 16; tick++) {
            h.now_ms += 250;
            db_engine_poll(h.engine);
        }
        ASSERT_TRUE(h.emitted_count > 1);
        ASSERT_EQ_INT(1, harness_take_synack(&h, NULL));
        harness_ingest_ack(&h, REMOTE, 443);
        ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_relay_opened(h.engine, h.last_flow));
        for (int tick = 0; tick < 2 + session % 13; tick++) {
            h.now_ms += 250;
            db_engine_poll(h.engine);
        }
        const uint8_t payload[] = "after reconnect";
        harness_ingest_payload(&h, REMOTE, 443, payload, sizeof payload);
        ASSERT_EQ_INT(sizeof payload, h.relay_outbound_len);
        // Alternate active and gracefully closing PCBs; FIN_WAIT must not survive a session.
        if (session % 2 == 0) {
            ASSERT_EQ_INT(DB_ENGINE_OK, db_engine_on_relay_closed(h.engine, h.last_flow, 0));
            uint8_t finish[64];
            size_t n = build_tcp_packet_full(finish, sizeof finish, "198.18.0.2", h.mac_port, REMOTE, 443,
                                             DB_TCP_FIN | DB_TCP_ACK, h.mac_seq, h.mac_ack + 1, NULL, 0);
            db_engine_input_packet(h.engine, finish, n);
            ASSERT_EQ_INT(0, db_engine_active_flow_count(h.engine));
        }
        harness_destroy(&h);
    }
}

/* Latest advertised right edge is what a conforming TCP uploader may send. */
static uint32_t receive_right_edge(harness_t *h) {
    for (int i = h->emitted_count - 1; i >= 0; i--) {
        emitted_packet_t *p = &h->emitted[i];
        db_ipv4_view_t ip; db_tcp_view_t tcp;
        if (db_ipv4_parse(p->bytes, p->len, &ip) != DB_PACKET_OK ||
            db_tcp_parse(p->bytes, p->len, &ip, &tcp) != DB_PACKET_OK || !(tcp.flags & DB_TCP_ACK)) continue;
        const uint8_t *segment = p->bytes + ip.header_length;
        return tcp.ack + ((uint32_t)segment[14] << 8) + segment[15];
    }
    ASSERT_TRUE(0); return h->mac_seq;
}

static void test_upload_window_tracks_relay_consumption(void) {
    for (int before_open = 0; before_open < 2; before_open++) {
        harness_t h; harness_create(&h, 4);
        harness_ingest_syn(&h, 42000, REMOTE, 443);
        ASSERT_TRUE(harness_take_synack(&h, NULL));
        uint32_t initial_edge = receive_right_edge(&h);
        uint32_t window = initial_edge - h.mac_seq;
        harness_ingest_ack(&h, REMOTE, 443);
        if (!before_open) db_engine_on_relay_opened(h.engine, h.last_flow);
        uint8_t body[3 * 32768];
        for (size_t i = 0; i < sizeof body; i++) body[i] = (uint8_t)(i * 13 + i / 251);
        size_t sent = 0;
        for (int round = 0; round < 3; round++) {
            uint32_t edge = receive_right_edge(&h);
            h.send_return = DB_SEND_AGAIN;
            while (h.mac_seq < edge && sent < sizeof body) {
                size_t n = edge - h.mac_seq; if (n > 1200) n = 1200;
                if (n > sizeof body - sent) n = sizeof body - sent;
                harness_ingest_payload(&h, REMOTE, 443, body + sent, n);
                sent += n; h.now_ms += 250; db_engine_poll(h.engine);
            }
            ASSERT_EQ_INT(h.mac_seq, receive_right_edge(&h)); /* zero window, no extra credit */
            ASSERT_EQ_INT(1, db_engine_active_flow_count(h.engine));
            ASSERT_EQ_INT(0, h.close_count);
            ASSERT_EQ_INT((size_t)round * window, h.relay_outbound_len);
            harness_clear_emitted(&h);
            h.send_return = 0;
            if (round == 0 && before_open) db_engine_on_relay_opened(h.engine, h.last_flow);
            else db_engine_on_relay_writable(h.engine, h.last_flow);
            ASSERT_EQ_INT(h.mac_seq + window, receive_right_edge(&h));
            ASSERT_EQ_INT(sent, h.relay_outbound_len);
            ASSERT_MEM_EQ(body, h.relay_outbound, sent);
        }
        ASSERT_EQ_INT(sizeof body, sent);
        ASSERT_EQ_INT(0, harness_find_flag(&h, DB_TCP_RST, NULL));
        harness_destroy(&h);
    }
}

static void test_synack_advertises_mss_for_1500_byte_tunnel(void) {
    harness_t h; harness_create(&h, 4);
    harness_ingest_syn(&h, 42002, REMOTE, 443);
    emitted_packet_t synack;
    ASSERT_TRUE(harness_take_synack(&h, &synack));
    const uint8_t *tcp = synack.bytes + (synack.bytes[0] & 0x0f) * 4;
    size_t options_end = (size_t)(tcp[12] >> 4) * 4;
    int mss = -1;
    for (size_t i = 20; i + 1 < options_end;) {
        if (tcp[i] == 0) break;
        if (tcp[i] == 1) { i++; continue; }
        if (tcp[i] == 2 && tcp[i + 1] == 4) mss = (tcp[i + 2] << 8) | tcp[i + 3];
        i += tcp[i + 1] ? tcp[i + 1] : 1;
    }
    ASSERT_EQ_INT(1440, mss); /* 1200 was sized for the old 1280-byte MTU */
    harness_destroy(&h);
}

static void test_partial_relay_acceptance_does_not_credit_buffered_tail(void) {
    harness_t h; harness_create(&h, 4);
    harness_ingest_syn(&h, 42001, REMOTE, 443); harness_take_synack(&h, NULL);
    uint32_t initial_edge = receive_right_edge(&h);
    harness_ingest_ack(&h, REMOTE, 443);
    db_engine_on_relay_opened(h.engine, h.last_flow);
    uint8_t body[32768]; memset(body, 0x6d, sizeof body);
    h.send_return = 300;
    harness_ingest_payload(&h, REMOTE, 443, body, 1200);
    h.send_return = DB_SEND_AGAIN;
    for (size_t sent = 1200; sent < sizeof body;) {
        size_t n = sizeof body - sent; if (n > 1200) n = 1200;
        harness_ingest_payload(&h, REMOTE, 443, body + sent, n);
        sent += n; h.now_ms += 250; db_engine_poll(h.engine);
    }
    ASSERT_TRUE(receive_right_edge(&h) <= initial_edge + 300);
    ASSERT_EQ_INT(300, h.relay_outbound_len);
    h.send_return = 0;
    db_engine_on_relay_writable(h.engine, h.last_flow);
    ASSERT_EQ_INT(sizeof body, h.relay_outbound_len);
    ASSERT_MEM_EQ(body, h.relay_outbound, sizeof body);
    ASSERT_EQ_INT(h.mac_seq + sizeof body, receive_right_edge(&h));
    harness_destroy(&h);
}

static void test_abandoned_handshake_releases_capacity_and_rejects_stale_ack(void) {
    for (int reset = 0; reset < 2; reset++) {
        harness_t h; harness_create_at_time(&h, 1, UINT32_MAX - 5000u);
        harness_ingest_syn(&h, 42002, REMOTE, 443); harness_take_synack(&h, NULL);
        if (reset) {
            uint8_t p[128];
            size_t n = build_tcp_packet_full(p, sizeof p, "198.18.0.2", h.mac_port, REMOTE, 443,
                                             DB_TCP_RST, h.mac_seq, 0, NULL, 0);
            db_engine_input_packet(h.engine, p, n);
        } else {
            for (int tick = 0; tick < 124; tick++) { h.now_ms += 250; db_engine_poll(h.engine); }
        }
        ASSERT_EQ_INT(0, db_engine_active_flow_count(h.engine));
        ASSERT_EQ_INT(0, h.open_flow_count);
        ASSERT_EQ_INT(0, h.close_count); /* relay was never opened */
        harness_ingest_ack(&h, REMOTE, 443); /* old final ACK cannot resurrect the flow */
        ASSERT_EQ_INT(0, h.open_flow_count);
        harness_clear_emitted(&h);
        harness_ingest_syn(&h, 42003, REMOTE, 443);
        ASSERT_TRUE(harness_take_synack(&h, NULL));
        harness_ingest_ack(&h, REMOTE, 443);
        ASSERT_EQ_INT(1, h.open_flow_count);
        for (int tick = 0; tick < 124; tick++) { h.now_ms += 250; db_engine_poll(h.engine); }
        ASSERT_EQ_INT(1, db_engine_active_flow_count(h.engine));
        harness_destroy(&h);
    }
}

static void test_handshake_deadline_reaps_children_after_delayed_poll(void) {
    harness_t h; harness_create_at_time(&h, 1, 500000);
    for (int round = 0; round < 4; round++) {
        harness_clear_emitted(&h);
        harness_ingest_syn(&h, (uint16_t)(42100 + round), REMOTE, 443);
        ASSERT_TRUE(harness_take_synack(&h, NULL));
        /* Duplicate SYN must not extend the original deadline. */
        h.now_ms += 29000;
        harness_ingest_syn(&h, (uint16_t)(42100 + round), REMOTE, 443);
        h.now_ms += 1001;
        db_engine_poll(h.engine);
        ASSERT_EQ_INT(0, db_engine_active_flow_count(h.engine));
        harness_clear_emitted(&h);
        for (int tick = 0; tick < 16; tick++) { h.now_ms += 250; db_engine_poll(h.engine); }
        ASSERT_EQ_INT(0, h.emitted_count); /* no orphan SYN-ACK retransmissions */
    }
    ASSERT_EQ_INT(0, h.open_flow_count);
    ASSERT_EQ_INT(0, h.close_count);
    harness_destroy(&h);
}

static void test_invalid_reset_does_not_cancel_handshake(void) {
    harness_t h; harness_create(&h, 1);
    harness_ingest_syn(&h, 42004, REMOTE, 443); harness_take_synack(&h, NULL);
    uint8_t p[128];
    size_t n = build_tcp_packet_full(p, sizeof p, "198.18.0.2", h.mac_port, REMOTE, 443,
                                     DB_TCP_RST, h.mac_seq + 1000000, 0, NULL, 0);
    db_engine_input_packet(h.engine, p, n);
    ASSERT_EQ_INT(1, db_engine_active_flow_count(h.engine));
    harness_ingest_ack(&h, REMOTE, 443);
    ASSERT_EQ_INT(1, h.open_flow_count);
    harness_destroy(&h);
}

void run_packet_engine_tcp_tests(void) {
    RUN(test_upload_window_tracks_relay_consumption);
    RUN(test_partial_relay_acceptance_does_not_credit_buffered_tail);
    RUN(test_abandoned_handshake_releases_capacity_and_rejects_stale_ack);
    RUN(test_invalid_reset_does_not_cancel_handshake);
    RUN(test_handshake_deadline_reaps_children_after_delayed_poll);
    RUN(test_tcp_stream_opens_relay_and_returns_remote_bytes);
    RUN(test_relay_open_failure_resets);
    RUN(test_data_before_open_is_buffered_then_flushed);
    RUN(test_mac_fin_half_closes);
    RUN(test_mac_fin_waits_for_buffered_request);
    RUN(test_abandoned_client_half_close_is_bounded);
    RUN(test_active_half_close_refreshes_deadline);
    RUN(test_reverse_half_close_retains_buffered_tail);
    RUN(test_relay_bytes_wait_for_lwip_send_space_instead_of_dropping);
    RUN(test_full_receive_queue_waits_then_retries_without_data_loss);
    RUN(test_remote_eof_delivers_buffered_tail_before_fin);
    RUN(test_remote_fin_retransmits_and_closing_flow_retires);
    RUN(test_eof_waiting_for_peer_fin_is_bounded);
    RUN(test_passive_eof_close_releases_flow_after_fin_ack);
    RUN(test_reconnect_after_tcp_timers_have_started);
    RUN(test_synack_advertises_mss_for_1500_byte_tunnel);
}
