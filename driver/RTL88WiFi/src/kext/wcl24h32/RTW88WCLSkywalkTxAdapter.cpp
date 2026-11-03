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
    if (_radio || _txPool || _tickets.hasOutstanding())
        return kIOReturnBusy;

    radio->retain();
    txPool->retain();
    _radio = radio;
    _txPool = txPool;
    return kIOReturnSuccess;
}

IOReturn RTW88WCLSkywalkTxAdapter::unbind()
{
    if (_tickets.hasOutstanding())
        return kIOReturnBusy;

    RTW88IEEE80211 *radio = _radio;
    IOSkywalkPacketBufferPool *pool = _txPool;
    _radio = nullptr;
    _txPool = nullptr;
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

IOReturn RTW88WCLSkywalkTxAdapter::submitPacket(IOSkywalkPacket *packet)
{
    if (!packet)
        return kIOReturnBadArgument;
    if (!_radio || !_txPool)
        return kIOReturnNotReady;

    RTW88WCLPacketView view = {};
    if (!RTW88WCLResolveEthernetTxPacket(packet, _txPool, &view))
        return kIOReturnBadArgument;

    mbuf_t mbuf = copyPacketToMbuf(view.bytes, view.length);
    if (!mbuf)
        return kIOReturnNoMemory;

    packet->retain();
    TicketPool::Ticket *ticket = _tickets.reserve(packet);
    if (!ticket) {
        packet->release();
        mbuf_freem(mbuf);
        return kIOReturnBusy;
    }

    /* Keep the adapter alive until the workloop-side completion drain drops
     * this ticket. backendCompletion() intentionally does not release it. */
    retain();
    const UInt32 backendResult = _radio->outputPacketWithCompletion(
        mbuf, &RTW88WCLSkywalkTxAdapter::backendCompletion, this, ticket);

    /* outputPacketWithCompletion consumes the mbuf and reports exactly one
     * terminal callback, including synchronous drops. Once the ticket has
     * been reserved, adapter acceptance is successful; the actual transmitted
     * vs dropped result is delivered later through the completion sink. */
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
         * It must finish any Skywalk queue handoff before returning. */
        if (packet)
            sink(packet, transmitted, context);

        TicketPool::finish(ticket);
        if (packet)
            packet->release();
        release();
        ++drained;
    }
    release();
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
    /* A per-ticket retain prevents free() while hardware callbacks are still
     * pending. The owning controller must drain every completion before its
     * final reference is released. */
    if (_tickets.hasOutstanding())
        IOLog("rtl88wifi-wcl: TX adapter free attempted with outstanding tickets\n");
    unbind();
    super::free();
}
