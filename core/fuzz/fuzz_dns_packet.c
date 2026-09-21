#include <stddef.h>
#include <stdint.h>
#include "droidbridge_dns.h"

/* Fuzz the DNS validators and the SERVFAIL synthesizer. */
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size > 4096) return 0;
    if (db_dns_valid(data, size)) {
        (void)db_dns_transaction_id(data);
    }
    uint8_t out[512];
    (void)db_dns_build_servfail(data, size, out, sizeof out);
    return 0;
}
