#ifndef DROIDBRIDGE_LWIP_PORT_H
#define DROIDBRIDGE_LWIP_PORT_H

#include <stdint.h>

/* The engine injects a monotonic clock and RNG so lwIP is deterministic under test. */
typedef uint32_t (*db_lwip_now_fn)(void *context);
typedef uint32_t (*db_lwip_rand_fn)(void *context);

void db_lwip_port_set_clock(db_lwip_now_fn now, void *context);
void db_lwip_port_set_random(db_lwip_rand_fn rand_fn, void *context);

#endif
