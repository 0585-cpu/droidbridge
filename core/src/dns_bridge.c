/* Virtual DNS bridge: intercepts UDP queries to 198.18.0.1:53, hands them to the relay via send_dns,
 * and emits the answer back as a correctly addressed UDP packet. TCP DNS framing lives in dns_tcp.c.
 * Fixed table of 128 outstanding queries with a 5-second deadline. */
#include "droidbridge_dns.h"
#include "droidbridge_packet.h"

#include <string.h>

int db_dns_valid(const uint8_t *dns, size_t length);
uint16_t db_dns_transaction_id(const uint8_t *dns);
size_t db_dns_build_servfail(const uint8_t *query, size_t query_len, uint8_t *out, size_t cap);

#define DNS_DEADLINE_MS 5000u

void db_dns_table_init(db_dns_table_t *table) { memset(table, 0, sizeof *table); table->next_query_id = 1; }

static db_dns_entry_t *find_entry(db_dns_table_t *table, uint32_t query_id) {
    for (size_t i = 0; i < DB_DNS_MAX_QUERIES; i++)
        if (table->entries[i].in_use && table->entries[i].query_id == query_id) return &table->entries[i];
    return NULL;
}

int db_dns_register(db_dns_table_t *table, const uint8_t mac_ip[4], uint16_t mac_port,
                    uint16_t txid, uint32_t now_ms, uint32_t *out_query_id) {
    for (size_t i = 0; i < DB_DNS_MAX_QUERIES; i++) {
        if (!table->entries[i].in_use) {
            table->entries[i].in_use = 1;
            table->entries[i].query_id = table->next_query_id++;
            memcpy(table->entries[i].mac_ip, mac_ip, 4);
            table->entries[i].mac_port = mac_port;
            table->entries[i].txid = txid;
            table->entries[i].deadline_ms = now_ms + DNS_DEADLINE_MS;
            *out_query_id = table->entries[i].query_id;
            return 0;
        }
    }
    return -1; /* table full */
}

int db_dns_take(db_dns_table_t *table, uint32_t query_id, db_dns_entry_t *out) {
    db_dns_entry_t *e = find_entry(table, query_id);
    if (e == NULL) return -1;
    *out = *e;
    e->in_use = 0;
    return 0;
}

/* Writes an IPv4/UDP DNS packet (src 198.18.0.1:53 -> mac) into `out`; returns length or 0. */
size_t db_dns_build_udp_response(const db_dns_entry_t *entry, const uint8_t *dns, size_t dns_len,
                                 uint8_t *out, size_t cap) {
    size_t total = 20 + 8 + dns_len;
    if (total > cap || total > 1280) return 0;
    memset(out, 0, total);
    out[0] = 0x45;
    out[2] = (uint8_t)(total >> 8); out[3] = (uint8_t)total;
    out[8] = 64; out[9] = DB_IPPROTO_UDP;
    out[12] = DB_GATEWAY_IP0; out[13] = DB_GATEWAY_IP1; out[14] = DB_GATEWAY_IP2; out[15] = DB_GATEWAY_IP3;
    memcpy(out + 16, entry->mac_ip, 4);
    uint16_t ipck = db_ipv4_header_checksum(out, 20);
    out[10] = (uint8_t)(ipck >> 8); out[11] = (uint8_t)ipck;

    uint8_t *udp = out + 20;
    udp[0] = 0; udp[1] = 53;                     /* src port 53 */
    udp[2] = (uint8_t)(entry->mac_port >> 8); udp[3] = (uint8_t)entry->mac_port;
    uint16_t udp_len = (uint16_t)(8 + dns_len);
    udp[4] = (uint8_t)(udp_len >> 8); udp[5] = (uint8_t)udp_len;
    memcpy(udp + 8, dns, dns_len);
    /* UDP checksum with IPv4 pseudo-header */
    uint32_t acc = 0;
    for (int i = 12; i < 20; i += 2) acc += ((uint32_t)out[i] << 8) | out[i + 1]; /* src+dst ip */
    acc += DB_IPPROTO_UDP;
    acc += udp_len;
    for (size_t i = 0; i + 1 < udp_len; i += 2) { if (i == 6) continue; acc += ((uint32_t)udp[i] << 8) | udp[i + 1]; }
    if (udp_len & 1) acc += (uint32_t)udp[udp_len - 1] << 8;
    while (acc >> 16) acc = (acc & 0xFFFF) + (acc >> 16);
    uint16_t ck = (uint16_t)~acc; if (ck == 0) ck = 0xFFFF;
    udp[6] = (uint8_t)(ck >> 8); udp[7] = (uint8_t)ck;
    return total;
}
