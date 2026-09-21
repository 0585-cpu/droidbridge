/* DroidBridge B1 data-plane engine: terminates IPv4/TCP flows via lwIP and bridges them to the
 * Android relay through host callbacks. One serialized engine thread; no payload logging. */
#ifndef DROIDBRIDGE_CORE_H
#define DROIDBRIDGE_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t db_flow_id_t;

typedef enum {
    DB_ENGINE_OK = 0,
    DB_ENGINE_ERR_ARGUMENT = -1,
    DB_ENGINE_ERR_CONFIG = -2,
    DB_ENGINE_ERR_UNKNOWN_FLOW = -3,
    DB_ENGINE_ERR_STATE = -4
} db_engine_status_t;

typedef enum {
    DB_CLOSE_NORMAL = 0,   /* Mac or remote sent FIN */
    DB_CLOSE_RESET = 1,    /* RST / abort */
    DB_CLOSE_LIMIT = 2,    /* flow limit or buffer overflow */
    DB_CLOSE_TIMEOUT = 3
} db_close_reason_t;

/* send_flow returns the number of bytes accepted, or DB_SEND_AGAIN when the relay queue is full
 * (the engine keeps the data and retries on db_engine_on_relay_writable), or DB_SEND_ERROR to abort. */
#define DB_SEND_AGAIN (-1)
#define DB_SEND_ERROR (-2)

typedef void (*db_emit_packet_fn)(void *context, const uint8_t *packet, size_t length);
typedef void (*db_open_flow_fn)(void *context, db_flow_id_t flow, const uint8_t dst_ip[4], uint16_t dst_port);
typedef long (*db_send_flow_fn)(void *context, db_flow_id_t flow, const uint8_t *data, size_t length);
typedef void (*db_close_flow_fn)(void *context, db_flow_id_t flow, db_close_reason_t reason);
typedef void (*db_send_dns_fn)(void *context, db_flow_id_t flow, const uint8_t *query, size_t length);
typedef uint32_t (*db_random_u32_fn)(void *context);
typedef uint32_t (*db_now_ms_fn)(void *context);

typedef struct {
    uint16_t maximum_flows;   /* 1..256 */
    uint16_t mtu;             /* must be 1280 for B1 */
    uint64_t idle_timeout_ms;
    db_emit_packet_fn emit_packet;
    db_open_flow_fn open_flow;
    db_send_flow_fn send_flow;
    db_close_flow_fn close_flow;
    db_send_dns_fn send_dns;
    db_random_u32_fn random_u32;
    db_now_ms_fn now_ms;
    void *context;
} db_engine_config_t;

typedef struct db_engine db_engine_t;

db_engine_t *db_engine_create(const db_engine_config_t *config);
void db_engine_destroy(db_engine_t *engine);

/* Feed one IPv4 packet read from the tunnel (Mac -> internet direction). */
db_engine_status_t db_engine_input_packet(db_engine_t *engine, const uint8_t *packet, size_t length);
/* Advance timers (call periodically). */
void db_engine_poll(db_engine_t *engine);

/* Relay -> engine notifications. */
db_engine_status_t db_engine_on_relay_opened(db_engine_t *engine, db_flow_id_t flow);
db_engine_status_t db_engine_on_relay_open_failed(db_engine_t *engine, db_flow_id_t flow);
db_engine_status_t db_engine_on_relay_data(db_engine_t *engine, db_flow_id_t flow, const uint8_t *data, size_t length);
db_engine_status_t db_engine_on_relay_writable(db_engine_t *engine, db_flow_id_t flow);
db_engine_status_t db_engine_on_relay_closed(db_engine_t *engine, db_flow_id_t flow, int is_error);

/* Virtual DNS: `query` is the flow/query id passed to send_dns. Emits the UDP DNS answer to the Mac. */
db_engine_status_t db_engine_on_dns_response(db_engine_t *engine, db_flow_id_t query, const uint8_t *response, size_t length);

size_t db_engine_active_flow_count(const db_engine_t *engine);

#ifdef __cplusplus
}
#endif

#endif
