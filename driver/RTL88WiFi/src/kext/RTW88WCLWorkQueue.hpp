/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * Serialized RTW88 -> native WCL event delivery.
 */
#pragma once

#include <IOKit/IOEventSource.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOWorkLoop.h>
#include <libkern/c++/OSMetaClass.h>

#include "RTW88WCLRadioBridge.hpp"
#include "RTW88WCLRadioEventRing.hpp"

class RTW88WCLRadioEventHandler {
public:
    virtual void handleRTW88WCLRadioEvent(const RTW88WCLRadioEvent &event) = 0;
    virtual ~RTW88WCLRadioEventHandler() {}
};

/* IOEventSource implementation used as the bridge's event sink.
 *
 * Producer context: copy a bounded event record under an interrupt-safe spin
 * lock, then signalWorkAvailable(). No allocation, sleeping, Apple message
 * posting or radio calls occur on this path.
 *
 * Consumer context: IOWorkLoop calls checkForWork(), which drains the ring and
 * invokes the handler on the controller's work-loop thread.
 *
 * Lifecycle contract: detach and quiesce the RTW88 bridge before stop/free.
 * stop() must run outside this event source's active checkForWork()/handler
 * callback; IOWorkLoop removal serializes against any in-flight work check.
 */
class RTW88WCLWorkQueue final : public IOEventSource,
                                public RTW88WCLRadioEventSink {
    OSDeclareDefaultStructors(RTW88WCLWorkQueue)

public:
    using IOEventSource::init;
    static constexpr size_t kCapacity = 128;

    bool init(OSObject *owner, IOWorkLoop *workLoop,
              RTW88WCLRadioEventHandler *handler);
    void stop();
    void free() override;

    void onRTW88WCLRadioEvent(const RTW88WCLRadioEvent &event) override;
    bool checkForWork() override;

    uint32_t droppedEvents() const;
    uint32_t coalescedRSSIEvents() const;
    bool isInitialized() const { return _lock && _workLoop && _registered; }

private:
    bool enqueueLocked(const RTW88WCLRadioEvent &event);
    static bool isTelemetryEvent(const RTW88WCLRadioEvent &event);

    IOSimpleLock *_lock = nullptr;
    IOWorkLoop *_workLoop = nullptr;               // non-owning
    RTW88WCLRadioEventHandler *_handler = nullptr; // non-owning
    RTW88WCLRadioEventRing<RTW88WCLRadioEvent, kCapacity> _events;
    uint32_t _pendingSignal = 0;   // guarded by _lock
    uint32_t _stopping = 0;        // guarded by _lock
    uint32_t _registered = 0;      // lifecycle-owned
    uint32_t _dropped = 0;         // guarded by _lock
    uint32_t _coalescedRSSI = 0;    // guarded by _lock
};
