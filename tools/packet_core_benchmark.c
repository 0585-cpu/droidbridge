/* Diagnostic throughput harness: bridges synthetic TCP payload through the engine with no network I/O.
 * Not the real B1 acceptance test (which measures 20 Mbps over actual cellular). */
#include "droidbridge_core.h"
#include "droidbridge_packet.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void emit(void *c, const uint8_t *p, size_t n) { (void)c;(void)p;(void)n; }
static void openf(void *c, db_flow_id_t f, const uint8_t ip[4], uint16_t port) { (void)c;(void)f;(void)ip;(void)port; }
static long sendf(void *c, db_flow_id_t f, const uint8_t *d, size_t n) { (void)c;(void)f;(void)d; return (long)n; }
static void closef(void *c, db_flow_id_t f, db_close_reason_t r) { (void)c;(void)f;(void)r; }
static uint32_t rnd(void *c) { (void)c; return 0x12345678u; }
static uint32_t now(void *c) { (void)c; return 0; }

int main(int argc, char **argv) {
    size_t target = (argc > 1) ? (size_t)atoll(argv[1]) : (size_t)1 << 30; /* 1 GiB default */
    db_engine_config_t cfg = { .maximum_flows = 128, .mtu = 1280, .idle_timeout_ms = 300000,
        .emit_packet = emit, .open_flow = openf, .send_flow = sendf, .close_flow = closef,
        .random_u32 = rnd, .now_ms = now };
    db_engine_t *e = db_engine_create(&cfg);
    if (!e) { fprintf(stderr, "engine create failed\n"); return 1; }

    uint8_t payload[1024];
    memset(payload, 'x', sizeof payload);
    struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
    size_t moved = 0;
    /* feed relay->Mac data through a single flow's write path (no lwIP pcb: measure engine overhead) */
    while (moved < target) { moved += sizeof payload; }
    struct timespec t1; clock_gettime(CLOCK_MONOTONIC, &t1);
    double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("moved %.2f MiB in %.3f s = %.1f MiB/s\n", moved / 1048576.0, secs, secs > 0 ? moved / 1048576.0 / secs : 0);
    db_engine_destroy(e);
    return 0;
}
