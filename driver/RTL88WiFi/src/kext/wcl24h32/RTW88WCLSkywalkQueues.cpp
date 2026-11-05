/* SPDX-License-Identifier: GPL-2.0-only
 * Sequoia 24H32 Skywalk queue and packet-pool resource owner.
 */
#include "RTW88WCLSkywalkQueues.hpp"
#include "RTW88WCLPacketView.hpp"
#include "RTW88WCLTXQueueArrayContract.hpp"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSMetaClass.h>

static_assert(RTW88WCLTXQueueContract::kRequiredCount ==
                  RTW88WCLSkywalkQueues::kTXSubmissionQueueCount,
              "TX queue owner and contract counts must match");

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
    for (UInt32 i = 0; i < kTXSubmissionQueueCount; ++i)
        _txSubmissionQueues[i] = nullptr;
    _txCompletion = nullptr;
    _rxSubmission = nullptr;
    _rxCompletion = nullptr;
    _allocated = false;
    return true;
}

IOReturn RTW88WCLSkywalkQueues::createQueues()
{
    if (_allocated)
        return (_acquisitionJournal.isCommitted() && queuesAllocated())
                   ? kIOReturnSuccess : kIOReturnNotReady;
    if (_txPool || _rxPool || _txCompletion || _rxSubmission || _rxCompletion)
        return kIOReturnBusy;
    for (UInt32 i = 0; i < kTXSubmissionQueueCount; ++i) {
        if (_txSubmissionQueues[i])
            return kIOReturnBusy;
    }
    if (!_acquisitionJournal.begin())
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
    if (!_acquisitionJournal.record(
            RTW88WCLAcquisitionJournal::Resource::kTXPool)) {
        _txPool->release();
        _txPool = nullptr;
        goto no_memory;
    }

    _rxPool = IOSkywalkPacketBufferPool::withName(
        "RTL88WiFi-WCL-RX", this, kIOSkywalkPacketTypeNetwork, &rxOptions);
    if (!_rxPool)
        goto no_memory;
    if (!_acquisitionJournal.record(
            RTW88WCLAcquisitionJournal::Resource::kRXPool)) {
        _rxPool->release();
        _rxPool = nullptr;
        goto no_memory;
    }

    /* The target exports this explicit-service-class withPool overload.
     * Its 24H32 ABI is:
     *   withPool(pool, capacity, queueId, owner, queryHandler, action,
     *            refCon, options, serviceClass)
     * The wrapper passes serviceClass first to initWithPool, then capacity
     * and queueId. Do not call initWithPool directly or write private fields.
     * The action-only overload at 0xffffff80029840c2 hard-codes 0xffffffff.
     */
    for (UInt32 i = 0; i < kTXSubmissionQueueCount; ++i) {
        _txSubmissionQueues[i] = IOSkywalkTxSubmissionQueue::withPool(
            _txPool, kQueueCapacity, i, this, nullptr,
            &RTW88WCLSkywalkQueues::txSubmissionAction, this, 0,
            static_cast<UInt32>(RTW88WCLTXQueueContract::kServiceClasses[i]));
        if (!_txSubmissionQueues[i])
            goto no_memory;

        RTW88WCLAcquisitionJournal::Resource resource =
            RTW88WCLAcquisitionJournal::Resource::kInvalid;
        if (!RTW88WCLAcquisitionJournal::txSubmissionResource(i, &resource) ||
            !_acquisitionJournal.record(resource)) {
            _txSubmissionQueues[i]->release();
            _txSubmissionQueues[i] = nullptr;
            goto no_memory;
        }
    }

    /* These queue objects are deliberately not added to an IOWorkLoop and
     * are not passed to registerEthernetInterface() yet. Skywalk owns their
     * scheduling and packet lifetime only after a complete RegistrationInfo
     * + ring setup transaction, which is a later stage. */

    _txCompletion = IOSkywalkTxCompletionQueue::withPool(
        _txPool, kQueueCapacity, 0, this,
        &RTW88WCLSkywalkQueues::txCompletionAction, this, 0);
    if (!_txCompletion)
        goto no_memory;
    if (!_acquisitionJournal.record(
            RTW88WCLAcquisitionJournal::Resource::kTXCompletion)) {
        _txCompletion->release();
        _txCompletion = nullptr;
        goto no_memory;
    }

    _rxSubmission = IOSkywalkRxSubmissionQueue::withPool(
        _rxPool, kQueueCapacity, 0, static_cast<kern_packet_svc_class_t>(0),
        this, &RTW88WCLSkywalkQueues::rxSubmissionAction, this, 0);
    if (!_rxSubmission)
        goto no_memory;
    if (!_acquisitionJournal.record(
            RTW88WCLAcquisitionJournal::Resource::kRXSubmission)) {
        _rxSubmission->release();
        _rxSubmission = nullptr;
        goto no_memory;
    }

    _rxCompletion = IOSkywalkRxCompletionQueue::withPool(
        _rxPool, kQueueCapacity, 0, this,
        &RTW88WCLSkywalkQueues::rxCompletionAction, this, 0);
    if (!_rxCompletion)
        goto no_memory;
    if (!_acquisitionJournal.record(
            RTW88WCLAcquisitionJournal::Resource::kRXCompletion)) {
        _rxCompletion->release();
        _rxCompletion = nullptr;
        goto no_memory;
    }

    if (!txSubmissionQueuesValid() || !_acquisitionJournal.commit())
        goto no_memory;

    _allocated = true;
    IOLog("rtl88wifi-wcl: allocated Skywalk pools and four WMM TX submission queues (not registered)\n");
    return kIOReturnSuccess;

no_memory:
    destroyQueues();
    return kIOReturnNoMemory;
}

void RTW88WCLSkywalkQueues::destroyQueues()
{
    if (_acquisitionJournal.isEmpty()) {
        if (hasOutstandingResources())
            IOLog("rtl88wifi-wcl: empty acquisition journal still has live queue/pool pointers; retaining owner\n");
        else
            _allocated = false;
        return;
    }

    /* The journal contains only successful acquisitions. Popping it releases
     * each resource in exact reverse order, including every partial-failure
     * prefix. It remains committed until teardown explicitly begins.
     */
    if (!_acquisitionJournal.beginRollback()) {
        IOLog("rtl88wifi-wcl: invalid queue acquisition journal; retaining resources\n");
        return;
    }

    RTW88WCLAcquisitionJournal::Resource resource =
        RTW88WCLAcquisitionJournal::Resource::kInvalid;
    while (_acquisitionJournal.popRollback(&resource))
        releaseAcquiredResource(resource);

    if (!_acquisitionJournal.finishRollback()) {
        IOLog("rtl88wifi-wcl: queue acquisition rollback incomplete; retaining owner state\n");
        return;
    }
    _allocated = false;
}

void RTW88WCLSkywalkQueues::releaseAcquiredResource(
    RTW88WCLAcquisitionJournal::Resource resource)
{
    using RTW88WCLAcquisitionJournal::Resource;
    switch (resource) {
    case Resource::kRXCompletion:
        if (_rxCompletion) {
            _rxCompletion->release();
            _rxCompletion = nullptr;
        } else {
            IOLog("rtl88wifi-wcl: rollback journal expected RX completion queue\n");
        }
        break;
    case Resource::kRXSubmission:
        if (_rxSubmission) {
            _rxSubmission->release();
            _rxSubmission = nullptr;
        } else {
            IOLog("rtl88wifi-wcl: rollback journal expected RX submission queue\n");
        }
        break;
    case Resource::kTXCompletion:
        if (_txCompletion) {
            _txCompletion->release();
            _txCompletion = nullptr;
        } else {
            IOLog("rtl88wifi-wcl: rollback journal expected TX completion queue\n");
        }
        break;
    case Resource::kTXSubmission3:
    case Resource::kTXSubmission2:
    case Resource::kTXSubmission1:
    case Resource::kTXSubmission0: {
        const UInt32 index = static_cast<UInt32>(resource) -
            static_cast<UInt32>(Resource::kTXSubmission0);
        if (index < kTXSubmissionQueueCount && _txSubmissionQueues[index]) {
            _txSubmissionQueues[index]->release();
            _txSubmissionQueues[index] = nullptr;
        } else {
            IOLog("rtl88wifi-wcl: rollback journal expected TX submission queue %u\n",
                  index);
        }
        break;
    }
    case Resource::kRXPool:
        if (_rxPool) {
            _rxPool->release();
            _rxPool = nullptr;
        } else {
            IOLog("rtl88wifi-wcl: rollback journal expected RX pool\n");
        }
        break;
    case Resource::kTXPool:
        if (_txPool) {
            _txPool->release();
            _txPool = nullptr;
        } else {
            IOLog("rtl88wifi-wcl: rollback journal expected TX pool\n");
        }
        break;
    case Resource::kInvalid:
        IOLog("rtl88wifi-wcl: invalid resource in queue rollback journal\n");
        break;
    }
}

bool RTW88WCLSkywalkQueues::hasOutstandingResources() const
{
    if (_txPool || _rxPool || _txCompletion || _rxSubmission || _rxCompletion)
        return true;
    for (UInt32 i = 0; i < kTXSubmissionQueueCount; ++i) {
        if (_txSubmissionQueues[i])
            return true;
    }
    return false;
}

bool RTW88WCLSkywalkQueues::txSubmissionQueuesValid() const
{
    RTW88WCLTXQueueContract::Entry entries[kTXSubmissionQueueCount] = {};
    for (UInt32 i = 0; i < kTXSubmissionQueueCount; ++i) {
        IOSkywalkTxSubmissionQueue *queue = _txSubmissionQueues[i];
        if (!queue)
            return false;
        entries[i].identity = queue;
        entries[i].serviceClass = static_cast<UInt32>(queue->getServiceClass());
    }
    return RTW88WCLTXQueueContract::validate(
        entries, kTXSubmissionQueueCount);
}

bool RTW88WCLSkywalkQueues::ownsTXSubmissionQueue(
    const IOSkywalkTxSubmissionQueue *queue) const
{
    if (!queue)
        return false;
    for (UInt32 i = 0; i < kTXSubmissionQueueCount; ++i) {
        if (_txSubmissionQueues[i] == queue)
            return true;
    }
    return false;
}

bool RTW88WCLSkywalkQueues::queuesAllocated() const
{
    return _allocated && _acquisitionJournal.isCommitted() &&
           _txPool && _rxPool && txSubmissionQueuesValid() &&
           _txCompletion && _rxSubmission && _rxCompletion;
}

/*
 * Sequoia 24H32 callback contract: although the bundled Skywalk action
 * typedefs are declared as IOReturn, the audited queue dispatchers
 * consume these callback return values as packet counts. Zero means
 * that no packets were accepted or completed. Do not return nonzero
 * IOReturn error constants from these action callbacks.
 */
UInt32 RTW88WCLSkywalkQueues::txSubmissionAction(
    OSObject *owner, IOSkywalkTxSubmissionQueue *queue,
    IOSkywalkPacket **packets, UInt32 packetCount, void *refCon)
{
    (void)refCon;
    auto *self = OSDynamicCast(RTW88WCLSkywalkQueues, owner);
    if (!self || !self->ownsTXSubmissionQueue(queue) ||
        !packets || packetCount == 0)
        return static_cast<UInt32>(0);

    /* Validate every descriptor before a future TX path is allowed to copy
     * bytes or hand ownership to RTW88. The callback remains fail-closed:
     * a validated packet is not yet accepted until its hardware completion
     * cookie is connected to the native completion queue. */
    for (UInt32 i = 0; i < packetCount; ++i) {
        if (!packets[i])
            return static_cast<UInt32>(0);
        RTW88WCLPacketView view = {};
        if (!RTW88WCLResolveEthernetTxPacket(
                packets[i], self->_txPool, &view))
            return static_cast<UInt32>(0);
    }

    return static_cast<UInt32>(0);
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
    if (!_acquisitionJournal.isEmpty() || hasOutstandingResources() || _allocated) {
        IOLog("rtl88wifi-wcl: queue-owner rollback incomplete; quarantining owner and retaining resources\n");
        /* A live queue/pool may retain this owner as its callback context.
         * Never destroy the owner while any journaled or residual resource
         * could still reference it.
         */
        return;
    }
    super::free();
}
