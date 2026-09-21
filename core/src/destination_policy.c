#include "droidbridge_policy.h"

#include <stddef.h>

typedef struct {
    uint32_t network;
    uint32_t mask;
    db_policy_result_t result;
} blocked_range_t;

#define CIDR(a, b, c, d, bits) \
    ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d)), \
    ((bits) == 0 ? 0u : (uint32_t)(0xFFFFFFFFu << (32 - (bits))))

/* Must stay identical to BLOCKED_CIDRS in tools/generate_protocol_vectors.py;
 * the generated boundary fixture in tests enforces that. */
static const blocked_range_t BLOCKED[] = {
    {CIDR(0, 0, 0, 0, 8), DB_POLICY_DENY_RESERVED},
    {CIDR(10, 0, 0, 0, 8), DB_POLICY_DENY_PRIVATE},
    {CIDR(100, 64, 0, 0, 10), DB_POLICY_DENY_SHARED},
    {CIDR(127, 0, 0, 0, 8), DB_POLICY_DENY_LOOPBACK},
    {CIDR(169, 254, 0, 0, 16), DB_POLICY_DENY_LINK_LOCAL},
    {CIDR(172, 16, 0, 0, 12), DB_POLICY_DENY_PRIVATE},
    {CIDR(192, 0, 0, 0, 24), DB_POLICY_DENY_RESERVED},
    {CIDR(192, 0, 2, 0, 24), DB_POLICY_DENY_DOCUMENTATION},
    {CIDR(192, 168, 0, 0, 16), DB_POLICY_DENY_PRIVATE},
    {CIDR(198, 18, 0, 0, 15), DB_POLICY_DENY_BENCHMARK},
    {CIDR(198, 51, 100, 0, 24), DB_POLICY_DENY_DOCUMENTATION},
    {CIDR(203, 0, 113, 0, 24), DB_POLICY_DENY_DOCUMENTATION},
    {CIDR(224, 0, 0, 0, 4), DB_POLICY_DENY_MULTICAST},
    {CIDR(240, 0, 0, 0, 4), DB_POLICY_DENY_RESERVED},
};

db_policy_result_t db_policy_check_ipv4(const uint8_t address[4]) {
    if (address == NULL) return DB_POLICY_DENY_RESERVED;
    uint32_t value = (uint32_t)address[0] << 24 | (uint32_t)address[1] << 16 |
                     (uint32_t)address[2] << 8 | (uint32_t)address[3];
    for (size_t i = 0; i < sizeof BLOCKED / sizeof BLOCKED[0]; i++) {
        if ((value & BLOCKED[i].mask) == BLOCKED[i].network) return BLOCKED[i].result;
    }
    return DB_POLICY_ALLOW;
}
