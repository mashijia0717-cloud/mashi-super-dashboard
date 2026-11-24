#ifndef RD_DISPLAY_TOPOLOGY_H
#define RD_DISPLAY_TOPOLOGY_H
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define RD_TOPOLOGY_CAPACITY 128
#define RD_BUILTIN 1u
#define RD_ONLINE 2u
#define RD_ACTIVE 4u
#define RD_ASLEEP 8u
#define RD_MAIN 16u
#define RD_VIRTUAL 32u

typedef struct {
    uint32_t id, vendor, model, serial, flags, mirror;
    uint32_t width, height, pixelWidth, pixelHeight;
    double x, y, boundWidth, boundHeight, refreshRate;
} RDDisplay;

typedef struct {
    bool valid;
    uint32_t physicalCount, managedCount;
    RDDisplay physical[RD_TOPOLOGY_CAPACITY];
    RDDisplay managed[RD_TOPOLOGY_CAPACITY];
} RDTopology;

typedef enum { RDEventScreenParameters, RDEventDisplayCallback, RDEventStartup, RDEventWake, RDEventScreenWake } RDEvent;

typedef struct {
    RDTopology previous;
    uint32_t knownManaged[RD_TOPOLOGY_CAPACITY];
    uint32_t knownManagedCount;
    bool initialized, virtualBurst;
} RDTopologyGate;

static inline bool RDIsManagedVirtual(uint32_t vendor, uint32_t model, bool builtin) {
    return !builtin && vendor == 0x5244u && model == 0x4150u;
}

static inline bool RDIsVirtualDisplay(uint32_t vendor, uint32_t model, uint32_t serial, bool builtin) {
    if (builtin) return false;
    // 0x5244/0x4150: RustDesk virtual display; 0x6d737472 ("mstr" = 1836479232): Ferry/UU virtual display
    return RDIsManagedVirtual(vendor, model, false) || serial == 0x6d737472u;
}

static inline bool RDDisplayEqual(RDDisplay first, RDDisplay second) {
    return first.id == second.id && first.vendor == second.vendor && first.model == second.model &&
        first.serial == second.serial && first.flags == second.flags && first.mirror == second.mirror &&
        first.width == second.width && first.height == second.height && first.pixelWidth == second.pixelWidth &&
        first.pixelHeight == second.pixelHeight && first.x == second.x && first.y == second.y &&
        first.boundWidth == second.boundWidth && first.boundHeight == second.boundHeight && first.refreshRate == second.refreshRate;
}

static inline RDTopology RDTopologyCreate(bool valid) {
    RDTopology value = {0}; value.valid = valid; return value;
}

static inline bool RDTopologyAdd(RDTopology *topology, RDDisplay display) {
    if (!topology->valid || topology->physicalCount + topology->managedCount >= RD_TOPOLOGY_CAPACITY) {
        topology->valid = false; return false;
    }
    bool builtin = (display.flags & RD_BUILTIN) != 0;
    if (RDIsVirtualDisplay(display.vendor, display.model, display.serial, builtin)) {
        display.flags |= RD_VIRTUAL;
    }
    bool managed = RDIsManagedVirtual(display.vendor, display.model, builtin);
    RDDisplay *rows = managed ? topology->managed : topology->physical;
    uint32_t *count = managed ? &topology->managedCount : &topology->physicalCount;
    uint32_t index = *count;
    while (index > 0 && rows[index - 1].id > display.id) { rows[index] = rows[index - 1]; index--; }
    rows[index] = display; (*count)++; return true;
}

static inline RDDisplay RDPhysicalDisplayAt(const RDTopology *topology, uint32_t index) {
    RDDisplay empty = {0};
    return (topology && index < topology->physicalCount && index < RD_TOPOLOGY_CAPACITY) ? topology->physical[index] : empty;
}

static inline bool RDHasPhysical(const RDTopology *topology, uint32_t identifier) {
    for (uint32_t index = 0; index < topology->physicalCount; index++)
        if (topology->physical[index].id == identifier && !(topology->physical[index].flags & RD_VIRTUAL)) return true;
    return false;
}

static inline bool RDSamePhysical(const RDTopology *first, const RDTopology *second) {
    if (!first->valid || !second->valid || first->physicalCount != second->physicalCount) return false;
    for (uint32_t index = 0; index < first->physicalCount; index++)
        if (!RDDisplayEqual(first->physical[index], second->physical[index])) return false;
    return true;
}

static inline void RDRememberManaged(RDTopologyGate *gate, const RDTopology *topology) {
    uint32_t kept = 0;
    for (uint32_t index = 0; index < gate->knownManagedCount; index++)
        if (!RDHasPhysical(topology, gate->knownManaged[index])) gate->knownManaged[kept++] = gate->knownManaged[index];
    gate->knownManagedCount = kept;
    for (uint32_t index = 0; index < topology->managedCount; index++) {
        uint32_t identifier = topology->managed[index].id;
        bool found = false;
        for (uint32_t known = 0; known < kept; known++) if (gate->knownManaged[known] == identifier) found = true;
        if (!found && kept < RD_TOPOLOGY_CAPACITY) gate->knownManaged[kept++] = identifier;
    }
    gate->knownManagedCount = kept;
}

static inline RDTopologyGate RDTopologyGateCreate(RDTopology initial) {
    RDTopologyGate gate = {0}; gate.previous = initial; gate.initialized = initial.valid;
    if (initial.valid) RDRememberManaged(&gate, &initial);
    return gate;
}

static inline bool RDTopologyShouldProcess(RDTopologyGate *gate, RDTopology current, RDEvent event, uint32_t eventDisplay) {
    if (!current.valid) { gate->initialized = false; gate->virtualBurst = false; return true; }
    bool process = true;
    if (gate->initialized && RDSamePhysical(&gate->previous, &current) && event != RDEventStartup && event != RDEventWake) {
        if (event == RDEventDisplayCallback) {
            bool physical = RDHasPhysical(&current, eventDisplay) || RDHasPhysical(&gate->previous, eventDisplay);
            bool managed = false;
            for (uint32_t index = 0; index < current.managedCount; index++)
                if (current.managed[index].id == eventDisplay) managed = true;
            for (uint32_t index = 0; index < gate->knownManagedCount; index++)
                if (gate->knownManaged[index] == eventDisplay) managed = true;
            process = physical || !managed;
        } else {
            process = !(current.managedCount || gate->previous.managedCount || gate->virtualBurst);
        }
    }
    gate->virtualBurst = !process;
    RDRememberManaged(gate, &current);
    gate->previous = current;
    gate->initialized = true;
    return process;
}

static inline uint32_t RDUsableExternalCount(const RDTopology *topology) {
    uint32_t count = 0;
    if (!topology->valid) return 0;
    for (uint32_t index = 0; index < topology->physicalCount; index++) {
        uint32_t flags = topology->physical[index].flags;
        bool usableSize = topology->physical[index].boundWidth > 1 && topology->physical[index].boundHeight > 1;
        if (!(flags & RD_BUILTIN) && !(flags & RD_VIRTUAL) && (flags & RD_ONLINE) && (flags & RD_ACTIVE) && !(flags & RD_ASLEEP) && usableSize) count++;
    }
    return count;
}

#if defined(__APPLE__) && !defined(RD_NO_SYSTEM_READER)
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

static inline bool RDQuerySystemVirtualDisplay(CGDirectDisplayID identifier) {
    if (CGDisplayIsBuiltin(identifier)) return false;
    uint32_t vendor = CGDisplayVendorNumber(identifier);
    uint32_t model = CGDisplayModelNumber(identifier);
    uint32_t serial = CGDisplaySerialNumber(identifier);
    if (RDIsVirtualDisplay(vendor, model, serial, false)) return true;

    typedef CFDictionaryRef (*RDCreateInfoFn)(CGDirectDisplayID);
    static RDCreateInfoFn createInfo = NULL;
    static bool resolved = false;
    if (!resolved) {
        void *handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
        if (handle) createInfo = (RDCreateInfoFn)dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary");
        resolved = true;
    }
    if (!createInfo) return false;
    CFDictionaryRef info = createInfo(identifier);
    if (!info) return false;
    bool isVirtual = false;
    CFTypeRef virtualVal = CFDictionaryGetValue(info, CFSTR("kCGDisplayIsVirtualDevice"));
    if (virtualVal && CFGetTypeID(virtualVal) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)virtualVal)) {
        isVirtual = true;
    }
    CFTypeRef airplayVal = CFDictionaryGetValue(info, CFSTR("kCGDisplayIsAirPlay"));
    if (airplayVal && CFGetTypeID(airplayVal) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)airplayVal)) {
        isVirtual = true;
    }
    CFRelease(info);
    return isVirtual;
}

static inline RDTopology RDReadSystemTopology(void) {
    RDTopology result = RDTopologyCreate(true);
    CGDirectDisplayID identifiers[RD_TOPOLOGY_CAPACITY]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(RD_TOPOLOGY_CAPACITY, identifiers, &count) != kCGErrorSuccess || count >= RD_TOPOLOGY_CAPACITY)
        return RDTopologyCreate(false);
    for (uint32_t index = 0; index < count; index++) {
        CGDirectDisplayID identifier = identifiers[index];
        RDDisplay display = {0}; display.id = identifier;
        display.vendor = CGDisplayVendorNumber(identifier); display.model = CGDisplayModelNumber(identifier);
        display.serial = CGDisplaySerialNumber(identifier); display.mirror = CGDisplayMirrorsDisplay(identifier);
        if (CGDisplayIsBuiltin(identifier)) display.flags |= RD_BUILTIN;
        if (CGDisplayIsOnline(identifier)) display.flags |= RD_ONLINE;
        if (CGDisplayIsActive(identifier)) display.flags |= RD_ACTIVE;
        if (CGDisplayIsAsleep(identifier)) display.flags |= RD_ASLEEP;
        if (CGDisplayIsMain(identifier)) display.flags |= RD_MAIN;
        if (RDQuerySystemVirtualDisplay(identifier)) display.flags |= RD_VIRTUAL;
        CGRect bounds = CGDisplayBounds(identifier);
        display.x = bounds.origin.x; display.y = bounds.origin.y;
        display.boundWidth = bounds.size.width; display.boundHeight = bounds.size.height;
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(identifier);
        if (mode) {
            display.width = (uint32_t)CGDisplayModeGetWidth(mode); display.height = (uint32_t)CGDisplayModeGetHeight(mode);
            display.pixelWidth = (uint32_t)CGDisplayModeGetPixelWidth(mode); display.pixelHeight = (uint32_t)CGDisplayModeGetPixelHeight(mode);
            display.refreshRate = CGDisplayModeGetRefreshRate(mode); CGDisplayModeRelease(mode);
        }
        RDTopologyAdd(&result, display);
    }
    return result;
}
#endif
#endif
