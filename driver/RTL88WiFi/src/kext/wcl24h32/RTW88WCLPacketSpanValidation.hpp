/* SPDX-License-Identifier: GPL-2.0-only
 * Overflow-safe bounds checks shared by native Skywalk TX and RX adapters.
 * This file intentionally has no IOKit dependency so the arithmetic can be
 * exhaustively tested on the host before it is used with private ABI objects.
 */
#pragma once

#include <stdint.h>

struct RTW88WCLPacketSpan {
    uint64_t segmentLength;
    uint64_t bufferOffset;
    uint32_t bufferCapacity;
    uint32_t dataOffset;
    uint32_t dataLength;
};

static inline bool RTW88WCLRangeFits(uint64_t extent,
                                     uint64_t offset,
                                     uint64_t length)
{
    return offset <= extent && length <= (extent - offset);
}

static inline bool RTW88WCLPacketSpanIsValid(const RTW88WCLPacketSpan &span)
{
    if (span.bufferCapacity == 0)
        return false;
    if (!RTW88WCLRangeFits(span.segmentLength, span.bufferOffset,
                           span.bufferCapacity))
        return false;
    if (!RTW88WCLRangeFits(span.bufferCapacity, span.dataOffset,
                           span.dataLength))
        return false;
    return true;
}

static inline bool RTW88WCLIsValidEthernetFrameLength(uint32_t length,
                                                       uint32_t bufferCapacity)
{
    /* Match RTW88IEEE80211::txDataFrame(): Ethernet header through 2048 bytes. */
    return length >= 14 && length <= 2048 && length <= bufferCapacity;
}

static inline bool RTW88WCLResolvePacketBufferAddress(
    uint64_t segmentBase, const RTW88WCLPacketSpan &span,
    uintptr_t *address)
{
    if (!address || segmentBase == 0 ||
        !RTW88WCLPacketSpanIsValid(span))
        return false;

    if (span.bufferOffset > UINT64_MAX - span.dataOffset)
        return false;
    const uint64_t relative = span.bufferOffset + span.dataOffset;
    if (segmentBase > UINT64_MAX - relative)
        return false;

    const uint64_t candidate = segmentBase + relative;
    if (candidate > static_cast<uint64_t>(UINTPTR_MAX) ||
        span.dataLength > static_cast<uint64_t>(UINTPTR_MAX) - candidate)
        return false;

    *address = static_cast<uintptr_t>(candidate);
    return true;
}
