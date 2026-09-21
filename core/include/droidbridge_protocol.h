/* DBP/1 wire codec. Structure validation only: no crypto, no I/O.
 * Wire format: protocol/dbp-v1.md. Fixtures: protocol/test-vectors/dbp-v1.json. */
#ifndef DROIDBRIDGE_PROTOCOL_H
#define DROIDBRIDGE_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DBP_HEADER_SIZE 64u
#define DBP_HMAC_SIZE 32u
#define DBP_MAX_DOMAIN_LENGTH 253u
#define DBP_OPEN_TCP_MAX_SIZE (4u + DBP_MAX_DOMAIN_LENGTH)

typedef enum {
    DBP_OK = 0,
    DBP_ERR_ARGUMENT = -1,
    DBP_ERR_TRUNCATED = -2,
    DBP_ERR_MAGIC = -3,
    DBP_ERR_HEADER_LENGTH = -4,
    DBP_ERR_MESSAGE_TYPE = -5,
    DBP_ERR_FLAGS = -6,
    DBP_ERR_ADDRESS_TYPE = -7,
    DBP_ERR_PORT = -8,
    DBP_ERR_DOMAIN_LENGTH = -9,
    DBP_ERR_OUTPUT_TOO_SMALL = -10
} dbp_status_t;

typedef enum {
    DBP_MESSAGE_HELLO = 0x01,
    DBP_MESSAGE_HELLO_OK = 0x02,
    DBP_MESSAGE_OPEN_TCP = 0x10,
    DBP_MESSAGE_OPEN_OK = 0x11,
    DBP_MESSAGE_OPEN_ERROR = 0x12,
    DBP_MESSAGE_DNS_QUERY = 0x20,
    DBP_MESSAGE_DNS_RESPONSE = 0x21,
    DBP_MESSAGE_HEALTH = 0x30,
    DBP_MESSAGE_HEALTH_RESPONSE = 0x31
} dbp_message_type_t;

typedef enum {
    DBP_ERROR_AUTH_FAILED = 1,
    DBP_ERROR_VERSION_UNSUPPORTED = 2,
    DBP_ERROR_POLICY_DENIED = 3,
    DBP_ERROR_CELLULAR_UNAVAILABLE = 4,
    DBP_ERROR_DNS_FAILED = 5,
    DBP_ERROR_CONNECT_TIMEOUT = 6,
    DBP_ERROR_CONNECT_REFUSED = 7,
    DBP_ERROR_SESSION_LIMIT = 8,
    DBP_ERROR_INTERNAL_ERROR = 9
} dbp_error_code_t;

typedef enum {
    DBP_ADDRESS_IPV4 = 1,
    DBP_ADDRESS_DOMAIN = 3
} dbp_address_type_t;

typedef struct {
    uint8_t message_type;
    uint8_t flags;
    uint64_t client_nonce;
    uint64_t server_nonce;
    uint64_t unix_time_seconds;
} dbp_header_fields_t;

typedef struct {
    uint8_t address_type;              /* dbp_address_type_t */
    uint16_t port;                     /* 1..65535 */
    uint8_t domain_length;             /* 1..253 when address_type is domain */
    uint8_t address[4];                /* valid when address_type is IPv4 */
    uint8_t domain[DBP_MAX_DOMAIN_LENGTH]; /* not NUL-terminated */
} dbp_open_tcp_t;

/* Writes exactly DBP_HEADER_SIZE bytes. `mac` may be NULL to write zeros
 * (the HMAC input form). Validates message type and flags. */
dbp_status_t dbp_encode_header(const dbp_header_fields_t *fields,
                               const uint8_t mac[DBP_HMAC_SIZE],
                               uint8_t *out, size_t out_size);

/* Reads the first DBP_HEADER_SIZE bytes of `in`. Never reads past `in_size`. */
dbp_status_t dbp_decode_header(const uint8_t *in, size_t in_size,
                               dbp_header_fields_t *fields,
                               uint8_t mac[DBP_HMAC_SIZE]);

dbp_status_t dbp_encode_open_tcp(const dbp_open_tcp_t *open,
                                 uint8_t *out, size_t out_size, size_t *written);

/* `in_size` must be exactly the payload length: trailing bytes are an error. */
dbp_status_t dbp_decode_open_tcp(const uint8_t *in, size_t in_size,
                                 dbp_open_tcp_t *open);

#ifdef __cplusplus
}
#endif

#endif
