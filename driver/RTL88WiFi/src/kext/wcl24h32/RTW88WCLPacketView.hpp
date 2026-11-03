/* SPDX-License-Identifier: GPL-2.0-only
 * Checked view over a single-buffer IOSkywalk network packet.
 */
#pragma once

#include <IOKit/skywalk/IOSkywalkNetworkPacket.h>
#include <IOKit/skywalk/IOSkywalkPacketBuffer.h>
#include <IOKit/skywalk/IOSkywalkMemorySegment.h>

#include "RTW88WCLPacketSpanValidation.hpp"

struct RTW88WCLPacketView {
    const uint8_t *bytes;
    uint32_t length;
    uint32_t capacity;
};

static inline bool RTW88WCLResolveSingleBufferPacket(
    IOSkywalkPacket *packet,
    IOSkywalkPacketBufferPool *expectedPool,
    RTW88WCLPacketView *view)
{
    if (!packet || !expectedPool || !view)
        return false;
    view->bytes = nullptr;
    view->length = 0;
    view->capacity = 0;

    if (packet->getPacketType() != kIOSkywalkPacketTypeNetwork ||
        packet->getPacketBufferPool() != expectedPool ||
        packet->getPacketBufferCount() != 1)
        return false;

    IOSkywalkPacketBuffer *buffers[1] = { nullptr };
    if (packet->getPacketBuffers(buffers, 1) != 1 || !buffers[0])
        return false;

    IOSkywalkPacketBuffer *buffer = buffers[0];
    if (buffer->getPacketBufferPool() != expectedPool)
        return false;

    IOSkywalkMemorySegment *segment = buffer->getMemorySegment();
    if (!segment)
        return false;
    IOMemoryDescriptor *memory = segment->getMemoryDescriptor();
    if (!memory)
        return false;

    const uint64_t segmentLength = memory->getLength();
    const uint64_t segmentBase = segment->getVirtualAddress();
    const uint64_t bufferOffset = buffer->getMemorySegmentOffset();
    const uint32_t capacity = buffer->getBufferSize();
    const uint32_t dataOffset = buffer->getDataOffset();
    const uint32_t dataLength = buffer->getDataLength();
    if (packet->getDataOffset() != dataOffset ||
        packet->getDataLength() != dataLength)
        return false;

    const RTW88WCLPacketSpan span = {
        segmentLength, bufferOffset, capacity, dataOffset, dataLength
    };
    if (!RTW88WCLPacketSpanIsValid(span) || segmentBase == 0)
        return false;

    const uint64_t relativeOffset = bufferOffset + dataOffset;
    if (segmentBase > UINT64_MAX - relativeOffset)
        return false;
    const uint64_t address = segmentBase + relativeOffset;
    if (address > (uint64_t)UINTPTR_MAX)
        return false;

    view->bytes = reinterpret_cast<const uint8_t *>(
        static_cast<uintptr_t>(address));
    view->length = dataLength;
    view->capacity = capacity - dataOffset;
    return true;
}

static inline bool RTW88WCLResolveEthernetTxPacket(
    IOSkywalkPacket *packet,
    IOSkywalkPacketBufferPool *expectedPool,
    RTW88WCLPacketView *view)
{
    if (!RTW88WCLResolveSingleBufferPacket(packet, expectedPool, view))
        return false;
    return RTW88WCLIsValidEthernetFrameLength(view->length, view->capacity);
}
