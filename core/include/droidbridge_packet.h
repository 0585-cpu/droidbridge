/* Strict IPv4/TCP parsing, checksums, and transparent flow rewrite for the B1 data plane.
 * Byte-access only: no packed structs, no unaligned casts. */
#ifndef DROIDBRIDGE_PACKET_H
#define DROIDBRIDGE_PACKET_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* B1 virtual addressing (spec §11). */
#define DB_GATEWAY_IP0 198u
#define DB_GATEWAY_IP1 18u
#define DB_GATEWAY_IP2 0u
#define DB_GATEWAY_IP3 1u   /* 198.18.0.1 gateway/DNS */
#define DB_MAC_IP3 2u       /* 198.18.0.2 Mac interface */
#define DB_LOCAL_PORT_MIN 20000u
#define DB_LOCAL_PORT_MAX 20255u
#define DB_LOCAL_PORT_COUNT (DB_LOCAL_PORT_MAX - DB_LOCAL_PORT_MIN + 1u)

#define DB_TCP_FIN 0x01u
#define DB_TCP_SYN 0x02u
#define DB_TCP_RST 0x04u
#define DB_TCP_PSH 0x08u
#define DB_TCP_ACK 0x10u

typedef enum {
    DB_PACKET_OK = 0,
    DB_PACKET_ERR_ARGUMENT = -1,
    DB_PACKET_ERR_TRUNCATED = -2,
    DB_PACKET_ERR_VERSION = -3,
    DB_PACKET_ERR_IHL = -4,
    DB_PACKET_ERR_LENGTH = -5,
    DB_PACKET_ERR_FRAGMENT = -6,
    DB_PACKET_ERR_PROTOCOL = -7,
    DB_PACKET_ERR_CHECKSUM = -8,
    DB_PACKET_ERR_TCP_OFFSET = -9,
    DB_PACKET_ERR_SOURCE = -10,
    DB_PACKET_ERR_POOL_EXHAUSTED = -11,
    DB_PACKET_ERR_TABLE_FULL = -12,
    DB_PACKET_ERR_NOT_FOUND = -13
} db_packet_status_t;

#define DB_IPPROTO_TCP 6u
#define DB_IPPROTO_UDP 17u

typedef struct {
    const uint8_t *base;   /* start of the IPv4 header */
    size_t header_length;  /* IHL * 4 */
    size_t total_length;   /* from the IPv4 total length field */
    uint8_t protocol;
    uint8_t src[4];
    uint8_t dst[4];
} db_ipv4_view_t;

typedef struct {
    size_t offset;         /* offset of the TCP header within the packet */
    size_t header_length;  /* data offset * 4 */
    uint16_t src_port;
    uint16_t dst_port;
    uint32_t seq;
    uint32_t ack;
    uint8_t flags;
    const uint8_t *payload;
    size_t payload_length;
} db_tcp_view_t;

typedef struct {
    uint8_t src_ip[4];
    uint16_t src_port;
    uint8_t dst_ip[4];
    uint16_t dst_port;
} db_flow_key_t;

typedef struct {
    db_flow_key_t original;
    uint16_t local_port;
} db_flow_mapping_t;

/* Validated complete IP envelope. IPv6 extensions are bounded (4 headers/256 bytes).
 * All callers must validate the upper-layer checksum before rewriting/synthesis. */
typedef struct {
    uint8_t family, protocol, ttl;
    uint8_t src[16], dst[16];
    size_t transport_offset, transport_length, total_length;
} db_ip_view_t;
db_packet_status_t db_ip_parse(const uint8_t *packet, size_t length, db_ip_view_t *view);
uint16_t db_transport_checksum(const db_ip_view_t *, const uint8_t *transport, size_t length);
/* Builds an IP envelope around an already initialized upper-layer message. */
size_t db_ip_build(uint8_t family, uint8_t protocol, const uint8_t *src, const uint8_t *dst,
                   const uint8_t *transport, size_t length, uint8_t *out, size_t capacity);

/* Parsing (validates version/IHL/length/fragment; does not verify checksums). */
db_packet_status_t db_ipv4_parse(const uint8_t *packet, size_t length, db_ipv4_view_t *view);
db_packet_status_t db_tcp_parse(const uint8_t *packet, size_t length, const db_ipv4_view_t *ip, db_tcp_view_t *view);

/* Checksums. */
uint16_t db_ipv4_header_checksum(const uint8_t *packet, size_t header_length);
uint16_t db_tcp_checksum(const uint8_t *packet, const db_ipv4_view_t *ip);
int db_ipv4_checksum_valid(const uint8_t *packet, size_t length);
int db_tcp_checksum_valid(const uint8_t *packet, size_t length);

/* Transparent rewrite. `mapping.original` is the full Mac->remote four-tuple. */
db_packet_status_t db_rewrite_to_local(uint8_t *packet, size_t length, const db_flow_mapping_t *mapping);
db_packet_status_t db_rewrite_from_local(uint8_t *packet, size_t length, const db_flow_mapping_t *mapping);

/* Fixed-capacity flow table with a 20000..20255 local-port pool. */
typedef struct db_flow_table db_flow_table_t;
db_flow_table_t *db_flow_table_create(uint16_t maximum_flows);
void db_flow_table_destroy(db_flow_table_t *table);
size_t db_flow_table_count(const db_flow_table_t *table);
/* Returns an existing mapping for the key, or allocates one with a fresh local port. */
db_packet_status_t db_flow_table_get_or_create(db_flow_table_t *table, const db_flow_key_t *key, db_flow_mapping_t *out);
db_packet_status_t db_flow_table_lookup(const db_flow_table_t *table, const db_flow_key_t *key, db_flow_mapping_t *out);
db_packet_status_t db_flow_table_lookup_by_local(const db_flow_table_t *table, uint16_t local_port, db_flow_mapping_t *out);
db_packet_status_t db_flow_table_remove(db_flow_table_t *table, const db_flow_key_t *key);

#ifdef __cplusplus
}
#endif

#endif
