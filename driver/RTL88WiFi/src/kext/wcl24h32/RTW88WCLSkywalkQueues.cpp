/* SPDX-License-Identifier: GPL-2.0-only
 * Sequoia 24H32 Skywalk queue and packet-pool resource owner.
 */
#include "RTW88WCLSkywalkQueues.hpp"
#include "RTW88WCLPacketView.hpp"
#include "RTW88WCLTXQueueArrayContract.hpp"
#include "RTW88WCLSkywalkTxAdapter.hpp"
#include "RTW88WCLTxSubmissionBatch.hpp"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSMetaClass.h>

static_assert(RTW88WCLTXQueueContract::kRequiredCount ==
                  RTW88WCLSkywalkQueues::kTXSubmissionQueueCount,
              "TX queue owner and contract counts must match");

/* The queue callback is synchronous and bounded, so this route context can
 * live on the callback stack while submitPrefix invokes submitTXPacket. */
struct RTW88WCLTXSubmitContext {
    RTW88WCLSkywalkTxAdapter *adapter;
    RTW88WCLTXQueueContract::Route route;
};

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
    bzero(_registrationQueues, sizeof(_registrationQueues));
    _registered = false;
    _txAdapter = nullptr;
    _allocated = false;
    return true;
}

IOReturn RTW88WCLSkywalkQueues::createQueues()
{
    if (_allocated)
        return (_acquisitionJournal.isCommitted() && queuesAllocated())
                   ? kIOReturnSuccess : kIOReturnNotReady;
    if (_registered || _txAdapter || _txPool || _rxPool ||
        _txCompletion || _rxSubmission || _rxCompletion)
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

    /* 24H32's initWithPool symbol encodes this action as UInt32: the number
     * of packet pointers produced. The pinned generic SDK typedef labels the
     * function pointer IOReturn, so cast only at this target-specific boundary.
     * This callback returns zero (no callback packets); Stage92 uses the
     * synchronous enqueuePackets(packet-array) path from its own workloop. */
    using TxCompletionAction24H32 = UInt32 (*)(
        OSObject *, IOSkywalkTxCompletionQueue *, IOSkywalkPacket **,
        UInt32, void *);
    static_assert(sizeof(TxCompletionAction24H32) ==
                      sizeof(IOSkywalkTxCompletionQueueAction),
                  "24H32 TX completion callback pointer size mismatch");
    _txCompletion = IOSkywalkTxCompletionQueue::withPool(
        _txPool, kQueueCapacity, 0, this,
        reinterpret_cast<IOSkywalkTxCompletionQueueAction>(
            &RTW88WCLSkywalkQueues::txCompletionAction),
        this, 0);
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

    /* Owner-resident stable queue vector for the 24H32 registration ABI.
     * QueueSet classifies queues using performCommand(0x10000), not pointer
     * array position. */
    for (UInt32 i = 0; i < kTXSubmissionQueueCount; ++i)
        _registrationQueues[i] = _txSubmissionQueues[i];
    _registrationQueues[4] = _txCompletion;
    _registrationQueues[5] = _rxSubmission;
    _registrationQueues[6] = _rxCompletion;

    if (!txSubmissionQueuesValid() || !registrationQueuesValid() ||
        !_acquisitionJournal.commit())
        goto no_memory;

    _allocated = true;
    IOLog("rtl88wifi-wcl: allocated and ABI-validated seven TX/RX registration queues\n");
    return kIOReturnSuccess;

no_memory:
    destroyQueues();
    return kIOReturnNoMemory;
}

void RTW88WCLSkywalkQueues::destroyQueues()
{
    /* Registered QueueSets own queue scheduling and packet lifetime. The
     * interface must deregister before queue/pool callback context is freed. */
    if (_registered) {
        IOLog("rtl88wifi-wcl: Skywalk queues still registered; rollback deferred\n");
        return;
    }

    /* The adapter owns the TX pool and is retained as callback context by
     * this owner. Detach it only after admission is closed and its tickets are
     * drained; never roll back queue/pool resources underneath a live adapter. */
    if (_txAdapter || !_txCallbackGate.isUnbound()) {
        IOLog("rtl88wifi-wcl: TX adapter/callback gate still attached; queue rollback deferred\n");
        return;
    }

    if (_acquisitionJournal.isEmpty()) {
        if (hasOutstandingResources())
            IOLog("rtl88wifi-wcl: empty acquisition journal still has live queue/pool pointers; retaining owner\n");
        else {
            bzero(_registrationQueues, sizeof(_registrationQueues));
            _allocated = false;
        }
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
    bzero(_registrationQueues, sizeof(_registrationQueues));
    _registered = false;
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
            _registrationQueues[6] = nullptr;
        } else {
            IOLog("rtl88wifi-wcl: rollback journal expected RX completion queue\n");
        }
        break;
    case Resource::kRXSubmission:
        if (_rxSubmission) {
            _rxSubmission->release();
            _rxSubmission = nullptr;
            _registrationQueues[5] = nullptr;
        } else {
            IOLog("rtl88wifi-wcl: rollback journal expected RX submission queue\n");
        }
        break;
    case Resource::kTXCompletion:
        if (_txCompletion) {
            _txCompletion->release();
            _txCompletion = nullptr;
            _registrationQueues[4] = nullptr;
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
            _registrationQueues[index] = nullptr;
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
    if (_registered || _txPool || _rxPool || _txCompletion || _rxSubmission ||
        _rxCompletion || _txAdapter || !_txCallbackGate.isUnbound())
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

bool RTW88WCLSkywalkQueues::registrationQueuesValid() const
{
    if (!_txPool || !_rxPool || !txSubmissionQueuesValid() ||
        !_txCompletion || !_rxSubmission || !_rxCompletion)
        return false;

    struct alignas(8) QueueDescriptor24H32 {
        UInt32 type;
        UInt32 capacity;
        IOSkywalkPacketBufferPool *pool;
    };
    static_assert(sizeof(QueueDescriptor24H32) == 0x10,
                  "24H32 QueueSet descriptor must be 16 bytes");

    const UInt32 expectedTypes[kRegistrationQueueCount] = {
        1, 1, 1, 1, 2, 3, 4
    };
    for (UInt32 i = 0; i < kRegistrationQueueCount; ++i) {
        IOSkywalkPacketQueue *queue = _registrationQueues[i];
        if (!queue)
            return false;
        QueueDescriptor24H32 descriptor = {};
        const IOReturn status =
            queue->performCommand(0x10000, &descriptor, sizeof(descriptor));
        if (status != kIOReturnSuccess ||
            descriptor.type != expectedTypes[i])
            return false;
        IOSkywalkPacketBufferPool *expectedPool =
            (i < kTXSubmissionQueueCount || i == 4) ? _txPool : _rxPool;
        if (descriptor.pool != expectedPool)
            return false;
        if ((descriptor.type == 1 || descriptor.type == 4) &&
            descriptor.capacity != queue->getCapacity())
            return false;
        if ((descriptor.type == 2 || descriptor.type == 3) &&
            descriptor.capacity != 0)
            return false;
    }
    return true;
}

IOReturn RTW88WCLSkywalkQueues::setRegistered(bool registered)
{
    if (registered == _registered)
        return registered ? kIOReturnBusy : kIOReturnSuccess;
    if (registered) {
        if (!queuesAllocated() || !registrationQueuesValid())
            return kIOReturnNotReady;
        _registered = true;
        return kIOReturnSuccess;
    }
    _registered = false;
    return kIOReturnSuccess;
}

IOReturn RTW88WCLSkywalkQueues::enqueueRXPacketForNetworking(
    IOSkywalkPacket *packet)
{
    if (!packet)
        return kIOReturnBadArgument;
    if (!_registered || !_rxCompletion || !_rxPool ||
        packet->getPacketBufferPool() != _rxPool)
        return kIOReturnNotReady;

    const IOSkywalkPacket *packets[1] = { packet };
    /* The 24H32 networking enqueue helper is the queue-to-stack handoff.
     * Caller retains packet ownership unless the helper reports success. */
    return _rxCompletion->enqueuePacketsForNetworking(packets, 1, 0);
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

bool RTW88WCLSkywalkQueues::resourcesReleased() const
{
    return !_allocated && _acquisitionJournal.isEmpty() &&
           !hasOutstandingResources();
}

IOReturn RTW88WCLSkywalkQueues::bindTXAdapter(
    RTW88WCLSkywalkTxAdapter *adapter)
{
    if (!adapter)
        return kIOReturnBadArgument;
    if (!queuesAllocated())
        return kIOReturnNotReady;
    if (_txAdapter)
        return kIOReturnBusy;
    if (!adapter->isBoundToPool(_txPool))
        return kIOReturnBusy;
    if (!_txCallbackGate.beginBind())
        return kIOReturnBusy;

    adapter->retain();
    _txAdapter = adapter;
    if (!_txCallbackGate.finishBind()) {
        _txAdapter = nullptr;
        adapter->release();
        _txCallbackGate.abortBind();
        return kIOReturnBusy;
    }
    return kIOReturnSuccess;
}

IOReturn RTW88WCLSkywalkQueues::unbindTXAdapter(
    RTW88WCLSkywalkTxAdapter *adapter)
{
    if (!adapter || _txAdapter != adapter)
        return kIOReturnBadArgument;
    if (!_txCallbackGate.beginUnbind() ||
        !_txCallbackGate.canFinishUnbind())
        return kIOReturnBusy;
    if (!adapter->isUnbound() || adapter->hasOutstandingCompletions())
        return kIOReturnBusy;

    _txAdapter = nullptr;
    if (!_txCallbackGate.finishUnbind()) {
        _txAdapter = adapter;
        return kIOReturnBusy;
    }
    adapter->release();
    return kIOReturnSuccess;
}

/*
 * The Sequoia 15.8.1 / 24H32 x86_64 withPool symbol encodes the TX action as
 * UInt32 (OSObject *, queue *, IOSkywalkPacket * const *, UInt32, void *).
 * This differs from the generic SDK typedef and the earlier Stage72 source
 * stub's IOReturn return. The target ABI's UInt32 is the accepted packet count.
 */
int RTW88WCLSkywalkQueues::submitTXPacket(void *context, void *rawPacket)
{
    auto *submission = static_cast<RTW88WCLTXSubmitContext *>(context);
    auto *packet = static_cast<IOSkywalkPacket *>(rawPacket);
    return submission && submission->adapter && packet
               ? static_cast<int>(submission->adapter->submitPacket(
                     packet, submission->route.accessCategory,
                     submission->route.tid))
               : static_cast<int>(kIOReturnNotReady);
}

UInt32 RTW88WCLSkywalkQueues::txSubmissionAction(
    OSObject *owner, IOSkywalkTxSubmissionQueue *queue,
    IOSkywalkPacket * const *packets, UInt32 packetCount, void *refCon)
{
    auto *self = OSDynamicCast(RTW88WCLSkywalkQueues, owner);
    if (!self || refCon != self ||
        !self->_txCallbackGate.enterSubmission())
        return static_cast<UInt32>(0);

    /* Enter the owner gate before reading _txAdapter or queue pointers. The
     * matching unbind closes this gate and waits for this entire callback,
     * preventing teardown from detaching the adapter between pointer-load and
     * the adapter's own submission-gate entry.
     */
    UInt32 accepted = 0;
    if (self->ownsTXSubmissionQueue(queue) && self->queuesAllocated() &&
        self->_txAdapter && packets && packetCount != 0) {
        RTW88WCLTXSubmitContext submission = {};
        submission.adapter = self->_txAdapter;
        const UInt32 serviceClass = static_cast<UInt32>(queue->getServiceClass());
        if (RTW88WCLTXQueueContract::routeForServiceClass(
                serviceClass, &submission.route)) {
            /* Preserve the calling queue's exact WMM class all the way into
             * RTW88's AC ring and 802.11 QoS TID. Accept only a bounded
             * contiguous prefix; the first rejected packet and suffix remain
             * Skywalk-owned. No completion or queue mutation occurs here.
             */
            accepted = RTW88WCLTxSubmissionBatch::submitPrefix<IOSkywalkPacket>(
                packets, packetCount, &RTW88WCLSkywalkQueues::submitTXPacket,
                &submission);
        }
    }
    self->_txCallbackGate.leaveSubmission();
    return accepted;
}

UInt32 RTW88WCLSkywalkQueues::txCompletionAction(
    OSObject *owner, IOSkywalkTxCompletionQueue *queue,
    IOSkywalkPacket **packets, UInt32 packetCount, void *refCon)
{
    (void)owner; (void)queue; (void)packets; (void)packetCount; (void)refCon;
    /* A 24H32 action result is a packet count, never an IOReturn status. */
    return 0;
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
