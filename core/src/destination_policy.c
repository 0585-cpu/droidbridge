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

/* Only global unicast plus the standard translation prefix. Special-purpose
 * 2001::/23, documentation, 6to4, ORCHID, ULA, mapped/compatible, link-local,
 * multicast and discard ranges all fail closed. */
db_policy_result_t db_policy_check_ipv6(const uint8_t a[16]) {
    if (!a)
        return DB_POLICY_DENY_RESERVED;
    static const uint8_t well_known[12] = {0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0};
    int match = 1;
    for (int i = 0; i < 12; i++)
        if (a[i] != well_known[i])
            match = 0;
    if (match)
        return db_policy_check_ipv4(a + 12);
    if ((a[0] & 0xe0) != 0x20)
        return DB_POLICY_DENY_RESERVED;
    if (a[0] == 0x20 && a[1] == 1 && a[2] < 2)
        return DB_POLICY_DENY_RESERVED;
    if (a[0] == 0x20 && a[1] == 1 && a[2] == 0x0d && a[3] == 0xb8)
        return DB_POLICY_DENY_DOCUMENTATION;
    if (a[0] == 0x3f && a[1] == 0xff && (a[2] & 0xf0) == 0)
        return DB_POLICY_DENY_DOCUMENTATION;
    if (a[0] == 0x20 && a[1] == 2)
        return DB_POLICY_DENY_RESERVED; /* 6to4 embedded IPv4 */
    return DB_POLICY_ALLOW;
}
db_policy_result_t db_policy_check_ipv6_nat64(const uint8_t a[16], const uint8_t prefix[16], uint8_t bits) {
    if (!a)
        return DB_POLICY_DENY_RESERVED;
    if (!bits)
        return db_policy_check_ipv6(a);
    if (!prefix || !(bits == 32 || bits == 40 || bits == 48 || bits == 56 || bits == 64 || bits == 96))
        return DB_POLICY_DENY_RESERVED;
    for (unsigned i = 0; i < bits / 8; i++)
        if (a[i] != prefix[i])
            return db_policy_check_ipv6(a);
    uint8_t ip[4];
    unsigned at = bits / 8;
    for (unsigned i = 0; i < 4; i++) {
        if (at == 8)
            at++;
        ip[i] = a[at++];
    }
    if (bits != 96 && a[8])
        return DB_POLICY_DENY_RESERVED; /* RFC 6052 reserved u octet */
    for (; at < 16; at++)
        if (a[at])
            return DB_POLICY_DENY_RESERVED;
    return db_policy_check_ipv4(ip);
}
