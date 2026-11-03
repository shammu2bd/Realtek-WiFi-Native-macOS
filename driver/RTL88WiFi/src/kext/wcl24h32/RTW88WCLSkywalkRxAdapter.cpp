/* SPDX-License-Identifier: GPL-2.0-only
 * Deferred bounded RX conversion. Packet delivery stays disabled until the
 * 24H32 registration and RX-completion ownership contract is verified.
 */
#include "RTW88WCLSkywalkRxAdapter.hpp"
#include "RTW88WCLPacketSpanValidation.hpp"

#include <IOKit/IOLib.h>
#include <IOKit/skywalk/IOSkywalkMemorySegment.h>
#include <IOKit/skywalk/IOSkywalkNetworkPacket.h>
#include <IOKit/skywalk/IOSkywalkPacketBuffer.h>
#include <sys/kpi_mbuf.h>

#define super IOEventSource
OSDefineMetaClassAndStructors(RTW88WCLSkywalkRxAdapter, IOEventSource)

bool RTW88WCLSkywalkRxAdapter::init(OSObject *owner, IOWorkLoop *workLoop,
                                    IOSkywalkPacketBufferPool *rxPool,
                                    FrameSink sink, void *context)
{
    if (!owner || !workLoop || !rxPool || _workLoop || _rxPool || _registered)
        return false;
    if (!super::init(owner, nullptr))
        return false;

    _frames.reset();
    _workLoop = workLoop;
    _rxPool = rxPool;
    _rxPool->retain();
    _sink = sink;
    _sinkContext = context;
    __atomic_store_n(&_pendingSignal, 0U, __ATOMIC_RELAXED);
    __atomic_store_n(&_stopping, 0U, __ATOMIC_RELAXED);
    __atomic_store_n(&_dropped, 0U, __ATOMIC_RELAXED);
    __atomic_store_n(&_prepared, 0U, __ATOMIC_RELAXED);

    const IOReturn status = workLoop->addEventSource(this);
    if (status != kIOReturnSuccess) {
        _rxPool->release();
        _rxPool = nullptr;
        _workLoop = nullptr;
        _sink = nullptr;
        _sinkContext = nullptr;
        return false;
    }
    _registered = true;
    return true;
}

bool RTW88WCLSkywalkRxAdapter::isValidMbuf(mbuf_t packet)
{
    if (!packet)
        return false;

    /* Do not require the Ethernet header to fit in the first mbuf. RTW88 may
     * hand us a chained mbuf; mbuf_copydata() below safely spans the chain. */
    const size_t packetLength = mbuf_pkthdr_len(packet);
    return packetLength >= kMinimumFrameLength &&
           packetLength <= kMaximumFrameLength;
}

bool RTW88WCLSkywalkRxAdapter::copyMbufToSkywalkPacket(
    IOSkywalkPacketBufferPool *pool, mbuf_t source,
    IOSkywalkPacket **outPacket)
{
    if (outPacket)
        *outPacket = nullptr;
    if (!pool || !source || !outPacket)
        return false;

    const size_t packetLength = mbuf_pkthdr_len(source);
    if (packetLength < kMinimumFrameLength ||
        packetLength > kMaximumFrameLength)
        return false;

    IOSkywalkPacket *packet = nullptr;
    /* Option bit 0 requests non-blocking allocation in a packet callback. */
    if (pool->allocatePacket(1, &packet, 1) != kIOReturnSuccess || !packet)
        return false;

    bool valid = false;
    do {
        if (packet->getPacketType() != kIOSkywalkPacketTypeNetwork ||
            packet->getPacketBufferPool() != pool ||
            packet->getPacketBufferCount() != 1)
            break;

        auto *networkPacket = OSDynamicCast(IOSkywalkNetworkPacket, packet);
        if (!networkPacket)
            break;

        IOSkywalkPacketBuffer *buffers[1] = { nullptr };
        if (packet->getPacketBuffers(buffers, 1) != 1 || !buffers[0])
            break;
        IOSkywalkPacketBuffer *buffer = buffers[0];
        if (buffer->getPacketBufferPool() != pool)
            break;

        IOSkywalkMemorySegment *segment = buffer->getMemorySegment();
        if (!segment)
            break;
        IOMemoryDescriptor *memory = segment->getMemoryDescriptor();
        if (!memory)
            break;

        const uint64_t segmentBase = segment->getVirtualAddress();
        const RTW88WCLPacketSpan span = {
            memory->getLength(),
            buffer->getMemorySegmentOffset(),
            buffer->getBufferSize(),
            0,
            static_cast<uint32_t>(packetLength)
        };
        uintptr_t destinationAddress = 0;
        if (!RTW88WCLResolvePacketBufferAddress(
                segmentBase, span, &destinationAddress))
            break;

        if (packet->setDataOffsetAndLength(
                0, static_cast<UInt32>(packetLength)) != kIOReturnSuccess)
            break;
        if (packet->getDataOffset() != 0 ||
            packet->getDataLength() != packetLength ||
            buffer->getDataOffset() != 0 ||
            buffer->getDataLength() != packetLength)
            break;

        auto *destination = reinterpret_cast<void *>(destinationAddress);
        if (mbuf_copydata(source, 0, packetLength, destination) != 0)
            break;

        if (networkPacket->setCompletionStatus(0) != kIOReturnSuccess)
            break;

        *outPacket = packet;
        valid = true;
    } while (false);

    if (!valid)
        (void)pool->deallocatePacket(packet);
    return valid;
}

IOReturn RTW88WCLSkywalkRxAdapter::enqueueFrame(mbuf_t packet)
{
    if (!packet)
        return kIOReturnBadArgument;

    if (__atomic_load_n(&_stopping, __ATOMIC_ACQUIRE) ||
        !isValidMbuf(packet)) {
        __atomic_add_fetch(&_dropped, 1U, __ATOMIC_RELAXED);
        mbuf_freem(packet);
        return kIOReturnNotReady;
    }

    if (!_frames.push(packet)) {
        __atomic_add_fetch(&_dropped, 1U, __ATOMIC_RELAXED);
        mbuf_freem(packet);
        return kIOReturnNoResources;
    }

    uint32_t expected = 0;
    if (__atomic_compare_exchange_n(&_pendingSignal, &expected, 1U, false,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
        signalWorkAvailable();
    return kIOReturnSuccess;
}

bool RTW88WCLSkywalkRxAdapter::checkForWork()
{
    if (__atomic_load_n(&_stopping, __ATOMIC_ACQUIRE))
        return false;

    uint32_t drained = 0;
    mbuf_t source = nullptr;
    while (drained < kDrainBudget && _frames.pop(&source)) {
        if (source) {
            IOSkywalkPacket *packet = nullptr;
            if (copyMbufToSkywalkPacket(_rxPool, source, &packet)) {
                __atomic_add_fetch(&_prepared, 1U, __ATOMIC_RELAXED);
                /* A true return means the sink has accepted ownership. The
                 * current controller sink returns false because the RX
                 * completion queue is still unregistered. */
                const bool accepted = _sink && _sink(packet, _sinkContext);
                if (!accepted) {
                    (void)_rxPool->deallocatePacket(packet);
                    __atomic_add_fetch(&_dropped, 1U, __ATOMIC_RELAXED);
                }
            } else {
                __atomic_add_fetch(&_dropped, 1U, __ATOMIC_RELAXED);
            }
            mbuf_freem(source);
            source = nullptr;
        }
        ++drained;
    }

    if (drained == kDrainBudget)
        return true; // bounded workloop occupancy; schedule another pass

    __atomic_store_n(&_pendingSignal, 0U, __ATOMIC_RELEASE);
    if (!_frames.empty()) {
        uint32_t expected = 0;
        if (__atomic_compare_exchange_n(&_pendingSignal, &expected, 1U,
                                        false, __ATOMIC_ACQ_REL,
                                        __ATOMIC_ACQUIRE))
            return true;
    }
    return false;
}

void RTW88WCLSkywalkRxAdapter::stop()
{
    __atomic_store_n(&_stopping, 1U, __ATOMIC_RELEASE);
    if (_registered && _workLoop) {
        /* Synchronous removal serializes against checkForWork(). The owner
         * must stop/quiesce RTW88 RX producers before invoking stop(). */
        _workLoop->removeEventSource(this);
        _registered = false;
    }

    mbuf_t packet = nullptr;
    while (_frames.pop(&packet)) {
        if (packet)
            mbuf_freem(packet);
        packet = nullptr;
    }
    _sink = nullptr;
    _sinkContext = nullptr;
    _workLoop = nullptr;
    if (_rxPool) {
        _rxPool->release();
        _rxPool = nullptr;
    }
}

void RTW88WCLSkywalkRxAdapter::free()
{
    stop();
    super::free();
}

uint32_t RTW88WCLSkywalkRxAdapter::droppedFrames() const
{
    return __atomic_load_n(&_dropped, __ATOMIC_ACQUIRE);
}

uint32_t RTW88WCLSkywalkRxAdapter::preparedFrames() const
{
    return __atomic_load_n(&_prepared, __ATOMIC_ACQUIRE);
}

uint32_t RTW88WCLSkywalkRxAdapter::queuedFrames() const
{
    return _frames.approximateSize();
}

#undef super
