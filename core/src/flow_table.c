#include "droidbridge_packet.h"

#include <stdlib.h>
#include <string.h>

/* ponytail: linear-scan table over <=256 live mappings + a port bitmap. The plan suggests an
 * open-addressed 512-slot hash; at 256 entries a linear scan is simpler and fast enough.
 * Upgrade to hashing if flow counts ever grow past low hundreds. */
struct db_flow_table {
    uint16_t maximum_flows;
    size_t count;
    db_flow_mapping_t *entries; /* capacity == maximum_flows; in_use tracked in parallel */
    uint8_t *in_use;
    uint8_t port_used[DB_LOCAL_PORT_COUNT];
    uint16_t next_port_hint;
};

static int key_equal(const db_flow_key_t *a, const db_flow_key_t *b) {
    return memcmp(a->src_ip, b->src_ip, 4) == 0 && a->src_port == b->src_port &&
           memcmp(a->dst_ip, b->dst_ip, 4) == 0 && a->dst_port == b->dst_port;
}

db_flow_table_t *db_flow_table_create(uint16_t maximum_flows) {
    if (maximum_flows < 1 || maximum_flows > 256) return NULL;
    db_flow_table_t *table = calloc(1, sizeof *table);
    if (table == NULL) return NULL;
    table->maximum_flows = maximum_flows;
    table->entries = calloc(maximum_flows, sizeof *table->entries);
    table->in_use = calloc(maximum_flows, sizeof *table->in_use);
    if (table->entries == NULL || table->in_use == NULL) {
        db_flow_table_destroy(table);
        return NULL;
    }
    return table;
}

void db_flow_table_destroy(db_flow_table_t *table) {
    if (table == NULL) return;
    free(table->entries);
    free(table->in_use);
    free(table);
}

size_t db_flow_table_count(const db_flow_table_t *table) { return table ? table->count : 0; }

static int find_index(const db_flow_table_t *table, const db_flow_key_t *key) {
    for (uint16_t i = 0; i < table->maximum_flows; i++) {
        if (table->in_use[i] && key_equal(&table->entries[i].original, key)) return (int)i;
    }
    return -1;
}

static db_packet_status_t allocate_port(db_flow_table_t *table, uint16_t *out_port) {
    for (uint16_t i = 0; i < DB_LOCAL_PORT_COUNT; i++) {
        uint16_t slot = (uint16_t)((table->next_port_hint + i) % DB_LOCAL_PORT_COUNT);
        if (!table->port_used[slot]) {
            table->port_used[slot] = 1;
            table->next_port_hint = (uint16_t)((slot + 1) % DB_LOCAL_PORT_COUNT);
            *out_port = (uint16_t)(DB_LOCAL_PORT_MIN + slot);
            return DB_PACKET_OK;
        }
    }
    return DB_PACKET_ERR_POOL_EXHAUSTED;
}

db_packet_status_t db_flow_table_get_or_create(db_flow_table_t *table, const db_flow_key_t *key, db_flow_mapping_t *out) {
    if (table == NULL || key == NULL || out == NULL) return DB_PACKET_ERR_ARGUMENT;
    int existing = find_index(table, key);
    if (existing >= 0) { *out = table->entries[existing]; return DB_PACKET_OK; }
    if (table->count >= table->maximum_flows) return DB_PACKET_ERR_TABLE_FULL;

    uint16_t port;
    db_packet_status_t status = allocate_port(table, &port);
    if (status != DB_PACKET_OK) return status;

    for (uint16_t i = 0; i < table->maximum_flows; i++) {
        if (!table->in_use[i]) {
            table->entries[i].original = *key;
            table->entries[i].local_port = port;
            table->in_use[i] = 1;
            table->count++;
            *out = table->entries[i];
            return DB_PACKET_OK;
        }
    }
    return DB_PACKET_ERR_TABLE_FULL; /* unreachable: count < maximum implies a free slot */
}

db_packet_status_t db_flow_table_lookup(const db_flow_table_t *table, const db_flow_key_t *key, db_flow_mapping_t *out) {
    if (table == NULL || key == NULL || out == NULL) return DB_PACKET_ERR_ARGUMENT;
    int index = find_index(table, key);
    if (index < 0) return DB_PACKET_ERR_NOT_FOUND;
    *out = table->entries[index];
    return DB_PACKET_OK;
}

db_packet_status_t db_flow_table_lookup_by_local(const db_flow_table_t *table, uint16_t local_port, db_flow_mapping_t *out) {
    if (table == NULL || out == NULL) return DB_PACKET_ERR_ARGUMENT;
    for (uint16_t i = 0; i < table->maximum_flows; i++) {
        if (table->in_use[i] && table->entries[i].local_port == local_port) { *out = table->entries[i]; return DB_PACKET_OK; }
    }
    return DB_PACKET_ERR_NOT_FOUND;
}

db_packet_status_t db_flow_table_remove(db_flow_table_t *table, const db_flow_key_t *key) {
    if (table == NULL || key == NULL) return DB_PACKET_ERR_ARGUMENT;
    int index = find_index(table, key);
    if (index < 0) return DB_PACKET_ERR_NOT_FOUND;
    uint16_t port = table->entries[index].local_port;
    if (port >= DB_LOCAL_PORT_MIN && port <= DB_LOCAL_PORT_MAX) table->port_used[port - DB_LOCAL_PORT_MIN] = 0;
    table->in_use[index] = 0;
    table->count--;
    return DB_PACKET_OK;
}
