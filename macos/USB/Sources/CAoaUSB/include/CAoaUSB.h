#ifndef DB_AOA_USB_H
#define DB_AOA_USB_H
#include <stdint.h>
#include <stddef.h>
typedef struct db_usb db_usb;
typedef struct { char location[64]; uint16_t vendor; uint16_t product; int accessory; } db_usb_info;
db_usb *db_usb_create(const char *library, char *error, size_t error_size);
void db_usb_destroy(db_usb *usb);
int db_usb_list(db_usb *usb, db_usb_info *output, int capacity);
int db_usb_open(db_usb *usb, const char *location);
void db_usb_close_device(db_usb *usb);
int db_usb_control(db_usb *usb, int input, uint8_t request, uint16_t index, unsigned char *data, uint16_t size);
int db_usb_claim(db_usb *usb);
int db_usb_reset(db_usb *usb);
int db_usb_out_packet_size(db_usb *usb);
int db_usb_read(db_usb *usb, unsigned char *data, int size);
int db_usb_write(db_usb *usb, unsigned char *data, int size, int *sent);
#endif
