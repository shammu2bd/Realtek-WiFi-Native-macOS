/* SPDX-License-Identifier: GPL-2.0-only
 * Skywalk -> mbuf -> RTW88 TX adapter, isolated until queue registration.
 */
#pragma once

#include <IOKit/skywalk/IOSkywalkPacket.h>
#include <IOKit/skywalk/IOSkywalkPacketBufferPool.h>
#include <libkern/c++/OSObject.h>
#include <sys/mbuf.h>

#include "RTW88WCLTxCompletionSlots.hpp"

class RTW88IEEE80211;

class RTW88WCLSkywalkTxAdapter final : public OSObject {
    OSDeclareDefaultStructors(RTW88WCLSkywalkTxAdapter)

public:
    using CompletionSink = void (*)(IOSkywalkPacket *packet,
                                    bool transmitted,
                                    void *context);

    static constexpr uint32_t kCompletionCapacity = 128;

    bool init() override;
    IOReturn bind(RTW88IEEE80211 *radio,
                  IOSkywalkPacketBufferPool *txPool);
    IOReturn unbind();

    /* Copies a validated, single-buffer Skywalk Ethernet frame to an mbuf,
     * then submits it to RTW88 with a bounded completion ticket. Ownership of
     * the Skywalk packet stays with this adapter until drainCompletions(). */
    IOReturn submitPacket(IOSkywalkPacket *packet);

    /* Must be called later from a serialized/deferred context. The sink may
     * enqueue the packet to Skywalk's TX-completion queue once that queue's
     * ABI and lifecycle have been validated. The adapter releases its packet
     * retain after the sink returns. */
    uint32_t drainCompletions(CompletionSink sink, void *context);

    bool hasOutstandingCompletions() const;
    uint32_t outstandingCompletionCount() const;
    void free() override;

private:
    using TicketPool = RTW88WCLTxCompletionSlots<kCompletionCapacity>;

    static void backendCompletion(void *context, void *cookie,
                                  bool transmitted);
    static mbuf_t copyPacketToMbuf(const uint8_t *bytes, uint32_t length);

    RTW88IEEE80211 *_radio = nullptr; // retained while bound
    IOSkywalkPacketBufferPool *_txPool = nullptr; // retained while bound
    TicketPool _tickets;
};
