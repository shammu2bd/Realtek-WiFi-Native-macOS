/* SPDX-License-Identifier: GPL-2.0-only
 * Sequoia 24H32 Skywalk Ethernet TX packet conversion and completion bridge.
 */
#include "RTW88WCLSkywalkTxAdapter.hpp"
#include "RTW88WCLPacketView.hpp"
#include "../RTW88IEEE80211.hpp"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSMetaClass.h>
#include <sys/kpi_mbuf.h>

#define super OSObject
OSDefineMetaClassAndStructors(RTW88WCLSkywalkTxAdapter, OSObject)

bool RTW88WCLSkywalkTxAdapter::init()
{
    if (!super::init())
        return false;
    _radio = nullptr;
    _txPool = nullptr;
    _tickets.reset();
    return true;
}

IOReturn RTW88WCLSkywalkTxAdapter::bind(
    RTW88IEEE80211 *radio, IOSkywalkPacketBufferPool *txPool)
{
    if (!radio || !txPool)
        return kIOReturnBadArgument;
    if (!_submissionGate.beginBind())
        return kIOReturnBusy;
    if (_tickets.hasOutstanding()) {
        _submissionGate.abortBind();
        return kIOReturnBusy;
    }

    radio->retain();
    txPool->retain();
    _radio = radio;
    _txPool = txPool;
    if (!_submissionGate.finishBind()) {
        _radio = nullptr;
        _txPool = nullptr;
        txPool->release();
        radio->release();
        _submissionGate.abortBind();
        return kIOReturnBusy;
    }
    return kIOReturnSuccess;
}

IOReturn RTW88WCLSkywalkTxAdapter::quiesceSubmissions()
{
    /* An already-unbound adapter is a valid partial-construction cleanup
     * state. Otherwise close admission and wait for the callback's bounded
     * copy/ticket reservation section to leave before radio teardown starts.
     */
    if (_submissionGate.isUnbound())
        return kIOReturnSuccess;
    if (!_submissionGate.beginUnbind())
        return kIOReturnBusy;
    return _submissionGate.canFinishUnbind()
               ? kIOReturnSuccess : kIOReturnBusy;
}

IOReturn RTW88WCLSkywalkTxAdapter::unbind()
{
    const IOReturn quiesceStatus = quiesceSubmissions();
    if (quiesceStatus != kIOReturnSuccess)
        return quiesceStatus;

    /* A later stage drains completed tickets through the Skywalk completion
     * queue. Until every retained packet has a terminal handoff, preserve the
     * radio, pool, adapter and queue-owner references. */
    if (_tickets.hasOutstanding())
        return kIOReturnBusy;

    if (_submissionGate.isUnbound()) {
        return (!_radio && !_txPool) ? kIOReturnSuccess : kIOReturnBusy;
    }

    RTW88IEEE80211 *radio = _radio;
    IOSkywalkPacketBufferPool *pool = _txPool;
    _radio = nullptr;
    _txPool = nullptr;
    if (!_submissionGate.finishUnbind()) {
        /* A failed finish is an invariant violation. Restore the references
         * and retain the quiescing state rather than losing their owners. */
        _radio = radio;
        _txPool = pool;
        return kIOReturnBusy;
    }

    if (pool)
        pool->release();
    if (radio)
        radio->release();
    return kIOReturnSuccess;
}

mbuf_t RTW88WCLSkywalkTxAdapter::copyPacketToMbuf(
    const uint8_t *bytes, uint32_t length)
{
    if (!bytes || length < 14 || length > 2048)
        return nullptr;

    mbuf_t mbuf = nullptr;
    if (mbuf_allocpacket(MBUF_DONTWAIT, length, nullptr, &mbuf) != 0 || !mbuf)
        return nullptr;

    /* allocpacket may return a chain; copyback handles every segment. Keep
     * the copy non-blocking because this runs in a Skywalk queue callback. */
    if (mbuf_copyback(mbuf, 0, length, bytes, MBUF_DONTWAIT) != 0) {
        mbuf_freem(mbuf);
        return nullptr;
    }
    mbuf_pkthdr_setlen(mbuf, length);
    return mbuf;
}

IOReturn RTW88WCLSkywalkTxAdapter::submitPacket(
    IOSkywalkPacket *packet, uint8_t accessCategory, uint8_t tid)
{
    if (!packet)
        return kIOReturnBadArgument;
    if (!_submissionGate.enterSubmission())
        return kIOReturnNotReady;

    /* The call-level retain covers every non-ticket exit and prevents a
     * concurrent owner release from destroying this adapter mid-copy. */
    retain();
    const IOReturn result = submitPacketEntered(packet, accessCategory, tid);
    _submissionGate.leaveSubmission();
    release();
    return result;
}

IOReturn RTW88WCLSkywalkTxAdapter::submitPacketEntered(
    IOSkywalkPacket *packet, uint8_t accessCategory, uint8_t tid)
{
    if (!_radio || !_txPool)
        return kIOReturnNotReady;

    RTW88WCLPacketView view = {};
    if (!RTW88WCLResolveEthernetTxPacket(packet, _txPool, &view))
        return kIOReturnBadArgument;

    mbuf_t mbuf = copyPacketToMbuf(view.bytes, view.length);
    if (!mbuf)
        return kIOReturnNoMemory;

    /* The original Skywalk packet remains with Skywalk on every rejection.
     * Ownership crosses only after a retained packet has a completion ticket
     * and the RTW88 completion contract is invoked. */
    packet->retain();
    TicketPool::Ticket *ticket = _tickets.reserve(packet);
    if (!ticket) {
        packet->release();
        mbuf_freem(mbuf);
        return kIOReturnBusy;
    }

    /* Keep the adapter alive until the deferred completion drain drops this
     * ticket. backendCompletion() never releases OSObjects or calls Skywalk. */
    retain();
    const UInt32 backendResult = _radio->outputPacketWithCompletion(
        mbuf, &RTW88WCLSkywalkTxAdapter::backendCompletion, this, ticket,
        accessCategory, tid);

    /* outputPacketWithCompletion consumes the mbuf and invokes exactly one
     * terminal callback, including synchronous drops. A reserved ticket is
     * accepted even when RTW88 immediately reports a failed transmission;
     * Stage92 will return that terminal result through the completion queue.
     */
    (void)backendResult;
    return kIOReturnSuccess;
}

void RTW88WCLSkywalkTxAdapter::backendCompletion(
    void *context, void *cookie, bool transmitted)
{
    auto *self = static_cast<RTW88WCLSkywalkTxAdapter *>(context);
    auto *ticket = static_cast<TicketPool::Ticket *>(cookie);
    if (!self || !ticket)
        return;

    /* No Skywalk API, OSObject release, allocation, or blocking operation is
     * allowed here. A deferred consumer performs the completion handoff. */
    (void)TicketPool::complete(ticket, transmitted);
}

uint32_t RTW88WCLSkywalkTxAdapter::drainCompletions(
    CompletionSink sink, void *context)
{
    if (!sink)
        return 0;

    /* A sink may trigger owner teardown; keep this adapter alive until the
     * drain loop has stopped touching its ticket pool. */
    retain();
    uint32_t drained = 0;
    for (;;) {
        TicketPool::Ticket *ticket = _tickets.claimCompleted();
        if (!ticket)
            break;

        auto *packet = static_cast<IOSkywalkPacket *>(TicketPool::packet(ticket));
        const bool transmitted = TicketPool::transmitted(ticket);

        /* The sink runs in deferred context and borrows the retained packet.
         * true means the Skywalk completion queue accepted the handoff. On
         * false, restore the ticket to Completed and keep both packet and
         * per-ticket adapter retains so the caller can retry on a later pass.
         * Stop this drain pass to avoid spinning on the same failed ticket.
         */
        if (!packet || !sink(packet, transmitted, context)) {
            if (!TicketPool::retry(ticket))
                IOLog("rtl88wifi-wcl: completion ticket retry transition failed; retaining ownership\\n");
            break;
        }

        TicketPool::finish(ticket);
        packet->release();
        release(); // matching per-ticket adapter retain
        ++drained;
    }
    release(); // drain-loop retain
    return drained;
}

bool RTW88WCLSkywalkTxAdapter::hasOutstandingCompletions() const
{
    return _tickets.hasOutstanding();
}

uint32_t RTW88WCLSkywalkTxAdapter::outstandingCompletionCount() const
{
    return _tickets.outstandingCount();
}

void RTW88WCLSkywalkTxAdapter::free()
{
    const IOReturn status = unbind();
    if (status != kIOReturnSuccess || !_submissionGate.isUnbound() ||
        _tickets.hasOutstanding()) {
        IOLog("rtl88wifi-wcl: TX adapter free deferred; submission or completion ownership remains\n");
        /* Retained callbacks/tickets may still reference this adapter and its
         * radio/pool. Quarantine it instead of destroying live callback state. */
        return;
    }
    super::free();
}
