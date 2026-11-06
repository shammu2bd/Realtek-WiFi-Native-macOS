/* SPDX-License-Identifier: GPL-2.0-only
 * Sequoia 24H32 Skywalk Ethernet TX packet conversion and completion bridge.
 */
#include "RTW88WCLSkywalkTxAdapter.hpp"
#include "RTW88WCLPacketView.hpp"
#include "../RTW88IEEE80211.hpp"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSMetaClass.h>
#include <sys/kpi_mbuf.h>

extern "C" {
#include "../../compat/linux/slab.h"
#include "../../compat/linux/skbuff_tx_completion.h"
}

#define super OSObject
OSDefineMetaClassAndStructors(RTW88WCLSkywalkTxAdapter, OSObject)

bool RTW88WCLSkywalkTxAdapter::init()
{
    if (!super::init())
        return false;
    _radio = nullptr;
    _txPool = nullptr;
    _tickets.reset();
    rtw88_mpsc_bounded_queue_init(&_retiredCompletionTokens);
    _backendCompletionCallbacksInFlight = 0;
    _retiredCompletionTokenCount = 0;
    _retiredCompletionTokenRejectedCount = 0;
    _completionNotifier = nullptr;
    _completionNotifierContext = nullptr;
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

    /* The Stage92 workloop worker returns completed packets through the
     * target Skywalk TX-completion queue. Keep the radio, pool, adapter and
     * queue-owner references until all tickets are free and every backend
     * completion callback has returned from its notifier thunk. */
    if (_tickets.hasOutstanding() ||
        __atomic_load_n(&_backendCompletionCallbacksInFlight, __ATOMIC_ACQUIRE) != 0 ||
        hasRetiredCompletionTokens())
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

    /* The accepted ticket's per-ticket retain keeps self alive on callback
     * entry. This separate entrant count prevents a concurrently signaled
     * worker from draining that ticket and allowing teardown to remove the
     * worker while this callback is still executing its notifier thunk. */
    __atomic_add_fetch(&self->_backendCompletionCallbacksInFlight, 1U,
                       __ATOMIC_ACQ_REL);

    /* No Skywalk API, OSObject release, allocation, or blocking operation is
     * allowed here. Publish the ticket, then signal the already-attached
     * workloop event source through its IRQ-safe notifier. */
    /* Always wake the reaper after token publication, even if the ticket
     * state transition fails. A bad ticket remains outstanding/fail-closed,
     * but must not strand a separately retired token on an unsignaled list. */
    const bool ticketCompleted = TicketPool::complete(ticket, transmitted);
    (void)ticketCompleted;
    CompletionNotify notify = self->_completionNotifier;
    void *notifyContext = self->_completionNotifierContext;
    if (notify)
        notify(notifyContext);

    __atomic_sub_fetch(&self->_backendCompletionCallbacksInFlight, 1U,
                       __ATOMIC_ACQ_REL);
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
                IOLog("rtl88wifi-wcl: completion ticket retry transition failed; retaining ownership\n");
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

uint32_t RTW88WCLSkywalkTxAdapter::readyCompletionCount() const
{
    return _tickets.completedCount();
}

void RTW88WCLSkywalkTxAdapter::retireCompletionToken(
    struct rtw88_skb_tx_completion_token *token)
{
    if (!token)
        return;

    /* Count before publication. Queue-full is fail-closed: keep the count
     * elevated and quarantine the token rather than freeing it in callback
     * context or allowing teardown to release its callback owner.
     */
    __atomic_add_fetch(&_retiredCompletionTokenCount, 1U, __ATOMIC_ACQ_REL);
    if (!rtw88_mpsc_bounded_queue_enqueue(&_retiredCompletionTokens, token))
        __atomic_add_fetch(&_retiredCompletionTokenRejectedCount, 1U,
                           __ATOMIC_RELAXED);
}

void RTW88WCLSkywalkTxAdapter::reapDeferredCompletionTokens()
{
    /* Single consumer: the worker thread call, or passive teardown only after
     * that call has been joined. */
    struct rtw88_skb_tx_completion_token *token;
    while ((token = static_cast<struct rtw88_skb_tx_completion_token *>(
                rtw88_mpsc_bounded_queue_dequeue(&_retiredCompletionTokens))) != nullptr) {
        kfree(token);
        __atomic_sub_fetch(&_retiredCompletionTokenCount, 1U, __ATOMIC_RELEASE);
    }
}

bool RTW88WCLSkywalkTxAdapter::hasReapableCompletionTokens() const
{
    return !rtw88_mpsc_bounded_queue_empty(&_retiredCompletionTokens);
}

bool RTW88WCLSkywalkTxAdapter::hasRetiredCompletionTokens() const
{
    return __atomic_load_n(&_retiredCompletionTokenCount, __ATOMIC_ACQUIRE) != 0 ||
           !rtw88_mpsc_bounded_queue_empty(&_retiredCompletionTokens);
}

bool RTW88WCLSkywalkTxAdapter::hasBackendCompletionCallbacksInFlight() const
{
    return __atomic_load_n(&_backendCompletionCallbacksInFlight,
                           __ATOMIC_ACQUIRE) != 0;
}

extern "C" void rtw88_wcl_defer_skb_tx_completion_token(
    void *context, void *token)
{
    auto *adapter = static_cast<RTW88WCLSkywalkTxAdapter *>(context);
    if (adapter && token) {
        adapter->retireCompletionToken(
            static_cast<struct rtw88_skb_tx_completion_token *>(token));
    }
}

IOReturn RTW88WCLSkywalkTxAdapter::setCompletionNotifier(
    CompletionNotify notify, void *context)
{
    if (!notify || !context)
        return kIOReturnBadArgument;
    if (!_submissionGate.isBound())
        return kIOReturnNotReady;
    if (_completionNotifier || _completionNotifierContext)
        return kIOReturnBusy;

    /* Installed before TX can be enabled and removed only after radio stop
     * plus an empty ticket table, so these non-owning fields are not rewritten
     * while a backend completion callback can read them. */
    _completionNotifierContext = context;
    _completionNotifier = notify;
    return kIOReturnSuccess;
}

void RTW88WCLSkywalkTxAdapter::clearCompletionNotifier(void *context)
{
    if (context && _completionNotifierContext == context) {
        _completionNotifier = nullptr;
        _completionNotifierContext = nullptr;
    }
}

void RTW88WCLSkywalkTxAdapter::free()
{
    const IOReturn status = unbind();
    if (status != kIOReturnSuccess || !_submissionGate.isUnbound() ||
        _tickets.hasOutstanding() || hasRetiredCompletionTokens()) {
        IOLog("rtl88wifi-wcl: TX adapter free deferred; submission or completion ownership remains\n");
        /* Retained callbacks/tickets may still reference this adapter and its
         * radio/pool. Quarantine it instead of destroying live callback state. */
        return;
    }
    super::free();
}
