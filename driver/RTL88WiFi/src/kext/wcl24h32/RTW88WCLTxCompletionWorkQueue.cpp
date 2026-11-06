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

    _tokenReapCall = thread_call_allocate_with_priority(
        &RTW88WCLTxCompletionWorkQueue::deferredTokenReap,
        this, THREAD_CALL_PRIORITY_KERNEL);
    if (!_tokenReapCall)
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
    (void)stop();
    return false;
}

IOReturn RTW88WCLTxCompletionWorkQueue::stop()
{
    /* A live ticket or retired token still owns callback context. Keep the
     * event source, thread call, adapter and queue alive until controller
     * unbind proves both producer and deferred-reclamation paths are drained. */
    if (_adapter &&
        (_adapter->hasOutstandingCompletions() ||
         _adapter->hasRetiredCompletionTokens()))
        return kIOReturnBusy;

    __atomic_store_n(&_stopping, 1U, __ATOMIC_RELEASE);
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

    /* Event-source removal closes the only scheduler. The thread-call callback
     * never re-enqueues itself; cancel_wait therefore covers the one pending or
     * active invocation before its storage and adapter references are released. */
    if (_tokenReapCall) {
        (void)thread_call_cancel_wait(_tokenReapCall);
        if (!thread_call_free(_tokenReapCall)) {
            IOLog("rtl88wifi-wcl: token reaper thread-call still active; retaining worker owners\n");
            return kIOReturnBusy;
        }
        _tokenReapCall = nullptr;
    }
    __atomic_store_n(&_tokenReapState, 0U, __ATOMIC_RELEASE);

    if (_completionQueue) {
        _completionQueue->release();
        _completionQueue = nullptr;
    }
    if (_adapter) {
        _adapter->release();
        _adapter = nullptr;
    }
    return kIOReturnSuccess;
}

void RTW88WCLTxCompletionWorkQueue::free()
{
    if (stop() != kIOReturnSuccess) {
        IOLog("rtl88wifi-wcl: completion worker free deferred; callback ownership remains\n");
        return;
    }
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

void RTW88WCLTxCompletionWorkQueue::scheduleTokenReap()
{
    if (__atomic_load_n(&_stopping, __ATOMIC_ACQUIRE) != 0 ||
        !_adapter || !_tokenReapCall ||
        !_adapter->hasReapableCompletionTokens())
        return;

    uint32_t state = __atomic_load_n(&_tokenReapState, __ATOMIC_ACQUIRE);
    for (;;) {
        if (state & kTokenReapScheduled) {
            if (state & kTokenReapResignal)
                return;
            const uint32_t desired = state | kTokenReapResignal;
            if (__atomic_compare_exchange_n(&_tokenReapState, &state, desired,
                                            false, __ATOMIC_ACQ_REL,
                                            __ATOMIC_ACQUIRE))
                return;
        } else {
            if (__atomic_compare_exchange_n(&_tokenReapState, &state,
                                            kTokenReapScheduled, false,
                                            __ATOMIC_ACQ_REL,
                                            __ATOMIC_ACQUIRE)) {
                /* TRUE means already pending; it is not an error. Keep the
                 * scheduled bit set until the one callback reaches its tail. */
                (void)thread_call_enter(_tokenReapCall);
                return;
            }
        }
        state = __atomic_load_n(&_tokenReapState, __ATOMIC_ACQUIRE);
    }
}

void RTW88WCLTxCompletionWorkQueue::deferredTokenReap(
    thread_call_param_t context, thread_call_param_t unused)
{
    (void)unused;
    auto *self = static_cast<RTW88WCLTxCompletionWorkQueue *>(context);
    if (!self)
        return;

    for (;;) {
        if (self->_adapter)
            self->_adapter->reapDeferredCompletionTokens();

        uint32_t state = __atomic_load_n(&self->_tokenReapState,
                                         __ATOMIC_ACQUIRE);
        if (state & kTokenReapResignal) {
            uint32_t expected = state;
            if (__atomic_compare_exchange_n(&self->_tokenReapState, &expected,
                                            kTokenReapScheduled, false,
                                            __ATOMIC_ACQ_REL,
                                            __ATOMIC_ACQUIRE))
                continue;
            continue;
        }

        uint32_t expected = kTokenReapScheduled;
        if (__atomic_compare_exchange_n(&self->_tokenReapState, &expected, 0U,
                                        false, __ATOMIC_ACQ_REL,
                                        __ATOMIC_ACQUIRE))
            return;
        if (!(expected & kTokenReapScheduled))
            return;
    }
}

bool RTW88WCLTxCompletionWorkQueue::checkForWork()
{
    if (__atomic_load_n(&_stopping, __ATOMIC_ACQUIRE) != 0 ||
        !_adapter || !_completionQueue)
        return false;

    (void)_adapter->drainCompletions(
        &RTW88WCLTxCompletionWorkQueue::completionSink, this);
    scheduleTokenReap();

    /* drainCompletions stops on the first rejected handoff and returns the
     * ticket to Completed. Retry later rather than spinning when Skywalk is
     * temporarily not-ready or its internal action gate is busy. */
    if (_adapter->readyCompletionCount() != 0 && _retryTimer)
        _retryTimer->setTimeoutMS(kRetryDelayMilliseconds);
    return false;
}

#undef super
