#include <stdint.h>
#include "droidbridge_policy.h"
#include "policy_cases_generated.h"
#include "test_support.h"

typedef struct {
    uint8_t ip[4];
    db_policy_result_t expected;
} policy_case_t;

/* Hand-written spot checks from the plan; the generated table is exhaustive. */
static const policy_case_t cases[] = {
    {{10, 0, 0, 0}, DB_POLICY_DENY_PRIVATE},
    {{10, 255, 255, 255}, DB_POLICY_DENY_PRIVATE},
    {{11, 0, 0, 0}, DB_POLICY_ALLOW},
    {{100, 64, 0, 0}, DB_POLICY_DENY_SHARED},
    {{100, 127, 255, 255}, DB_POLICY_DENY_SHARED},
    {{100, 128, 0, 0}, DB_POLICY_ALLOW},
    {{127, 0, 0, 1}, DB_POLICY_DENY_LOOPBACK},
    {{169, 254, 1, 1}, DB_POLICY_DENY_LINK_LOCAL},
    {{172, 16, 0, 0}, DB_POLICY_DENY_PRIVATE},
    {{172, 31, 255, 255}, DB_POLICY_DENY_PRIVATE},
    {{172, 32, 0, 0}, DB_POLICY_ALLOW},
    {{192, 168, 1, 1}, DB_POLICY_DENY_PRIVATE},
    {{198, 18, 0, 0}, DB_POLICY_DENY_BENCHMARK},
    {{198, 18, 0, 1}, DB_POLICY_DENY_BENCHMARK}, /* virtual DNS server, never an exit destination */
    {{198, 19, 255, 255}, DB_POLICY_DENY_BENCHMARK},
    {{203, 0, 113, 255}, DB_POLICY_DENY_DOCUMENTATION},
    {{224, 0, 0, 0}, DB_POLICY_DENY_MULTICAST},
    {{239, 255, 255, 255}, DB_POLICY_DENY_MULTICAST},
    {{240, 0, 0, 0}, DB_POLICY_DENY_RESERVED},
    {{255, 255, 255, 255}, DB_POLICY_DENY_RESERVED},
    {{0, 0, 0, 0}, DB_POLICY_DENY_RESERVED},
    {{1, 1, 1, 1}, DB_POLICY_ALLOW},
    {{93, 184, 216, 34}, DB_POLICY_ALLOW},
};

static void test_spot_checks(void) {
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        db_policy_result_t got = db_policy_check_ipv4(cases[i].ip);
        if (got != cases[i].expected)
            FAIL_AT("%u.%u.%u.%u: expected %d, got %d", cases[i].ip[0], cases[i].ip[1],
                    cases[i].ip[2], cases[i].ip[3], (int)cases[i].expected, (int)got);
    }
}

static void test_generated_boundaries(void) {
    size_t n = sizeof policy_cases_generated / sizeof policy_cases_generated[0];
    ASSERT_EQ_INT(53, n);
    for (size_t i = 0; i < n; i++) {
        const policy_case_generated_t *c = &policy_cases_generated[i];
        db_policy_result_t got = db_policy_check_ipv4(c->ip);
        if ((int)got != c->expected)
            FAIL_AT("%s: expected %d, got %d", c->address, c->expected, (int)got);
    }
}

static void test_null_is_denied(void) {
    ASSERT_EQ_INT(DB_POLICY_DENY_RESERVED, db_policy_check_ipv4(NULL));
}

void run_destination_policy_tests(void) {
    RUN(test_spot_checks);
    RUN(test_generated_boundaries);
    RUN(test_null_is_denied);
}
