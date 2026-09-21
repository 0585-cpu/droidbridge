/* Minimal DNS wire helpers for the virtual DNS bridge. No name caching, no logging of names. */
#include "droidbridge_packet.h"
#include <string.h>

int db_dns_valid(const uint8_t *dns, size_t length) {
    return dns != NULL && length >= 12 && length <= 4096;
}

uint16_t db_dns_transaction_id(const uint8_t *dns) {
    return ((uint16_t)dns[0] << 8) | (uint16_t)dns[1];
}

/* Builds a SERVFAIL response echoing the question section, when it parses cleanly. Returns length or 0. */
size_t db_dns_build_servfail(const uint8_t *query, size_t query_len, uint8_t *out, size_t cap) {
    if (!db_dns_valid(query, query_len)) return 0;
    uint16_t qdcount = ((uint16_t)query[4] << 8) | query[5];
    if (qdcount != 1) return 0;
    /* find end of the single question: name + 4 bytes (qtype+qclass) */
    size_t i = 12;
    while (i < query_len && query[i] != 0) {
        uint8_t label = query[i];
        if (label & 0xC0) return 0; /* no compression in a query */
        i += 1 + label;
    }
    if (i >= query_len) return 0;
    i += 1;          /* zero label */
    i += 4;          /* qtype + qclass */
    if (i > query_len) return 0;
    if (i > cap) return 0;
    memcpy(out, query, i);
    out[2] = 0x81; out[3] = 0x82; /* QR=1, RD=1, RA=1, RCODE=2 (SERVFAIL) */
    out[6] = 0; out[7] = 0;       /* ANCOUNT */
    out[8] = 0; out[9] = 0;       /* NSCOUNT */
    out[10] = 0; out[11] = 0;     /* ARCOUNT */
    return i;
}
