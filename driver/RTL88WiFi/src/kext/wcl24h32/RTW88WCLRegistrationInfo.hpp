/* SPDX-License-Identifier: GPL-2.0-only
 * Opaque IOSkywalk RegistrationInfo storage and the verified Apple 24H32
 * post-initializer writes. Field semantics intentionally remain unnamed.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace RTW88WCLRegistrationInfo24H32 {

constexpr size_t kSize = 0x130;
constexpr uint64_t kVersionAndSize = 0x0000013000000001ULL;

/* Offsets/values observed in the 24H32 createSkywalkInterface producer.
 * These are deliberately described as opaque slots, not guessed fields.
 */
constexpr size_t kOpaqueSlot0C = 0x0c;
constexpr size_t kOpaqueSlot14 = 0x14;
constexpr size_t kOpaqueSlot24 = 0x24;
constexpr size_t kOpaqueSlot40 = 0x40;
constexpr size_t kHardwareAddress = 0x108;

constexpr uint32_t kOpaqueValue0C = 3;
constexpr uint32_t kOpaqueValue14 = 2;
constexpr uint64_t kOpaqueValue24 = 0x0000008000000080ULL;
constexpr uint32_t kOpaqueValue40 = 0;

struct alignas(8) Storage {
    uint8_t bytes[kSize];
};
static_assert(sizeof(Storage) == kSize, "24H32 RegistrationInfo storage size");
static_assert(alignof(Storage) >= 8, "24H32 RegistrationInfo alignment");
static_assert(kOpaqueSlot0C + sizeof(uint32_t) <= kSize,
              "24H32 opaque slot 0x0c is in bounds");
static_assert(kOpaqueSlot14 + sizeof(uint32_t) <= kSize,
              "24H32 opaque slot 0x14 is in bounds");
static_assert(kOpaqueSlot24 + sizeof(uint64_t) <= kSize,
              "24H32 opaque slot 0x24 is in bounds");
static_assert(kOpaqueSlot40 + sizeof(uint32_t) <= kSize,
              "24H32 opaque slot 0x40 is in bounds");
static_assert(kHardwareAddress + 6 <= kSize,
              "24H32 hardware address is in bounds");

inline void clear(Storage &storage)
{
    memset(storage.bytes, 0, sizeof(storage.bytes));
}

inline void storeU32(Storage &storage, size_t offset, uint32_t value)
{
    memcpy(storage.bytes + offset, &value, sizeof(value));
}

inline void storeU64(Storage &storage, size_t offset, uint64_t value)
{
    memcpy(storage.bytes + offset, &value, sizeof(value));
}

inline uint64_t loadU64(const Storage &storage, size_t offset)
{
    uint64_t value = 0;
    memcpy(&value, storage.bytes + offset, sizeof(value));
    return value;
}

inline uint32_t loadU32(const Storage &storage, size_t offset)
{
    uint32_t value = 0;
    memcpy(&value, storage.bytes + offset, sizeof(value));
    return value;
}

/* Apply only the fields written by Apple's 24H32 createSkywalkInterface
 * caller after initRegistrationInfo(). The initializer itself remains a
 * separate kernel call because it populates other values from virtual hooks.
 */
inline bool applyAppleProducerWrites(Storage &storage,
                                     const uint8_t hardwareAddress[6])
{
    if (!hardwareAddress)
        return false;

    storeU32(storage, kOpaqueSlot14, kOpaqueValue14);
    storeU64(storage, kOpaqueSlot24, kOpaqueValue24);
    storeU32(storage, kOpaqueSlot0C, kOpaqueValue0C);
    storeU32(storage, kOpaqueSlot40, kOpaqueValue40);
    memcpy(storage.bytes + kHardwareAddress, hardwareAddress, 6);
    return true;
}

/* Called only after the kernel initRegistrationInfo() method has returned
 * true and applyAppleProducerWrites() has run.
 */
inline bool matchesApple24H32Template(const Storage &storage,
                                      const uint8_t hardwareAddress[6])
{
    if (!hardwareAddress)
        return false;
    if (loadU64(storage, 0) != kVersionAndSize)
        return false;
    if (loadU32(storage, kOpaqueSlot0C) != kOpaqueValue0C)
        return false;
    if (loadU32(storage, kOpaqueSlot14) != kOpaqueValue14)
        return false;
    if (loadU64(storage, kOpaqueSlot24) != kOpaqueValue24)
        return false;
    if (loadU32(storage, kOpaqueSlot40) != kOpaqueValue40)
        return false;
    return memcmp(storage.bytes + kHardwareAddress, hardwareAddress, 6) == 0;
}

} // namespace RTW88WCLRegistrationInfo24H32
