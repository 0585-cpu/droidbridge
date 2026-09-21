/* Minimal lwIP architecture header for the NO_SYS macOS/clang port. */
#ifndef DROIDBRIDGE_ARCH_CC_H
#define DROIDBRIDGE_ARCH_CC_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>

#define LWIP_NO_STDINT_H 0
#define LWIP_NO_INTTYPES_H 0

/* Injected RNG (defined in lwip_port.c). */
uint32_t db_lwip_rand(void);
#define LWIP_RAND() (db_lwip_rand())

#define LWIP_PLATFORM_DIAG(x) do { printf x; } while (0)
#define LWIP_PLATFORM_ASSERT(x) do { \
    fprintf(stderr, "lwip assert: %s at %s:%d\n", x, __FILE__, __LINE__); abort(); } while (0)

#endif
