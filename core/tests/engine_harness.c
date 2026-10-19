#include "engine_harness.h"
#include "droidbridge_packet.h"
#include "packet_builder.h"

#include <string.h>

static void cb_emit(void *ctx, const uint8_t *packet, size_t length) {
    harness_t *h = ctx;
    if (h->emitted_count < HARNESS_MAX_EMIT && length <= 2048) {
        memcpy(h->emitted[h->emitted_count].bytes, packet, length);
        h->emitted[h->emitted_count].len = length;
        h->emitted_count++;
    }
}
static void cb_open(void *ctx, db_flow_id_t flow, const uint8_t dst_ip[4], uint16_t dst_port) {
    harness_t *h = ctx;
    h->open_flow_count++;
    h->last_flow = flow;
    memcpy(h->last_dst_ip, dst_ip, 4);
    h->last_dst_port = dst_port;
}
static long cb_send(void *ctx, db_flow_id_t flow, const uint8_t *data, size_t length) {
    (void)flow;
    harness_t *h = ctx;
    if (h->send_return < 0) return h->send_return;
    size_t took = h->send_return == 0 || (size_t)h->send_return >= length ? length : (size_t)h->send_return;
    if (h->relay_outbound_len + took <= HARNESS_BUF) {
        memcpy(h->relay_outbound + h->relay_outbound_len, data, took);
        h->relay_outbound_len += took;
    }
    return (long)took;
}
static void cb_close(void *ctx, db_flow_id_t flow, db_close_reason_t reason) {
    (void)flow;
    harness_t *h = ctx;
    h->close_count++;
    h->last_close_reason = reason;
}
static void cb_dns(void *ctx, db_flow_id_t flow, const uint8_t *q, size_t len) {
    harness_t *h = ctx;
    h->dns_query_count++;
    h->last_query_id = flow;
    if (len <= sizeof h->last_dns_query) { memcpy(h->last_dns_query, q, len); h->last_dns_query_len = len; }
}
static uint32_t cb_rand(void *ctx) { (void)ctx; return 0x12345678u; }
static uint32_t cb_now(void *ctx) { return ((harness_t *)ctx)->now_ms; }

void harness_create(harness_t *h, uint16_t max_flows) {
    harness_create_at_time(h, max_flows, 0);
}

void harness_create_at_time(harness_t *h, uint16_t max_flows, uint32_t now_ms) {
    memset(h, 0, sizeof *h);
    h->now_ms = now_ms;
    db_engine_config_t cfg = {
        .maximum_flows = max_flows, .mtu = DB_TUNNEL_MTU, .idle_timeout_ms = 300000,
        .emit_packet = cb_emit, .open_flow = cb_open, .send_flow = cb_send,
        .close_flow = cb_close, .send_dns = cb_dns, .random_u32 = cb_rand, .now_ms = cb_now,
        .context = h,
    };
    h->engine = db_engine_create(&cfg);
}

void harness_destroy(harness_t *h) { if (h->engine) db_engine_destroy(h->engine); h->engine = NULL; }

void harness_ingest_syn(harness_t *h, uint16_t mac_port, const char *dst_ip, uint16_t dst_port) {
    h->mac_port = mac_port;
    h->mac_seq = 1000;
    uint8_t p[128];
    size_t n = build_tcp_packet_full(p, sizeof p, "198.18.0.2", mac_port, dst_ip, dst_port,
                                     DB_TCP_SYN, h->mac_seq, 0, NULL, 0);
    db_engine_input_packet(h->engine, p, n);
}

int harness_take_synack(harness_t *h, emitted_packet_t *out) {
    for (int i = 0; i < h->emitted_count; i++) {
        db_ipv4_view_t ip; db_tcp_view_t tcp;
        if (db_ipv4_parse(h->emitted[i].bytes, h->emitted[i].len, &ip) != DB_PACKET_OK) continue;
        if (db_tcp_parse(h->emitted[i].bytes, h->emitted[i].len, &ip, &tcp) != DB_PACKET_OK) continue;
        if ((tcp.flags & DB_TCP_SYN) && (tcp.flags & DB_TCP_ACK)) {
            h->mac_seq = tcp.ack;             /* our next seq = what the remote acked */
            h->mac_ack = tcp.seq + 1;         /* ack the SYN-ACK's ISN + 1 */
            if (out) *out = h->emitted[i];
            return 1;
        }
    }
    return 0;
}

void harness_ingest_ack(harness_t *h, const char *dst_ip, uint16_t dst_port) {
    uint8_t p[128];
    size_t n = build_tcp_packet_full(p, sizeof p, "198.18.0.2", h->mac_port, dst_ip, dst_port,
                                     DB_TCP_ACK, h->mac_seq, h->mac_ack, NULL, 0);
    db_engine_input_packet(h->engine, p, n);
}

void harness_ingest_payload(harness_t *h, const char *dst_ip, uint16_t dst_port, const uint8_t *data, size_t len) {
    uint8_t p[2048];
    size_t n = build_tcp_packet_full(p, sizeof p, "198.18.0.2", h->mac_port, dst_ip, dst_port,
                                     DB_TCP_ACK | DB_TCP_PSH, h->mac_seq, h->mac_ack, data, len);
    db_engine_input_packet(h->engine, p, n);
    h->mac_seq += (uint32_t)len;
}

int harness_find_payload(harness_t *h, emitted_packet_t *out) {
    for (int i = 0; i < h->emitted_count; i++) {
        db_ipv4_view_t ip; db_tcp_view_t tcp;
        if (db_ipv4_parse(h->emitted[i].bytes, h->emitted[i].len, &ip) != DB_PACKET_OK) continue;
        if (db_tcp_parse(h->emitted[i].bytes, h->emitted[i].len, &ip, &tcp) != DB_PACKET_OK) continue;
        if (tcp.payload_length > 0) { if (out) *out = h->emitted[i]; return 1; }
    }
    return 0;
}

int harness_find_flag(harness_t *h, uint8_t flag, emitted_packet_t *out) {
    for (int i = 0; i < h->emitted_count; i++) {
        db_ipv4_view_t ip; db_tcp_view_t tcp;
        if (db_ipv4_parse(h->emitted[i].bytes, h->emitted[i].len, &ip) != DB_PACKET_OK) continue;
        if (db_tcp_parse(h->emitted[i].bytes, h->emitted[i].len, &ip, &tcp) != DB_PACKET_OK) continue;
        if (tcp.flags & flag) { if (out) *out = h->emitted[i]; return 1; }
    }
    return 0;
}

void harness_clear_emitted(harness_t *h) { h->emitted_count = 0; }
