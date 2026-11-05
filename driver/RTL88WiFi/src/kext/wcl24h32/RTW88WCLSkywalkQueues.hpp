/* SPDX-License-Identifier: GPL-2.0-only
 * Sequoia Skywalk queue/pool resource owner.
 *
 * This owner acquires native queue objects and packet pools but does not
 * register them with IOSkywalkEthernetInterface. Four WMM TX submission
 * queues are held in a stable owner-resident array. Stage91 binds a retained
 * TX adapter to their action callback; completion and registration remain
 * fenced for later stages.
 */
#pragma once

#include <IOKit/skywalk/IOSkywalkPacketBufferPool.h>
#include <IOKit/skywalk/IOSkywalkTxSubmissionQueue.h>
#include <IOKit/skywalk/IOSkywalkTxCompletionQueue.h>
#include <IOKit/skywalk/IOSkywalkRxSubmissionQueue.h>
#include <IOKit/skywalk/IOSkywalkRxCompletionQueue.h>
#include <libkern/c++/OSObject.h>

#include "RTW88WCLAcquisitionJournal.hpp"

class RTW88WCLSkywalkTxAdapter;

class RTW88WCLSkywalkQueues final : public OSObject {
    OSDeclareDefaultStructors(RTW88WCLSkywalkQueues)

public:
    bool init() override;
    IOReturn createQueues();
    void destroyQueues();
    bool queuesAllocated() const;
    bool txSubmissionQueuesValid() const;

    IOReturn bindTXAdapter(RTW88WCLSkywalkTxAdapter *adapter);
    IOReturn unbindTXAdapter(RTW88WCLSkywalkTxAdapter *adapter);

    IOSkywalkTxSubmissionQueue * const *txSubmissionQueues() const {
        return _txSubmissionQueues;
    }
    void free() override;

    static constexpr UInt32 kQueueCapacity = 128;
    static constexpr UInt32 kTXSubmissionQueueCount = 4;
    static constexpr UInt32 kTxBufferSize = 2048;
    static constexpr UInt32 kRxBufferSize = 4096;

    /* Borrowed accessors. Bound adapters retain their pool dependencies. */
    IOSkywalkPacketBufferPool *txPacketPool() const { return _txPool; }
    IOSkywalkPacketBufferPool *rxPacketPool() const { return _rxPool; }

private:
    void releaseAcquiredResource(RTW88WCLAcquisitionJournal::Resource resource);
    bool hasOutstandingResources() const;
    bool ownsTXSubmissionQueue(const IOSkywalkTxSubmissionQueue *queue) const;
    static int submitTXPacket(void *context, void *packet);

    static UInt32 txSubmissionAction(OSObject *owner,
                                     IOSkywalkTxSubmissionQueue *queue,
                                     IOSkywalkPacket * const *packets,
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
    RTW88WCLTxAdapter *_txAdapter = nullptr; // retained; action callback context
    RTW88WCLAcquisitionJournal::Journal _acquisitionJournal;
    bool _allocated = false;
};
