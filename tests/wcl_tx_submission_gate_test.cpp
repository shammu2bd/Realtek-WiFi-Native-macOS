/* SPDX-License-Identifier: GPL-2.0-only */
#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLTxSubmissionGate.hpp"

#include <atomic>
#include <cassert>
#include <cstdint>
#include <thread>
#include <vector>
#include <sched.h>

static void testLifecycleTransitions()
{
    RTW88WCLTxSubmissionGate gate;
    assert(gate.isUnbound());
    assert(!gate.enterSubmission());
    assert(!gate.finishBind());

    assert(gate.beginBind());
    assert(!gate.beginBind());
    assert(!gate.enterSubmission());
    assert(gate.finishBind());
    assert(gate.isBound());
    assert(gate.enterSubmission());
    assert(gate.inFlight() == 1);

    assert(gate.beginUnbind());
    assert(!gate.isBound());
    assert(!gate.enterSubmission());
    assert(!gate.canFinishUnbind());
    gate.leaveSubmission();
    assert(gate.canFinishUnbind());
    assert(gate.finishUnbind());
    assert(gate.isUnbound());
    assert(!gate.finishUnbind());

    /* A quiesced adapter can be rebound only after full unbind. */
    assert(gate.beginBind());
    assert(gate.finishBind());
    assert(gate.beginUnbind());
    assert(gate.finishUnbind());
}

static void testUnbindWaitsForRacingSubmitters()
{
    RTW88WCLTxSubmissionGate gate;
    assert(gate.beginBind());
    assert(gate.finishBind());

    constexpr uint32_t kThreads = 8;
    std::atomic<bool> stop{false};
    std::atomic<uint32_t> active{0};
    std::atomic<uint32_t> entered{0};
    std::vector<std::thread> producers;
    producers.reserve(kThreads);

    for (uint32_t n = 0; n < kThreads; ++n) {
        producers.emplace_back([&] {
            while (!stop.load(std::memory_order_acquire)) {
                if (!gate.enterSubmission()) {
                    sched_yield();
                    continue;
                }
                active.fetch_add(1, std::memory_order_acq_rel);
                entered.fetch_add(1, std::memory_order_relaxed);
                sched_yield();
                active.fetch_sub(1, std::memory_order_acq_rel);
                gate.leaveSubmission();
            }
        });
    }

    while (entered.load(std::memory_order_acquire) < 1000)
        sched_yield();

    assert(gate.beginUnbind());
    stop.store(true, std::memory_order_release);
    for (auto &producer : producers)
        producer.join();

    assert(active.load(std::memory_order_acquire) == 0);
    assert(gate.inFlight() == 0);
    assert(!gate.enterSubmission());
    assert(gate.canFinishUnbind());
    assert(gate.finishUnbind());
    assert(gate.isUnbound());
}

static void testAbortAndBusyBinding()
{
    RTW88WCLTxSubmissionGate gate;
    assert(gate.beginBind());
    gate.abortBind();
    assert(gate.isUnbound());

    assert(gate.beginBind());
    assert(!gate.beginUnbind()); // cannot tear down a partially bound adapter
    gate.abortBind();
    assert(gate.isUnbound());
}


static void testOwnerGateProtectsAdapterPointerLoadWindow()
{
    RTW88WCLTxSubmissionGate ownerGate;
    RTW88WCLTxSubmissionGate adapterGate;
    std::atomic<bool> pointerAttached{true};
    std::atomic<bool> pointerLoaded{false};
    std::atomic<bool> continueCallback{false};
    std::atomic<bool> adapterRejected{false};

    assert(ownerGate.beginBind());
    assert(ownerGate.finishBind());
    assert(adapterGate.beginBind());
    assert(adapterGate.finishBind());

    std::thread callback([&] {
        assert(ownerGate.enterSubmission());
        assert(pointerAttached.load(std::memory_order_acquire));
        pointerLoaded.store(true, std::memory_order_release);

        while (!continueCallback.load(std::memory_order_acquire))
            sched_yield();

        /* The adapter may already be quiesced, but the owner gate keeps its
         * pointer/context retained until this callback has stopped reading it.
         */
        const bool entered = adapterGate.enterSubmission();
        adapterRejected.store(!entered, std::memory_order_release);
        if (entered)
            adapterGate.leaveSubmission();
        ownerGate.leaveSubmission();
    });

    while (!pointerLoaded.load(std::memory_order_acquire))
        sched_yield();

    /* Model the controller's order: close adapter admission first, then ask
     * the queue owner to detach. The owner gate must still report in-flight.
     */
    assert(adapterGate.beginUnbind());
    assert(adapterGate.canFinishUnbind());
    assert(adapterGate.finishUnbind());
    assert(ownerGate.beginUnbind());
    assert(!ownerGate.canFinishUnbind());
    assert(pointerAttached.load(std::memory_order_acquire));

    continueCallback.store(true, std::memory_order_release);
    callback.join();

    assert(adapterRejected.load(std::memory_order_acquire));
    assert(ownerGate.canFinishUnbind());
    assert(ownerGate.finishUnbind());
    pointerAttached.store(false, std::memory_order_release);
    assert(!pointerAttached.load(std::memory_order_acquire));
}

int main()
{
    testLifecycleTransitions();
    testUnbindWaitsForRacingSubmitters();
    testAbortAndBusyBinding();
    testOwnerGateProtectsAdapterPointerLoadWindow();
    return 0;
}
