/* SPDX-License-Identifier: GPL-2.0-only
 * Portable contract checks and WMM routing for the 24H32 TX queue array.
 */
#pragma once

#include <stdint.h>

namespace RTW88WCLTXQueueContract {

static constexpr uint32_t kRequiredCount = 4;

/* These values are the 24H32 packet_svc_class_t values from the pinned
 * Skywalk SDK: PKT_SC_BK, PKT_SC_BE, PKT_SC_VI and PKT_SC_VO. */
static constexpr uint32_t kServiceClassBackground = 0x00100080U;
static constexpr uint32_t kServiceClassBestEffort = 0x00000000U;
static constexpr uint32_t kServiceClassVideo = 0x00380100U;
static constexpr uint32_t kServiceClassVoice = 0x00400180U;

inline constexpr uint32_t kServiceClasses[kRequiredCount] = {
    kServiceClassBackground,
    kServiceClassBestEffort,
    kServiceClassVideo,
    kServiceClassVoice,
};

/* Linux/mac80211 IEEE80211_AC_* values in this port:
 * VO=0, VI=1, BE=2, BK=3. Use the canonical WMM TID representatives:
 * BK=1, BE=0, VI=5, VO=6.
 */
struct Route {
    uint8_t accessCategory;
    uint8_t tid;
};

static constexpr uint8_t kAccessCategoryVoice = 0;
static constexpr uint8_t kAccessCategoryVideo = 1;
static constexpr uint8_t kAccessCategoryBestEffort = 2;
static constexpr uint8_t kAccessCategoryBackground = 3;

inline bool routeForServiceClass(uint32_t serviceClass, Route *route)
{
    if (!route)
        return false;

    switch (serviceClass) {
    case kServiceClassBackground:
        route->accessCategory = kAccessCategoryBackground;
        route->tid = 1;
        return true;
    case kServiceClassBestEffort:
        route->accessCategory = kAccessCategoryBestEffort;
        route->tid = 0;
        return true;
    case kServiceClassVideo:
        route->accessCategory = kAccessCategoryVideo;
        route->tid = 5;
        return true;
    case kServiceClassVoice:
        route->accessCategory = kAccessCategoryVoice;
        route->tid = 6;
        return true;
    default:
        return false;
    }
}

struct Entry {
    const void *identity;
    uint32_t serviceClass;
};

/*
 * Validate the exact role-1 QueueSet contract before any future registration
 * argument assembly. Pointer identity and WMM class are checked independently;
 * array order is the service-class order above.
 */
inline bool validate(const Entry *entries, uint32_t count)
{
    if (!entries || count != kRequiredCount)
        return false;

    for (uint32_t i = 0; i < kRequiredCount; ++i) {
        if (!entries[i].identity ||
            entries[i].serviceClass != kServiceClasses[i])
            return false;

        Route route = {};
        if (!routeForServiceClass(entries[i].serviceClass, &route))
            return false;

        for (uint32_t j = 0; j < i; ++j) {
            if (entries[i].identity == entries[j].identity)
                return false;
        }
    }
    return true;
}

} // namespace RTW88WCLTXQueueContract
