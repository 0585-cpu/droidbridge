/* Serialized data plane. TCP uses lwIP for sequence/window/retransmission state.
 * IPv6 TCP envelopes are validated and converted to private IPv4 envelopes for
 * lwIP, then restored on emission. Original IPv6 endpoints remain in the flow
 * and are the only endpoints exposed to relay callbacks and destination policy. */
#include "droidbridge_core.h"
#include "droidbridge_dns.h"
#include "droidbridge_lwip.h"
#include "droidbridge_packet.h"
#include "droidbridge_policy.h"
#include "droidbridge_protocol.h"

#include "lwip/ip4_addr.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"

#include <stdlib.h>
#include <string.h>

#define DB_TCP_OPENING_TIMEOUT_MS 30000u
#define DB_MAC_BUFFER_MAX (64 * 1024)   /* Mac->relay bytes buffered before OPEN_OK / under backpressure */
#define DB_RELAY_QUEUE_MAX (256 * 1024) /* relay->Mac bytes queued into lwIP at once */

typedef enum { FLOW_FREE = 0, FLOW_OPENING, FLOW_OPEN, FLOW_MAC_CLOSED, FLOW_CLOSING } flow_state_t;

struct db_engine; /* fwd */

typedef struct {
    struct db_engine *engine;
    flow_state_t state;
    db_flow_id_t id;
    db_flow_mapping_t mapping;
    uint8_t family, src_ip[16], dst_ip[16];
    struct tcp_pcb *listen_pcb;
    struct tcp_pcb *conn_pcb;
    uint32_t opening_started;
    int relay_opened;
    int relay_eof; /* retain queued download bytes until acknowledged before closing */
    int relay_fin_requested;
    int mac_fin_notified;
    uint32_t half_close_touched;
    uint8_t *mac_buffer; /* Mac data awaiting relay open or relay backpressure */
    size_t mac_buffer_len;
    size_t relay_queued;   /* bytes currently in lwIP sndbuf for this flow */
    uint8_t *relay_buffer; /* relay data waiting for space in the lwIP send buffer */
    size_t relay_buffer_len;
} flow_t;

#define DB_UDP_LIMIT 256
#define DB_ICMP_LIMIT 64
#define DB_UDP_IDLE_MS 120000u
#define DB_REQUEST_TIMEOUT_MS 5000u
typedef struct {
    uint8_t family, src[16], dst[16];
    uint16_t sport, dport;
} packet_tuple_t;
typedef struct {
    int used;
    db_flow_id_t id;
    uint32_t touched;
    packet_tuple_t tuple;
} udp_flow_t;
typedef struct {
    int used;
    db_flow_id_t id;
    uint32_t started;
    packet_tuple_t tuple;
    uint8_t echo[4], payload[1200];
    size_t length;
} echo_request_t;
typedef struct {
    int used;
    db_flow_id_t id;
    uint32_t started;
    packet_tuple_t tuple;
    uint16_t txid;
} dns_request_t;

struct db_engine {
    db_engine_config_t config;
    db_lwip_context_t *lwip;
    db_flow_table_t *flow_table;
    flow_t *flows;
    db_flow_id_t next_id;
    size_t active;
    uint64_t capabilities;
    udp_flow_t udp[DB_UDP_LIMIT];
    size_t udp_active;
    uint64_t udp_drops;
    echo_request_t echo[DB_ICMP_LIMIT];
    dns_request_t dns_pending[DB_DNS_MAX_QUERIES];
    uint8_t nat64[16], nat64_bits;
};

/* ---- flow lookup / lifecycle ---- */

static flow_t *flow_by_id(db_engine_t *e, db_flow_id_t id) {
    for (uint16_t i = 0; i < e->config.maximum_flows; i++)
        if (e->flows[i].state != FLOW_FREE && e->flows[i].id == id)
            return &e->flows[i];
    return NULL;
}

static flow_t *flow_by_local_port(db_engine_t *e, uint16_t local_port) {
    for (uint16_t i = 0; i < e->config.maximum_flows; i++)
        if (e->flows[i].state != FLOW_FREE && e->flows[i].mapping.local_port == local_port)
            return &e->flows[i];
    return NULL;
}

static flow_t *alloc_flow(db_engine_t *e) {
    for (uint16_t i = 0; i < e->config.maximum_flows; i++)
        if (e->flows[i].state == FLOW_FREE)
            return &e->flows[i];
    return NULL;
}

static void free_flow(flow_t *f) {
    db_engine_t *e = f->engine;
    if (f->conn_pcb) {
        tcp_arg(f->conn_pcb, NULL);
        tcp_recv(f->conn_pcb, NULL);
        tcp_sent(f->conn_pcb, NULL);
        tcp_err(f->conn_pcb, NULL);
        tcp_abort(f->conn_pcb);
        f->conn_pcb = NULL;
    }
    if (f->listen_pcb) {
        db_lwip_abort_pending(f->listen_pcb);
        tcp_close(f->listen_pcb);
        f->listen_pcb = NULL;
    }
    free(f->mac_buffer);
    free(f->relay_buffer);
    db_flow_table_remove(e->flow_table, &f->mapping.original);
    if (e->active > 0)
        e->active--;
    memset(f, 0, sizeof *f);
}

/* Emit callback from lwIP: rewrite gateway:local_port -> original remote, then hand to the host. */
static void engine_emit(void *context, const uint8_t *packet, size_t length) {
    db_engine_t *e = context;
    db_ipv4_view_t ip;
    if (db_ipv4_parse(packet, length, &ip) != DB_PACKET_OK || ip.protocol != DB_IPPROTO_TCP)
        return;
    db_tcp_view_t tcp;
    if (db_tcp_parse(packet, length, &ip, &tcp) != DB_PACKET_OK)
        return;
    flow_t *f = flow_by_local_port(e, tcp.src_port);
    if (f == NULL)
        return;
    uint8_t scratch[2048];
    if (length > sizeof scratch)
        return;
    memcpy(scratch, packet, length);
    if (f->family == 6) {
        size_t n = ip.total_length - ip.header_length;
        uint8_t segment[DB_TUNNEL_MTU];
        if (n > sizeof segment)
            return;
        memcpy(segment, packet + ip.header_length, n);
        segment[0] = (uint8_t)(f->mapping.original.dst_port >> 8);
        segment[1] = (uint8_t)f->mapping.original.dst_port;
        segment[16] = segment[17] = 0;
        db_ip_view_t v = {.family = 6, .protocol = 6};
        memcpy(v.src, f->dst_ip, 16);
        memcpy(v.dst, f->src_ip, 16);
        uint16_t ck = db_transport_checksum(&v, segment, n);
        segment[16] = (uint8_t)(ck >> 8);
        segment[17] = (uint8_t)ck;
        size_t out = db_ip_build(6, 6, v.src, v.dst, segment, n, scratch, sizeof scratch);
        if (out)
            e->config.emit_packet(e->config.context, scratch, out);
        return;
    }
    if (db_rewrite_from_local(scratch, length, &f->mapping) != DB_PACKET_OK)
        return;
    e->config.emit_packet(e->config.context, scratch, length);
}

/* Push buffered Mac data to the relay. Returns -1 to abort the flow. */
static void finish_mac_eof(flow_t *f) {
    if (f->state != FLOW_MAC_CLOSED || !f->relay_opened || f->mac_buffer_len || f->mac_fin_notified)
        return;
    f->mac_fin_notified = 1;
    f->engine->config.close_flow(f->engine->config.context, f->id, DB_CLOSE_NORMAL);
    /* TIME_WAIT PCB may already be detached while this tail drained. */
    if (!f->conn_pcb && f->relay_fin_requested) free_flow(f);
}

static int drain_mac_buffer(flow_t *f) {
    db_engine_t *e = f->engine;
    if (!f->relay_opened || f->mac_buffer_len == 0)
        return 0;
    long accepted = e->config.send_flow(e->config.context, f->id, f->mac_buffer, f->mac_buffer_len);
    if (accepted == DB_SEND_ERROR)
        return -1;
    if (accepted == DB_SEND_AGAIN || accepted == 0)
        return 0;
    size_t took = (size_t)accepted >= f->mac_buffer_len ? f->mac_buffer_len : (size_t)accepted;
    memmove(f->mac_buffer, f->mac_buffer + took, f->mac_buffer_len - took);
    f->mac_buffer_len -= took;
    if ((f->relay_eof || f->state == FLOW_MAC_CLOSED) && e->config.now_ms)
        f->half_close_touched = e->config.now_ms(e->config.context);
    if (f->conn_pcb)
        tcp_recved(f->conn_pcb, (u16_t)took);
    return 0;
}

static int buffer_mac_data(flow_t *f, const uint8_t *data, size_t len) {
    if (f->mac_buffer_len + len > DB_MAC_BUFFER_MAX)
        return -1; /* overflow -> caller resets flow */
    uint8_t *grown = realloc(f->mac_buffer, f->mac_buffer_len + len);
    if (grown == NULL)
        return -1;
    f->mac_buffer = grown;
    memcpy(f->mac_buffer + f->mac_buffer_len, data, len);
    f->mac_buffer_len += len;
    return 0;
}

static int buffer_relay_data(flow_t *f, const uint8_t *data, size_t len) {
    if (len > DB_RELAY_QUEUE_MAX - f->relay_queued - f->relay_buffer_len)
        return -1;
    uint8_t *grown = realloc(f->relay_buffer, f->relay_buffer_len + len);
    if (grown == NULL)
        return -1;
    f->relay_buffer = grown;
    memcpy(f->relay_buffer + f->relay_buffer_len, data, len);
    f->relay_buffer_len += len;
    return 0;
}

static int drain_relay_buffer(flow_t *f) {
    while (f->conn_pcb && f->relay_buffer_len > 0) {
        u16_t sndbuf = tcp_sndbuf(f->conn_pcb);
        if (sndbuf == 0 || f->relay_queued >= DB_RELAY_QUEUE_MAX)
            break;
        size_t chunk = f->relay_buffer_len;
        if (chunk > sndbuf)
            chunk = sndbuf;
        if (chunk > DB_RELAY_QUEUE_MAX - f->relay_queued)
            chunk = DB_RELAY_QUEUE_MAX - f->relay_queued;
        if (chunk == 0)
            break;
        if (tcp_write(f->conn_pcb, f->relay_buffer, (u16_t)chunk, TCP_WRITE_FLAG_COPY) != ERR_OK)
            break;
        memmove(f->relay_buffer, f->relay_buffer + chunk, f->relay_buffer_len - chunk);
        f->relay_buffer_len -= chunk;
        f->relay_queued += chunk;
    }
    if (f->relay_buffer_len == 0) {
        free(f->relay_buffer);
        f->relay_buffer = NULL;
    }
    return f->conn_pcb ? tcp_output(f->conn_pcb) : ERR_CONN;
}

/* ---- lwIP pcb callbacks ---- */

static void lwip_err_cb(void *arg, err_t err) {
    flow_t *f = arg;
    if (f == NULL)
        return;
    f->conn_pcb = NULL; /* lwIP freed it */
    if (f->state != FLOW_FREE) {
        /* LAST_ACK can finish before a backpressured request tail reaches the relay.
         * Like TIME_WAIT, only the PCB is finished; preserve pending upload ownership. */
        if (err == ERR_CLSD && f->state == FLOW_MAC_CLOSED && !f->mac_fin_notified)
            return;
        f->engine->config.close_flow(f->engine->config.context, f->id,
                                     err == ERR_CLSD ? DB_CLOSE_COMPLETE : DB_CLOSE_RESET);
        free_flow(f);
    }
}

static err_t lwip_sent_cb(void *arg, struct tcp_pcb *pcb, u16_t len) {
    (void)pcb;
    flow_t *f = arg;
    if (f == NULL)
        return ERR_OK;
    f->relay_queued = (f->relay_queued >= len) ? f->relay_queued - len : 0;
    if ((f->relay_eof || f->state == FLOW_MAC_CLOSED) && len && f->engine->config.now_ms)
        f->half_close_touched = f->engine->config.now_ms(f->engine->config.context);
    if (drain_relay_buffer(f) != ERR_OK) {
        f->engine->config.close_flow(f->engine->config.context, f->id, DB_CLOSE_RESET);
        free_flow(f);
        return ERR_ABRT;
    }
    return ERR_OK;
}

static err_t lwip_recv_cb(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err) {
    flow_t *f = arg;
    if (f == NULL) {
        if (p)
            pbuf_free(p);
        return ERR_OK;
    }
    db_engine_t *e = f->engine;

    if (err != ERR_OK) {
        if (p)
            pbuf_free(p);
        return err;
    }
    if (p == NULL) {
        /* Mac sent FIN: half-close. Tell the relay via close_flow(NORMAL); keep conn for remote->Mac. */
        f->state = FLOW_MAC_CLOSED;
        f->half_close_touched = e->config.now_ms ? e->config.now_ms(e->config.context) : 0;
        finish_mac_eof(f);
        return ERR_OK;
    }

    /* Flatten pbuf and either send to relay or buffer. */
    uint8_t stackbuf[2048];
    uint8_t *bytes = stackbuf;
    uint8_t *heap = NULL;
    if (p->tot_len > sizeof stackbuf) {
        heap = malloc(p->tot_len);
        bytes = heap;
    }
    if (bytes == NULL) {
        pbuf_free(p);
        return ERR_MEM;
    }
    pbuf_copy_partial(p, bytes, p->tot_len, 0);
    u16_t total = p->tot_len;

    int abort_flow = 0;
    if (!f->relay_opened) {
        if (buffer_mac_data(f, bytes, total) != 0)
            abort_flow = 1;
        /* Buffered bytes still consume the peer's receive window. */
    } else if (f->mac_buffer_len > 0) {
        /* still draining an earlier backlog: append and keep order */
        if (buffer_mac_data(f, bytes, total) != 0)
            abort_flow = 1;
        else {
            if (drain_mac_buffer(f) != 0)
                abort_flow = 1;
        }
    } else {
        long accepted = e->config.send_flow(e->config.context, f->id, bytes, total);
        if (accepted == DB_SEND_ERROR)
            abort_flow = 1;
        else if (accepted == DB_SEND_AGAIN || accepted == 0) {
            if (buffer_mac_data(f, bytes, total) != 0)
                abort_flow = 1;

        } else {
            size_t took = (size_t)accepted >= total ? total : (size_t)accepted;
            if (took < total) {
                if (buffer_mac_data(f, bytes + took, total - took) != 0)
                    abort_flow = 1;
            }
            /* Credit only the accepted prefix; the buffered tail is credited on drain. */
            tcp_recved(pcb, (u16_t)took);
        }
    }

    if (!abort_flow && total && f->relay_eof && e->config.now_ms)
        f->half_close_touched = e->config.now_ms(e->config.context);
    free(heap);
    pbuf_free(p);
    if (abort_flow) {
        e->config.close_flow(e->config.context, f->id, DB_CLOSE_LIMIT);
        free_flow(f);
        return ERR_ABRT;
    }
    return ERR_OK;
}

static err_t lwip_accept_cb(void *arg, struct tcp_pcb *newpcb, err_t err) {
    flow_t *f = arg;
    if (f == NULL || err != ERR_OK || newpcb == NULL)
        return ERR_VAL;
    db_engine_t *e = f->engine;
    f->conn_pcb = newpcb;
    f->state = FLOW_OPEN;
    tcp_arg(newpcb, f);
    tcp_recv(newpcb, lwip_recv_cb);
    tcp_sent(newpcb, lwip_sent_cb);
    tcp_err(newpcb, lwip_err_cb);
    /* one listener served its single flow; close it so the port is not reused mid-flow */
    if (f->listen_pcb) {
        tcp_close(f->listen_pcb);
        f->listen_pcb = NULL;
    }
    if (e->config.open_flow_ip)
        e->config.open_flow_ip(e->config.context, f->id, f->family, f->dst_ip, f->mapping.original.dst_port);
    else if (f->family == 4)
        e->config.open_flow(e->config.context, f->id, f->dst_ip, f->mapping.original.dst_port);
    return ERR_OK;
}

/* Half-shutdown keeps the PCB callbacks and mapping alive for FIN retransmits/ACKs.
 * Full tcp_close transfers ownership to lwIP and can free the PCB without notifying us. */
static void finish_relay_eof(flow_t *f) {
    if (!f->relay_eof || f->relay_fin_requested || f->relay_queued || f->relay_buffer_len || !f->conn_pcb)
        return;
    if (tcp_shutdown(f->conn_pcb, 0, 1) == ERR_OK)
        f->relay_fin_requested = 1;
}

/* tcp_input has already emitted the final ACK. Reap immediately after input, before
 * another tcp_new or timer can silently recycle a TIME_WAIT PCB. */
static void reap_finished_flows(db_engine_t *e) {
    for (uint16_t i = 0; i < e->config.maximum_flows; i++) {
        flow_t *f = &e->flows[i];
        /* Only lwIP decides whether a RST is valid. Once it removes the unaccepted
         * child (RST, timer, or allocation failure), retire its engine slot too. */
        if (f->state == FLOW_OPENING && !db_lwip_has_pending(f->listen_pcb)) {
            free_flow(f);
            continue;
        }
        if (f->state != FLOW_FREE && f->conn_pcb && f->conn_pcb->state == TIME_WAIT) {
            /* Release lwIP ownership before its timers recycle the PCB, but retain a
             * backpressured upload until all accepted bytes and its FIN reach the relay. */
            tcp_arg(f->conn_pcb, NULL);
            tcp_err(f->conn_pcb, NULL);
            tcp_abort(f->conn_pcb); /* TIME_WAIT: no RST */
            f->conn_pcb = NULL;
            if (f->mac_fin_notified) free_flow(f);
        }
    }
}

/* ---- public API ---- */

db_engine_t *db_engine_create(const db_engine_config_t *config) {
    if (config == NULL || config->emit_packet == NULL ||
        (config->open_flow == NULL && config->open_flow_ip == NULL) || config->send_flow == NULL ||
        config->close_flow == NULL)
        return NULL;
    if (config->maximum_flows < 1 || config->maximum_flows > 256)
        return NULL;
    if (config->mtu != DB_TUNNEL_MTU)
        return NULL;

    db_engine_t *e = calloc(1, sizeof *e);
    if (e == NULL)
        return NULL;
    e->config = *config;
    e->flows = calloc(config->maximum_flows, sizeof *e->flows);
    e->flow_table = db_flow_table_create(config->maximum_flows);
    if (e->flows == NULL || e->flow_table == NULL) {
        db_engine_destroy(e);
        return NULL;
    }
    e->next_id = 1;
    e->capabilities = 1;

    e->lwip = db_lwip_init(engine_emit, e, (db_lwip_now_fn)config->now_ms,
                           (db_lwip_rand_fn)config->random_u32, config->context);
    if (e->lwip == NULL) {
        db_engine_destroy(e);
        return NULL;
    }
    return e;
}

void db_engine_destroy(db_engine_t *e) {
    if (e == NULL)
        return;
    if (e->flows) {
        for (uint16_t i = 0; i < e->config.maximum_flows; i++)
            if (e->flows[i].state != FLOW_FREE)
                free_flow(&e->flows[i]);
    }
    for (size_t i = 0; i < DB_UDP_LIMIT; i++)
        if (e->udp[i].used && e->config.close_udp)
            e->config.close_udp(e->config.context, e->udp[i].id, DB_CLOSE_NORMAL);
    if (e->lwip)
        db_lwip_shutdown(e->lwip);
    free(e->flows);
    if (e->flow_table)
        db_flow_table_destroy(e->flow_table);
    free(e);
}

/* Build and emit a bare RST back to the Mac for a SYN we refuse (flow limit). */
static void emit_rst_for_syn(db_engine_t *e, const uint8_t *packet, size_t length, const db_ipv4_view_t *ip,
                             const db_tcp_view_t *tcp) {
    (void)packet;
    (void)length;
    uint8_t rst[40];
    memset(rst, 0, sizeof rst);
    rst[0] = 0x45;
    rst[2] = 0;
    rst[3] = 40;
    rst[8] = 64;
    rst[9] = DB_IPPROTO_TCP;
    memcpy(rst + 12, ip->dst, 4); /* swap src/dst */
    memcpy(rst + 16, ip->src, 4);
    uint8_t *t = rst + 20;
    t[0] = (uint8_t)(tcp->dst_port >> 8);
    t[1] = (uint8_t)tcp->dst_port;
    t[2] = (uint8_t)(tcp->src_port >> 8);
    t[3] = (uint8_t)tcp->src_port;
    uint32_t ackno = tcp->seq + 1;
    t[8] = (uint8_t)(ackno >> 24);
    t[9] = (uint8_t)(ackno >> 16);
    t[10] = (uint8_t)(ackno >> 8);
    t[11] = (uint8_t)ackno;
    t[12] = 5 << 4;
    t[13] = DB_TCP_RST | DB_TCP_ACK;
    /* checksums */
    uint16_t ipck;
    {
        db_ipv4_view_t v;
        if (db_ipv4_parse(rst, 40, &v) == DB_PACKET_OK) {
            ipck = db_ipv4_header_checksum(rst, 20);
            rst[10] = (uint8_t)(ipck >> 8);
            rst[11] = (uint8_t)ipck;
            uint16_t tck = db_tcp_checksum(rst, &v);
            t[16] = (uint8_t)(tck >> 8);
            t[17] = (uint8_t)tck;
        }
    }
    e->config.emit_packet(e->config.context, rst, 40);
}

static db_engine_status_t engine_input_tcp4(db_engine_t *e, const uint8_t *packet, size_t length,
                                            const db_ip_view_t *original) {
    if (e == NULL || packet == NULL)
        return DB_ENGINE_ERR_ARGUMENT;
    db_ipv4_view_t ip;
    if (db_ipv4_parse(packet, length, &ip) != DB_PACKET_OK)
        return DB_ENGINE_OK; /* drop non-IPv4/fragment */

    if (ip.protocol != DB_IPPROTO_TCP)
        return DB_ENGINE_OK; /* B1: no other protocols */
    db_tcp_view_t tcp;
    if (db_tcp_parse(packet, length, &ip, &tcp) != DB_PACKET_OK)
        return DB_ENGINE_OK;

    db_flow_key_t key;
    memcpy(key.src_ip, ip.src, 4);
    key.src_port = tcp.src_port;
    memcpy(key.dst_ip, ip.dst, 4);
    key.dst_port = tcp.dst_port;

    db_flow_mapping_t mapping;
    int is_new = (db_flow_table_lookup(e->flow_table, &key, &mapping) != DB_PACKET_OK);

    if (is_new) {
        if ((tcp.flags & DB_TCP_SYN) == 0 || (tcp.flags & DB_TCP_ACK) != 0) {
            /* not a fresh SYN and unknown flow: ignore (could be stray ACK/RST) */
            return DB_ENGINE_OK;
        }
        if (e->active >= e->config.maximum_flows || e->active + e->udp_active >= 512) {
            emit_rst_for_syn(e, packet, length, &ip, &tcp);
            return DB_ENGINE_OK;
        }
        if (db_flow_table_get_or_create(e->flow_table, &key, &mapping) != DB_PACKET_OK) {
            emit_rst_for_syn(e, packet, length, &ip, &tcp);
            return DB_ENGINE_OK;
        }
        flow_t *f = alloc_flow(e);
        if (f == NULL) {
            db_flow_table_remove(e->flow_table, &key);
            return DB_ENGINE_OK;
        }
        memset(f, 0, sizeof *f);
        f->engine = e;
        f->state = FLOW_OPENING;
        f->opening_started = e->config.now_ms ? e->config.now_ms(e->config.context) : 0;
        e->active++; /* free_flow also balances failures while creating the listener. */
        f->id = e->next_id++;
        f->mapping = mapping;
        f->family = original->family;
        memcpy(f->src_ip, original->src, 16);
        memcpy(f->dst_ip, original->dst, 16);
        /* listener bound to gateway:local_port */
        struct tcp_pcb *lp = tcp_new();
        ip4_addr_t gw;
        IP4_ADDR(&gw, 198, 18, 0, 1);
        if (lp == NULL || tcp_bind(lp, &gw, mapping.local_port) != ERR_OK) {
            if (lp)
                tcp_close(lp);
            free_flow(f);
            return DB_ENGINE_OK;
        }
        struct tcp_pcb *listen = tcp_listen(lp);
        if (listen == NULL) {
            tcp_close(lp);
            free_flow(f);
            return DB_ENGINE_OK;
        }
        f->listen_pcb = listen;
        tcp_arg(listen, f);
        tcp_accept(listen, lwip_accept_cb);
    }

    /* rewrite to gateway:local_port and feed lwIP */
    uint8_t scratch[2048];
    if (length > sizeof scratch)
        return DB_ENGINE_OK;
    memcpy(scratch, packet, length);
    db_flow_mapping_t map2;
    if (db_flow_table_lookup(e->flow_table, &key, &map2) != DB_PACKET_OK)
        return DB_ENGINE_OK;
    if (db_rewrite_to_local(scratch, length, &map2) != DB_PACKET_OK)
        return DB_ENGINE_OK;
    db_lwip_input(e->lwip, scratch, length);
    reap_finished_flows(e);
    return DB_ENGINE_OK;
}

void db_engine_poll(db_engine_t *e) {
    if (e == NULL)
        return;
    uint32_t now = e->config.now_ms ? e->config.now_ms(e->config.context) : 0;
    for (size_t i = 0; i < DB_UDP_LIMIT; i++)
        if (e->udp[i].used && (uint32_t)(now - e->udp[i].touched) >= DB_UDP_IDLE_MS) {
            db_flow_id_t id = e->udp[i].id;
            e->udp[i].used = 0;
            e->udp_active--;
            if (e->config.close_udp)
                e->config.close_udp(e->config.context, id, DB_CLOSE_TIMEOUT);
        }
    for (size_t i = 0; i < DB_ICMP_LIMIT; i++)
        if (e->echo[i].used && (uint32_t)(now - e->echo[i].started) >= DB_REQUEST_TIMEOUT_MS)
            e->echo[i].used = 0;
    for (size_t i = 0; i < DB_DNS_MAX_QUERIES; i++)
        if (e->dns_pending[i].used && (uint32_t)(now - e->dns_pending[i].started) >= DB_REQUEST_TIMEOUT_MS)
            e->dns_pending[i].used = 0;
    reap_finished_flows(e);
    db_lwip_poll(e->lwip);
    reap_finished_flows(e);
    for (uint16_t i = 0; i < e->config.maximum_flows; i++) {
        flow_t *f = &e->flows[i];
        if (f->state == FLOW_FREE) continue;
        if (f->state == FLOW_OPENING && (uint32_t)(now - f->opening_started) >= DB_TCP_OPENING_TIMEOUT_MS) {
            free_flow(f); /* No relay callback exists until the final handshake ACK. */
            continue;
        }
        /* Bound either abandoned half-close by five minutes without byte/ACK progress.
         * An active response after client FIN refreshes this deadline. */
        if ((f->relay_eof || f->state == FLOW_MAC_CLOSED) &&
            (uint32_t)(now - f->half_close_touched) >= 300000u) {
            e->config.close_flow(e->config.context, f->id, DB_CLOSE_TIMEOUT);
            free_flow(f);
            continue;
        }
        if (f->relay_buffer_len && drain_relay_buffer(f) != ERR_OK) {
            e->config.close_flow(e->config.context, f->id, DB_CLOSE_RESET);
            free_flow(f);
            continue;
        }
        finish_relay_eof(f);
    }
}

db_engine_status_t db_engine_on_relay_opened(db_engine_t *e, db_flow_id_t flow) {
    if (e == NULL)
        return DB_ENGINE_ERR_ARGUMENT;
    flow_t *f = flow_by_id(e, flow);
    if (f == NULL)
        return DB_ENGINE_ERR_UNKNOWN_FLOW;
    f->relay_opened = 1;
    if (drain_mac_buffer(f) != 0) {
        e->config.close_flow(e->config.context, f->id, DB_CLOSE_RESET);
        free_flow(f);
    } else finish_mac_eof(f);
    return DB_ENGINE_OK;
}

db_engine_status_t db_engine_on_relay_open_failed(db_engine_t *e, db_flow_id_t flow) {
    if (e == NULL)
        return DB_ENGINE_ERR_ARGUMENT;
    flow_t *f = flow_by_id(e, flow);
    if (f == NULL)
        return DB_ENGINE_ERR_UNKNOWN_FLOW;
    free_flow(f); /* tcp_abort in free_flow emits RST to the Mac */
    return DB_ENGINE_OK;
}

db_engine_status_t db_engine_on_relay_data(db_engine_t *e, db_flow_id_t flow, const uint8_t *data,
                                           size_t length) {
    if (e == NULL || data == NULL)
        return DB_ENGINE_ERR_ARGUMENT;
    flow_t *f = flow_by_id(e, flow);
    if (f == NULL || f->conn_pcb == NULL)
        return DB_ENGINE_ERR_UNKNOWN_FLOW;
    if (f->relay_eof) return DB_ENGINE_ERR_STATE;
    if (length > DB_RELAY_QUEUE_MAX) return DB_ENGINE_ERR_ARGUMENT;
    if (length > DB_RELAY_QUEUE_MAX - f->relay_queued - f->relay_buffer_len)
        return DB_ENGINE_AGAIN;
    if (length == 0) return DB_ENGINE_OK;
    if (buffer_relay_data(f, data, length) != 0) {
        e->config.close_flow(e->config.context, f->id, DB_CLOSE_LIMIT);
        free_flow(f);
        return DB_ENGINE_ERR_STATE;
    }
    if (drain_relay_buffer(f) != ERR_OK) {
        e->config.close_flow(e->config.context, f->id, DB_CLOSE_RESET);
        free_flow(f);
        return DB_ENGINE_ERR_STATE;
    }
    if ((f->relay_eof || f->state == FLOW_MAC_CLOSED) && e->config.now_ms)
        f->half_close_touched = e->config.now_ms(e->config.context);
    return DB_ENGINE_OK;
}

db_engine_status_t db_engine_on_relay_writable(db_engine_t *e, db_flow_id_t flow) {
    if (e == NULL)
        return DB_ENGINE_ERR_ARGUMENT;
    flow_t *f = flow_by_id(e, flow);
    if (f == NULL)
        return DB_ENGINE_ERR_UNKNOWN_FLOW;
    if (drain_mac_buffer(f) != 0) {
        e->config.close_flow(e->config.context, f->id, DB_CLOSE_RESET);
        free_flow(f);
    } else finish_mac_eof(f);
    return DB_ENGINE_OK;
}

db_engine_status_t db_engine_on_relay_closed(db_engine_t *e, db_flow_id_t flow, int is_error) {
    if (e == NULL)
        return DB_ENGINE_ERR_ARGUMENT;
    flow_t *f = flow_by_id(e, flow);
    if (f == NULL)
        return DB_ENGINE_ERR_UNKNOWN_FLOW;
    if (is_error) {
        free_flow(f); /* RST */
    } else if (f->conn_pcb) {
        if (!f->relay_eof) {
            f->relay_eof = 1;
            f->half_close_touched = e->config.now_ms ? e->config.now_ms(e->config.context) : 0;
        }
        finish_relay_eof(f);
    } else {
        free_flow(f);
    }
    return DB_ENGINE_OK;
}

size_t db_engine_active_flow_count(const db_engine_t *e) { return e ? e->active + e->udp_active : 0; }

static uint16_t read16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static void write16(uint8_t *p, uint16_t n) {
    p[0] = (uint8_t)(n >> 8);
    p[1] = (uint8_t)n;
}
static uint32_t engine_now(db_engine_t *e) {
    return e->config.now_ms ? e->config.now_ms(e->config.context) : 0;
}
static packet_tuple_t tuple_for(const db_ip_view_t *v, const uint8_t *t) {
    packet_tuple_t k = {.family = v->family, .sport = read16(t), .dport = read16(t + 2)};
    memcpy(k.src, v->src, 16);
    memcpy(k.dst, v->dst, 16);
    return k;
}
static int tuple_equal(const packet_tuple_t *a, const packet_tuple_t *b) {
    return a->family == b->family && a->sport == b->sport && a->dport == b->dport &&
           memcmp(a->src, b->src, 16) == 0 && memcmp(a->dst, b->dst, 16) == 0;
}
static int destination_allowed(db_engine_t *e, const db_ip_view_t *v) {
    return (v->family == 4 ? db_policy_check_ipv4(v->dst)
                           : db_policy_check_ipv6_nat64(v->dst, e->nat64, e->nat64_bits)) == DB_POLICY_ALLOW;
}
static udp_flow_t *udp_by_id(db_engine_t *e, db_flow_id_t id) {
    for (size_t i = 0; i < DB_UDP_LIMIT; i++)
        if (e->udp[i].used && e->udp[i].id == id)
            return &e->udp[i];
    return NULL;
}
static void emit_udp(db_engine_t *e, const packet_tuple_t *k, const uint8_t *data, size_t len) {
    uint8_t t[DB_TUNNEL_MTU - 20], out[DB_TUNNEL_MTU];
    write16(t, k->dport);
    write16(t + 2, k->sport);
    write16(t + 4, (uint16_t)(8 + len));
    t[6] = t[7] = 0;
    if (len)
        memcpy(t + 8, data, len);
    db_ip_view_t v = {.family = k->family, .protocol = 17};
    memcpy(v.src, k->dst, 16);
    memcpy(v.dst, k->src, 16);
    uint16_t ck = db_transport_checksum(&v, t, 8 + len);
    write16(t + 6, ck ? ck : 0xffff);
    size_t n = db_ip_build(k->family, 17, k->dst, k->src, t, 8 + len, out, sizeof out);
    if (n)
        e->config.emit_packet(e->config.context, out, n);
}
static void input_udp(db_engine_t *e, const db_ip_view_t *v, const uint8_t *t) {
    size_t n = v->transport_length;
    if (n < 8 || read16(t + 4) != n || (v->family == 6 && read16(t + 6) == 0) ||
        (read16(t + 6) != 0 && db_transport_checksum(v, t, n) != 0)) {
        e->udp_drops++;
        return;
    }
    packet_tuple_t key = tuple_for(v, t);
    size_t len = n - 8;
    const uint8_t *data = t + 8;
    /* DNS interception precedes remote address policy and general UDP capabilities. */
    if (key.dport == 53) {
        if (!db_dns_valid(data, len) || len > 1232 || !e->config.send_dns) {
            e->udp_drops++;
            return;
        }
        for (size_t i = 0; i < DB_DNS_MAX_QUERIES; i++)
            if (!e->dns_pending[i].used) {
                dns_request_t *q = &e->dns_pending[i];
                q->used = 1;
                q->id = e->next_id++;
                q->tuple = key;
                q->started = engine_now(e);
                q->txid = db_dns_transaction_id(data);
                e->config.send_dns(e->config.context, q->id, data, len);
                return;
            }
        e->udp_drops++;
        return;
    }
    uint64_t cap = v->family == 4 ? DB_CAP_UDP4 : DB_CAP_UDP6;
    if (!(e->capabilities & cap) || (!e->config.open_udp && !e->config.open_udp_endpoint) || !e->config.send_udp ||
        !destination_allowed(e, v) || len > DB_UDP_MAX_PAYLOAD || key.dport == 0) {
        e->udp_drops++;
        return;
    }
    udp_flow_t *f = NULL, *free_slot = NULL;
    for (size_t i = 0; i < DB_UDP_LIMIT; i++) {
        if (e->udp[i].used) {
            if (tuple_equal(&e->udp[i].tuple, &key)) {
                f = &e->udp[i];
                break;
            }
        } else if (!free_slot)
            free_slot = &e->udp[i];
    }
    if (!f) {
        if (!free_slot || e->active + e->udp_active >= 512) {
            e->udp_drops++;
            return;
        }
        f = free_slot;
        f->used = 1;
        f->id = e->next_id++;
        f->tuple = key;
        f->touched = engine_now(e);
        e->udp_active++;
        db_flow_id_t id = f->id;
        if (e->config.open_udp_endpoint)
            e->config.open_udp_endpoint(e->config.context, id, key.family, key.dst, key.dport, key.sport, key.src);
        else
            e->config.open_udp(e->config.context, id, key.family, key.dst, key.dport);
        /* A synchronous open failure may retire this flow. */
        f = udp_by_id(e, id);
        if (!f) {
            e->udp_drops++;
            return;
        }
    }
    f->touched = engine_now(e);
    e->config.send_udp(e->config.context, f->id, len ? data : NULL, len);
}
static void input_echo(db_engine_t *e, const db_ip_view_t *v, const uint8_t *t) {
    uint64_t cap = v->family == 4 ? DB_CAP_ICMP4_ECHO : DB_CAP_ICMP6_ECHO;
    size_t n = v->transport_length;
    if (!(e->capabilities & cap) || !e->config.send_icmp || n < 8 || n > 1208 ||
        t[0] != (v->family == 4 ? 8 : 128) || t[1] != 0 || db_transport_checksum(v, t, n) ||
        !destination_allowed(e, v))
        return;
    for (size_t i = 0; i < DB_ICMP_LIMIT; i++)
        if (!e->echo[i].used) {
            echo_request_t *q = &e->echo[i];
            q->used = 1;
            q->id = e->next_id++;
            q->started = engine_now(e);
            q->tuple = tuple_for(v, t);
            memcpy(q->echo, t + 4, 4);
            q->length = n - 8;
            if (q->length)
                memcpy(q->payload, t + 8, q->length);
            e->config.send_icmp(e->config.context, q->id, v->family, v->dst, v->ttl, q->length ? t + 8 : NULL,
                                q->length);
            return;
        }
}
db_engine_status_t db_engine_input_packet(db_engine_t *e, const uint8_t *p, size_t n) {
    if (!e || !p)
        return DB_ENGINE_ERR_ARGUMENT;
    db_ip_view_t v;
    if (n > e->config.mtu || db_ip_parse(p, n, &v) != DB_PACKET_OK) {
        if (n >= 10 && ((p[0] >> 4 == 4 && p[9] == 17) || (p[0] >> 4 == 6 && p[6] == 17)))
            e->udp_drops++;
        return DB_ENGINE_OK;
    }
    static const uint8_t mac4[4] = {198, 18, 0, 2};
    if (v.family == 4 && memcmp(v.src, mac4, 4) != 0)
        return DB_ENGINE_OK;
    if (v.family == 6) {
        uint8_t any = 0;
        for (unsigned i = 0; i < 16; i++)
            any |= v.src[i];
        if (!any || v.src[0] == 0xff)
            return DB_ENGINE_OK;
    }
    const uint8_t *t = p + v.transport_offset;
    if (v.protocol == 17) {
        input_udp(e, &v, t);
        return DB_ENGINE_OK;
    }
    if ((v.family == 4 && v.protocol == 1) || (v.family == 6 && v.protocol == 58)) {
        input_echo(e, &v, t);
        return DB_ENGINE_OK;
    }
    if (v.protocol != 6 || v.transport_length < 20 || (t[12] >> 4) < 5 ||
        (size_t)(t[12] >> 4) * 4 > v.transport_length || read16(t + 2) == 0 ||
        db_transport_checksum(&v, t, v.transport_length))
        return DB_ENGINE_OK;
    if (!(e->capabilities & (v.family == 4 ? DB_CAP_TCP4 : DB_CAP_TCP6)) || !destination_allowed(e, &v))
        return DB_ENGINE_OK;
    if (v.family == 4)
        return engine_input_tcp4(e, p, n, &v);
    if (!e->config.open_flow_ip)
        return DB_ENGINE_OK;
    /* IPv6 is a validated envelope around the same TCP stream. Internally lwIP
     * sees a private IPv4 envelope; its sequence/window/retransmission state is
     * unchanged. A unique synthetic destination per live slot avoids tuple
     * aliasing. Synthetic addresses never leave this engine or reach policy. */
    flow_t *flow = NULL;
    for (uint16_t i = 0; i < e->config.maximum_flows; i++) {
        flow_t *f = &e->flows[i];
        if (f->state != FLOW_FREE && f->family == 6 && f->mapping.original.src_port == read16(t) &&
            f->mapping.original.dst_port == read16(t + 2) && memcmp(f->src_ip, v.src, 16) == 0 &&
            memcmp(f->dst_ip, v.dst, 16) == 0) {
            flow = f;
            break;
        }
    }
    uint8_t synthetic[4] = {198, 19, 0, 0};
    if (flow)
        memcpy(synthetic, flow->mapping.original.dst_ip, 4);
    else {
        flow = alloc_flow(e);
        if (!flow)
            return DB_ENGINE_OK;
        size_t index = (size_t)(flow - e->flows);
        synthetic[2] = (uint8_t)(index >> 8);
        synthetic[3] = (uint8_t)index;
    }
    uint8_t segment[DB_TUNNEL_MTU], converted[DB_TUNNEL_MTU];
    memcpy(segment, t, v.transport_length);
    segment[16] = segment[17] = 0;
    db_ip_view_t internal = {.family = 4, .protocol = 6};
    memcpy(internal.src, mac4, 4);
    memcpy(internal.dst, synthetic, 4);
    write16(segment + 16, db_transport_checksum(&internal, segment, v.transport_length));
    size_t length = db_ip_build(4, 6, internal.src, internal.dst, segment, v.transport_length, converted,
                                sizeof converted);
    if (length)
        engine_input_tcp4(e, converted, length, &v);
    return DB_ENGINE_OK;
}
db_engine_status_t db_engine_on_udp_data(db_engine_t *e, db_flow_id_t id, const uint8_t *data, size_t len) {
    if (!e || (!data && len))
        return DB_ENGINE_ERR_ARGUMENT;
    udp_flow_t *f = udp_by_id(e, id);
    if (!f)
        return DB_ENGINE_ERR_UNKNOWN_FLOW;
    if (len > DB_UDP_MAX_PAYLOAD) {
        e->udp_drops++;
        return DB_ENGINE_ERR_ARGUMENT;
    }
    f->touched = engine_now(e);
    emit_udp(e, &f->tuple, data, len);
    return DB_ENGINE_OK;
}
db_engine_status_t db_engine_on_udp_closed(db_engine_t *e, db_flow_id_t id) {
    if (!e)
        return DB_ENGINE_ERR_ARGUMENT;
    udp_flow_t *f = udp_by_id(e, id);
    if (!f)
        return DB_ENGINE_ERR_UNKNOWN_FLOW;
    f->used = 0;
    e->udp_active--;
    return DB_ENGINE_OK;
}
db_engine_status_t db_engine_on_dns_response(db_engine_t *e, db_flow_id_t id, const uint8_t *data,
                                             size_t len) {
    if (!e || !data)
        return DB_ENGINE_ERR_ARGUMENT;
    for (size_t i = 0; i < DB_DNS_MAX_QUERIES; i++)
        if (e->dns_pending[i].used && e->dns_pending[i].id == id) {
            dns_request_t q = e->dns_pending[i];
            e->dns_pending[i].used = 0;
            if (!db_dns_valid(data, len) || len > 1232 || db_dns_transaction_id(data) != q.txid)
                return DB_ENGINE_ERR_STATE;
            emit_udp(e, &q.tuple, data, len);
            return DB_ENGINE_OK;
        }
    return DB_ENGINE_ERR_UNKNOWN_FLOW;
}
db_engine_status_t db_engine_on_icmp_response(db_engine_t *e, db_flow_id_t id, const uint8_t *data,
                                              size_t len) {
    if (!e || (!data && len))
        return DB_ENGINE_ERR_ARGUMENT;
    for (size_t i = 0; i < DB_ICMP_LIMIT; i++)
        if (e->echo[i].used && e->echo[i].id == id) {
            echo_request_t q = e->echo[i];
            e->echo[i].used = 0;
            if ((uint32_t)(engine_now(e) - q.started) >= DB_REQUEST_TIMEOUT_MS)
                return DB_ENGINE_ERR_UNKNOWN_FLOW;
            if (len != q.length || (len && memcmp(data, q.payload, len)))
                return DB_ENGINE_ERR_STATE;
            uint8_t t[1208] = {0}, out[DB_TUNNEL_MTU];
            t[0] = q.tuple.family == 4 ? 0 : 129;
            memcpy(t + 4, q.echo, 4);
            if (len)
                memcpy(t + 8, data, len);
            db_ip_view_t v = {.family = q.tuple.family, .protocol = q.tuple.family == 4 ? 1 : 58};
            memcpy(v.src, q.tuple.dst, 16);
            memcpy(v.dst, q.tuple.src, 16);
            write16(t + 2, db_transport_checksum(&v, t, 8 + len));
            size_t n = db_ip_build(v.family, v.protocol, v.src, v.dst, t, 8 + len, out, sizeof out);
            if (n)
                e->config.emit_packet(e->config.context, out, n);
            return n ? DB_ENGINE_OK : DB_ENGINE_ERR_STATE;
        }
    return DB_ENGINE_ERR_UNKNOWN_FLOW;
}
db_engine_status_t db_engine_on_icmp_failed(db_engine_t *e, db_flow_id_t id) {
    if (!e)
        return DB_ENGINE_ERR_ARGUMENT;
    for (size_t i = 0; i < DB_ICMP_LIMIT; i++)
        if (e->echo[i].used && e->echo[i].id == id) {
            e->echo[i].used = 0;
            return DB_ENGINE_OK;
        }
    return DB_ENGINE_ERR_UNKNOWN_FLOW;
}
size_t db_engine_udp_flow_count(const db_engine_t *e) { return e ? e->udp_active : 0; }
uint64_t db_engine_udp_drop_count(const db_engine_t *e) { return e ? e->udp_drops : 0; }
void db_engine_set_capabilities(db_engine_t *e, uint64_t flags) {
    if (!e)
        return;
    e->capabilities = flags;
    for (size_t i = 0; i < DB_UDP_LIMIT; i++)
        if (e->udp[i].used && !(flags & (e->udp[i].tuple.family == 4 ? DB_CAP_UDP4 : DB_CAP_UDP6))) {
            db_flow_id_t id = e->udp[i].id;
            e->udp[i].used = 0;
            e->udp_active--;
            if (e->config.close_udp)
                e->config.close_udp(e->config.context, id, DB_CLOSE_RESET);
        }
    for (size_t i = 0; i < DB_ICMP_LIMIT; i++)
        if (e->echo[i].used &&
            !(flags & (e->echo[i].tuple.family == 4 ? DB_CAP_ICMP4_ECHO : DB_CAP_ICMP6_ECHO)))
            e->echo[i].used = 0;
    for (uint16_t i = 0; i < e->config.maximum_flows; i++)
        if (e->flows[i].state != FLOW_FREE &&
            !(flags & (e->flows[i].family == 4 ? DB_CAP_TCP4 : DB_CAP_TCP6))) {
            e->config.close_flow(e->config.context, e->flows[i].id, DB_CLOSE_RESET);
            free_flow(&e->flows[i]);
        }
}
db_engine_status_t db_engine_set_nat64_prefix(db_engine_t *e, const uint8_t prefix[16], uint8_t bits) {
    if (!e)
        return DB_ENGINE_ERR_ARGUMENT;
    if (bits == 0) {
        memset(e->nat64, 0, 16);
        e->nat64_bits = 0;
        return DB_ENGINE_OK;
    }
    if (!prefix || !(bits == 32 || bits == 40 || bits == 48 || bits == 56 || bits == 64 || bits == 96))
        return DB_ENGINE_ERR_ARGUMENT;
    for (unsigned i = bits / 8; i < 16; i++)
        if (prefix[i])
            return DB_ENGINE_ERR_ARGUMENT;
    static const uint8_t wkp[16] = {0, 0x64, 0xff, 0x9b};
    if (!(bits == 96 && memcmp(prefix, wkp, 16) == 0) && db_policy_check_ipv6(prefix) != DB_POLICY_ALLOW)
        return DB_ENGINE_ERR_ARGUMENT;
    memcpy(e->nat64, prefix, 16);
    e->nat64_bits = bits;
    return DB_ENGINE_OK;
}
