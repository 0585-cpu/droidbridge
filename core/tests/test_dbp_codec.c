#include <stdint.h>
#include <string.h>
#include "droidbridge_protocol.h"
#include "dbp_vectors_generated.h"
#include "dbp_extensions_generated.h"
#include "test_support.h"

static void test_header_round_trip(void) {
    dbp_header_fields_t fields = {
        .message_type = DBP_MESSAGE_OPEN_TCP,
        .flags = 0,
        .client_nonce = UINT64_C(0x0102030405060708),
        .server_nonce = UINT64_C(0x1112131415161718),
        .unix_time_seconds = UINT64_C(1700000000),
    };
    uint8_t mac[DBP_HMAC_SIZE];
    uint8_t encoded[DBP_HEADER_SIZE] = {0};
    dbp_header_fields_t decoded = {0};
    uint8_t decoded_mac[DBP_HMAC_SIZE] = {0};
    for (unsigned i = 0; i < DBP_HMAC_SIZE; i++) mac[i] = (uint8_t)i;

    ASSERT_EQ_INT(DBP_OK, dbp_encode_header(&fields, mac, encoded, sizeof encoded));
    ASSERT_EQ_INT(DBP_OK, dbp_decode_header(encoded, sizeof encoded, &decoded, decoded_mac));
    ASSERT_EQ_INT(fields.message_type, decoded.message_type);
    ASSERT_EQ_INT(0, decoded.flags);
    ASSERT_EQ_U64(fields.client_nonce, decoded.client_nonce);
    ASSERT_EQ_U64(fields.server_nonce, decoded.server_nonce);
    ASSERT_EQ_U64(fields.unix_time_seconds, decoded.unix_time_seconds);
    ASSERT_MEM_EQ(mac, decoded_mac, DBP_HMAC_SIZE);
    ASSERT_EQ_INT(DBP_ERR_OUTPUT_TOO_SMALL, dbp_encode_header(&fields, mac, encoded, 63));
    ASSERT_EQ_INT(DBP_ERR_ARGUMENT, dbp_encode_header(NULL, mac, encoded, sizeof encoded));
}

static void test_header_matches_fixture_vectors(void) {
    for (size_t i = 0; i < sizeof dbp_vectors / sizeof dbp_vectors[0]; i++) {
        const dbp_vector_t *v = &dbp_vectors[i];
        dbp_header_fields_t decoded = {0};
        uint8_t mac[DBP_HMAC_SIZE];
        uint8_t reencoded[DBP_HEADER_SIZE];
        ASSERT_EQ_INT(DBP_OK, dbp_decode_header(v->packet, v->packet_size, &decoded, mac));
        ASSERT_EQ_INT(v->message_type, decoded.message_type);
        ASSERT_EQ_U64(v->client_nonce, decoded.client_nonce);
        ASSERT_EQ_U64(v->server_nonce, decoded.server_nonce);
        ASSERT_EQ_U64(v->unix_time, decoded.unix_time_seconds);
        ASSERT_EQ_INT(DBP_OK, dbp_encode_header(&decoded, mac, reencoded, sizeof reencoded));
        ASSERT_MEM_EQ(v->packet, reencoded, DBP_HEADER_SIZE);
    }
}

static void test_truncated_and_bad_magic_are_rejected(void) {
    uint8_t bytes[DBP_HEADER_SIZE] = {0};
    dbp_header_fields_t fields = {0};
    uint8_t mac[DBP_HMAC_SIZE] = {0};
    ASSERT_EQ_INT(DBP_ERR_TRUNCATED, dbp_decode_header(bytes, 63, &fields, mac));
    ASSERT_EQ_INT(DBP_ERR_TRUNCATED, dbp_decode_header(bytes, 0, &fields, mac));
    ASSERT_EQ_INT(DBP_ERR_MAGIC, dbp_decode_header(bytes, sizeof bytes, &fields, mac));
    ASSERT_EQ_INT(DBP_ERR_ARGUMENT, dbp_decode_header(NULL, sizeof bytes, &fields, mac));
}

static void mutate_vector(uint8_t out[DBP_HEADER_SIZE], size_t offset, uint8_t value) {
    memcpy(out, dbp_vector_hello_bytes, DBP_HEADER_SIZE);
    out[offset] = value;
}

static void test_header_field_validation(void) {
    uint8_t bytes[DBP_HEADER_SIZE];
    dbp_header_fields_t fields = {0};
    uint8_t mac[DBP_HMAC_SIZE];

    mutate_vector(bytes, 5, 0x01); /* flags */
    ASSERT_EQ_INT(DBP_ERR_FLAGS, dbp_decode_header(bytes, sizeof bytes, &fields, mac));

    mutate_vector(bytes, 7, 0x3f); /* header length 63 */
    ASSERT_EQ_INT(DBP_ERR_HEADER_LENGTH, dbp_decode_header(bytes, sizeof bytes, &fields, mac));
    mutate_vector(bytes, 7, 0x41); /* header length 65 */
    ASSERT_EQ_INT(DBP_ERR_HEADER_LENGTH, dbp_decode_header(bytes, sizeof bytes, &fields, mac));
    mutate_vector(bytes, 6, 0x01); /* header length 0x0140 */
    ASSERT_EQ_INT(DBP_ERR_HEADER_LENGTH, dbp_decode_header(bytes, sizeof bytes, &fields, mac));

    static const uint8_t known[] = {0x01, 0x02, 0x10, 0x11, 0x12, 0x20, 0x21, 0x30, 0x31, 0x32, 0x33, 0x40, 0x41, 0x42, 0x43, 0x44, 0x60, 0x61, 0x62};
    for (unsigned type = 0; type < 256; type++) {
        int is_known = 0;
        for (size_t k = 0; k < sizeof known; k++) is_known |= (known[k] == type);
        mutate_vector(bytes, 4, (uint8_t)type);
        ASSERT_EQ_INT(is_known ? DBP_OK : DBP_ERR_MESSAGE_TYPE,
                      dbp_decode_header(bytes, sizeof bytes, &fields, mac));
    }
    /* encoder enforces the same rules */
    dbp_header_fields_t bad = {.message_type = 0x03};
    ASSERT_EQ_INT(DBP_ERR_MESSAGE_TYPE, dbp_encode_header(&bad, mac, bytes, sizeof bytes));
    bad.message_type = DBP_MESSAGE_HELLO;
    bad.flags = 1;
    ASSERT_EQ_INT(DBP_ERR_FLAGS, dbp_encode_header(&bad, mac, bytes, sizeof bytes));
}

static void test_open_tcp_ipv4_round_trip(void) {
    dbp_open_tcp_t open = {.address_type = DBP_ADDRESS_IPV4, .port = 443,
                           .address = {93, 184, 216, 34}};
    uint8_t out[DBP_OPEN_TCP_MAX_SIZE];
    size_t written = 0;
    dbp_open_tcp_t decoded = {0};

    ASSERT_EQ_INT(DBP_OK, dbp_encode_open_tcp(&open, out, sizeof out, &written));
    ASSERT_EQ_INT(8, written);
    ASSERT_MEM_EQ(dbp_vector_open_ipv4_443_bytes + DBP_HEADER_SIZE, out, written);
    ASSERT_EQ_INT(DBP_OK, dbp_decode_open_tcp(out, written, &decoded));
    ASSERT_EQ_INT(DBP_ADDRESS_IPV4, decoded.address_type);
    ASSERT_EQ_INT(443, decoded.port);
    ASSERT_MEM_EQ(open.address, decoded.address, 4);
    ASSERT_EQ_INT(DBP_ERR_OUTPUT_TOO_SMALL, dbp_encode_open_tcp(&open, out, 7, &written));
}

static void test_open_tcp_domain_round_trip(void) {
    dbp_open_tcp_t open = {.address_type = DBP_ADDRESS_DOMAIN, .port = 443, .domain_length = 11};
    memcpy(open.domain, "example.com", 11);
    uint8_t out[DBP_OPEN_TCP_MAX_SIZE];
    size_t written = 0;
    dbp_open_tcp_t decoded = {0};

    ASSERT_EQ_INT(DBP_OK, dbp_encode_open_tcp(&open, out, sizeof out, &written));
    ASSERT_EQ_INT(15, written);
    ASSERT_MEM_EQ(dbp_vector_open_domain_443_bytes + DBP_HEADER_SIZE, out, written);
    ASSERT_EQ_INT(DBP_OK, dbp_decode_open_tcp(out, written, &decoded));
    ASSERT_EQ_INT(DBP_ADDRESS_DOMAIN, decoded.address_type);
    ASSERT_EQ_INT(11, decoded.domain_length);
    ASSERT_MEM_EQ("example.com", decoded.domain, 11);

    /* maximum domain length 253 is accepted, no NUL on the wire */
    open.domain_length = DBP_MAX_DOMAIN_LENGTH;
    memset(open.domain, 'a', DBP_MAX_DOMAIN_LENGTH);
    ASSERT_EQ_INT(DBP_OK, dbp_encode_open_tcp(&open, out, sizeof out, &written));
    ASSERT_EQ_INT(4 + DBP_MAX_DOMAIN_LENGTH, written);
    ASSERT_EQ_INT(DBP_OK, dbp_decode_open_tcp(out, written, &decoded));
    ASSERT_EQ_INT(DBP_MAX_DOMAIN_LENGTH, decoded.domain_length);
}

static void test_open_tcp_rejections(void) {
    dbp_open_tcp_t decoded = {0};
    uint8_t out[DBP_OPEN_TCP_MAX_SIZE];
    size_t written = 0;

    /* zero port */
    uint8_t zero_port[] = {1, 0, 0, 4, 93, 184, 216, 34};
    ASSERT_EQ_INT(DBP_ERR_PORT, dbp_decode_open_tcp(zero_port, sizeof zero_port, &decoded));
    /* unknown address type (5, 4, 0, 255) */
    uint8_t bad_type[] = {5, 1, 187, 4, 93, 184, 216, 34};
    ASSERT_EQ_INT(DBP_ERR_ADDRESS_TYPE, dbp_decode_open_tcp(bad_type, sizeof bad_type, &decoded));
    bad_type[0] = 4;
    ASSERT_EQ_INT(DBP_ERR_ADDRESS_TYPE, dbp_decode_open_tcp(bad_type, sizeof bad_type, &decoded));
    bad_type[0] = 0;
    ASSERT_EQ_INT(DBP_ERR_ADDRESS_TYPE, dbp_decode_open_tcp(bad_type, sizeof bad_type, &decoded));
    bad_type[0] = 255;
    ASSERT_EQ_INT(DBP_ERR_ADDRESS_TYPE, dbp_decode_open_tcp(bad_type, sizeof bad_type, &decoded));
    /* IPv4 with wrong length */
    uint8_t bad_ipv4_len[] = {1, 1, 187, 3, 93, 184, 216};
    ASSERT_EQ_INT(DBP_ERR_DOMAIN_LENGTH, dbp_decode_open_tcp(bad_ipv4_len, sizeof bad_ipv4_len, &decoded));
    /* domain length 0 */
    uint8_t empty_domain[] = {3, 1, 187, 0};
    ASSERT_EQ_INT(DBP_ERR_DOMAIN_LENGTH, dbp_decode_open_tcp(empty_domain, sizeof empty_domain, &decoded));
    /* domain length 254 */
    uint8_t long_domain[4 + 254];
    memset(long_domain, 'a', sizeof long_domain);
    long_domain[0] = 3; long_domain[1] = 1; long_domain[2] = 187; long_domain[3] = 254;
    ASSERT_EQ_INT(DBP_ERR_DOMAIN_LENGTH, dbp_decode_open_tcp(long_domain, sizeof long_domain, &decoded));
    /* truncated: header only, and declared length longer than buffer */
    uint8_t truncated[] = {3, 1, 187, 11, 'e', 'x', 'a'};
    ASSERT_EQ_INT(DBP_ERR_TRUNCATED, dbp_decode_open_tcp(truncated, sizeof truncated, &decoded));
    ASSERT_EQ_INT(DBP_ERR_TRUNCATED, dbp_decode_open_tcp(truncated, 3, &decoded));
    /* trailing garbage after the address is not allowed */
    uint8_t trailing[] = {1, 1, 187, 4, 93, 184, 216, 34, 0};
    ASSERT_EQ_INT(DBP_ERR_TRUNCATED, dbp_decode_open_tcp(trailing, sizeof trailing, &decoded));

    /* encoder rejects the same */
    dbp_open_tcp_t bad = {.address_type = DBP_ADDRESS_IPV4, .port = 0};
    ASSERT_EQ_INT(DBP_ERR_PORT, dbp_encode_open_tcp(&bad, out, sizeof out, &written));
    bad.port = 443; bad.address_type = 5;
    ASSERT_EQ_INT(DBP_ERR_ADDRESS_TYPE, dbp_encode_open_tcp(&bad, out, sizeof out, &written));
    bad.address_type = DBP_ADDRESS_DOMAIN; bad.domain_length = 0;
    ASSERT_EQ_INT(DBP_ERR_DOMAIN_LENGTH, dbp_encode_open_tcp(&bad, out, sizeof out, &written));
    bad.domain_length = 254;
    ASSERT_EQ_INT(DBP_ERR_DOMAIN_LENGTH, dbp_encode_open_tcp(&bad, out, sizeof out, &written));
    ASSERT_EQ_INT(DBP_ERR_ARGUMENT, dbp_decode_open_tcp(NULL, 8, &decoded));
    ASSERT_EQ_INT(DBP_ERR_ARGUMENT, dbp_encode_open_tcp(NULL, out, sizeof out, &written));
}

static void test_ipv6_open_preserves_all_address_bytes(void) {
    uint8_t wire[20] = {2, 1, 187, 16, 0x26, 0x06, 0x47, 0x00, 0x47, 0x00,
                       0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11};
    dbp_open_tcp_t decoded;
    ASSERT_EQ_INT(DBP_OK, dbp_decode_open_tcp(wire, sizeof wire, &decoded));
    ASSERT_TRUE(memcmp(decoded.address, wire + 4, 16) == 0);
    uint8_t out[20]; size_t n;
    ASSERT_EQ_INT(DBP_OK, dbp_encode_open_tcp(&decoded, out, sizeof out, &n));
    ASSERT_EQ_INT(20, n); ASSERT_TRUE(memcmp(out, wire, 20) == 0);
    wire[3] = 15;
    ASSERT_EQ_INT(DBP_ERR_DOMAIN_LENGTH, dbp_decode_open_tcp(wire, sizeof wire, &decoded));
}

/* Crypto is intentionally owned by Swift/Kotlin. The C codec must preserve
 * the canonical authenticated header bytes, including every HMAC byte. */
static void test_extension_headers_match_canonical_authenticated_vectors(void) {
    for (size_t i = 0; i < sizeof dbp_extension_vectors / sizeof dbp_extension_vectors[0]; i++) {
        const dbp_extension_vector_t *v = &dbp_extension_vectors[i];
        dbp_header_fields_t decoded = {0};
        uint8_t mac[DBP_HMAC_SIZE], encoded[DBP_HEADER_SIZE];
        ASSERT_EQ_INT(DBP_OK, dbp_decode_header(v->packet, v->packet_size, &decoded, mac));
        ASSERT_EQ_INT(v->message_type, decoded.message_type);
        ASSERT_EQ_INT(0, decoded.flags);
        ASSERT_EQ_U64(v->client_nonce, decoded.client_nonce);
        ASSERT_EQ_U64(v->server_nonce, decoded.server_nonce);
        ASSERT_EQ_U64(v->unix_time, decoded.unix_time_seconds);
        ASSERT_MEM_EQ(v->packet + 32, mac, DBP_HMAC_SIZE);
        dbp_header_fields_t fields = {.message_type=v->message_type, .flags=0,
            .client_nonce=v->client_nonce, .server_nonce=v->server_nonce, .unix_time_seconds=v->unix_time};
        ASSERT_EQ_INT(DBP_OK, dbp_encode_header(&fields, v->packet + 32, encoded, sizeof encoded));
        ASSERT_MEM_EQ(v->packet, encoded, sizeof encoded);
        ASSERT_EQ_INT(DBP_ERR_TRUNCATED, dbp_decode_header(v->packet, 63, &decoded, mac));
    }
}

static void test_ipv6_open_matches_canonical_extension_vector(void) {
    const uint8_t *wire = dbp_extension_vector_open_tcp_ipv6_bytes + DBP_HEADER_SIZE;
    const size_t size = sizeof dbp_extension_vector_open_tcp_ipv6_bytes - DBP_HEADER_SIZE;
    const uint8_t expected[16] = {0x26,0x06,0x47,0x00,0x47,0x00,0,0,0,0,0,0,0,0,0x11,0x11};
    dbp_open_tcp_t open;
    ASSERT_EQ_INT(DBP_OK, dbp_decode_open_tcp(wire, size, &open));
    ASSERT_EQ_INT(DBP_ADDRESS_IPV6, open.address_type);
    ASSERT_EQ_INT(443, open.port);
    ASSERT_MEM_EQ(expected, open.address, sizeof expected);
    uint8_t output[21]; size_t written;
    ASSERT_EQ_INT(DBP_OK, dbp_encode_open_tcp(&open, output, sizeof output, &written));
    ASSERT_EQ_INT(20, written);
    ASSERT_MEM_EQ(wire, output, size);
    output[20] = 0;
    ASSERT_EQ_INT(DBP_ERR_TRUNCATED, dbp_decode_open_tcp(output, 21, &open));
    ASSERT_EQ_INT(DBP_ERR_TRUNCATED, dbp_decode_open_tcp(wire, size - 1, &open));
}

void run_dbp_codec_tests(void) {
    RUN(test_extension_headers_match_canonical_authenticated_vectors);
    RUN(test_ipv6_open_matches_canonical_extension_vector);
    RUN(test_ipv6_open_preserves_all_address_bytes);
    RUN(test_header_round_trip);
    RUN(test_header_matches_fixture_vectors);
    RUN(test_truncated_and_bad_magic_are_rejected);
    RUN(test_header_field_validation);
    RUN(test_open_tcp_ipv4_round_trip);
    RUN(test_open_tcp_domain_round_trip);
    RUN(test_open_tcp_rejections);
}
