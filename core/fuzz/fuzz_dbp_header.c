#include <stddef.h>
#include <stdint.h>
#include "droidbridge_protocol.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    dbp_header_fields_t fields = {0};
    uint8_t mac[DBP_HMAC_SIZE] = {0};
    (void)dbp_decode_header(data, size, &fields, mac);
    return 0;
}
