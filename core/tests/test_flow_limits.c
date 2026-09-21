#include "engine_harness.h"
#include "droidbridge_core.h"
#include "droidbridge_packet.h"
#include "test_support.h"

static void test_rejects_bad_config(void) {
    db_engine_config_t base = { .maximum_flows = 128, .mtu = 1280,
        .emit_packet = (db_emit_packet_fn)1, .open_flow = (db_open_flow_fn)1,
        .send_flow = (db_send_flow_fn)1, .close_flow = (db_close_flow_fn)1 };
    db_engine_config_t bad = base; bad.mtu = 1500;
    ASSERT_TRUE(db_engine_create(&bad) == NULL);
    bad = base; bad.maximum_flows = 0;
    ASSERT_TRUE(db_engine_create(&bad) == NULL);
    bad = base; bad.maximum_flows = 257;
    ASSERT_TRUE(db_engine_create(&bad) == NULL);
}

static void test_flow_limit_emits_rst(void) {
    harness_t h; harness_create(&h, 2); /* small cap */
    char ip[16];
    for (int i = 0; i < 2; i++) {
        snprintf(ip, sizeof ip, "93.184.216.%d", 10 + i);
        harness_ingest_syn(&h, (uint16_t)(50000 + i), ip, 443);
        harness_take_synack(&h, NULL);
        harness_ingest_ack(&h, ip, 443);
    }
    ASSERT_EQ_INT(2, (int)db_engine_active_flow_count(h.engine));
    /* third distinct flow over the cap -> RST, no new flow */
    harness_clear_emitted(&h);
    harness_ingest_syn(&h, 50099, "93.184.216.99", 443);
    ASSERT_EQ_INT(1, harness_find_flag(&h, DB_TCP_RST, NULL));
    ASSERT_EQ_INT(2, (int)db_engine_active_flow_count(h.engine));
    harness_destroy(&h);
}

void run_flow_limits_tests(void) {
    RUN(test_rejects_bad_config);
    RUN(test_flow_limit_emits_rst);
}
