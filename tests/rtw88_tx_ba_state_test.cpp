#include "../driver/RTL88WiFi/src/kext/RTW88TxBAState.hpp"

#include <atomic>
#include <cassert>
#include <cstdio>
#include <thread>

static void testSnapshotAndTid()
{
    RTW88TxBAState state;
    assert(!state.active());
    assert(!state.activeForTid(0));
    state.activate(5);
    assert(state.active());
    assert(state.tid() == 5);
    assert(state.activeForTid(5));
    assert(!state.activeForTid(0));
    state.clear();
    assert(!state.active());
}

static void testConcurrentSnapshotsNeverMixActiveAndTid()
{
    RTW88TxBAState state;
    std::atomic<bool> start{false};
    std::atomic<unsigned> failures{0};

    std::thread writer([&]() {
        while (!start.load(std::memory_order_acquire))
            std::this_thread::yield();
        for (unsigned i = 0; i < 500000; ++i) {
            state.activate(5);
            state.activate(0);
            state.clear();
        }
    });

    std::thread reader([&]() {
        start.store(true, std::memory_order_release);
        for (unsigned i = 0; i < 1000000; ++i) {
            const uint32_t s = state.snapshot();
            if (s & RTW88TxBAState::kActiveBit) {
                const uint32_t tid = s & RTW88TxBAState::kTidMask;
                if (tid != 0 && tid != 5)
                    failures.fetch_add(1, std::memory_order_relaxed);
            }
        }
    });

    writer.join();
    reader.join();
    assert(failures.load(std::memory_order_relaxed) == 0);
}

int main()
{
    testSnapshotAndTid();
    testConcurrentSnapshotsNeverMixActiveAndTid();
    std::puts("PASS: packed TX Block Ack state snapshot and concurrency");
    return 0;
}
