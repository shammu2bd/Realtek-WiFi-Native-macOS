/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * Serialized RTW88 -> native WCL event delivery.
 */
#include "RTW88WCLWorkQueue.hpp"

#include <IOKit/IOLib.h>

#define super IOEventSource
OSDefineMetaClassAndStructors(RTW88WCLWorkQueue, IOEventSource)

bool RTW88WCLWorkQueue::init(OSObject *owner, IOWorkLoop *workLoop,
                             RTW88WCLRadioEventHandler *handler)
{
    if (!owner || !workLoop || !handler || _lock || _workLoop)
        return false;
    if (!super::init(owner, nullptr))
        return false;

    _lock = IOSimpleLockAlloc();
    if (!_lock)
        return false;

    _workLoop = workLoop;
    _handler = handler;
    _events.clear();
    _pendingSignal = 0;
    _stopping = 0;
    _registered = 0;
    _dropped = 0;
    _coalescedRSSI = 0;

    const IOReturn status = workLoop->addEventSource(this);
    if (status != kIOReturnSuccess) {
        _workLoop = nullptr;
        _handler = nullptr;
        IOSimpleLockFree(_lock);
        _lock = nullptr;
        return false;
    }
    _registered = 1;
    return true;
}

void RTW88WCLWorkQueue::stop()
{
    IOSimpleLock *lock = _lock;
    if (!lock)
        return;

    IOInterruptState interruptState = IOSimpleLockLockDisableInterrupt(lock);
    _stopping = 1;
    _handler = nullptr;
    _events.clear();
    _pendingSignal = 0;
    IOSimpleLockUnlockEnableInterrupt(lock, interruptState);

    /* Caller must have detached/quiesced the RTW88 event producer. Removal is
     * synchronous with the IOWorkLoop and waits out an active checkForWork(). */
    if (_registered && _workLoop) {
        _workLoop->removeEventSource(this);
        _registered = 0;
    }
    _workLoop = nullptr;
}

void RTW88WCLWorkQueue::free()
{
    stop();
    if (_lock) {
        IOSimpleLockFree(_lock);
        _lock = nullptr;
    }
    super::free();
}

bool RTW88WCLWorkQueue::isTelemetryEvent(const RTW88WCLRadioEvent &event)
{
    return event.event == kRTW88EventRSSIChanged;
}

bool RTW88WCLWorkQueue::enqueueLocked(const RTW88WCLRadioEvent &event)
{
    if (isTelemetryEvent(event)) {
        const bool replaced = _events.replaceLast(
            [&event](const RTW88WCLRadioEvent &queued) {
                return queued.event == kRTW88EventRSSIChanged &&
                       queued.joinGeneration == event.joinGeneration;
            }, event);
        if (replaced) {
            ++_coalescedRSSI;
            return true;
        }
    }

    if (_events.full() && !isTelemetryEvent(event)) {
        /* RSSI samples are advisory; preserve scan/association/disconnect
         * transitions by evicting the oldest RSSI sample first. */
        const bool evicted = _events.removeFirst(
            [](const RTW88WCLRadioEvent &queued) {
                return queued.event == kRTW88EventRSSIChanged;
            });
        if (evicted)
            ++_dropped;
    }

    if (!_events.push(event)) {
        ++_dropped;
        return false;
    }
    return true;
}

void RTW88WCLWorkQueue::onRTW88WCLRadioEvent(
    const RTW88WCLRadioEvent &event)
{
    IOSimpleLock *lock = _lock;
    if (!lock)
        return;

    bool signal = false;
    IOInterruptState interruptState = IOSimpleLockLockDisableInterrupt(lock);
    if (!_stopping && enqueueLocked(event) && !_pendingSignal) {
        _pendingSignal = 1;
        signal = true;
    }
    IOSimpleLockUnlockEnableInterrupt(lock, interruptState);

    /* IOEventSource::signalWorkAvailable wakes its IOWorkLoop. The event
     * source does the actual callback only in checkForWork() on that loop. */
    if (signal)
        signalWorkAvailable();
}

bool RTW88WCLWorkQueue::checkForWork()
{
    /* Bound one pass so sustained telemetry or state churn cannot monopolize
     * the shared workloop. Returning true asks IOWorkLoop to call us again. */
    uint32_t budget = 32;
    while (budget-- != 0) {
        RTW88WCLRadioEvent event = {};
        RTW88WCLRadioEventHandler *handler = nullptr;
        IOSimpleLock *lock = _lock;
        if (!lock)
            return false;

        IOInterruptState interruptState = IOSimpleLockLockDisableInterrupt(lock);
        if (_stopping || !_events.pop(&event)) {
            if (_stopping)
                _events.clear();
            _pendingSignal = 0;
            IOSimpleLockUnlockEnableInterrupt(lock, interruptState);
            return false;
        }
        handler = _handler;
        IOSimpleLockUnlockEnableInterrupt(lock, interruptState);

        /* WCL controller/interface message translation belongs in this
         * handler, which is guaranteed to execute on the controller workloop. */
        if (handler)
            handler->handleRTW88WCLRadioEvent(event);
    }

    IOSimpleLock *lock = _lock;
    if (!lock)
        return false;
    IOInterruptState interruptState = IOSimpleLockLockDisableInterrupt(lock);
    const bool moreWork = !_stopping && !_events.empty();
    if (!moreWork)
        _pendingSignal = 0;
    IOSimpleLockUnlockEnableInterrupt(lock, interruptState);
    return moreWork;
}

uint32_t RTW88WCLWorkQueue::droppedEvents() const
{
    IOSimpleLock *lock = _lock;
    if (!lock)
        return _dropped;
    IOInterruptState state = IOSimpleLockLockDisableInterrupt(lock);
    const uint32_t value = _dropped;
    IOSimpleLockUnlockEnableInterrupt(lock, state);
    return value;
}

uint32_t RTW88WCLWorkQueue::coalescedRSSIEvents() const
{
    IOSimpleLock *lock = _lock;
    if (!lock)
        return _coalescedRSSI;
    IOInterruptState state = IOSimpleLockLockDisableInterrupt(lock);
    const uint32_t value = _coalescedRSSI;
    IOSimpleLockUnlockEnableInterrupt(lock, state);
    return value;
}

#undef super
