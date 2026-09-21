#include <stdio.h>
#include "test_support.h"

int test_failures = 0;

void run_dbp_codec_tests(void);
void run_destination_policy_tests(void);
void run_ipv4_tcp_tests(void);
void run_tcp_rewrite_tests(void);
void run_lwip_adapter_tests(void);
void run_packet_engine_tcp_tests(void);
void run_flow_limits_tests(void);
void run_dns_bridge_tests(void);

int main(void) {
    run_dbp_codec_tests();
    run_destination_policy_tests();
    run_ipv4_tcp_tests();
    run_tcp_rewrite_tests();
    run_lwip_adapter_tests();
    run_packet_engine_tcp_tests();
    run_flow_limits_tests();
    run_dns_bridge_tests();
    if (test_failures != 0) {
        fprintf(stderr, "%d assertion(s) failed\n", test_failures);
        return 1;
    }
    return 0;
}
