/* SPDX-License-Identifier: GPL-2.0-only
 * Sequoia 24H32 synchronous TX completion handoff on the controller workloop.
 */
#include "RTW88WCLTxCompletionWorkQueue.hpp"
#include "RTW88WCLSkywalkTxAdapter.hpp"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSMetaClass.h>

extern "C" {
#include "../../compat/linux/skbuff_tx_completion.h"
}
extern "C" void rtw88_wcl_defer_skb_tx_completion_token(
    void *context, void *token);

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
    _workCallbackGate = kWorkCallbackGateClosed;

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

    __atomic_store_n(&_workCallbackGate, 0U, __ATOMIC_RELEASE);
    __atomic_store_n(&_stopping, 0U, __ATOMIC_RELEASE);
    if (_adapter->setCompletionNotifier(
            &RTW88WCLTxCompletionWorkQueue::completionNotifier,
            this) != kIOReturnSuccess)
        goto fail;

    /* Install the WCL-only retire hook after the worker is ready but before
     * any native TX queue can accept a packet. The shared radio object remains
     * linkable in the legacy Airport build without this WCL implementation. */
    rtw88_set_skb_tx_completion_token_releaser(
        &rtw88_wcl_defer_skb_tx_completion_token);

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
    /* Controller unbind must first stop RTW88 and prove ticket callbacks have
     * returned. Remaining token ownership keeps this worker alive and retryable.
     */
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

    /* Event-source/timer dispatches are counted at entry. Once they are
     * removed, close admission and join any callback already inside the
     * worker before touching its adapter or thread-call context.
     */
    __atomic_fetch_or(&_workCallbackGate, kWorkCallbackGateClosed,
                      __ATOMIC_ACQ_REL);
    while ((__atomic_load_n(&_workCallbackGate, __ATOMIC_ACQUIRE) &
            kWorkCallbackGateActive) != 0)
        IOSleep(1);

    if (_tokenReapCall) {
        /* cancel_wait can cancel a pending invocation without joining another
         * active invocation for a normal non-ONCE call. Producer admission is
         * now closed, so isactive is a stable final join condition.
         */
        (void)thread_call_cancel_wait(_tokenReapCall);
        while (thread_call_isactive(_tokenReapCall))
            IOSleep(1);
        if (!thread_call_free(_tokenReapCall)) {
            IOLog("rtl88wifi-wcl: token reaper thread-call still active; retaining worker owners\\n");
            return kIOReturnBusy;
        }
        _tokenReapCall = nullptr;
    }

    __atomic_store_n(&_tokenReapState, 0U, __ATOMIC_RELEASE);

    /* All release-hook producers were stopped by controller unbind, all
     * workloop schedulers are joined, and the thread call is idle. A final
     * passive drain is now the only token consumer.
     */
    if (_adapter && _adapter->hasRetiredCompletionTokens())
        _adapter->reapDeferredCompletionTokens();
    if (_adapter && _adapter->hasRetiredCompletionTokens()) {
        IOLog("rtl88wifi-wcl: retired completion tokens remain after final drain; retaining worker\\n");
        return kIOReturnBusy;
    }

    rtw88_set_skb_tx_completion_token_releaser(nullptr);
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

bool RTW88WCLTxCompletionWorkQueue::enterWorkCallback()
{
    uint32_t gate = __atomic_load_n(&_workCallbackGate, __ATOMIC_ACQUIRE);
    for (;;) {
        if (gate & kWorkCallbackGateClosed)
            return false;
        if ((gate & kWorkCallbackGateActive) == kWorkCallbackGateActive)
            return false;
        if (__atomic_compare_exchange_n(&_workCallbackGate, &gate, gate + 1U,
                                        false, __ATOMIC_ACQ_REL,
                                        __ATOMIC_ACQUIRE))
            return true;
    }
}

void RTW88WCLTxCompletionWorkQueue::leaveWorkCallback()
{
    __atomic_sub_fetch(&_workCallbackGate, 1U, __ATOMIC_RELEASE);
}

void RTW88WCLTxCompletionWorkQueue::completionNotifier(void *context)
{
    auto *self = static_cast<RTW88WCLTxCompletionWorkQueue *>(context);
    if (self && self->enterWorkCallback()) {
        self->signalCompletionAvailable();
        self->leaveWorkCallback();
    }
}

void RTW88WCLTxCompletionWorkQueue::retryTimerFired(
    OSObject *owner, IOTimerEventSource *timer)
{
    (void)timer;
    auto *self = OSDynamicCast(RTW88WCLTxCompletionWorkQueue, owner);
    if (self && self->enterWorkCallback()) {
        self->signalCompletionAvailable();
        self->leaveWorkCallback();
    }
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
    if (!enterWorkCallback())
        return false;

    bool more = false;
    if (__atomic_load_n(&_stopping, __ATOMIC_ACQUIRE) == 0 &&
        _adapter && _completionQueue) {
        (void)_adapter->drainCompletions(
            &RTW88WCLTxCompletionWorkQueue::completionSink, this);
        scheduleTokenReap();

        more = _adapter->readyCompletionCount() != 0;
        if (!more && _retryTimer)
            _retryTimer->setTimeoutMS(kRetryDelayMilliseconds);
    }

    leaveWorkCallback();
    return more;
}

#undef super
