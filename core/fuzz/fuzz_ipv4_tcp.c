#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "droidbridge_packet.h"

/* Fuzz the IPv4/TCP parsers and the transparent rewrite against arbitrary input. */
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size > 2048) return 0;
    db_ipv4_view_t ip;
    if (db_ipv4_parse(data, size, &ip) == DB_PACKET_OK) {
        db_tcp_view_t tcp;
        (void)db_tcp_parse(data, size, &ip, &tcp);
        (void)db_ipv4_checksum_valid(data, size);
        (void)db_tcp_checksum_valid(data, size);
        /* rewrite on a mutable copy */
        uint8_t copy[2048];
        memcpy(copy, data, size);
        db_flow_mapping_t mapping;
        memset(&mapping, 0, sizeof mapping);
        mapping.local_port = 20000;
        mapping.original.dst_ip[0] = 93;
        (void)db_rewrite_to_local(copy, size, &mapping);
        (void)db_rewrite_from_local(copy, size, &mapping);
    }
    return 0;
}
