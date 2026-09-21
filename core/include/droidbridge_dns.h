#ifndef DROIDBRIDGE_DNS_H
#define DROIDBRIDGE_DNS_H

#include <stddef.h>
#include <stdint.h>

#define DB_DNS_MAX_QUERIES 128

typedef struct {
    int in_use;
    uint32_t query_id;
    uint8_t mac_ip[4];
    uint16_t mac_port;
    uint16_t txid;
    uint32_t deadline_ms;
} db_dns_entry_t;

typedef struct {
    db_dns_entry_t entries[DB_DNS_MAX_QUERIES];
    uint32_t next_query_id;
} db_dns_table_t;

void db_dns_table_init(db_dns_table_t *table);
int db_dns_register(db_dns_table_t *table, const uint8_t mac_ip[4], uint16_t mac_port,
                    uint16_t txid, uint32_t now_ms, uint32_t *out_query_id);
int db_dns_take(db_dns_table_t *table, uint32_t query_id, db_dns_entry_t *out);
size_t db_dns_build_udp_response(const db_dns_entry_t *entry, const uint8_t *dns, size_t dns_len,
                                 uint8_t *out, size_t cap);

int db_dns_valid(const uint8_t *dns, size_t length);
uint16_t db_dns_transaction_id(const uint8_t *dns);
size_t db_dns_build_servfail(const uint8_t *query, size_t query_len, uint8_t *out, size_t cap);

#endif
