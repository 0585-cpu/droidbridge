/* lwIP NO_SYS adapter: a single virtual netif (198.18.0.1/30, MTU 1280) driven by packet callbacks. */
#ifndef DROIDBRIDGE_LWIP_H
#define DROIDBRIDGE_LWIP_H

#include <stddef.h>
#include <stdint.h>
#include "lwip_port.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    DB_LWIP_OK = 0,
    DB_LWIP_ERR_ARGUMENT = -1,
    DB_LWIP_ERR_MEMORY = -2,
    DB_LWIP_ERR_INPUT = -3
} db_lwip_status_t;

/* Called with one contiguous IPv4 packet lwIP wants to send. Bytes are owned by the caller
 * only for the duration of the call. */
typedef void (*db_lwip_emit_fn)(void *context, const uint8_t *packet, size_t length);

typedef struct db_lwip_context db_lwip_context_t;

db_lwip_context_t *db_lwip_init(db_lwip_emit_fn emit, void *emit_context,
                                db_lwip_now_fn now, db_lwip_rand_fn rand_fn, void *clock_context);
db_lwip_status_t db_lwip_input(db_lwip_context_t *ctx, const uint8_t *packet, size_t length);
void db_lwip_poll(db_lwip_context_t *ctx);
void db_lwip_address(db_lwip_context_t *ctx, uint8_t out[4]);
void db_lwip_netmask(db_lwip_context_t *ctx, uint8_t out[4]);
uint16_t db_lwip_mtu(db_lwip_context_t *ctx);
struct netif *db_lwip_netif(db_lwip_context_t *ctx);
void db_lwip_shutdown(db_lwip_context_t *ctx);

#ifdef __cplusplus
}
#endif

#endif
