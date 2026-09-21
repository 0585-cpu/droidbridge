#include "lwip_port.h"
#include "lwip/sys.h"
#include <stdlib.h>

static db_lwip_now_fn g_now = NULL;
static void *g_now_ctx = NULL;
static db_lwip_rand_fn g_rand = NULL;
static void *g_rand_ctx = NULL;

void db_lwip_port_set_clock(db_lwip_now_fn now, void *context) { g_now = now; g_now_ctx = context; }
void db_lwip_port_set_random(db_lwip_rand_fn rand_fn, void *context) { g_rand = rand_fn; g_rand_ctx = context; }

u32_t sys_now(void) { return g_now ? g_now(g_now_ctx) : 0; }

u32_t db_lwip_rand(void) { return g_rand ? g_rand(g_rand_ctx) : (u32_t)rand(); }
