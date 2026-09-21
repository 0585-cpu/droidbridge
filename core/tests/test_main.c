#include <stdio.h>
int dbp_codec_self_test(void);

int main(void) {
    if (dbp_codec_self_test() != 0) {
        fprintf(stderr, "dbp codec self test failed\n");
        return 1;
    }
    return 0;
}
