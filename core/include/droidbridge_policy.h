/* IPv4 destination policy (spec §10). Pure function, no allocation, no I/O.
 * Table and boundary fixture: protocol/test-vectors/destination-policy.json. */
#ifndef DROIDBRIDGE_POLICY_H
#define DROIDBRIDGE_POLICY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Values match "results" in destination-policy.json. Non-zero means deny. */
typedef enum {
    DB_POLICY_ALLOW = 0,
    DB_POLICY_DENY_PRIVATE = 1,        /* 10/8, 172.16/12, 192.168/16 */
    DB_POLICY_DENY_SHARED = 2,         /* 100.64/10 CGNAT */
    DB_POLICY_DENY_LOOPBACK = 3,       /* 127/8 */
    DB_POLICY_DENY_LINK_LOCAL = 4,     /* 169.254/16 */
    DB_POLICY_DENY_RESERVED = 5,       /* 0/8, 192.0.0/24, 240/4 */
    DB_POLICY_DENY_DOCUMENTATION = 6,  /* 192.0.2/24, 198.51.100/24, 203.0.113/24 */
    DB_POLICY_DENY_BENCHMARK = 7,      /* 198.18/15 (also the virtual DNS range) */
    DB_POLICY_DENY_MULTICAST = 8       /* 224/4 */
} db_policy_result_t;

/* `address` is 4 bytes in network order. NULL is denied. */
db_policy_result_t db_policy_check_ipv4(const uint8_t address[4]);

#ifdef __cplusplus
}
#endif

#endif
