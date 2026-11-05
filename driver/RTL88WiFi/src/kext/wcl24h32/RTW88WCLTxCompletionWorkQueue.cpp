/* SPDX-License-Identifier: GPL-2.0-only
 * Sequoia 24H32 synchronous TX completion handoff on the controller workloop.
 */
#include "RTW88WCLTxCompletionWorkQueue.hpp"
#include "RTW88WCLSkywalkTxAdapter.hpp"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSMetaClass.h>

#define super IOEventSource
OSDefineMetaClassAndStructors(RTW88WCLTxCompletionWorkQueue, IOEventSource)

bool RTW88WCLTxCompletionWorkQueue::init(
    OSObject *owner, IOWorkLoop *workLoop,
    RTW88WCLSkywalkTxAdapter *adapter,
    IOSkywalkTxCompletionQueue *completionQueue)
{
    if (!owner || !workLoop || !adapter || !completionQueue)
        return false;
    if (!super::init(owner, nullptr))
        return false;

    _workLoop = workLoop;
    _adapter = adapter;
    _completionQueue = completionQueue;
    _adapter->retain();
    _completionQueue->retain();
    _stopping = 1;

    _retryTimer = IOTimerEventSource::timerEventSource(
        this, &RTW88WCLTxCompletionWorkQueue::retryTimerFired);
    if (!_retryTimer)
        goto fail;

    if (_workLoop->addEventSource(this) != kIOReturnSuccess)
        goto fail;
    _eventSourceRegistered = true;

    if (_workLoop->addEventSource(_retryTimer) != kIOReturnSuccess)
        goto fail;
    _timerRegistered = true;

    __atomic_store_n(&_stopping, 0U, __ATOMIC_RELEASE);
    if (_adapter->setCompletionNotifier(
            &RTW88WCLTxCompletionWorkQueue::completionNotifier,
            this) != kIOReturnSuccess)
        goto fail;

    /* Cover a terminal callback that raced setup before the notifier was
     * installed. No packet can be submitted until queue activation, but this
     * makes the worker robust if setup ordering changes in a future stage. */
    if (_adapter->readyCompletionCount() != 0)
        signalCompletionAvailable();
    return true;

fail:
    stop();
    return false;
}

void RTW88WCLTxCompletionWorkQueue::stop()
{
    __atomic_store_n(&_stopping, 1U, __ATOMIC_RELEASE);

    /* Controller calls stop only after adapter->unbind() proves the ticket
     * table empty and the RTW88 producer stopped. */
    if (_adapter)
        _adapter->clearCompletionNotifier(this);

    if (_retryTimer) {
        _retryTimer->cancelTimeout();
        if (_timerRegistered && _workLoop) {
            _workLoop->removeEventSource(_retryTimer);
            _timerRegistered = false;
        }
        _retryTimer->release();
        _retryTimer = nullptr;
    }

    if (_eventSourceRegistered && _workLoop) {
        _workLoop->removeEventSource(this);
        _eventSourceRegistered = false;
    }
    _workLoop = nullptr;

    if (_completionQueue) {
        _completionQueue->release();
        _completionQueue = nullptr;
    }
    if (_adapter) {
        _adapter->release();
        _adapter = nullptr;
    }
}

void RTW88WCLTxCompletionWorkQueue::free()
{
    stop();
    super::free();
}

void RTW88WCLTxCompletionWorkQueue::completionNotifier(void *context)
{
    auto *self = static_cast<RTW88WCLTxCompletionWorkQueue *>(context);
    if (self)
        self->signalCompletionAvailable();
}

void RTW88WCLTxCompletionWorkQueue::retryTimerFired(
    OSObject *owner, IOTimerEventSource *timer)
{
    (void)timer;
    auto *self = OSDynamicCast(RTW88WCLTxCompletionWorkQueue, owner);
    if (self)
        self->signalCompletionAvailable();
}

void RTW88WCLTxCompletionWorkQueue::signalCompletionAvailable()
{
    if (__atomic_load_n(&_stopping, __ATOMIC_ACQUIRE) == 0)
        signalWorkAvailable();
}

bool RTW88WCLTxCompletionWorkQueue::completionSink(
    IOSkywalkPacket *packet, bool transmitted, void *context)
{
    auto *self = static_cast<RTW88WCLTxCompletionWorkQueue *>(context);
    if (!self || !packet ||
        __atomic_load_n(&self->_stopping, __ATOMIC_ACQUIRE) != 0 ||
        !self->_completionQueue)
        return false;

    /* The target API has no per-packet success/error argument: it completes
     * packet ownership in the TX direction. Do not smuggle RTW88's bool result
     * into undocumented IOOptionBits. The result remains in the ticket until
     * the synchronous queue call returns. */
    (void)transmitted;
    const IOSkywalkPacket *batch[1] = { packet };

    /* In 24H32 this overload preflights queue/table readiness, copies the
     * pointer array into the queue's internal completion array, calls
     * completePackets() synchronously, then returns kIOReturnSuccess.
     * completePackets() calls completeWithQueue(queue, Tx, 0), which completes
     * each packet buffer and then the packet through its vtable completion.
     *
     * Any non-success result is a preflight failure before the array copy or
     * packet completion. Returning false keeps the ticket and adapter retain
     * for the timer-driven retry path. */
    return self->_completionQueue->enqueuePackets(batch, 1, 0) ==
           kIOReturnSuccess;
}

bool RTW88WCLTxCompletionWorkQueue::checkForWork()
{
    if (__atomic_load_n(&_stopping, __ATOMIC_ACQUIRE) != 0 ||
        !_adapter || !_completionQueue)
        return false;

    (void)_adapter->drainCompletions(
        &RTW88WCLTxCompletionWorkQueue::completionSink, this);

    /* drainCompletions stops on the first rejected handoff and returns the
     * ticket to Completed. Retry later rather than spinning when Skywalk is
     * temporarily not-ready or its internal action gate is busy. */
    if (_adapter->readyCompletionCount() != 0 && _retryTimer)
        _retryTimer->setTimeoutMS(kRetryDelayMilliseconds);
    return false;
}

#undef super
