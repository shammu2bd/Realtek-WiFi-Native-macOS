/* SPDX-License-Identifier: GPL-2.0-only
 * Sequoia Skywalk queue/pool resource owner.
 *
 * This stage allocates the native queue objects and packet pools but does not
 * register them with IOSkywalkEthernetInterface. Queue callbacks intentionally
 * fail closed until packet layout, completion semantics and RX buffer refill
 * have been validated against the 24H32 runtime.
 */
#pragma once

#include <IOKit/skywalk/IOSkywalkPacketBufferPool.h>
#include <IOKit/skywalk/IOSkywalkTxSubmissionQueue.h>
#include <IOKit/skywalk/IOSkywalkTxCompletionQueue.h>
#include <IOKit/skywalk/IOSkywalkRxSubmissionQueue.h>
#include <IOKit/skywalk/IOSkywalkRxCompletionQueue.h>
#include <libkern/c++/OSObject.h>

class RTW88WCLSkywalkQueues final : public OSObject {
    OSDeclareDefaultStructors(RTW88WCLSkywalkQueues)

public:
    bool init() override;
    IOReturn createQueues();
    void destroyQueues();
    bool queuesAllocated() const;
    void free() override;

    static constexpr UInt32 kQueueCapacity = 128;
    static constexpr UInt32 kTxBufferSize = 2048;
    static constexpr UInt32 kRxBufferSize = 4096;

    /* Borrowed by the controller only long enough for the RX adapter to retain it. */
    IOSkywalkPacketBufferPool *rxPacketPool() const { return _rxPool; }

private:
    static IOReturn txSubmissionAction(OSObject *owner,
                                      IOSkywalkTxSubmissionQueue *queue,
                                      const IOSkywalkPacket **packets,
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
    IOSkywalkTxSubmissionQueue *_txSubmission = nullptr;
    IOSkywalkTxCompletionQueue *_txCompletion = nullptr;
    IOSkywalkRxSubmissionQueue *_rxSubmission = nullptr;
    IOSkywalkRxCompletionQueue *_rxCompletion = nullptr;
    bool _allocated = false;
};
