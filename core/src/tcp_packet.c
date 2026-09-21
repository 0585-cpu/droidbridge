#include "droidbridge_packet.h"

db_packet_status_t db_tcp_parse(const uint8_t *packet, size_t length,
                                const db_ipv4_view_t *ip, db_tcp_view_t *view) {
    if (packet == NULL || ip == NULL || view == NULL) return DB_PACKET_ERR_ARGUMENT;
    if (ip->protocol != DB_IPPROTO_TCP) return DB_PACKET_ERR_PROTOCOL;
    size_t tcp_offset = ip->header_length;
    if (tcp_offset + 20 > ip->total_length) return DB_PACKET_ERR_TRUNCATED;
    if (ip->total_length > length) return DB_PACKET_ERR_LENGTH;

    const uint8_t *tcp = packet + tcp_offset;
    uint8_t data_offset = tcp[12] >> 4;
    if (data_offset < 5) return DB_PACKET_ERR_TCP_OFFSET;
    size_t tcp_header_length = (size_t)data_offset * 4;
    if (tcp_offset + tcp_header_length > ip->total_length) return DB_PACKET_ERR_TCP_OFFSET;

    view->offset = tcp_offset;
    view->header_length = tcp_header_length;
    view->src_port = ((uint16_t)tcp[0] << 8) | (uint16_t)tcp[1];
    view->dst_port = ((uint16_t)tcp[2] << 8) | (uint16_t)tcp[3];
    view->seq = ((uint32_t)tcp[4] << 24) | ((uint32_t)tcp[5] << 16) | ((uint32_t)tcp[6] << 8) | (uint32_t)tcp[7];
    view->ack = ((uint32_t)tcp[8] << 24) | ((uint32_t)tcp[9] << 16) | ((uint32_t)tcp[10] << 8) | (uint32_t)tcp[11];
    view->flags = tcp[13];
    view->payload = packet + tcp_offset + tcp_header_length;
    view->payload_length = ip->total_length - tcp_offset - tcp_header_length;
    return DB_PACKET_OK;
}
