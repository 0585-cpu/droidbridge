#include "CAoaUSB.h"
#include "libusb.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define USB_APIS(X) \
 X(init) X(exit) X(get_device_list) X(free_device_list) X(get_device_descriptor) \
 X(get_bus_number) X(get_port_numbers) X(get_config_descriptor) X(free_config_descriptor) \
 X(open) X(close) X(get_device) X(control_transfer) X(claim_interface) X(release_interface) X(bulk_transfer)

struct db_usb {
    void *library;
    libusb_context *context;
    libusb_device_handle *handle;
    int interface_number;
    unsigned char input, output;
    int output_packet_size;
#define FIELD(name) __typeof__(&libusb_##name) name;
    USB_APIS(FIELD)
#undef FIELD
};

db_usb *db_usb_create(const char *library, char *error, size_t error_size) {
    db_usb *usb = calloc(1, sizeof(*usb));
    if (!usb) return NULL;
    usb->interface_number = -1;
    usb->library = dlopen(library, RTLD_LOCAL | RTLD_NOW);
    if (!usb->library) { snprintf(error, error_size, "bundled libusb could not be loaded"); free(usb); return NULL; }
#define LOAD(name) usb->name = dlsym(usb->library, "libusb_" #name); if (!usb->name) goto failed;
    USB_APIS(LOAD)
#undef LOAD
    if (usb->init(&usb->context) != 0) goto failed;
    return usb;
failed:
    snprintf(error, error_size, "libusb initialization failed");
    dlclose(usb->library); free(usb); return NULL;
}

void db_usb_close_device(db_usb *usb) {
    if (!usb || !usb->handle) return;
    if (usb->interface_number >= 0) usb->release_interface(usb->handle, usb->interface_number);
    usb->close(usb->handle); usb->handle = NULL; usb->interface_number = -1;
}
void db_usb_destroy(db_usb *usb) {
    if (!usb) return;
    db_usb_close_device(usb);
    usb->exit(usb->context); dlclose(usb->library); free(usb);
}
static void location(db_usb *usb, libusb_device *device, char *result, size_t capacity) {
    uint8_t ports[8];
    int count = usb->get_port_numbers(device, ports, sizeof ports);
    size_t used = (size_t)snprintf(result, capacity, "%u", usb->get_bus_number(device));
    for (int i = 0; i < count && used < capacity; ++i)
        used += (size_t)snprintf(result + used, capacity - used, "-%u", ports[i]);
}
static int is_accessory(const struct libusb_device_descriptor *d) {
    return d->idVendor == 0x18d1 && (d->idProduct == 0x2d00 || d->idProduct == 0x2d01);
}
static int candidate(db_usb *usb, libusb_device *device, const struct libusb_device_descriptor *d) {
    if (is_accessory(d)) return 1;
    struct libusb_config_descriptor *config = NULL;
    int found = 0;
    if (usb->get_config_descriptor(device, 0, &config) == 0) {
      for (int i = 0; i < config->bNumInterfaces; ++i) {
        const struct libusb_interface *interface = &config->interface[i];
        for (int j = 0; j < interface->num_altsetting; ++j) {
            const struct libusb_interface_descriptor *a = &interface->altsetting[j];
            if ((a->bInterfaceClass == 6 && a->bInterfaceSubClass == 1) ||
                (a->bInterfaceClass == 255 && a->bInterfaceSubClass == 0x42 && a->bInterfaceProtocol == 1)) found = 1;
        }
      }
      usb->free_config_descriptor(config);
    }
    // Charge-only Android configurations can expose no MTP/ADB interface. Known phone vendors
    // may be selected, but GET_PROTOCOL still must succeed before any mode-switch requests.
    if (d->idVendor == 0x18d1 || d->idVendor == 0x04e8 || d->idVendor == 0x22b8 ||
        d->idVendor == 0x2717 || d->idVendor == 0x2a70 || d->idVendor == 0x12d1) found = 1;
    return found;
}
int db_usb_list(db_usb *usb, db_usb_info *output, int capacity) {
    libusb_device **devices = NULL;
    ssize_t count = usb->get_device_list(usb->context, &devices);
    if (count < 0) return (int)count;
    int written = 0;
    for (ssize_t i = 0; i < count && written < capacity; ++i) {
        struct libusb_device_descriptor descriptor;
        if (usb->get_device_descriptor(devices[i], &descriptor) != 0 || !candidate(usb, devices[i], &descriptor)) continue;
        db_usb_info *info = &output[written++];
        memset(info, 0, sizeof *info);
        location(usb, devices[i], info->location, sizeof info->location);
        info->vendor = descriptor.idVendor; info->product = descriptor.idProduct;
        info->accessory = is_accessory(&descriptor);
    }
    usb->free_device_list(devices, 1);
    return written;
}
int db_usb_open(db_usb *usb, const char *wanted) {
    if (usb->handle) return LIBUSB_ERROR_BUSY;
    libusb_device **devices = NULL;
    ssize_t count = usb->get_device_list(usb->context, &devices);
    if (count < 0) return (int)count;
    int result = LIBUSB_ERROR_NO_DEVICE;
    for (ssize_t i = 0; i < count; ++i) {
        char value[64]; location(usb, devices[i], value, sizeof value);
        if (strcmp(value, wanted) == 0) { result = usb->open(devices[i], &usb->handle); break; }
    }
    usb->free_device_list(devices, 1);
    return result;
}
int db_usb_control(db_usb *usb, int input, uint8_t request, uint16_t index, unsigned char *data, uint16_t size) {
    if (!usb->handle) return LIBUSB_ERROR_NO_DEVICE;
    return usb->control_transfer(usb->handle, input ? 0xc0 : 0x40, request, 0, index, data, size, 1000);
}
int db_usb_claim(db_usb *usb) {
    if (!usb->handle) return LIBUSB_ERROR_NO_DEVICE;
    libusb_device *device = usb->get_device(usb->handle);
    struct libusb_device_descriptor descriptor;
    if (usb->get_device_descriptor(device, &descriptor) != 0 || !is_accessory(&descriptor)) return LIBUSB_ERROR_NOT_SUPPORTED;
    struct libusb_config_descriptor *config = NULL;
    int result = usb->get_config_descriptor(device, 0, &config);
    if (result != 0) return result;
    result = LIBUSB_ERROR_NOT_FOUND;
    // AOA interface zero is the accessory. Interface one, when present, belongs to ADB.
    for (int i = 0; i < config->bNumInterfaces; ++i) {
        if (!config->interface[i].num_altsetting) continue;
        const struct libusb_interface_descriptor *a = &config->interface[i].altsetting[0];
        if (a->bInterfaceNumber != 0) continue;
        unsigned char input = 0, output = 0;
        int output_packet_size = 0;
        for (int j = 0; j < a->bNumEndpoints; ++j) {
            const struct libusb_endpoint_descriptor *e = &a->endpoint[j];
            if ((e->bmAttributes & 3) != LIBUSB_TRANSFER_TYPE_BULK) continue;
            if (e->bEndpointAddress & 0x80) input = e->bEndpointAddress;
            else { output = e->bEndpointAddress; output_packet_size = e->wMaxPacketSize & 0x7ff; }
        }
        if (!input || !output) continue;
        // Do not detach drivers, seize/reset a device, or change another application's interface.
        result = usb->claim_interface(usb->handle, a->bInterfaceNumber);
        if (!result) {
            usb->interface_number = a->bInterfaceNumber; usb->input = input; usb->output = output;
            usb->output_packet_size = output_packet_size;
        }
        break;
    }
    usb->free_config_descriptor(config);
    return result;
}
int db_usb_read(db_usb *usb, unsigned char *data, int size) {
    int transferred = 0;
    int result = usb->bulk_transfer(usb->handle, usb->input, data, size, &transferred, 250);
    // Only success and timeout preserve usable bytes. In particular, an overflow's
    // count and buffer contents are undefined; feeding them to the frame decoder
    // can silently corrupt this session instead of retiring it at the USB boundary.
    if (result == 0 || result == LIBUSB_ERROR_TIMEOUT) return transferred;
    return result;
}
int db_usb_out_packet_size(db_usb *usb) { return usb->output_packet_size; }
int db_usb_write(db_usb *usb, unsigned char *data, int size) {
    int transferred = 0;
    // Allow a short accessory IO stall with a bounded per-transfer deadline.
    // A frame can require multiple transfers. Never replay a timeout.
    int result = usb->bulk_transfer(usb->handle, usb->output, data, size, &transferred, 2500);
    if (result != 0) return result; // any partial write error invalidates the framing session
    return transferred;
}
