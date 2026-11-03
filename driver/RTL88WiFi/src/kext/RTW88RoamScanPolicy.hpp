/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * Small, host-testable policy helpers for bounded associated-STA scans.
 */
#pragma once

#include <stdint.h>
#include <string.h>

namespace RTW88RoamScan {

/* Do not keep an infrastructure STA off-channel for a full-band scan. */
static const uint32_t kMaxMeshChannels = 8;

static inline bool requestedContains(const uint16_t *requested,
                                     uint32_t requestedCount,
                                     uint16_t channel)
{
    if (!requested || requestedCount == 0)
        return true;
    for (uint32_t i = 0; i < requestedCount; ++i)
        if (requested[i] == channel)
            return true;
    return false;
}

/* Append a valid, non-home, unique channel while respecting the caller's cap. */
static inline bool appendUnique(uint16_t *channels, uint32_t *count,
                                uint32_t capacity, uint16_t channel,
                                uint16_t homeChannel)
{
    if (!channels || !count || channel == 0 || channel == homeChannel ||
        *count >= capacity)
        return false;
    for (uint32_t i = 0; i < *count; ++i)
        if (channels[i] == channel)
            return false;
    channels[(*count)++] = channel;
    return true;
}

} // namespace RTW88RoamScan
