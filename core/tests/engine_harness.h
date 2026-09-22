#ifndef DB_ENGINE_HARNESS_H
#define DB_ENGINE_HARNESS_H

#include <stddef.h>
#include <stdint.h>
#include "droidbridge_core.h"

#define HARNESS_MAX_EMIT 128
#define HARNESS_BUF 4096

typedef struct { uint8_t bytes[2048]; size_t len; } emitted_packet_t;

typedef struct {
    db_engine_t *engine;
    /* recorded callback effects */
    emitted_packet_t emitted[HARNESS_MAX_EMIT];
    int emitted_count;
    int open_flow_count;
    db_flow_id_t last_flow;
    uint8_t last_dst_ip[4];
    uint16_t last_dst_port;
    uint8_t relay_outbound[HARNESS_BUF];
    size_t relay_outbound_len;
    long send_return;            /* what send_flow returns (override for backpressure tests) */
    int dns_query_count;
    uint32_t last_query_id;
    uint8_t last_dns_query[512];
    size_t last_dns_query_len;
    uint32_t now_ms;
    int close_count;
    db_close_reason_t last_close_reason;
    /* single-flow seq tracking for building packets */
    uint32_t mac_seq;
    uint32_t mac_ack;
    uint16_t mac_port;
} harness_t;

void harness_create(harness_t *h, uint16_t max_flows);
void harness_destroy(harness_t *h);
void harness_ingest_syn(harness_t *h, uint16_t mac_port, const char *dst_ip, uint16_t dst_port);
int harness_take_synack(harness_t *h, emitted_packet_t *out); /* finds SYN|ACK, updates mac_seq/ack */
void harness_ingest_ack(harness_t *h, const char *dst_ip, uint16_t dst_port);
void harness_ingest_payload(harness_t *h, const char *dst_ip, uint16_t dst_port, const uint8_t *data, size_t len);
int harness_find_payload(harness_t *h, emitted_packet_t *out); /* first emitted packet carrying payload */
int harness_find_flag(harness_t *h, uint8_t flag, emitted_packet_t *out);
void harness_clear_emitted(harness_t *h);

#endif
