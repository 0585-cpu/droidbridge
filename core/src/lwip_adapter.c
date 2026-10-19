/* Minimal lwIP NO_SYS port: one netif at 198.18.0.1/30, packet in/out via engine callbacks. */
#include "droidbridge_lwip.h"
#include "droidbridge_packet.h"
#include "lwip_port.h"

#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/ip4_addr.h"
#include "lwip/pbuf.h"
#include "lwip/timeouts.h"
#include "lwip/tcp.h"
#include "lwip/priv/tcp_priv.h"
#include "netif/ethernet.h"

#include <stdlib.h>
#include <string.h>

struct db_lwip_context {
    struct netif netif;
    db_lwip_emit_fn emit;
    void *emit_context;
    uint8_t scratch[2048]; /* flatten pbuf chains here before emitting */
};

/* lwIP owns process-global pools and timer lists; lwip_init() is not a session reset.
 * All adapter calls are serialized by the host, with at most one live netif. */
static int stack_initialized;
static db_lwip_context_t *active_context;

/* netif output: flatten the pbuf chain into one contiguous IPv4 packet and hand it to the engine.
 * Never retains lwIP-owned memory after returning. */
static err_t db_netif_output(struct netif *netif, struct pbuf *p, const ip4_addr_t *ipaddr) {
    (void)ipaddr;
    struct db_lwip_context *ctx = (struct db_lwip_context *)netif->state;
    if (p->tot_len > sizeof ctx->scratch) return ERR_MEM;
    u16_t copied = pbuf_copy_partial(p, ctx->scratch, p->tot_len, 0);
    if (copied != p->tot_len) return ERR_BUF;
    if (ctx->emit) ctx->emit(ctx->emit_context, ctx->scratch, copied);
    return ERR_OK;
}

static err_t db_netif_init(struct netif *netif) {
    netif->name[0] = 'd';
    netif->name[1] = 'b';
    netif->output = db_netif_output;
    netif->mtu = DB_TUNNEL_MTU;
    netif->flags = NETIF_FLAG_UP | NETIF_FLAG_LINK_UP;
    return ERR_OK;
}

db_lwip_context_t *db_lwip_init(db_lwip_emit_fn emit, void *emit_context,
                                db_lwip_now_fn now, db_lwip_rand_fn rand_fn, void *clock_context) {
    if (active_context != NULL) return NULL;
    db_lwip_context_t *ctx = calloc(1, sizeof *ctx);
    if (ctx == NULL) return NULL;
    ctx->emit = emit;
    ctx->emit_context = emit_context;

    db_lwip_port_set_clock(now, clock_context);
    db_lwip_port_set_random(rand_fn, clock_context);
    if (!stack_initialized) {
        lwip_init();
        stack_initialized = 1;
    } else {
        /* The previous session may have been stopped for a long time, or used a different
         * test clock. Rebase pending timers without reinitializing their memory pools. */
        sys_restart_timeouts();
    }

    ip4_addr_t addr, netmask, gateway;
    IP4_ADDR(&addr, 198, 18, 0, 1);
    IP4_ADDR(&netmask, 255, 255, 255, 252);
    IP4_ADDR(&gateway, 198, 18, 0, 1);

    if (netif_add(&ctx->netif, &addr, &netmask, &gateway, ctx, db_netif_init, ip_input) == NULL) {
        db_lwip_port_set_clock(NULL, NULL);
        db_lwip_port_set_random(NULL, NULL);
        free(ctx);
        return NULL;
    }
    netif_set_default(&ctx->netif);
    netif_set_up(&ctx->netif);
    netif_set_link_up(&ctx->netif);
    active_context = ctx;
    return ctx;
}

db_lwip_status_t db_lwip_input(db_lwip_context_t *ctx, const uint8_t *packet, size_t length) {
    if (ctx == NULL || packet == NULL) return DB_LWIP_ERR_ARGUMENT;
    if (length == 0 || length > 2048) return DB_LWIP_ERR_ARGUMENT;
    struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)length, PBUF_POOL);
    if (p == NULL) return DB_LWIP_ERR_MEMORY;
    if (pbuf_take(p, packet, (u16_t)length) != ERR_OK) { pbuf_free(p); return DB_LWIP_ERR_MEMORY; }
    if (ctx->netif.input(p, &ctx->netif) != ERR_OK) { pbuf_free(p); return DB_LWIP_ERR_INPUT; }
    return DB_LWIP_OK;
}

void db_lwip_poll(db_lwip_context_t *ctx) {
    if (ctx != NULL && ctx == active_context) sys_check_timeouts();
}

struct netif *db_lwip_netif(db_lwip_context_t *ctx) { return ctx ? &ctx->netif : NULL; }

void db_lwip_address(db_lwip_context_t *ctx, uint8_t out[4]) {
    const ip4_addr_t *a = netif_ip4_addr(&ctx->netif);
    uint32_t v = lwip_ntohl(ip4_addr_get_u32(a));
    out[0] = (uint8_t)(v >> 24); out[1] = (uint8_t)(v >> 16); out[2] = (uint8_t)(v >> 8); out[3] = (uint8_t)v;
}

void db_lwip_netmask(db_lwip_context_t *ctx, uint8_t out[4]) {
    const ip4_addr_t *a = netif_ip4_netmask(&ctx->netif);
    uint32_t v = lwip_ntohl(ip4_addr_get_u32(a));
    out[0] = (uint8_t)(v >> 24); out[1] = (uint8_t)(v >> 16); out[2] = (uint8_t)(v >> 8); out[3] = (uint8_t)v;
}

uint16_t db_lwip_mtu(db_lwip_context_t *ctx) { return ctx ? ctx->netif.mtu : 0; }

int db_lwip_has_pending(const struct tcp_pcb *listener) {
    if (listener == NULL) return 0;
    for (struct tcp_pcb *pcb = tcp_active_pcbs; pcb != NULL; pcb = pcb->next)
        if (pcb->state == SYN_RCVD && (const void *)pcb->listener == (const void *)listener) return 1;
    return 0;
}

void db_lwip_abort_pending(const struct tcp_pcb *listener) {
    if (listener == NULL) return;
    struct tcp_pcb *pcb = tcp_active_pcbs;
    while (pcb != NULL) {
        struct tcp_pcb *next = pcb->next;
        if (pcb->state == SYN_RCVD && (const void *)pcb->listener == (const void *)listener) {
            tcp_arg(pcb, NULL);
            tcp_err(pcb, NULL);
            tcp_abort(pcb);
        }
        pcb = next;
    }
}

void db_lwip_shutdown(db_lwip_context_t *ctx) {
    if (ctx == NULL || ctx != active_context) return;
    /* Engine-owned flows are already released. Gracefully closed TCP sockets can still
     * be in FIN_WAIT/TIME_WAIT; retire them before their netif and callback owner disappear. */
    ctx->emit = NULL;
    while (tcp_active_pcbs != NULL) {
        tcp_arg(tcp_active_pcbs, NULL);
        tcp_err(tcp_active_pcbs, NULL);
        tcp_abort(tcp_active_pcbs);
    }
    while (tcp_tw_pcbs != NULL) tcp_abort(tcp_tw_pcbs);
    while (tcp_bound_pcbs != NULL) {
        tcp_arg(tcp_bound_pcbs, NULL);
        tcp_err(tcp_bound_pcbs, NULL);
        tcp_abort(tcp_bound_pcbs);
    }
    while (tcp_listen_pcbs.pcbs != NULL) tcp_close(tcp_listen_pcbs.pcbs);
    netif_remove(&ctx->netif);
    active_context = NULL;
    db_lwip_port_set_clock(NULL, NULL);
    db_lwip_port_set_random(NULL, NULL);
    free(ctx);
}
