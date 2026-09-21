#ifndef DBP_TEST_SUPPORT_H
#define DBP_TEST_SUPPORT_H
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

extern int test_failures;

#define FAIL_AT(fmt, ...) \
    do { test_failures++; fprintf(stderr, "%s:%d: " fmt "\n", __FILE__, __LINE__, __VA_ARGS__); } while (0)

#define ASSERT_EQ_INT(expected, actual) \
    do { long long e_ = (long long)(expected), a_ = (long long)(actual); \
         if (e_ != a_) FAIL_AT("expected %lld, got %lld (%s)", e_, a_, #actual); } while (0)

#define ASSERT_EQ_U64(expected, actual) \
    do { uint64_t e_ = (expected), a_ = (actual); \
         if (e_ != a_) FAIL_AT("expected 0x%016" PRIx64 ", got 0x%016" PRIx64 " (%s)", e_, a_, #actual); } while (0)

#define ASSERT_MEM_EQ(expected, actual, size) \
    do { if (memcmp((expected), (actual), (size)) != 0) FAIL_AT("memory differs over %zu bytes (%s)", (size_t)(size), #actual); } while (0)

#define RUN(test) do { fprintf(stderr, "  %s\n", #test); test(); } while (0)

#endif
