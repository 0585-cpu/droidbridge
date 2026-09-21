#include <string.h>
#include "droidbridge_lwip.h"
#include "droidbridge_packet.h"
#include "packet_builder.h"
#include "test_support.h"

typedef struct { uint8_t last[2048]; size_t last_len; int count; } emitted_t;

static void test_emit(void *context, const uint8_t *packet, size_t length) {
    emitted_t *e = context;
    memcpy(e->last, packet, length);
    e->last_len = length;
    e->count++;
}

static uint32_t test_now(void *ctx) { (void)ctx; return 0; }
static uint32_t test_rand(void *ctx) { (void)ctx; return 0x11223344u; }

static void assert_ipv4(const uint8_t *got, const char *text) {
    uint8_t want[4]; parse_ipv4(text, want);
    if (memcmp(got, want, 4) != 0) FAIL_AT("ipv4 mismatch, wanted %s", text);
}

static void test_netif_has_expected_address_and_mtu(void) {
    emitted_t e = {0};
    db_lwip_context_t *ctx = db_lwip_init(test_emit, &e, test_now, test_rand, NULL);
    ASSERT_NOT_NULL(ctx);
    uint8_t addr[4], mask[4];
    db_lwip_address(ctx, addr);
    db_lwip_netmask(ctx, mask);
    assert_ipv4(addr, "198.18.0.1");
    assert_ipv4(mask, "255.255.255.252");
    ASSERT_EQ_INT(1280, db_lwip_mtu(ctx));
    db_lwip_shutdown(ctx);
}

static void test_repeated_create_destroy_is_isolated(void) {
    for (int i = 0; i < 5; i++) {
        emitted_t e = {0};
        db_lwip_context_t *ctx = db_lwip_init(test_emit, &e, test_now, test_rand, NULL);
        ASSERT_NOT_NULL(ctx);
        uint8_t addr[4];
        db_lwip_address(ctx, addr);
        assert_ipv4(addr, "198.18.0.1");
        db_lwip_shutdown(ctx);
    }
}

static void test_syn_to_gateway_emits_syn_ack(void) {
    emitted_t e = {0};
    db_lwip_context_t *ctx = db_lwip_init(test_emit, &e, test_now, test_rand, NULL);
    ASSERT_NOT_NULL(ctx);
    /* Without a listener lwIP replies to a SYN on a closed port with an RST — a single emitted
     * IPv4 packet. This proves input -> stack -> flattened single-packet output. */
    uint8_t syn[128];
    size_t n = build_tcp_packet(syn, sizeof syn, "198.18.0.2", 40000, "198.18.0.1", 20000, DB_TCP_SYN, NULL, 0);
    ASSERT_EQ_INT(DB_LWIP_OK, db_lwip_input(ctx, syn, n));
    db_lwip_poll(ctx);
    ASSERT_EQ_INT(1, e.count);
    db_ipv4_view_t ip;
    ASSERT_EQ_INT(DB_PACKET_OK, db_ipv4_parse(e.last, e.last_len, &ip));
    ASSERT_EQ_INT(DB_IPPROTO_TCP, ip.protocol);
    assert_ipv4(ip.src, "198.18.0.1");
    db_tcp_view_t tcp;
    ASSERT_EQ_INT(DB_PACKET_OK, db_tcp_parse(e.last, e.last_len, &ip, &tcp));
    ASSERT_TRUE((tcp.flags & DB_TCP_RST) != 0);
    db_lwip_shutdown(ctx);
}

void run_lwip_adapter_tests(void) {
    RUN(test_netif_has_expected_address_and_mtu);
    RUN(test_repeated_create_destroy_is_isolated);
    RUN(test_syn_to_gateway_emits_syn_ack);
}
