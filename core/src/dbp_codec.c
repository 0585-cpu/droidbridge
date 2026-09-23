#include "droidbridge_protocol.h"

#include <string.h>

static const uint8_t DBP_MAGIC[4] = {'D', 'B', 'P', '1'};

/* Explicit big-endian helpers: buffers may be unaligned, never cast them. */
static uint16_t read_u16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

static uint64_t read_u64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | p[i];
    return v;
}

static void write_u16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static void write_u64(uint8_t *p, uint64_t v) {
    for (int i = 7; i >= 0; i--) {
        p[i] = (uint8_t)v;
        v >>= 8;
    }
}

static int message_type_is_known(uint8_t type) {
    switch (type) {
    case DBP_MESSAGE_HELLO: case DBP_MESSAGE_HELLO_OK:
    case DBP_MESSAGE_OPEN_TCP: case DBP_MESSAGE_OPEN_OK: case DBP_MESSAGE_OPEN_ERROR:
    case DBP_MESSAGE_DNS_QUERY: case DBP_MESSAGE_DNS_RESPONSE:
    case DBP_MESSAGE_HEALTH: case DBP_MESSAGE_HEALTH_RESPONSE:
    case DBP_MESSAGE_CAPABILITIES: case DBP_MESSAGE_CAPABILITIES_RESPONSE:
    case DBP_MESSAGE_OPEN_UDP: case DBP_MESSAGE_OPEN_UDP_OK:
    case DBP_MESSAGE_OPEN_UDP_ERROR: case DBP_MESSAGE_UDP_CLOSE:
    case DBP_MESSAGE_ICMP_ECHO: case DBP_MESSAGE_ICMP_ECHO_RESPONSE: case DBP_MESSAGE_ICMP_ECHO_ERROR:
        return 1;
    default:
        return 0;
    }
}

dbp_status_t dbp_encode_header(const dbp_header_fields_t *fields,
                               const uint8_t mac[DBP_HMAC_SIZE],
                               uint8_t *out, size_t out_size) {
    if (fields == NULL || out == NULL) return DBP_ERR_ARGUMENT;
    if (out_size < DBP_HEADER_SIZE) return DBP_ERR_OUTPUT_TOO_SMALL;
    if (!message_type_is_known(fields->message_type)) return DBP_ERR_MESSAGE_TYPE;
    if (fields->flags != 0) return DBP_ERR_FLAGS;

    memcpy(out, DBP_MAGIC, 4);
    out[4] = fields->message_type;
    out[5] = 0;
    write_u16(out + 6, (uint16_t)DBP_HEADER_SIZE);
    write_u64(out + 8, fields->client_nonce);
    write_u64(out + 16, fields->server_nonce);
    write_u64(out + 24, fields->unix_time_seconds);
    if (mac != NULL) memcpy(out + 32, mac, DBP_HMAC_SIZE);
    else memset(out + 32, 0, DBP_HMAC_SIZE);
    return DBP_OK;
}

dbp_status_t dbp_decode_header(const uint8_t *in, size_t in_size,
                               dbp_header_fields_t *fields,
                               uint8_t mac[DBP_HMAC_SIZE]) {
    if (in == NULL || fields == NULL || mac == NULL) return DBP_ERR_ARGUMENT;
    if (in_size < DBP_HEADER_SIZE) return DBP_ERR_TRUNCATED;
    if (memcmp(in, DBP_MAGIC, 4) != 0) return DBP_ERR_MAGIC;
    if (read_u16(in + 6) != DBP_HEADER_SIZE) return DBP_ERR_HEADER_LENGTH;
    if (!message_type_is_known(in[4])) return DBP_ERR_MESSAGE_TYPE;
    if (in[5] != 0) return DBP_ERR_FLAGS;

    fields->message_type = in[4];
    fields->flags = 0;
    fields->client_nonce = read_u64(in + 8);
    fields->server_nonce = read_u64(in + 16);
    fields->unix_time_seconds = read_u64(in + 24);
    memcpy(mac, in + 32, DBP_HMAC_SIZE);
    return DBP_OK;
}

dbp_status_t dbp_encode_open_tcp(const dbp_open_tcp_t *open,
                                 uint8_t *out, size_t out_size, size_t *written) {
    if (open == NULL || out == NULL || written == NULL) return DBP_ERR_ARGUMENT;
    if (open->port == 0) return DBP_ERR_PORT;

    size_t length;
    const uint8_t *address;
    switch (open->address_type) {
    case DBP_ADDRESS_IPV4:
        length = 4;
        address = open->address;
        break;
    case DBP_ADDRESS_IPV6:
        length = 16;
        address = open->address;
        break;
    case DBP_ADDRESS_DOMAIN:
        if (open->domain_length < 1 || open->domain_length > DBP_MAX_DOMAIN_LENGTH)
            return DBP_ERR_DOMAIN_LENGTH;
        length = open->domain_length;
        address = open->domain;
        break;
    default:
        return DBP_ERR_ADDRESS_TYPE;
    }
    if (out_size < 4 + length) return DBP_ERR_OUTPUT_TOO_SMALL;

    out[0] = open->address_type;
    write_u16(out + 1, open->port);
    out[3] = (uint8_t)length;
    memcpy(out + 4, address, length);
    *written = 4 + length;
    return DBP_OK;
}

dbp_status_t dbp_decode_open_tcp(const uint8_t *in, size_t in_size,
                                 dbp_open_tcp_t *open) {
    if (in == NULL || open == NULL) return DBP_ERR_ARGUMENT;
    if (in_size < 4) return DBP_ERR_TRUNCATED;

    uint8_t type = in[0];
    uint16_t port = read_u16(in + 1);
    uint8_t length = in[3];

    if (type != DBP_ADDRESS_IPV4 && type != DBP_ADDRESS_IPV6 && type != DBP_ADDRESS_DOMAIN) return DBP_ERR_ADDRESS_TYPE;
    if (port == 0) return DBP_ERR_PORT;
    if (type == DBP_ADDRESS_IPV4 && length != 4) return DBP_ERR_DOMAIN_LENGTH;
    if (type == DBP_ADDRESS_IPV6 && length != 16) return DBP_ERR_DOMAIN_LENGTH;
    if (type == DBP_ADDRESS_DOMAIN && (length < 1 || length > DBP_MAX_DOMAIN_LENGTH))
        return DBP_ERR_DOMAIN_LENGTH;
    if (in_size != 4u + length) return DBP_ERR_TRUNCATED;

    memset(open, 0, sizeof *open);
    open->address_type = type;
    open->port = port;
    if (type == DBP_ADDRESS_IPV4 || type == DBP_ADDRESS_IPV6) {
        memcpy(open->address, in + 4, length);
    } else {
        open->domain_length = length;
        memcpy(open->domain, in + 4, length);
    }
    return DBP_OK;
}
