// Exercise the production wrapper with a timed libusb boundary; never opens real USB.
#include "../Sources/CAoaUSB/CAoaUSB.c"
#include <time.h>

static int calls;
static unsigned int ready_after_ms;
static int forced_result;
static int partial;

static double now_seconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

static int LIBUSB_CALL delayed_transfer(libusb_device_handle *handle, unsigned char endpoint,
        unsigned char *data, int length, int *transferred, unsigned int timeout) {
    (void)handle; (void)endpoint; (void)data;
    calls++;
    if (forced_result) {
        *transferred = partial ? length / 2 : 0;
        return forced_result;
    }
    unsigned int delay = ready_after_ms < timeout ? ready_after_ms : timeout;
    struct timespec wait = {.tv_sec = delay / 1000, .tv_nsec = (delay % 1000) * 1000000L};
    nanosleep(&wait, NULL);
    *transferred = ready_after_ms <= timeout ? length : 0;
    return ready_after_ms <= timeout ? 0 : LIBUSB_ERROR_TIMEOUT;
}

static void require(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static void check_read_integrity(void) {
    db_usb usb = {.bulk_transfer = delayed_transfer, .input = 0x81};
    unsigned char bytes[4];
    // A positive byte count does not make an errored transfer trustworthy.
    // In particular, libusb documents the contents/count on overflow as undefined.
    const int errors[] = {LIBUSB_ERROR_OVERFLOW, LIBUSB_ERROR_IO,
                          LIBUSB_ERROR_PIPE, LIBUSB_ERROR_NO_DEVICE};
    for (size_t i = 0; i < sizeof errors / sizeof errors[0]; ++i) {
        calls = 0; forced_result = errors[i]; partial = 1;
        require(db_usb_read(&usb, bytes, sizeof bytes) == errors[i],
                "a fatal USB read error must not deliver potentially corrupt partial bytes");
        require(calls == 1, "an errored read must not be retried inside the framing session");
    }
    calls = 0; forced_result = LIBUSB_ERROR_TIMEOUT; partial = 1;
    require(db_usb_read(&usb, bytes, sizeof bytes) == 2 && calls == 1,
            "a read timeout must preserve the bytes libusb successfully transferred");
    calls = 0; partial = 0;
    require(db_usb_read(&usb, bytes, sizeof bytes) == 0 && calls == 1,
            "an empty read timeout must remain an idle poll");
    forced_result = 0; ready_after_ms = 0;
    require(db_usb_read(&usb, bytes, sizeof bytes) == 4,
            "a successful USB read must return its transferred bytes");
    calls = 0;
    puts("USB read integrity: fatal errors rejected, partial timeout preserved, idle poll passed");
}

int main(void) {
    check_read_integrity();
    db_usb usb = {.bulk_transfer = delayed_transfer, .output = 1};
    unsigned char bytes[] = {1, 2, 3, 4};
    int sent = -1;
    ready_after_ms = 1500;
    require(db_usb_write(&usb, bytes, sizeof bytes, &sent) == sizeof bytes && sent == sizeof bytes,
            "a 1.5-second phone scheduling stall must complete without losing the USB session");
    require(calls == 1, "a delayed write is one transfer, never a whole-frame retry");

    calls = 0; ready_after_ms = 60000;
    double began = now_seconds();
    require(db_usb_write(&usb, bytes, sizeof bytes, &sent) == LIBUSB_ERROR_TIMEOUT && sent == 0,
            "a persistently stalled USB endpoint must still time out");
    require(now_seconds() - began < 2.9, "a stuck native transfer must respect its bounded deadline");
    require(calls == 1, "a timed out transfer must not be resent");

    calls = 0; forced_result = LIBUSB_ERROR_TIMEOUT; partial = 1;
    require(db_usb_write(&usb, bytes, sizeof bytes, &sent) == LIBUSB_ERROR_TIMEOUT && sent == 2,
            "a partial timeout reports the accepted bytes so the caller continues after them");
    require(calls == 1, "partially transferred bytes must never be replayed");

    calls = 0; forced_result = LIBUSB_ERROR_NO_DEVICE; partial = 1;
    require(db_usb_write(&usb, bytes, sizeof bytes, &sent) == LIBUSB_ERROR_NO_DEVICE && calls == 1 && sent == 0,
            "physical detach remains an immediate error and its count is never trusted");
    puts("USB write deadline: transient stall, bounded failure, partial timeout and detach passed");
}
