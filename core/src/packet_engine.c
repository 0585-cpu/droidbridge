/* B1 data-plane engine. Single serialized thread. Terminates Mac TCP flows in lwIP and bridges the
 * accepted byte stream to the Android relay through host callbacks. ponytail: the plan lists
 * tcp_bridge.c / flow_runtime.c separately; the engine is small enough to keep cohesive here. */
#include "droidbridge_core.h"
#include "droidbridge_packet.h"
#include "droidbridge_lwip.h"
#include "droidbridge_dns.h"

#include "lwip/tcp.h"
#include "lwip/ip4_addr.h"
#include "lwip/pbuf.h"

#include <stdlib.h>
#include <string.h>

#define DB_MAC_BUFFER_MAX (64 * 1024)     /* Mac->relay bytes buffered before OPEN_OK / under backpressure */
#define DB_RELAY_QUEUE_MAX (256 * 1024)   /* relay->Mac bytes queued into lwIP at once */

typedef enum { FLOW_FREE = 0, FLOW_OPENING, FLOW_OPEN, FLOW_MAC_CLOSED, FLOW_CLOSING } flow_state_t;

struct db_engine; /* fwd */

typedef struct {
    struct db_engine *engine;
    flow_state_t state;
    db_flow_id_t id;
    db_flow_mapping_t mapping;
    struct tcp_pcb *listen_pcb;
    struct tcp_pcb *conn_pcb;
    int relay_opened;
    uint8_t *mac_buffer;      /* Mac data awaiting relay open or relay backpressure */
    size_t mac_buffer_len;
    size_t relay_queued;      /* bytes currently in lwIP sndbuf for this flow */
} flow_t;

struct db_engine {
    db_engine_config_t config;
    db_lwip_context_t *lwip;
    db_flow_table_t *flow_table;
    flow_t *flows;
    db_flow_id_t next_id;
    size_t active;
    db_dns_table_t dns;
};

/* ---- flow lookup / lifecycle ---- */

static flow_t *flow_by_id(db_engine_t *e, db_flow_id_t id) {
    for (uint16_t i = 0; i < e->config.maximum_flows; i++)
        if (e->flows[i].state != FLOW_FREE && e->flows[i].id == id) return &e->flows[i];
    return NULL;
}

static flow_t *flow_by_local_port(db_engine_t *e, uint16_t local_port) {
    for (uint16_t i = 0; i < e->config.maximum_flows; i++)
        if (e->flows[i].state != FLOW_FREE && e->flows[i].mapping.local_port == local_port) return &e->flows[i];
    return NULL;
}

static flow_t *alloc_flow(db_engine_t *e) {
    for (uint16_t i = 0; i < e->config.maximum_flows; i++)
        if (e->flows[i].state == FLOW_FREE) return &e->flows[i];
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
    if (f->listen_pcb) { tcp_close(f->listen_pcb); f->listen_pcb = NULL; }
    free(f->mac_buffer);
    db_flow_table_remove(e->flow_table, &f->mapping.original);
    if (e->active > 0) e->active--;
    memset(f, 0, sizeof *f);
}

/* Emit callback from lwIP: rewrite gateway:local_port -> original remote, then hand to the host. */
static void engine_emit(void *context, const uint8_t *packet, size_t length) {
    db_engine_t *e = context;
    db_ipv4_view_t ip;
    if (db_ipv4_parse(packet, length, &ip) != DB_PACKET_OK || ip.protocol != DB_IPPROTO_TCP) return;
    db_tcp_view_t tcp;
    if (db_tcp_parse(packet, length, &ip, &tcp) != DB_PACKET_OK) return;
    flow_t *f = flow_by_local_port(e, tcp.src_port);
    if (f == NULL) return;
    uint8_t scratch[2048];
    if (length > sizeof scratch) return;
    memcpy(scratch, packet, length);
    if (db_rewrite_from_local(scratch, length, &f->mapping) != DB_PACKET_OK) return;
    e->config.emit_packet(e->config.context, scratch, length);
}

/* Push buffered Mac data to the relay. Returns -1 to abort the flow. */
static int drain_mac_buffer(flow_t *f) {
    db_engine_t *e = f->engine;
    if (!f->relay_opened || f->mac_buffer_len == 0) return 0;
    long accepted = e->config.send_flow(e->config.context, f->id, f->mac_buffer, f->mac_buffer_len);
    if (accepted == DB_SEND_ERROR) return -1;
    if (accepted == DB_SEND_AGAIN || accepted == 0) return 0;
    size_t took = (size_t)accepted >= f->mac_buffer_len ? f->mac_buffer_len : (size_t)accepted;
    memmove(f->mac_buffer, f->mac_buffer + took, f->mac_buffer_len - took);
    f->mac_buffer_len -= took;
    if (f->conn_pcb) tcp_recved(f->conn_pcb, (u16_t)took);
    return 0;
}

static int buffer_mac_data(flow_t *f, const uint8_t *data, size_t len) {
    if (f->mac_buffer_len + len > DB_MAC_BUFFER_MAX) return -1; /* overflow -> caller resets flow */
    uint8_t *grown = realloc(f->mac_buffer, f->mac_buffer_len + len);
    if (grown == NULL) return -1;
    f->mac_buffer = grown;
    memcpy(f->mac_buffer + f->mac_buffer_len, data, len);
    f->mac_buffer_len += len;
    return 0;
}

/* ---- lwIP pcb callbacks ---- */

static void lwip_err_cb(void *arg, err_t err) {
    (void)err;
    flow_t *f = arg;
    if (f == NULL) return;
    f->conn_pcb = NULL; /* lwIP freed it */
    if (f->state != FLOW_FREE) {
        f->engine->config.close_flow(f->engine->config.context, f->id, DB_CLOSE_RESET);
        free_flow(f);
    }
}

static err_t lwip_sent_cb(void *arg, struct tcp_pcb *pcb, u16_t len) {
    (void)pcb;
    flow_t *f = arg;
    if (f == NULL) return ERR_OK;
    f->relay_queued = (f->relay_queued >= len) ? f->relay_queued - len : 0;
    return ERR_OK;
}

static err_t lwip_recv_cb(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err) {
    flow_t *f = arg;
    if (f == NULL) { if (p) pbuf_free(p); return ERR_OK; }
    db_engine_t *e = f->engine;

    if (err != ERR_OK) { if (p) pbuf_free(p); return err; }
    if (p == NULL) {
        /* Mac sent FIN: half-close. Tell the relay via close_flow(NORMAL); keep conn for remote->Mac. */
        f->state = FLOW_MAC_CLOSED;
        e->config.close_flow(e->config.context, f->id, DB_CLOSE_NORMAL);
        return ERR_OK;
    }

    /* Flatten pbuf and either send to relay or buffer. */
    uint8_t stackbuf[2048];
    uint8_t *bytes = stackbuf;
    uint8_t *heap = NULL;
    if (p->tot_len > sizeof stackbuf) { heap = malloc(p->tot_len); bytes = heap; }
    if (bytes == NULL) { pbuf_free(p); return ERR_MEM; }
    pbuf_copy_partial(p, bytes, p->tot_len, 0);
    u16_t total = p->tot_len;

    int abort_flow = 0;
    if (!f->relay_opened) {
        if (buffer_mac_data(f, bytes, total) != 0) abort_flow = 1;
        else tcp_recved(pcb, total); /* accepted into our buffer */
    } else if (f->mac_buffer_len > 0) {
        /* still draining an earlier backlog: append and keep order */
        if (buffer_mac_data(f, bytes, total) != 0) abort_flow = 1;
        else { tcp_recved(pcb, total); if (drain_mac_buffer(f) != 0) abort_flow = 1; }
    } else {
        long accepted = e->config.send_flow(e->config.context, f->id, bytes, total);
        if (accepted == DB_SEND_ERROR) abort_flow = 1;
        else if (accepted == DB_SEND_AGAIN || accepted == 0) {
            if (buffer_mac_data(f, bytes, total) != 0) abort_flow = 1; else tcp_recved(pcb, total);
        } else {
            size_t took = (size_t)accepted >= total ? total : (size_t)accepted;
            if (took < total) { if (buffer_mac_data(f, bytes + took, total - took) != 0) abort_flow = 1; }
            tcp_recved(pcb, total);
        }
    }

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
    if (f == NULL || err != ERR_OK || newpcb == NULL) return ERR_VAL;
    db_engine_t *e = f->engine;
    f->conn_pcb = newpcb;
    f->state = FLOW_OPEN;
    tcp_arg(newpcb, f);
    tcp_recv(newpcb, lwip_recv_cb);
    tcp_sent(newpcb, lwip_sent_cb);
    tcp_err(newpcb, lwip_err_cb);
    /* one listener served its single flow; close it so the port is not reused mid-flow */
    if (f->listen_pcb) { tcp_close(f->listen_pcb); f->listen_pcb = NULL; }
    e->config.open_flow(e->config.context, f->id, f->mapping.original.dst_ip, f->mapping.original.dst_port);
    return ERR_OK;
}

/* ---- public API ---- */

db_engine_t *db_engine_create(const db_engine_config_t *config) {
    if (config == NULL || config->emit_packet == NULL || config->open_flow == NULL ||
        config->send_flow == NULL || config->close_flow == NULL) return NULL;
    if (config->maximum_flows < 1 || config->maximum_flows > 256) return NULL;
    if (config->mtu != 1280) return NULL;

    db_engine_t *e = calloc(1, sizeof *e);
    if (e == NULL) return NULL;
    e->config = *config;
    e->flows = calloc(config->maximum_flows, sizeof *e->flows);
    e->flow_table = db_flow_table_create(config->maximum_flows);
    if (e->flows == NULL || e->flow_table == NULL) { db_engine_destroy(e); return NULL; }
    e->next_id = 1;
    db_dns_table_init(&e->dns);

    e->lwip = db_lwip_init(engine_emit, e,
                           (db_lwip_now_fn)config->now_ms, (db_lwip_rand_fn)config->random_u32, config->context);
    if (e->lwip == NULL) { db_engine_destroy(e); return NULL; }
    return e;
}

void db_engine_destroy(db_engine_t *e) {
    if (e == NULL) return;
    if (e->flows) {
        for (uint16_t i = 0; i < e->config.maximum_flows; i++)
            if (e->flows[i].state != FLOW_FREE) free_flow(&e->flows[i]);
        free(e->flows);
    }
    if (e->lwip) db_lwip_shutdown(e->lwip);
    if (e->flow_table) db_flow_table_destroy(e->flow_table);
    free(e);
}

/* Build and emit a bare RST back to the Mac for a SYN we refuse (flow limit). */
static void emit_rst_for_syn(db_engine_t *e, const uint8_t *packet, size_t length,
                             const db_ipv4_view_t *ip, const db_tcp_view_t *tcp) {
    (void)length;
    uint8_t rst[40];
    memset(rst, 0, sizeof rst);
    rst[0] = 0x45; rst[2] = 0; rst[3] = 40; rst[8] = 64; rst[9] = DB_IPPROTO_TCP;
    memcpy(rst + 12, ip->dst, 4); /* swap src/dst */
    memcpy(rst + 16, ip->src, 4);
    uint8_t *t = rst + 20;
    t[0] = (uint8_t)(tcp->dst_port >> 8); t[1] = (uint8_t)tcp->dst_port;
    t[2] = (uint8_t)(tcp->src_port >> 8); t[3] = (uint8_t)tcp->src_port;
    uint32_t ackno = tcp->seq + 1;
    t[8] = (uint8_t)(ackno >> 24); t[9] = (uint8_t)(ackno >> 16); t[10] = (uint8_t)(ackno >> 8); t[11] = (uint8_t)ackno;
    t[12] = 5 << 4;
    t[13] = DB_TCP_RST | DB_TCP_ACK;
    /* checksums */
    uint16_t ipck; { db_ipv4_view_t v; if (db_ipv4_parse(rst, 40, &v) == DB_PACKET_OK) { ipck = db_ipv4_header_checksum(rst, 20); rst[10] = (uint8_t)(ipck >> 8); rst[11] = (uint8_t)ipck; uint16_t tck = db_tcp_checksum(rst, &v); t[16] = (uint8_t)(tck >> 8); t[17] = (uint8_t)tck; } }
    e->config.emit_packet(e->config.context, rst, 40);
}

/* Intercept UDP DNS to 198.18.0.1:53. Any other UDP is dropped (B1 forwards no general UDP). */
static db_engine_status_t engine_handle_udp(db_engine_t *e, const uint8_t *packet, size_t length, const db_ipv4_view_t *ip) {
    size_t udp_off = ip->header_length;
    if (udp_off + 8 > ip->total_length) return DB_ENGINE_OK;
    const uint8_t *udp = packet + udp_off;
    uint16_t dst_port = ((uint16_t)udp[2] << 8) | udp[3];
    if (dst_port != 53) return DB_ENGINE_OK; /* not DNS: drop */
    if (ip->dst[0] != DB_GATEWAY_IP0 || ip->dst[1] != DB_GATEWAY_IP1 ||
        ip->dst[2] != DB_GATEWAY_IP2 || ip->dst[3] != DB_GATEWAY_IP3) return DB_ENGINE_OK;
    uint16_t src_port = ((uint16_t)udp[0] << 8) | udp[1];
    const uint8_t *dns = udp + 8;
    size_t dns_len = ip->total_length - udp_off - 8;
    if (!db_dns_valid(dns, dns_len)) return DB_ENGINE_OK; /* malformed: drop, no reflect */
    uint32_t query_id;
    if (db_dns_register(&e->dns, ip->src, src_port, db_dns_transaction_id(dns),
                        e->config.now_ms ? e->config.now_ms(e->config.context) : 0, &query_id) != 0) {
        return DB_ENGINE_OK; /* table full: drop */
    }
    if (e->config.send_dns) e->config.send_dns(e->config.context, query_id, dns, dns_len);
    return DB_ENGINE_OK;
}

db_engine_status_t db_engine_on_dns_response(db_engine_t *e, db_flow_id_t query, const uint8_t *response, size_t length) {
    if (e == NULL || response == NULL) return DB_ENGINE_ERR_ARGUMENT;
    db_dns_entry_t entry;
    if (db_dns_take(&e->dns, query, &entry) != 0) return DB_ENGINE_ERR_UNKNOWN_FLOW;
    if (!db_dns_valid(response, length)) return DB_ENGINE_ERR_STATE;
    if (db_dns_transaction_id(response) != entry.txid) return DB_ENGINE_ERR_STATE;
    uint8_t out[1500];
    size_t n = db_dns_build_udp_response(&entry, response, length, out, sizeof out);
    if (n == 0) return DB_ENGINE_ERR_STATE;
    e->config.emit_packet(e->config.context, out, n);
    return DB_ENGINE_OK;
}

db_engine_status_t db_engine_input_packet(db_engine_t *e, const uint8_t *packet, size_t length) {
    if (e == NULL || packet == NULL) return DB_ENGINE_ERR_ARGUMENT;
    db_ipv4_view_t ip;
    if (db_ipv4_parse(packet, length, &ip) != DB_PACKET_OK) return DB_ENGINE_OK; /* drop non-IPv4/fragment */
    if (ip.protocol == DB_IPPROTO_UDP) return engine_handle_udp(e, packet, length, &ip);
    if (ip.protocol != DB_IPPROTO_TCP) return DB_ENGINE_OK; /* B1: no other protocols */
    db_tcp_view_t tcp;
    if (db_tcp_parse(packet, length, &ip, &tcp) != DB_PACKET_OK) return DB_ENGINE_OK;

    db_flow_key_t key;
    memcpy(key.src_ip, ip.src, 4); key.src_port = tcp.src_port;
    memcpy(key.dst_ip, ip.dst, 4); key.dst_port = tcp.dst_port;

    db_flow_mapping_t mapping;
    int is_new = (db_flow_table_lookup(e->flow_table, &key, &mapping) != DB_PACKET_OK);

    if (is_new) {
        if ((tcp.flags & DB_TCP_SYN) == 0 || (tcp.flags & DB_TCP_ACK) != 0) {
            /* not a fresh SYN and unknown flow: ignore (could be stray ACK/RST) */
            return DB_ENGINE_OK;
        }
        if (e->active >= e->config.maximum_flows) { emit_rst_for_syn(e, packet, length, &ip, &tcp); return DB_ENGINE_OK; }
        if (db_flow_table_get_or_create(e->flow_table, &key, &mapping) != DB_PACKET_OK) {
            emit_rst_for_syn(e, packet, length, &ip, &tcp); return DB_ENGINE_OK;
        }
        flow_t *f = alloc_flow(e);
        if (f == NULL) { db_flow_table_remove(e->flow_table, &key); return DB_ENGINE_OK; }
        memset(f, 0, sizeof *f);
        f->engine = e;
        f->state = FLOW_OPENING;
        f->id = e->next_id++;
        f->mapping = mapping;
        /* listener bound to gateway:local_port */
        struct tcp_pcb *lp = tcp_new();
        ip4_addr_t gw; IP4_ADDR(&gw, 198, 18, 0, 1);
        if (lp == NULL || tcp_bind(lp, &gw, mapping.local_port) != ERR_OK) {
            if (lp) tcp_close(lp); free_flow(f); return DB_ENGINE_OK;
        }
        struct tcp_pcb *listen = tcp_listen(lp);
        if (listen == NULL) { tcp_close(lp); free_flow(f); return DB_ENGINE_OK; }
        f->listen_pcb = listen;
        tcp_arg(listen, f);
        tcp_accept(listen, lwip_accept_cb);
        e->active++;
    }

    /* rewrite to gateway:local_port and feed lwIP */
    uint8_t scratch[2048];
    if (length > sizeof scratch) return DB_ENGINE_OK;
    memcpy(scratch, packet, length);
    db_flow_mapping_t map2;
    if (db_flow_table_lookup(e->flow_table, &key, &map2) != DB_PACKET_OK) return DB_ENGINE_OK;
    if (db_rewrite_to_local(scratch, length, &map2) != DB_PACKET_OK) return DB_ENGINE_OK;
    db_lwip_input(e->lwip, scratch, length);
    return DB_ENGINE_OK;
}

void db_engine_poll(db_engine_t *e) { if (e) db_lwip_poll(e->lwip); }

db_engine_status_t db_engine_on_relay_opened(db_engine_t *e, db_flow_id_t flow) {
    if (e == NULL) return DB_ENGINE_ERR_ARGUMENT;
    flow_t *f = flow_by_id(e, flow);
    if (f == NULL) return DB_ENGINE_ERR_UNKNOWN_FLOW;
    f->relay_opened = 1;
    if (drain_mac_buffer(f) != 0) { e->config.close_flow(e->config.context, f->id, DB_CLOSE_RESET); free_flow(f); }
    return DB_ENGINE_OK;
}

db_engine_status_t db_engine_on_relay_open_failed(db_engine_t *e, db_flow_id_t flow) {
    if (e == NULL) return DB_ENGINE_ERR_ARGUMENT;
    flow_t *f = flow_by_id(e, flow);
    if (f == NULL) return DB_ENGINE_ERR_UNKNOWN_FLOW;
    free_flow(f); /* tcp_abort in free_flow emits RST to the Mac */
    return DB_ENGINE_OK;
}

db_engine_status_t db_engine_on_relay_data(db_engine_t *e, db_flow_id_t flow, const uint8_t *data, size_t length) {
    if (e == NULL || data == NULL) return DB_ENGINE_ERR_ARGUMENT;
    flow_t *f = flow_by_id(e, flow);
    if (f == NULL || f->conn_pcb == NULL) return DB_ENGINE_ERR_UNKNOWN_FLOW;
    size_t offset = 0;
    while (offset < length) {
        u16_t sndbuf = tcp_sndbuf(f->conn_pcb);
        if (sndbuf == 0) break; /* backpressure: remaining bytes dropped for B1 test scope */
        size_t chunk = length - offset;
        if (chunk > sndbuf) chunk = sndbuf;
        if (f->relay_queued + chunk > DB_RELAY_QUEUE_MAX) chunk = DB_RELAY_QUEUE_MAX - f->relay_queued;
        if (chunk == 0) break;
        if (tcp_write(f->conn_pcb, data + offset, (u16_t)chunk, TCP_WRITE_FLAG_COPY) != ERR_OK) break;
        f->relay_queued += chunk;
        offset += chunk;
    }
    tcp_output(f->conn_pcb);
    return DB_ENGINE_OK;
}

db_engine_status_t db_engine_on_relay_writable(db_engine_t *e, db_flow_id_t flow) {
    if (e == NULL) return DB_ENGINE_ERR_ARGUMENT;
    flow_t *f = flow_by_id(e, flow);
    if (f == NULL) return DB_ENGINE_ERR_UNKNOWN_FLOW;
    if (drain_mac_buffer(f) != 0) { e->config.close_flow(e->config.context, f->id, DB_CLOSE_RESET); free_flow(f); }
    return DB_ENGINE_OK;
}

db_engine_status_t db_engine_on_relay_closed(db_engine_t *e, db_flow_id_t flow, int is_error) {
    if (e == NULL) return DB_ENGINE_ERR_ARGUMENT;
    flow_t *f = flow_by_id(e, flow);
    if (f == NULL) return DB_ENGINE_ERR_UNKNOWN_FLOW;
    if (is_error) {
        free_flow(f); /* RST */
    } else if (f->conn_pcb) {
        tcp_arg(f->conn_pcb, NULL);
        tcp_recv(f->conn_pcb, NULL);
        tcp_sent(f->conn_pcb, NULL);
        tcp_err(f->conn_pcb, NULL);
        tcp_close(f->conn_pcb); /* FIN */
        f->conn_pcb = NULL;
        free(f->mac_buffer);
        db_flow_table_remove(e->flow_table, &f->mapping.original);
        if (e->active > 0) e->active--;
        memset(f, 0, sizeof *f);
    } else {
        free_flow(f);
    }
    return DB_ENGINE_OK;
}

size_t db_engine_active_flow_count(const db_engine_t *e) { return e ? e->active : 0; }
