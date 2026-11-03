/* SPDX-License-Identifier: GPL-2.0-only
 * Bounds-checked decoder for the Sequoia 24H32 WCL scan/join request records.
 * The input format is little-endian and is intentionally independent of IOKit.
 */
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

namespace RTW88WCLRequest {
static inline uint16_t read16(const uint8_t *p) {
    return static_cast<uint16_t>(p[0]) |
           static_cast<uint16_t>(static_cast<uint16_t>(p[1]) << 8);
}
static inline uint32_t read32(const uint8_t *p) {
    return static_cast<uint32_t>(p[0]) |
           (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

struct Scan {
    uint32_t identifier;
    uint32_t type;
    uint8_t ssid[32];
    uint32_t ssidLength;
    uint8_t bssid[6];
    uint32_t channelCount;
    uint8_t channelBitmap[32];
};

inline bool decodeScan(const void *buffer, size_t length, Scan &out) {
    if (!buffer || length < 0x58) return false;
    const uint8_t *p = static_cast<const uint8_t *>(buffer);
    const uint32_t count = read32(p + 0x54);
    const uint32_t ssidLength = read32(p + 0x1c);
    const uint32_t type = read32(p + 0x40);
    if (count > 400 || ssidLength > 32 || type < 1 || type > 4 ||
        length < 0x58 + static_cast<size_t>(count) * 12) return false;

    Scan candidate = {};
    candidate.identifier = read32(p);
    candidate.type = type;
    candidate.ssidLength = ssidLength;
    candidate.channelCount = count;
    memcpy(candidate.ssid, p + 0x20, ssidLength);
    memcpy(candidate.bssid, p + 0x14, sizeof(candidate.bssid));
    for (uint32_t i = 0; i < count; ++i) {
        const uint8_t *entry = p + 0x58 + static_cast<size_t>(i) * 12;
        const uint32_t channel = read32(entry + 4);
        const uint32_t flags = read32(entry + 8);
        if (channel == 0 || channel > 196 || (flags & 0x2000)) continue;
        if (((flags & 0x8) && channel > 14) ||
            ((flags & 0x10) && channel <= 14)) continue;
        candidate.channelBitmap[channel / 8] |=
            static_cast<uint8_t>(1U << (channel % 8));
    }
    out = candidate;
    return true;
}

struct Join {
    uint32_t lowerAuth;
    uint32_t upperAuth;
    uint8_t ssid[32];
    uint32_t ssidLength;
    uint8_t key[64];
    uint32_t keyLength;
    uint32_t keyCipher;
    uint16_t keyIndex;
    uint8_t bssid[6];
    uint16_t channelSpec;
    uint8_t rsn[257];
    uint16_t rsnLength;
};

inline void wipeBytes(void *buffer, size_t length) {
    volatile uint8_t *bytes = static_cast<volatile uint8_t *>(buffer);
    while (length--) *bytes++ = 0;
}

inline bool validBSSID(const uint8_t bssid[6]) {
    uint8_t aggregate = 0;
    for (unsigned i = 0; i < 6; ++i) aggregate |= bssid[i];
    return aggregate != 0 && (bssid[0] & 1U) == 0;
}

inline bool validRSN(const uint8_t *ie, uint16_t length) {
    if (!length) return true;
    return ie && length >= 4 && ie[0] == 48 &&
           static_cast<uint16_t>(ie[1] + 2U) == length;
}

/* This RTW88 native-WCL slice supports open networks and WPA2-PSK with a
 * 32-byte PMK. Enterprise, SHA256 AKMs, passphrases, WEP and SAE are rejected
 * because the current RTW88 join engine has not implemented those WCL modes. */
inline bool supportedJoinAuth(const Join &j) {
    if (j.lowerAuth != 1 || !validRSN(j.rsn, j.rsnLength)) return false;
    if (j.upperAuth == 0)
        return j.keyLength == 0 && j.keyCipher == 0 && j.rsnLength == 0;
    return j.upperAuth == (1U << 3) && j.keyLength == 32 &&
           (j.keyCipher == 6 || j.keyCipher == 7);
}

inline bool decodeJoin(const void *buffer, size_t length, Join &out) {
    if (!buffer || length < 0x218) return false;
    const uint8_t *p = static_cast<const uint8_t *>(buffer);
    const uint32_t candidateCount = read32(p + 0x214);
    const uint32_t ssidLength = read32(p + 0x1c);
    const uint32_t keyLength = read32(p + 0x44);
    const uint16_t rsnLength = read16(p + 0xd4);
    if (candidateCount == 0 || candidateCount > 10 ||
        ssidLength == 0 || ssidLength > 32 || keyLength > 64 ||
        rsnLength > 257 || length < 0x218 + static_cast<size_t>(candidateCount) * 18 ||
        p[0x21c] & 1U) return false;
    if (keyLength > 32 && read32(p + 0x48) != 10) return false;

    Join candidate = {};
    candidate.lowerAuth = read32(p + 0x10);
    candidate.upperAuth = read32(p + 0x14);
    candidate.ssidLength = ssidLength;
    memcpy(candidate.ssid, p + 0x20, ssidLength);
    candidate.keyLength = keyLength;
    candidate.keyCipher = read32(p + 0x48);
    candidate.keyIndex = read16(p + 0x4e);
    memcpy(candidate.key, p + 0x50, keyLength);
    memcpy(candidate.bssid, p + 0x21c, 6);
    candidate.channelSpec = read16(p + 0x228);
    candidate.rsnLength = rsnLength;
    memcpy(candidate.rsn, p + 0xd6, rsnLength);
    if (!validBSSID(candidate.bssid) || !supportedJoinAuth(candidate)) {
        wipeBytes(candidate.key, sizeof(candidate.key));
        return false;
    }
    out = candidate;
    wipeBytes(candidate.key, sizeof(candidate.key));
    return true;
}
} // namespace RTW88WCLRequest
