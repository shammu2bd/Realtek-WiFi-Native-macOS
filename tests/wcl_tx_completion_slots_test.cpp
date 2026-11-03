/* SPDX-License-Identifier: GPL-2.0-only */
#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLTxCompletionSlots.hpp"

#include <atomic>
#include <cassert>
#include <cstdint>
#include <thread>
#include <vector>
#include <sched.h>

struct WorkItem {
    uint32_t id;
    std::atomic<uint32_t> completed{0};
};

static void testCapacityAndExactlyOnce()
{
    RTW88WCLTxCompletionSlots<4> pool;
    pool.reset();

    int values[5] = {0, 1, 2, 3, 4};
    auto *a = pool.reserve(&values[0]);
    auto *b = pool.reserve(&values[1]);
    auto *c = pool.reserve(&values[2]);
    auto *d = pool.reserve(&values[3]);
    assert(a && b && c && d);
    assert(pool.reserve(&values[4]) == nullptr);
    assert(pool.outstandingCount() == 4);

    assert(RTW88WCLTxCompletionSlots<4>::complete(a, true));
    assert(!RTW88WCLTxCompletionSlots<4>::complete(a, false));
    assert(RTW88WCLTxCompletionSlots<4>::complete(b, false));
    assert(RTW88WCLTxCompletionSlots<4>::complete(c, true));
    assert(RTW88WCLTxCompletionSlots<4>::complete(d, true));

    uint32_t seen = 0;
    bool sawSuccess = false;
    bool sawDrop = false;
    while (auto *ticket = pool.claimCompleted()) {
        auto *value = static_cast<int *>(RTW88WCLTxCompletionSlots<4>::packet(ticket));
        assert(value >= &values[0] && value <= &values[3]);
        if (RTW88WCLTxCompletionSlots<4>::transmitted(ticket))
            sawSuccess = true;
        else
            sawDrop = true;
        RTW88WCLTxCompletionSlots<4>::finish(ticket);
        ++seen;
    }
    assert(seen == 4 && sawSuccess && sawDrop);
    assert(!pool.hasOutstanding());
}

static void testConcurrentProducersAndConsumer()
{
    constexpr uint32_t kThreads = 12;
    constexpr uint32_t kPerThread = 2500;
    constexpr uint32_t kTotal = kThreads * kPerThread;
    RTW88WCLTxCompletionSlots<128> pool;
    pool.reset();

    std::vector<WorkItem> work(kTotal);
    for (uint32_t i = 0; i < kTotal; ++i)
        work[i].id = i;

    std::atomic<uint32_t> produced{0};
    std::atomic<uint32_t> drained{0};
    std::vector<std::thread> producers;
    producers.reserve(kThreads);

    for (uint32_t threadIndex = 0; threadIndex < kThreads; ++threadIndex) {
        producers.emplace_back([&, threadIndex] {
            for (uint32_t n = 0; n < kPerThread; ++n) {
                const uint32_t id = threadIndex * kPerThread + n;
                auto *item = &work[id];
                RTW88WCLTxCompletionSlots<128>::Ticket *ticket = nullptr;
                while (!(ticket = pool.reserve(item)))
                    sched_yield();
                const bool transmitted = ((id * 7U) % 5U) != 0;
                while (!RTW88WCLTxCompletionSlots<128>::complete(ticket, transmitted))
                    sched_yield();
                produced.fetch_add(1, std::memory_order_relaxed);
            }
        });
    }

    while (drained.load(std::memory_order_acquire) < kTotal) {
        auto *ticket = pool.claimCompleted();
        if (!ticket) {
            sched_yield();
            continue;
        }
        auto *item = static_cast<WorkItem *>(
            RTW88WCLTxCompletionSlots<128>::packet(ticket));
        assert(item != nullptr && item->id < kTotal);
        const uint32_t expected = ((item->id * 7U) % 5U) != 0 ? 1U : 0U;
        assert(RTW88WCLTxCompletionSlots<128>::transmitted(ticket) == (expected != 0));
        uint32_t notCompleted = 0;
        assert(item->completed.compare_exchange_strong(
            notCompleted, 1, std::memory_order_acq_rel));
        RTW88WCLTxCompletionSlots<128>::finish(ticket);
        drained.fetch_add(1, std::memory_order_release);
    }

    for (auto &producer : producers)
        producer.join();
    assert(produced.load(std::memory_order_acquire) == kTotal);
    assert(drained.load(std::memory_order_acquire) == kTotal);
    assert(!pool.hasOutstanding());
    for (const auto &item : work)
        assert(item.completed.load(std::memory_order_acquire) == 1);
}

int main()
{
    testCapacityAndExactlyOnce();
    testConcurrentProducersAndConsumer();
    return 0;
}
