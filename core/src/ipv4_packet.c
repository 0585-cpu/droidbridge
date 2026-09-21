#include "droidbridge_packet.h"

#include <string.h>

db_packet_status_t db_ipv4_parse(const uint8_t *packet, size_t length, db_ipv4_view_t *view) {
    if (packet == NULL || view == NULL) return DB_PACKET_ERR_ARGUMENT;
    if (length < 20) return DB_PACKET_ERR_TRUNCATED;

    uint8_t version = packet[0] >> 4;
    uint8_t ihl = packet[0] & 0x0F;
    if (version != 4) return DB_PACKET_ERR_VERSION;
    if (ihl < 5 || ihl > 15) return DB_PACKET_ERR_IHL;

    size_t header_length = (size_t)ihl * 4;
    size_t total_length = ((size_t)packet[2] << 8) | (size_t)packet[3];
    if (header_length > total_length) return DB_PACKET_ERR_LENGTH;
    if (total_length > length) return DB_PACKET_ERR_LENGTH;
    if (header_length > length) return DB_PACKET_ERR_TRUNCATED;

    /* B1 does not forward fragments: DF/reserved allowed, MF or non-zero offset rejected. */
    uint16_t flags_frag = ((uint16_t)packet[6] << 8) | (uint16_t)packet[7];
    if ((flags_frag & 0x2000u) != 0 || (flags_frag & 0x1FFFu) != 0) return DB_PACKET_ERR_FRAGMENT;

    view->base = packet;
    view->header_length = header_length;
    view->total_length = total_length;
    view->protocol = packet[9];
    memcpy(view->src, packet + 12, 4);
    memcpy(view->dst, packet + 16, 4);
    return DB_PACKET_OK;
}
