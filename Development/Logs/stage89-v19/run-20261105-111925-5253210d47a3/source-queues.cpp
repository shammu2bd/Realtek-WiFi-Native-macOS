/* SPDX-License-Identifier: GPL-2.0-only
 * Sequoia 24H32 Skywalk queue and packet-pool resource owner.
 */
#include "RTW88WCLSkywalkQueues.hpp"
#include "RTW88WCLPacketView.hpp"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSMetaClass.h>

/* The bundled SDK declares PoolOptions before its public: label. Expose the
 * exact protected nested ABI type through a derived access shim; its layout is
 * unchanged and no shim object is instantiated. */
class RTW88WCLPoolOptionsAccess : public IOSkywalkPacketBufferPool {
public:
    using PoolOptions = IOSkywalkPacketBufferPool::PoolOptions;
};

#define super OSObject
OSDefineMetaClassAndStructors(RTW88WCLSkywalkQueues, OSObject)

bool RTW88WCLSkywalkQueues::init()
{
    if (!super::init())
        return false;
    _txPool = nullptr;
    _rxPool = nullptr;
    _txSubmission = nullptr;
    _txCompletion = nullptr;
    _rxSubmission = nullptr;
    _rxCompletion = nullptr;
    _allocated = false;
    return true;
}

IOReturn RTW88WCLSkywalkQueues::createQueues()
{
    if (_allocated)
        return kIOReturnSuccess;
    if (_txPool || _rxPool || _txSubmission || _txCompletion ||
        _rxSubmission || _rxCompletion)
        return kIOReturnBusy;

    RTW88WCLPoolOptionsAccess::PoolOptions txOptions = {};
    txOptions.packetCount = kQueueCapacity;
    txOptions.bufferCount = kQueueCapacity;
    txOptions.bufferSize = kTxBufferSize;
    txOptions.maxBuffersPerPacket = 1;
    txOptions.memorySegmentSize = kQueueCapacity * kTxBufferSize;
    txOptions.poolFlags = 0;
    txOptions._reserved = 0;

    RTW88WCLPoolOptionsAccess::PoolOptions rxOptions = txOptions;
    rxOptions.bufferSize = kRxBufferSize;
    rxOptions.memorySegmentSize = kQueueCapacity * kRxBufferSize;

    _txPool = IOSkywalkPacketBufferPool::withName(
        "RTL88WiFi-WCL-TX", this, kIOSkywalkPacketTypeNetwork, &txOptions);
    if (!_txPool)
        goto no_memory;

    _rxPool = IOSkywalkPacketBufferPool::withName(
        "RTL88WiFi-WCL-RX", this, kIOSkywalkPacketTypeNetwork, &rxOptions);
    if (!_rxPool)
        goto no_memory;

    /* These queue objects are deliberately not added to an IOWorkLoop and
     * are not passed to registerEthernetInterface() yet. Skywalk owns their
     * scheduling and packet lifetime only after a complete RegistrationInfo
     * + ring setup transaction, which is a later stage. */
    _txSubmission = IOSkywalkTxSubmissionQueue::withPool(
        _txPool, kQueueCapacity, 0, this,
        &RTW88WCLSkywalkQueues::txSubmissionAction, this, 0);
    if (!_txSubmission)
        goto no_memory;

    _txCompletion = IOSkywalkTxCompletionQueue::withPool(
        _txPool, kQueueCapacity, 0, this,
        &RTW88WCLSkywalkQueues::txCompletionAction, this, 0);
    if (!_txCompletion)
        goto no_memory;

    _rxSubmission = IOSkywalkRxSubmissionQueue::withPool(
        _rxPool, kQueueCapacity, 0, static_cast<kern_packet_svc_class_t>(0),
        this, &RTW88WCLSkywalkQueues::rxSubmissionAction, this, 0);
    if (!_rxSubmission)
        goto no_memory;

    _rxCompletion = IOSkywalkRxCompletionQueue::withPool(
        _rxPool, kQueueCapacity, 0, this,
        &RTW88WCLSkywalkQueues::rxCompletionAction, this, 0);
    if (!_rxCompletion)
        goto no_memory;

    _allocated = true;
    IOLog("rtl88wifi-wcl: allocated Skywalk pools and four queue objects (not registered)\n");
    return kIOReturnSuccess;

no_memory:
    destroyQueues();
    return kIOReturnNoMemory;
}

void RTW88WCLSkywalkQueues::destroyQueues()
{
    /* Release queues before their pools: queue implementations retain and
     * reference their associated pool for packet and buffer accounting. */
    if (_rxCompletion) {
        _rxCompletion->release();
        _rxCompletion = nullptr;
    }
    if (_rxSubmission) {
        _rxSubmission->release();
        _rxSubmission = nullptr;
    }
    if (_txCompletion) {
        _txCompletion->release();
        _txCompletion = nullptr;
    }
    if (_txSubmission) {
        _txSubmission->release();
        _txSubmission = nullptr;
    }
    if (_rxPool) {
        _rxPool->release();
        _rxPool = nullptr;
    }
    if (_txPool) {
        _txPool->release();
        _txPool = nullptr;
    }
    _allocated = false;
}

bool RTW88WCLSkywalkQueues::queuesAllocated() const
{
    return _allocated && _txPool && _rxPool && _txSubmission &&
           _txCompletion && _rxSubmission && _rxCompletion;
}

/*
 * Sequoia 24H32 callback contract: although the bundled Skywalk action
 * typedefs are declared as IOReturn, the audited queue dispatchers
 * consume these callback return values as packet counts. Zero means
 * that no packets were accepted or completed. Do not return nonzero
 * IOReturn error constants from these action callbacks.
 */
IOReturn RTW88WCLSkywalkQueues::txSubmissionAction(
    OSObject *owner, IOSkywalkTxSubmissionQueue *queue,
    const IOSkywalkPacket **packets, UInt32 packetCount, void *refCon)
{
    (void)refCon;
    auto *self = OSDynamicCast(RTW88WCLSkywalkQueues, owner);
    if (!self || queue != self->_txSubmission || !packets || packetCount == 0)
        return static_cast<IOReturn>(0);

    /* Validate every descriptor before a future TX path is allowed to copy
     * bytes or hand ownership to RTW88. The callback remains fail-closed:
     * a validated packet is not yet accepted until its hardware completion
     * cookie is connected to the native completion queue. */
    for (UInt32 i = 0; i < packetCount; ++i) {
        if (!packets[i])
            return static_cast<IOReturn>(0);
        RTW88WCLPacketView view = {};
        if (!RTW88WCLResolveEthernetTxPacket(
                const_cast<IOSkywalkPacket *>(packets[i]), self->_txPool, &view))
            return static_cast<IOReturn>(0);
    }

    return static_cast<IOReturn>(0);
}

IOReturn RTW88WCLSkywalkQueues::txCompletionAction(
    OSObject *owner, IOSkywalkTxCompletionQueue *queue,
    IOSkywalkPacket **packets, UInt32 packetCount, void *refCon)
{
    (void)owner; (void)queue; (void)packets; (void)packetCount; (void)refCon;
    return static_cast<IOReturn>(0);
}

IOReturn RTW88WCLSkywalkQueues::rxSubmissionAction(
    OSObject *owner, IOSkywalkRxSubmissionQueue *queue,
    const IOSkywalkPacket **packets, UInt32 packetCount, void *refCon)
{
    (void)owner; (void)queue; (void)packets; (void)packetCount; (void)refCon;
    /* RX buffer ownership/refill is intentionally not accepted yet. */
    return static_cast<IOReturn>(0);
}

IOReturn RTW88WCLSkywalkQueues::rxCompletionAction(
    OSObject *owner, IOSkywalkRxCompletionQueue *queue,
    IOSkywalkPacket **packets, UInt32 packetCount, void *refCon)
{
    (void)owner; (void)queue; (void)packets; (void)packetCount; (void)refCon;
    return static_cast<IOReturn>(0);
}

void RTW88WCLSkywalkQueues::free()
{
    destroyQueues();
    super::free();
}
