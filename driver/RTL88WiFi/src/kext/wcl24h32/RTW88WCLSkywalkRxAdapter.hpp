/* SPDX-License-Identifier: GPL-2.0-only
 * Bounded RTW88 mbuf staging and native Skywalk RX packet construction.
 */
#pragma once

#include <IOKit/IOEventSource.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/skywalk/IOSkywalkPacket.h>
#include <IOKit/skywalk/IOSkywalkPacketBufferPool.h>
#include <libkern/c++/OSObject.h>
#include <sys/mbuf.h>

#include "RTW88WCLMbufRing.hpp"

class RTW88WCLSkywalkRxAdapter final : public IOEventSource {
    OSDeclareDefaultStructors(RTW88WCLSkywalkRxAdapter)

public:
    /* true transfers the prepared packet to the sink; false returns it to RX pool. */
    using FrameSink = bool (*)(IOSkywalkPacket *preparedPacket, void *context);
    static constexpr uint32_t kCapacity = 128;
    static constexpr uint32_t kDrainBudget = 32;
    static constexpr uint32_t kMinimumFrameLength = 14;
    static constexpr uint32_t kMaximumFrameLength = 4096;

    bool init(OSObject *owner, IOWorkLoop *workLoop,
              IOSkywalkPacketBufferPool *rxPool,
              FrameSink sink, void *context);

    /* Consumes mbuf ownership on every return path. The producer path performs
     * only bounded validation/enqueue and a workloop signal. */
    IOReturn enqueueFrame(mbuf_t packet);

    /* Removes the event source, drains queued mbufs, then releases the retained pool. */
    void stop();
    void free() override;

    bool checkForWork() override;
    uint32_t droppedFrames() const;
    uint32_t preparedFrames() const;
    uint32_t queuedFrames() const;
    bool isRegistered() const { return _registered; }

private:
    static bool isValidMbuf(mbuf_t packet);
    static bool copyMbufToSkywalkPacket(IOSkywalkPacketBufferPool *pool,
                                        mbuf_t source,
                                        IOSkywalkPacket **outPacket);

    RTW88WCLMbufRing<mbuf_t, kCapacity> _frames;
    IOWorkLoop *_workLoop = nullptr; // non-owning; controller owns workloop
    IOSkywalkPacketBufferPool *_rxPool = nullptr; // retained
    FrameSink _sink = nullptr;       // non-owning; invoked on workloop
    void *_sinkContext = nullptr;
    volatile uint32_t _pendingSignal = 0;
    volatile uint32_t _stopping = 0;
    volatile uint32_t _dropped = 0;
    volatile uint32_t _prepared = 0;
    bool _registered = false;        // workloop lifecycle-owned
};
