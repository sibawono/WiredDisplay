#ifdef __APPLE__
#include "WDAoaUSB.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define WD_AOA_VENDOR_GOOGLE 0x18D1
#define WD_AOA_PID_BASE      0x2D00
#define WD_AOA_PID_ADB       0x2D01

#define WD_AOA_REQ_GET_PROTOCOL 51
#define WD_AOA_REQ_SEND_STRING  52
#define WD_AOA_REQ_START        53

static const char *kAoaStrings[6] = {
    "WiredDisplay",
    "WiredDisplay",
    "WiredDisplay USB Display",
    "0.5.4",
    "https://wireddisplay.dev",
    "WD-AOA-1"
};

static void copy_cf_string_prop(io_service_t service, CFStringRef key, char *dst, size_t dst_len) {
    dst[0] = '\0';
    CFTypeRef val = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!val) return;
    if (CFGetTypeID(val) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)val, dst, (CFIndex)dst_len, kCFStringEncodingUTF8);
    }
    CFRelease(val);
}

static bool get_device_interface(io_service_t service, IOUSBDeviceInterface ***out_dev) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
                                          &plug, &score) != kIOReturnSuccess || !plug) {
        return false;
    }
    IOUSBDeviceInterface **dev = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (hr != S_OK || !dev) return false;
    *out_dev = dev;
    return true;
}

static bool has_android_interface(IOUSBDeviceInterface **dev) {
    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    req.bAlternateSetting = kIOUSBFindInterfaceDontCare;
    io_iterator_t iter = 0;
    if ((*dev)->CreateInterfaceIterator(dev, &req, &iter) != kIOReturnSuccess) return false;
    bool found = false;
    io_service_t intf_service;
    while ((intf_service = IOIteratorNext(iter)) != 0) {
        IOCFPlugInInterface **plug = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(intf_service, kIOUSBInterfaceUserClientTypeID,
                                              kIOCFPlugInInterfaceID, &plug, &score) == kIOReturnSuccess && plug) {
            IOUSBInterfaceInterface **intf = NULL;
            if ((*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
                                        (LPVOID *)&intf) == S_OK && intf) {
                UInt8 cls = 0, sub = 0, proto = 0;
                (*intf)->GetInterfaceClass(intf, &cls);
                (*intf)->GetInterfaceSubClass(intf, &sub);
                (*intf)->GetInterfaceProtocol(intf, &proto);
                /* ADB (FF/42/01), PTP/MTP (06/01/01), or Android MTP vendor (FF/FF/00). */
                if ((cls == 0xFF && sub == 0x42 && proto == 0x01) ||
                    (cls == 0x06 && sub == 0x01 && proto == 0x01) ||
                    (cls == 0xFF && sub == 0xFF && proto == 0x00)) {
                    found = true;
                }
                (*intf)->Release(intf);
            }
            (*plug)->Release(plug);
        }
        IOObjectRelease(intf_service);
        if (found) break;
    }
    IOObjectRelease(iter);
    return found;
}

static io_service_t find_device_by_location(uint32_t target_location) {
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matching) return 0;
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != kIOReturnSuccess) return 0;
    io_service_t found = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iter)) != 0) {
        IOUSBDeviceInterface **dev = NULL;
        if (get_device_interface(service, &dev)) {
            UInt32 loc = 0;
            if ((*dev)->GetLocationID(dev, &loc) == kIOReturnSuccess && loc == target_location) {
                found = service;
                (*dev)->Release(dev);
                break;
            }
            (*dev)->Release(dev);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    return found;
}

int wd_aoa_discover(wd_aoa_device_t *out_devices, int max_devices) {
    if (!out_devices || max_devices <= 0) return 0;
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matching) return 0;
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != kIOReturnSuccess) return 0;

    int count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iter)) != 0 && count < max_devices) {
        IOUSBDeviceInterface **dev = NULL;
        if (get_device_interface(service, &dev)) {
            UInt16 vid = 0, pid = 0;
            UInt32 loc = 0;
            (*dev)->GetDeviceVendor(dev, &vid);
            (*dev)->GetDeviceProduct(dev, &pid);
            (*dev)->GetLocationID(dev, &loc);

            /* Never probe Apple devices (0x05AC) or hubs. */
            if (vid != 0x05AC && vid != 0) {
                bool is_aoa = (vid == WD_AOA_VENDOR_GOOGLE &&
                               (pid == WD_AOA_PID_BASE || pid == WD_AOA_PID_ADB));
                bool is_candidate = is_aoa || has_android_interface(dev);
                if (is_candidate) {
                    wd_aoa_device_t *d = &out_devices[count++];
                    memset(d, 0, sizeof(*d));
                    d->location_id = loc;
                    d->vendor_id = vid;
                    d->product_id = pid;
                    d->in_accessory_mode = is_aoa;
                    copy_cf_string_prop(service, CFSTR(kUSBSerialNumberString), d->serial, sizeof(d->serial));
                    copy_cf_string_prop(service, CFSTR(kUSBProductString), d->product, sizeof(d->product));
                    if (d->serial[0] == '\0') {
                        snprintf(d->serial, sizeof(d->serial), "%08x", loc);
                    }
                }
            }
            (*dev)->Release(dev);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    return count;
}

int wd_aoa_switch_to_accessory(uint32_t location_id) {
    io_service_t service = find_device_by_location(location_id);
    if (!service) return -ENODEV;

    IOUSBDeviceInterface **dev = NULL;
    if (!get_device_interface(service, &dev)) {
        IOObjectRelease(service);
        return -EIO;
    }

    int rc = -EIO;
    if ((*dev)->USBDeviceOpen(dev) == kIOReturnSuccess) {
        UInt16 proto_ver = 0;
        IOUSBDevRequest req;
        memset(&req, 0, sizeof(req));
        req.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice);
        req.bRequest = WD_AOA_REQ_GET_PROTOCOL;
        req.wValue = 0;
        req.wIndex = 0;
        req.wLength = sizeof(proto_ver);
        req.pData = &proto_ver;

        if ((*dev)->DeviceRequest(dev, &req) == kIOReturnSuccess && proto_ver >= 1) {
            bool strings_ok = true;
            for (UInt16 idx = 0; idx < 6; idx++) {
                memset(&req, 0, sizeof(req));
                req.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBVendor, kUSBDevice);
                req.bRequest = WD_AOA_REQ_SEND_STRING;
                req.wValue = 0;
                req.wIndex = idx;
                req.wLength = (UInt16)(strlen(kAoaStrings[idx]) + 1);
                req.pData = (void *)kAoaStrings[idx];
                if ((*dev)->DeviceRequest(dev, &req) != kIOReturnSuccess) {
                    strings_ok = false;
                    break;
                }
            }
            if (strings_ok) {
                memset(&req, 0, sizeof(req));
                req.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBVendor, kUSBDevice);
                req.bRequest = WD_AOA_REQ_START;
                req.wValue = 0;
                req.wIndex = 0;
                req.wLength = 0;
                req.pData = NULL;
                if ((*dev)->DeviceRequest(dev, &req) == kIOReturnSuccess) {
                    rc = 0;
                }
            }
        }
        (*dev)->USBDeviceClose(dev);
    }

    (*dev)->Release(dev);
    IOObjectRelease(service);
    return rc;
}

typedef struct {
    IOUSBInterfaceInterface **intf;
    IOUSBDeviceInterface **dev;
    UInt8 pipe_in;
    UInt8 pipe_out;
    int sock_fd;
    volatile int stop;
    pthread_t writer_thread;
} wd_aoa_bridge_t;

static void *aoa_write_pump(void *arg) {
    wd_aoa_bridge_t *b = (wd_aoa_bridge_t *)arg;
    uint8_t *buf = (uint8_t *)malloc(65536);
    if (!buf) {
        b->stop = 1;
        return NULL;
    }
    while (!b->stop) {
        ssize_t n = recv(b->sock_fd, buf, 65536, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            break;
        }
        IOReturn kr = (*b->intf)->WritePipe(b->intf, b->pipe_out, buf, (UInt32)n);
        if (kr != kIOReturnSuccess) break;
    }
    b->stop = 1;
    (*b->intf)->AbortPipe(b->intf, b->pipe_in);
    free(buf);
    return NULL;
}

static void *aoa_read_pump(void *arg) {
    wd_aoa_bridge_t *b = (wd_aoa_bridge_t *)arg;
    uint8_t *buf = (uint8_t *)malloc(65536);
    if (buf) {
        while (!b->stop) {
            UInt32 size = 65536;
            IOReturn kr = (*b->intf)->ReadPipe(b->intf, b->pipe_in, buf, &size);
            if (kr != kIOReturnSuccess) break;
            size_t off = 0;
            while (off < size && !b->stop) {
                ssize_t w = send(b->sock_fd, buf + off, size - off, 0);
                if (w <= 0) {
                    if (w < 0 && errno == EINTR) continue;
                    b->stop = 1;
                    break;
                }
                off += (size_t)w;
            }
        }
        free(buf);
    }
    b->stop = 1;
    shutdown(b->sock_fd, SHUT_RDWR);
    (*b->intf)->AbortPipe(b->intf, b->pipe_out);
    pthread_join(b->writer_thread, NULL);
    close(b->sock_fd);
    (*b->intf)->USBInterfaceClose(b->intf);
    (*b->intf)->Release(b->intf);
    (*b->dev)->USBDeviceClose(b->dev);
    (*b->dev)->Release(b->dev);
    free(b);
    return NULL;
}

int wd_aoa_open_bridge(uint32_t location_id) {
    io_service_t service = find_device_by_location(location_id);
    if (!service) return -1;

    IOUSBDeviceInterface **dev = NULL;
    if (!get_device_interface(service, &dev)) {
        IOObjectRelease(service);
        return -1;
    }
    IOObjectRelease(service);

    if ((*dev)->USBDeviceOpen(dev) != kIOReturnSuccess) {
        (*dev)->Release(dev);
        return -1;
    }

    UInt8 current_cfg = 0;
    if ((*dev)->GetConfiguration(dev, &current_cfg) == kIOReturnSuccess && current_cfg == 0) {
        IOUSBConfigurationDescriptorPtr cfg_desc = NULL;
        if ((*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg_desc) == kIOReturnSuccess && cfg_desc) {
            (*dev)->SetConfiguration(dev, cfg_desc->bConfigurationValue);
        }
    }

    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass = 0xFF;
    req.bInterfaceSubClass = 0xFF;
    req.bInterfaceProtocol = 0x00;
    req.bAlternateSetting = kIOUSBFindInterfaceDontCare;

    io_iterator_t iter = 0;
    if ((*dev)->CreateInterfaceIterator(dev, &req, &iter) != kIOReturnSuccess) {
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return -1;
    }

    IOUSBInterfaceInterface **intf = NULL;
    UInt8 pipe_in = 0, pipe_out = 0;
    io_service_t intf_service;
    while ((intf_service = IOIteratorNext(iter)) != 0) {
        IOCFPlugInInterface **plug = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(intf_service, kIOUSBInterfaceUserClientTypeID,
                                              kIOCFPlugInInterfaceID, &plug, &score) == kIOReturnSuccess && plug) {
            IOUSBInterfaceInterface **cand = NULL;
            if ((*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
                                        (LPVOID *)&cand) == S_OK && cand) {
                if ((*cand)->USBInterfaceOpen(cand) == kIOReturnSuccess) {
                    UInt8 num_ep = 0;
                    (*cand)->GetNumEndpoints(cand, &num_ep);
                    for (UInt8 p = 1; p <= num_ep; p++) {
                        UInt8 dir = 0, num = 0, xfer = 0, interval = 0;
                        UInt16 max_pkt = 0;
                        if ((*cand)->GetPipeProperties(cand, p, &dir, &num, &xfer, &max_pkt, &interval) == kIOReturnSuccess) {
                            if (xfer == kUSBBulk) {
                                if (dir == kUSBIn && pipe_in == 0) pipe_in = p;
                                if (dir == kUSBOut && pipe_out == 0) pipe_out = p;
                            }
                        }
                    }
                    if (pipe_in != 0 && pipe_out != 0) {
                        intf = cand;
                    } else {
                        (*cand)->USBInterfaceClose(cand);
                        (*cand)->Release(cand);
                    }
                } else {
                    (*cand)->Release(cand);
                }
            }
            (*plug)->Release(plug);
        }
        IOObjectRelease(intf_service);
        if (intf) break;
    }
    IOObjectRelease(iter);

    if (!intf) {
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return -1;
    }

    int sv[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return -1;
    }

    int on = 1;
    setsockopt(sv[0], SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    setsockopt(sv[1], SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    int flags = fcntl(sv[0], F_GETFL);
    if (flags >= 0) fcntl(sv[0], F_SETFL, flags | O_NONBLOCK);

    wd_aoa_bridge_t *bridge = (wd_aoa_bridge_t *)calloc(1, sizeof(wd_aoa_bridge_t));
    if (!bridge) {
        close(sv[0]);
        close(sv[1]);
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return -1;
    }
    bridge->intf = intf;
    bridge->dev = dev;
    bridge->pipe_in = pipe_in;
    bridge->pipe_out = pipe_out;
    bridge->sock_fd = sv[1];

    pthread_t reader;
    if (pthread_create(&bridge->writer_thread, NULL, aoa_write_pump, bridge) != 0) {
        free(bridge);
        close(sv[0]);
        close(sv[1]);
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return -1;
    }
    if (pthread_create(&reader, NULL, aoa_read_pump, bridge) != 0) {
        bridge->stop = 1;
        shutdown(sv[1], SHUT_RDWR);
        pthread_join(bridge->writer_thread, NULL);
        free(bridge);
        close(sv[0]);
        close(sv[1]);
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return -1;
    }
    pthread_detach(reader);
    return sv[0];
}
#endif
