#include <stddef.h>
#include <stdint.h>
#include "droidbridge_protocol.h"
#include "droidbridge_policy.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    dbp_open_tcp_t open = {0};
    uint8_t out[DBP_OPEN_TCP_MAX_SIZE];
    size_t written = 0;
    if (dbp_decode_open_tcp(data, size, &open) == DBP_OK) {
        /* anything that decodes must re-encode to the same bytes and be policy-checkable */
        if (dbp_encode_open_tcp(&open, out, sizeof out, &written) != DBP_OK || written != size)
            __builtin_trap();
        for (size_t i = 0; i < size; i++)
            if (out[i] != data[i]) __builtin_trap();
        if (open.address_type == DBP_ADDRESS_IPV4) (void)db_policy_check_ipv4(open.address);
    }
    return 0;
}
