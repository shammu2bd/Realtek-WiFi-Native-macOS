/* SPDX-License-Identifier: GPL-2.0-only
 * Skywalk -> mbuf -> RTW88 TX adapter, isolated until queue registration.
 */
#pragma once

#include <IOKit/skywalk/IOSkywalkPacket.h>
#include <IOKit/skywalk/IOSkywalkPacketBufferPool.h>
#include <libkern/c++/OSObject.h>
#include <sys/mbuf.h>
#include <stdint.h>

#include "RTW88WCLTxCompletionSlots.hpp"
#include "RTW88WCLTxSubmissionGate.hpp"

class RTW88IEEE80211;

class RTW88WCLSkywalkTxAdapter final : public OSObject {
    OSDeclareDefaultStructors(RTW88WCLSkywalkTxAdapter)

public:
    /* Return true only after the packet was successfully accepted by the
     * Skywalk TX-completion handoff. False leaves the ticket and packet retain
     * outstanding so a later drain pass can retry safely. */
    using CompletionSink = bool (*)(IOSkywalkPacket *packet,
                                    bool transmitted,
                                    void *context);
    using CompletionNotify = void (*)(void *context);

    static constexpr uint32_t kCompletionCapacity = 128;

    bool init() override;
    IOReturn bind(RTW88IEEE80211 *radio,
                  IOSkywalkPacketBufferPool *txPool);
    IOReturn quiesceSubmissions();
    IOReturn unbind();
    bool isBound() const { return _submissionGate.isBound(); }
    bool isBoundToPool(const IOSkywalkPacketBufferPool *pool) const {
        return pool && _submissionGate.isBound() && _txPool == pool;
    }
    bool isUnbound() const { return _submissionGate.isUnbound(); }

    /* Validation/copy/ticket reservation all complete before success is
     * returned to the Skywalk action. On success the adapter retains packet
     * ownership until the deferred completion sink returns it in Stage92.
     * Rejected calls leave the packet with Skywalk. */
    IOReturn submitPacket(IOSkywalkPacket *packet,
                          uint8_t accessCategory, uint8_t tid);

    /* Must be called later from a serialized/deferred context. The sink may
     * enqueue the packet to Skywalk's TX-completion queue once that queue's
     * ABI and lifecycle have been validated. Return true only after the queue
     * accepted the packet and ownership transfer is complete. Return false
     * only if no handoff occurred; the adapter retains the packet and ticket
     * for a later retry. The adapter drops its retain only on true. */
    uint32_t drainCompletions(CompletionSink sink, void *context);

    bool hasOutstandingCompletions() const;
    uint32_t outstandingCompletionCount() const;
    uint32_t readyCompletionCount() const;
    IOReturn setCompletionNotifier(CompletionNotify notify, void *context);
    void clearCompletionNotifier(void *context);
    void free() override;

private:
    using TicketPool = RTW88WCLTxCompletionSlots<kCompletionCapacity>;

    static void backendCompletion(void *context, void *cookie,
                                  bool transmitted);
    static mbuf_t copyPacketToMbuf(const uint8_t *bytes, uint32_t length);
    IOReturn submitPacketEntered(IOSkywalkPacket *packet,
                                 uint8_t accessCategory, uint8_t tid);

    RTW88WCLTxSubmissionGate _submissionGate;
    RTW88IEEE80211 *_radio = nullptr; // retained while bound
    IOSkywalkPacketBufferPool *_txPool = nullptr; // retained while bound
    TicketPool _tickets;
    CompletionNotify _completionNotifier = nullptr; // non-owning, signal-only
    void *_completionNotifierContext = nullptr;     // non-owning; cleared after drain
};
