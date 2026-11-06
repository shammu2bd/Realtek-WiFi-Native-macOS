/* SPDX-License-Identifier: GPL-2.0-only
 * Serialized, retryable 24H32 Skywalk TX completion handoff.
 */
#pragma once

#include <IOKit/IOEventSource.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/skywalk/IOSkywalkPacket.h>
#include <IOKit/skywalk/IOSkywalkTxCompletionQueue.h>
#include <libkern/c++/OSObject.h>
#include <stdint.h>
#include <kern/thread_call.h>

class RTW88WCLSkywalkTxAdapter;

/*
 * RTW88 completion callbacks execute in a context that must not call Skywalk
 * or release OSObjects. The adapter notifier only signals this event source.
 * checkForWork() runs on the controller IOWorkLoop and uses the 24H32
 * synchronous enqueuePackets(packet-array) entry point.
 *
 * A failed queue preflight (not-ready/busy) leaves the adapter ticket
 * Completed. A low-frequency timer retries it without spinning the workloop.
 */
class RTW88WCLTxCompletionWorkQueue final : public IOEventSource {
    OSDeclareDefaultStructors(RTW88WCLTxCompletionWorkQueue)

public:
    static constexpr uint32_t kRetryDelayMilliseconds = 10;

    bool init(OSObject *owner, IOWorkLoop *workLoop,
              RTW88WCLSkywalkTxAdapter *adapter,
              IOSkywalkTxCompletionQueue *completionQueue);
    IOReturn stop();
    void free() override;
    bool checkForWork() override;
    void signalCompletionAvailable();

private:
    static void completionNotifier(void *context);
    static void retryTimerFired(OSObject *owner, IOTimerEventSource *timer);
    static bool completionSink(IOSkywalkPacket *packet, bool transmitted,
                               void *context);

    static void deferredTokenReap(thread_call_param_t context,
                                  thread_call_param_t unused);
    void scheduleTokenReap();
    bool enterWorkCallback();
    void leaveWorkCallback();

    enum : uint32_t {
        kTokenReapScheduled = 1U << 0,
        kTokenReapResignal = 1U << 1
    };

    IOWorkLoop *_workLoop = nullptr; // non-owning; controller owns workloop
    IOTimerEventSource *_retryTimer = nullptr; // retained by this object
    thread_call_t _tokenReapCall = nullptr; // native deferred context for IOFree
    volatile uint32_t _tokenReapState = 0;   // scheduled/resignal handshake
    enum : uint32_t {
        kWorkCallbackGateClosed = 0x80000000U,
        kWorkCallbackGateActive = 0x7FFFFFFFU
    };
    volatile uint32_t _workCallbackGate = kWorkCallbackGateClosed;
    RTW88WCLSkywalkTxAdapter *_adapter = nullptr; // retained
    IOSkywalkTxCompletionQueue *_completionQueue = nullptr; // retained
    bool _eventSourceRegistered = false;
    bool _timerRegistered = false;
    volatile uint32_t _stopping = 1;
};
