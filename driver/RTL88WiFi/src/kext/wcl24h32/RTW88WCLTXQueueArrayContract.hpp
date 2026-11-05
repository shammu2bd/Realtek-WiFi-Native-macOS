/* SPDX-License-Identifier: GPL-2.0-only
 * Portable contract checks for the 24H32 role-1 TX submission queue array.
 */
#pragma once

#include <stdint.h>

namespace RTW88WCLTXQueueContract {

static constexpr uint32_t kRequiredCount = 4;
inline constexpr uint32_t kServiceClasses[kRequiredCount] = {
    0x00100080U,
    0x00000000U,
    0x00380100U,
    0x00400180U,
};

struct Entry {
    const void *identity;
    uint32_t serviceClass;
    uint32_t queueId;
};

/*
 * Validate the exact role-1 QueueSet contract before any future registration
 * argument assembly. Pointer identity, WMM class and queue ID are checked
 * independently; array order is the service-class order above.
 */
inline bool validate(const Entry *entries, uint32_t count)
{
    if (!entries || count != kRequiredCount)
        return false;

    for (uint32_t i = 0; i < kRequiredCount; ++i) {
        if (!entries[i].identity ||
            entries[i].serviceClass != kServiceClasses[i] ||
            entries[i].queueId != i)
            return false;

        for (uint32_t j = 0; j < i; ++j) {
            if (entries[i].identity == entries[j].identity)
                return false;
        }
    }
    return true;
}

} // namespace RTW88WCLTXQueueContract
