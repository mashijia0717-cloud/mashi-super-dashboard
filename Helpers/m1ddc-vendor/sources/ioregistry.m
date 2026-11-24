@import Foundation;
@import IOKit;
@import ApplicationServices;
@import CoreGraphics;

#include "ioregistry.h"
#include "utils.h"

static CFTypeRef getCFStringRef(io_service_t service, char* key) {
    CFStringRef cfstring = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingASCII);
    if (!cfstring) return NULL;
    CFTypeRef value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, cfstring, kCFAllocatorDefault, kIORegistryIterateRecursively);
    CFRelease(cfstring);
    return value;
}

static Boolean isMCDP29XXProxy(io_service_t proxy) {
    io_registry_entry_t parent = MACH_PORT_NULL;
    if (IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) != KERN_SUCCESS) {
        return false;
    }

    Boolean isMCDP29XX = false;
    CFTypeRef providerClass = IORegistryEntryCreateCFProperty(
        parent,
        CFSTR("EPICProviderClass"),
        kCFAllocatorDefault,
        0
    );
    if (providerClass != NULL && CFGetTypeID(providerClass) == CFStringGetTypeID()) {
        isMCDP29XX = CFStringCompare(providerClass, CFSTR("AppleDCPMCDP29XX"), 0) == kCFCompareEqualTo;
    }

    if (providerClass != NULL) {
        CFRelease(providerClass);
    }
    IOObjectRelease(parent);
    return isMCDP29XX;
}

CGDisplayCount getOnlineDisplayInfos(DisplayInfos* displayInfos) {
    CGDisplayCount screenCount = 0;
    CGDirectDisplayID screenList[MAX_DISPLAYS];
    if (CGGetOnlineDisplayList(MAX_DISPLAYS, screenList, &screenCount) != kCGErrorSuccess) {
        return 0;
    }

    int validDisplayCount = 0;
    for (int i = 0; i < (int)screenCount && validDisplayCount < MAX_DISPLAYS; i++) {
        DisplayInfos *currDisplay = displayInfos + validDisplayCount;
        memset(currDisplay, 0, sizeof(DisplayInfos));
        currDisplay->id = screenList[i];

        CFDictionaryRef displayInfoDict = CoreDisplay_DisplayCreateInfoDictionary(currDisplay->id);
        if (displayInfoDict == NULL) {
            continue;
        }

        currDisplay->serial = CGDisplaySerialNumber(currDisplay->id);
        currDisplay->model = CGDisplayModelNumber(currDisplay->id);
        currDisplay->vendor = CGDisplayVendorNumber(currDisplay->id);

        CFTypeRef rawUUID = CFDictionaryGetValue(displayInfoDict, CFSTR("kCGDisplayUUID"));
        CFTypeRef rawLocation = CFDictionaryGetValue(displayInfoDict, CFSTR("IODisplayLocation"));
        CFTypeRef rawVirtual = CFDictionaryGetValue(displayInfoDict, CFSTR("kCGDisplayIsVirtualDevice"));
        Boolean isVirtual = rawVirtual && CFGetTypeID(rawVirtual) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)rawVirtual);

        if (isVirtual || rawUUID == NULL || rawLocation == NULL ||
            CFGetTypeID(rawUUID) != CFStringGetTypeID() || CFGetTypeID(rawLocation) != CFStringGetTypeID()) {
            CFRelease(displayInfoDict);
            continue;
        }

        currDisplay->uuid = [(__bridge NSString *)rawUUID copy];
        currDisplay->ioLocation = [(__bridge NSString *)rawLocation copy];
        CFRelease(displayInfoDict);

        currDisplay->adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, (__bridge CFStringRef)currDisplay->ioLocation);
        if (currDisplay->adapter == MACH_PORT_NULL) {
            continue;
        }

        CFTypeRef rawEDID = getCFStringRef(currDisplay->adapter, "EDID UUID");
        if (rawEDID) {
            if (CFGetTypeID(rawEDID) == CFStringGetTypeID()) {
                currDisplay->edid = [(__bridge NSString *)rawEDID copy];
            }
            CFRelease(rawEDID);
        }

        CFTypeRef displayAttrs = getCFStringRef(currDisplay->adapter, "DisplayAttributes");
        if (displayAttrs) {
            if (CFGetTypeID(displayAttrs) == CFDictionaryGetTypeID()) {
                NSDictionary* displayAttrsNS = (__bridge NSDictionary*)displayAttrs;
                NSDictionary* productAttrs = [displayAttrsNS objectForKey:@"ProductAttributes"];
                if ([productAttrs isKindOfClass:[NSDictionary class]]) {
                    currDisplay->productName = [[productAttrs objectForKey:@"ProductName"] copy] ?: @"Unknown Display";
                    currDisplay->manufacturer = [[productAttrs objectForKey:@"ManufacturerID"] copy];
                    currDisplay->alphNumSerial = [[productAttrs objectForKey:@"AlphanumericSerialNumber"] copy];
                }
            }
            CFRelease(displayAttrs);
        }
        if (!currDisplay->productName) {
            currDisplay->productName = @"Unknown Display";
        }

        validDisplayCount++;
    }

    return validDisplayCount;
}

NSString *getDisplayIdentifier(DisplayInfos *display, char *identificationMethod) {
    if (STR_EQ(identificationMethod, "id")) {
        return [NSString stringWithFormat:@"%u", display->id];
    } else if (STR_EQ(identificationMethod, "uuid")) {
        return display->uuid ?: @"";
    } else if (STR_EQ(identificationMethod, "edid")) {
        return display->edid ?: @"";
    } else if (STR_EQ(identificationMethod, "seid")) {
        return [NSString stringWithFormat:@"%@:%@",
            display->alphNumSerial ?: @"",
            display->edid ?: @""];
    } else if (STR_EQ(identificationMethod, "basic")) {
        return [NSString stringWithFormat:@"%u:%u:%u",
            display->vendor,
            display->model,
            display->serial];
    } else if (STR_EQ(identificationMethod, "ext")) {
        return [NSString stringWithFormat:@"%d:%d:%d:%@:%@:%@",
            display->vendor,
            display->model,
            display->serial,
            display->manufacturer ?: @"",
            display->alphNumSerial ?: @"",
            display->productName ?: @""];
    } else if (STR_EQ(identificationMethod, "full")) {
        return [NSString stringWithFormat:@"%d:%d:%d:%@:%@:%@:%@",
            display->vendor,
            display->model,
            display->serial,
            display->manufacturer ?: @"",
            display->alphNumSerial ?: @"",
            display->productName ?: @"",
            display->ioLocation ?: @""];
    }
    return NULL;
}

DisplayInfos* selectDisplay(DisplayInfos *displays, int connectedDisplays, char *displayIdentifier) {
    char *stop;
    long displayNumber = strtol(displayIdentifier, &stop, 10);
    if (*stop == '\0') {
        return (displayNumber >= 1 && displayNumber <= connectedDisplays) ? displays + (displayNumber - 1) : NULL;
    }

    char *identificationMethod = "uuid";
    char *delimiter = strstr(displayIdentifier, "=");
    if (delimiter != NULL) {
        if (delimiter == displayIdentifier || delimiter == displayIdentifier + strlen(displayIdentifier) - 1) return NULL;
        *delimiter = '\0';
        identificationMethod = displayIdentifier;
        displayIdentifier = delimiter + 1;
    }

    for (int i = 0; i < connectedDisplays; i++) {
        const char *displayValue = getDisplayIdentifier(displays + i, identificationMethod).UTF8String;
        if (displayValue != NULL && STR_EQ(displayIdentifier, displayValue)) {
            return displays + i;
        }
    }
    return NULL;
}

static kern_return_t getIORegistryRootIterator(io_iterator_t* iter) {
    *iter = MACH_PORT_NULL;
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (root == MACH_PORT_NULL) return KERN_FAILURE;
    kern_return_t ret = IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, iter);
    IOObjectRelease(root);
    return ret;
}

IOAVServiceRef getDefaultDisplayAVService() {
    return IOAVServiceCreate(kCFAllocatorDefault);
}

static Boolean tryCreateExternalTransportFromProxy(io_service_t service, DDCTransport *transport) {
    io_name_t name;
    if (IORegistryEntryGetName(service, name) != KERN_SUCCESS || !STR_EQ(name, "DCPAVServiceProxy")) {
        return false;
    }
    IOAVServiceRef avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
    if (avService == NULL) {
        return false;
    }
    CFTypeRef location = getCFStringRef(service, "Location");
    Boolean isExternal = location != NULL &&
        CFGetTypeID(location) == CFStringGetTypeID() &&
        CFStringCompare(CFSTR("External"), (CFStringRef)location, 0) == kCFCompareEqualTo;
    if (location != NULL) {
        CFRelease(location);
    }
    if (!isExternal) {
        CFRelease(avService);
        return false;
    }
    transport->service = avService;
    transport->chipAddress = isMCDP29XXProxy(service)
        ? DDC_CHIP_ADDRESS_MCDP29XX
        : DDC_CHIP_ADDRESS_DEFAULT;
    return true;
}

DDCTransport getDisplayDDCTransport(DisplayInfos* displayInfos) {
    DDCTransport transport = {
        .service = NULL,
        .chipAddress = DDC_CHIP_ADDRESS_DEFAULT,
    };
    if (displayInfos == NULL || displayInfos->adapter == MACH_PORT_NULL) {
        return transport;
    }

    // 1. Prefer direct subtree search under the display's own IOMobileFramebuffer adapter.
    io_iterator_t subIter = MACH_PORT_NULL;
    if (IORegistryEntryCreateIterator(displayInfos->adapter, kIOServicePlane, kIORegistryIterateRecursively, &subIter) == KERN_SUCCESS) {
        io_service_t subService;
        while ((subService = IOIteratorNext(subIter)) != MACH_PORT_NULL) {
            if (tryCreateExternalTransportFromProxy(subService, &transport)) {
                IOObjectRelease(subService);
                IOObjectRelease(subIter);
                return transport;
            }
            IOObjectRelease(subService);
        }
        IOObjectRelease(subIter);
    }

    // 2. Fallback: walk root registry matching exact adapter registry entry ID.
    uint64_t selectedAdapterID = 0;
    if (IORegistryEntryGetRegistryEntryID(displayInfos->adapter, &selectedAdapterID) != KERN_SUCCESS) {
        return transport;
    }

    io_iterator_t iter = MACH_PORT_NULL;
    if (getIORegistryRootIterator(&iter) != KERN_SUCCESS) {
        return transport;
    }

    Boolean framebufferMatchesDisplay = false;
    io_service_t service;

    while ((service = IOIteratorNext(iter)) != MACH_PORT_NULL) {
        if (IOObjectConformsTo(service, "IOMobileFramebuffer")) {
            uint64_t framebufferID = 0;
            framebufferMatchesDisplay =
                IORegistryEntryGetRegistryEntryID(service, &framebufferID) == KERN_SUCCESS &&
                framebufferID == selectedAdapterID;
            IOObjectRelease(service);
            continue;
        }

        if (framebufferMatchesDisplay && tryCreateExternalTransportFromProxy(service, &transport)) {
            IOObjectRelease(service);
            IOObjectRelease(iter);
            return transport;
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iter);
    return transport;
}

IOAVServiceRef getDisplayAVService(DisplayInfos* displayInfos) {
    return getDisplayDDCTransport(displayInfos).service;
}
