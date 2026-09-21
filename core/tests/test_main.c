#include <stdio.h>
#include "test_support.h"

int test_failures = 0;

void run_dbp_codec_tests(void);
void run_destination_policy_tests(void);

int main(void) {
    run_dbp_codec_tests();
    run_destination_policy_tests();
    if (test_failures != 0) {
        fprintf(stderr, "%d assertion(s) failed\n", test_failures);
        return 1;
    }
    return 0;
}
