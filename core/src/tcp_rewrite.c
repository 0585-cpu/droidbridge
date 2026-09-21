#include "droidbridge_packet.h"

#include <string.h>

static void write_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }

static void recompute_checksums(uint8_t *packet, size_t length) {
    /* re-parse the mutated packet so the pseudo-header uses the new src/dst */
    db_ipv4_view_t ip;
    if (db_ipv4_parse(packet, length, &ip) != DB_PACKET_OK) return;
    write_u16(packet + 10, 0);
    write_u16(packet + 10, db_ipv4_header_checksum(packet, ip.header_length));
    size_t tcp_offset = ip.header_length;
    write_u16(packet + tcp_offset + 16, 0);
    write_u16(packet + tcp_offset + 16, db_tcp_checksum(packet, &ip));
}

/* Ingress: Mac->remote packet gets its destination rewritten to gateway:local_port. */
db_packet_status_t db_rewrite_to_local(uint8_t *packet, size_t length, const db_flow_mapping_t *mapping) {
    if (packet == NULL || mapping == NULL) return DB_PACKET_ERR_ARGUMENT;
    db_ipv4_view_t ip;
    db_packet_status_t status = db_ipv4_parse(packet, length, &ip);
    if (status != DB_PACKET_OK) return status;
    if (ip.protocol != DB_IPPROTO_TCP) return DB_PACKET_ERR_PROTOCOL;
    db_tcp_view_t tcp;
    status = db_tcp_parse(packet, length, &ip, &tcp);
    if (status != DB_PACKET_OK) return status;
    /* ingress must originate from the Mac interface address */
    if (ip.src[0] != DB_GATEWAY_IP0 || ip.src[1] != DB_GATEWAY_IP1 ||
        ip.src[2] != DB_GATEWAY_IP2 || ip.src[3] != DB_MAC_IP3) return DB_PACKET_ERR_SOURCE;

    uint8_t gateway[4] = {DB_GATEWAY_IP0, DB_GATEWAY_IP1, DB_GATEWAY_IP2, DB_GATEWAY_IP3};
    memcpy(packet + 16, gateway, 4);                 /* dst IP -> gateway */
    write_u16(packet + ip.header_length + 2, mapping->local_port); /* dst port -> local */
    recompute_checksums(packet, length);
    return DB_PACKET_OK;
}

/* Egress: lwIP output (gateway:local_port -> Mac) gets its source rewritten to the original remote. */
db_packet_status_t db_rewrite_from_local(uint8_t *packet, size_t length, const db_flow_mapping_t *mapping) {
    if (packet == NULL || mapping == NULL) return DB_PACKET_ERR_ARGUMENT;
    db_ipv4_view_t ip;
    db_packet_status_t status = db_ipv4_parse(packet, length, &ip);
    if (status != DB_PACKET_OK) return status;
    if (ip.protocol != DB_IPPROTO_TCP) return DB_PACKET_ERR_PROTOCOL;
    db_tcp_view_t tcp;
    status = db_tcp_parse(packet, length, &ip, &tcp);
    if (status != DB_PACKET_OK) return status;

    memcpy(packet + 12, mapping->original.dst_ip, 4);            /* src IP -> original remote */
    write_u16(packet + ip.header_length, mapping->original.dst_port); /* src port -> original remote port */
    recompute_checksums(packet, length);
    return DB_PACKET_OK;
}
