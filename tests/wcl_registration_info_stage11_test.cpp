#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp"

#include <stdio.h>

using namespace RTW88WCLRegistrationInfo24H32;

static bool inRange(size_t offset, size_t start, size_t length)
{
    return offset >= start && offset < start + length;
}

int main()
{
    Storage storage;
    memset(storage.bytes, 0xa5, sizeof(storage.bytes));

    const uint8_t address[6] = {0x02, 0x11, 0x22, 0x33, 0x44, 0x55};
    if (!applyAppleProducerWrites(storage, address)) {
        fprintf(stderr, "applyAppleProducerWrites rejected a valid address\n");
        return 1;
    }

    if (loadU32(storage, kOpaqueSlot0C) != kOpaqueValue0C ||
        loadU32(storage, kOpaqueSlot14) != kOpaqueValue14 ||
        loadU64(storage, kOpaqueSlot24) != kOpaqueValue24 ||
        loadU32(storage, kOpaqueSlot40) != kOpaqueValue40 ||
        memcmp(storage.bytes + kHardwareAddress, address, sizeof(address)) != 0) {
        fprintf(stderr, "Apple 24H32 opaque writes do not match the audited values\n");
        return 2;
    }

    /* The writer must preserve all bytes not explicitly written by Apple's
     * producer. This protects the opaque values populated by initRegistrationInfo.
     */
    for (size_t i = 0; i < sizeof(storage.bytes); ++i) {
        const bool written =
            inRange(i, kOpaqueSlot0C, sizeof(uint32_t)) ||
            inRange(i, kOpaqueSlot14, sizeof(uint32_t)) ||
            inRange(i, kOpaqueSlot24, sizeof(uint64_t)) ||
            inRange(i, kOpaqueSlot40, sizeof(uint32_t)) ||
            inRange(i, kHardwareAddress, sizeof(address));
        if (!written && storage.bytes[i] != 0xa5) {
            fprintf(stderr, "opaque byte %zu was unexpectedly modified\n", i);
            return 3;
        }
    }

    if (matchesApple24H32Template(storage, address)) {
        fprintf(stderr, "template accepted without initRegistrationInfo header\n");
        return 4;
    }

    storeU64(storage, 0, kVersionAndSize);
    if (!matchesApple24H32Template(storage, address)) {
        fprintf(stderr, "template rejected after exact 24H32 header was set\n");
        return 5;
    }
    if (matchesApple24H32Template(storage, nullptr)) {
        fprintf(stderr, "template accepted a null address\n");
        return 6;
    }
    if (applyAppleProducerWrites(storage, nullptr)) {
        fprintf(stderr, "writer accepted a null address\n");
        return 7;
    }

    clear(storage);
    for (uint8_t byte : storage.bytes) {
        if (byte != 0) {
            fprintf(stderr, "clear left a nonzero byte\n");
            return 8;
        }
    }

    puts("PASS: 0x130-byte aligned opaque RegistrationInfo storage");
    puts("PASS: exact 24H32 Apple producer overrides and six-byte address copy");
    puts("PASS: all unlisted initializer-owned bytes remain untouched");
    puts("PASS: version/size header validation and clear");
    return 0;
}
