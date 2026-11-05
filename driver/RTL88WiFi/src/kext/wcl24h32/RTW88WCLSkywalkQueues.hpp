/* SPDX-License-Identifier: GPL-2.0-only
 * Sequoia Skywalk queue/pool resource owner.
 *
 * This stage allocates the native queue objects and packet pools but does not
 * register them with IOSkywalkEthernetInterface. TX submission consists of
 * four service-class-specific queues held in a stable, owner-resident array.
 * Queue callbacks intentionally fail closed until packet layout, completion
 * semantics and RX buffer refill have been validated against the 24H32 runtime.
 */
#pragma once

#include <IOKit/skywalk/IOSkywalkPacketBufferPool.h>
#include <IOKit/skywalk/IOSkywalkTxSubmissionQueue.h>
#include <IOKit/skywalk/IOSkywalkTxCompletionQueue.h>
#include <IOKit/skywalk/IOSkywalkRxSubmissionQueue.h>
#include <IOKit/skywalk/IOSkywalkRxCompletionQueue.h>
#include <libkern/c++/OSObject.h>

#include "RTW88WCLAcquisitionJournal.hpp"

class RTW88WCLSkywalkQueues final : public OSObject {
    OSDeclareDefaultStructors(RTW88WCLSkywalkQueues)

public:
    bool init() override;
    IOReturn createQueues();
    void destroyQueues();
    bool queuesAllocated() const;
    bool txSubmissionQueuesValid() const;
    IOSkywalkTxSubmissionQueue * const *txSubmissionQueues() const {
        return _txSubmissionQueues;
    }
    void free() override;

    static constexpr UInt32 kQueueCapacity = 128;
    static constexpr UInt32 kTXSubmissionQueueCount = 4;
    static constexpr UInt32 kTxBufferSize = 2048;
    static constexpr UInt32 kRxBufferSize = 4096;

    /* Borrowed by the controller only long enough for the RX adapter to retain it. */
    IOSkywalkPacketBufferPool *rxPacketPool() const { return _rxPool; }

private:
    void releaseAcquiredResource(RTW88WCLAcquisitionJournal::Resource resource);
    bool hasOutstandingResources() const;
    bool ownsTXSubmissionQueue(const IOSkywalkTxSubmissionQueue *queue) const;

    static UInt32 txSubmissionAction(OSObject *owner,
                                     IOSkywalkTxSubmissionQueue *queue,
                                     IOSkywalkPacket **packets,
                                     UInt32 packetCount, void *refCon);
    static IOReturn txCompletionAction(OSObject *owner,
                                       IOSkywalkTxCompletionQueue *queue,
                                       IOSkywalkPacket **packets,
                                       UInt32 packetCount, void *refCon);
    static IOReturn rxSubmissionAction(OSObject *owner,
                                      IOSkywalkRxSubmissionQueue *queue,
                                      const IOSkywalkPacket **packets,
                                      UInt32 packetCount, void *refCon);
    static IOReturn rxCompletionAction(OSObject *owner,
                                       IOSkywalkRxCompletionQueue *queue,
                                       IOSkywalkPacket **packets,
                                       UInt32 packetCount, void *refCon);

    IOSkywalkPacketBufferPool *_txPool = nullptr;
    IOSkywalkPacketBufferPool *_rxPool = nullptr;
    IOSkywalkTxSubmissionQueue *_txSubmissionQueues[kTXSubmissionQueueCount] = {};
    IOSkywalkTxCompletionQueue *_txCompletion = nullptr;
    IOSkywalkRxSubmissionQueue *_rxSubmission = nullptr;
    IOSkywalkRxCompletionQueue *_rxCompletion = nullptr;
    RTW88WCLAcquisitionJournal::Journal _acquisitionJournal;
    bool _allocated = false;
};
