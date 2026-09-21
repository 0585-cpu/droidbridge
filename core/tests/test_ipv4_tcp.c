#include <string.h>
#include "droidbridge_packet.h"
#include "packet_builder.h"
#include "test_support.h"

static void test_parse_valid_syn(void) {
    uint8_t p[128];
    size_t n = build_tcp_packet(p, sizeof p, "198.18.0.2", 50123, "93.184.216.34", 443, DB_TCP_SYN, NULL, 0);
    ASSERT_EQ_INT(40, (int)n);
    db_ipv4_view_t ip;
    ASSERT_EQ_INT(DB_PACKET_OK, db_ipv4_parse(p, n, &ip));
    ASSERT_EQ_INT(20, (int)ip.header_length);
    ASSERT_EQ_INT(DB_IPPROTO_TCP, ip.protocol);
    db_tcp_view_t tcp;
    ASSERT_EQ_INT(DB_PACKET_OK, db_tcp_parse(p, n, &ip, &tcp));
    ASSERT_EQ_INT(50123, tcp.src_port);
    ASSERT_EQ_INT(443, tcp.dst_port);
    ASSERT_EQ_INT(DB_TCP_SYN, tcp.flags);
    ASSERT_EQ_INT(1, db_ipv4_checksum_valid(p, n));
    ASSERT_EQ_INT(1, db_tcp_checksum_valid(p, n));
}

static void test_parse_rejections(void) {
    uint8_t p[128];
    size_t n = build_tcp_packet(p, sizeof p, "198.18.0.2", 1, "1.2.3.4", 2, DB_TCP_SYN, NULL, 0);
    db_ipv4_view_t ip;
    /* truncated */
    ASSERT_EQ_INT(DB_PACKET_ERR_TRUNCATED, db_ipv4_parse(p, 10, &ip));
    /* bad version */
    uint8_t bad = p[0]; p[0] = 0x65; ASSERT_EQ_INT(DB_PACKET_ERR_VERSION, db_ipv4_parse(p, n, &ip)); p[0] = bad;
    /* IHL < 5 */
    p[0] = 0x44; ASSERT_EQ_INT(DB_PACKET_ERR_IHL, db_ipv4_parse(p, n, &ip)); p[0] = 0x45;
    /* total length larger than buffer */
    uint8_t hi = p[2], lo = p[3]; p[2] = 0xFF; p[3] = 0xFF;
    ASSERT_EQ_INT(DB_PACKET_ERR_LENGTH, db_ipv4_parse(p, n, &ip)); p[2] = hi; p[3] = lo;
    /* MF fragment flag */
    p[6] = 0x20; ASSERT_EQ_INT(DB_PACKET_ERR_FRAGMENT, db_ipv4_parse(p, n, &ip)); p[6] = 0;
    /* non-zero fragment offset */
    p[6] = 0x00; p[7] = 0x01; ASSERT_EQ_INT(DB_PACKET_ERR_FRAGMENT, db_ipv4_parse(p, n, &ip)); p[7] = 0;
    /* non-TCP for tcp parse */
    ASSERT_EQ_INT(DB_PACKET_OK, db_ipv4_parse(p, n, &ip));
    ip.protocol = DB_IPPROTO_UDP;
    db_tcp_view_t tcp;
    ASSERT_EQ_INT(DB_PACKET_ERR_PROTOCOL, db_tcp_parse(p, n, &ip, &tcp));
}

static void test_checksum_detects_corruption(void) {
    uint8_t p[128];
    size_t n = build_tcp_packet(p, sizeof p, "198.18.0.2", 1, "1.2.3.4", 2, DB_TCP_ACK, (const uint8_t *)"hello", 5);
    ASSERT_EQ_INT(1, db_ipv4_checksum_valid(p, n));
    ASSERT_EQ_INT(1, db_tcp_checksum_valid(p, n));
    p[24] ^= 0xFF; /* flip a TCP header byte */
    ASSERT_EQ_INT(0, db_tcp_checksum_valid(p, n));
    p[24] ^= 0xFF;
    p[12] ^= 0xFF; /* flip a source IP byte */
    ASSERT_EQ_INT(0, db_ipv4_checksum_valid(p, n));
}

void run_ipv4_tcp_tests(void) {
    RUN(test_parse_valid_syn);
    RUN(test_parse_rejections);
    RUN(test_checksum_detects_corruption);
}
