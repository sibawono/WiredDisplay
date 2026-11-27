#ifndef WD_AOA_USB_H
#define WD_AOA_USB_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t location_id;
    uint16_t vendor_id;
    uint16_t product_id;
    bool in_accessory_mode;
    char serial[128];
    char product[128];
} wd_aoa_device_t;

/* Discovers USB-attached Android devices (already in AOA mode or switchable to AOA).
   Returns number of devices written to out_devices (up to max_devices). */
int wd_aoa_discover(wd_aoa_device_t *out_devices, int max_devices);

/* Sends AOA control requests 51/52/53 to switch an Android USB device into WiredDisplay accessory mode.
   Returns 0 on success, negative errno/code on failure. */
int wd_aoa_switch_to_accessory(uint32_t location_id);

/* Opens bulk IN/OUT endpoints on an AOA-mode device (0x18D1:0x2D00/0x2D01) and bridges them
   to a non-blocking UNIX stream socketpair. Returns the socket fd >= 0, or -1 on error. */
int wd_aoa_open_bridge(uint32_t location_id);

#ifdef __cplusplus
}
#endif

#endif /* WD_AOA_USB_H */
