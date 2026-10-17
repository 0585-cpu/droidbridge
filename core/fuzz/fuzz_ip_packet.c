#include "droidbridge_packet.h"
#include "droidbridge_policy.h"
#include <stddef.h>
#include <stdint.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    db_ip_view_t ip;
    if (db_ip_parse(data, size, &ip) == DB_PACKET_OK) {
        (void)db_transport_checksum(&ip, data + ip.transport_offset, ip.transport_length);
        if (ip.family == 6) {
            (void)db_policy_check_ipv6(ip.dst);
            static const uint8_t prefix[16] = {0x20, 1, 0x48, 0x60};
            static const uint8_t lengths[] = {32, 40, 48, 56, 64, 96};
            for (size_t i = 0; i < sizeof lengths; i++)
                (void)db_policy_check_ipv6_nat64(ip.dst, prefix, lengths[i]);
        }
        uint8_t output[1280];
        (void)db_ip_build(ip.family, ip.protocol, ip.dst, ip.src, data + ip.transport_offset,
                          ip.transport_length, output, sizeof output);
    }
    return 0;
}
