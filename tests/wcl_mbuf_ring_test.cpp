/* SPDX-License-Identifier: GPL-2.0-only */
#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLMbufRing.hpp"

#include <atomic>
#include <cassert>
#include <cstdint>
#include <thread>
#include <vector>
#include <sched.h>

static void testCapacityAndWrap()
{
    RTW88WCLMbufRing<void *, 4> ring;
    ring.reset();
    void *items[5] = {
        reinterpret_cast<void *>(uintptr_t(1)),
        reinterpret_cast<void *>(uintptr_t(2)),
        reinterpret_cast<void *>(uintptr_t(3)),
        reinterpret_cast<void *>(uintptr_t(4)),
        reinterpret_cast<void *>(uintptr_t(5))
    };
    for (int i = 0; i < 4; ++i)
        assert(ring.push(items[i]));
    assert(!ring.push(items[4]));
    for (int i = 0; i < 4; ++i) {
        void *out = nullptr;
        assert(ring.pop(&out));
        assert(out == items[i]);
    }
    void *out = nullptr;
    assert(!ring.pop(&out));
    for (uint32_t cycle = 0; cycle < 20000; ++cycle) {
        void *value = reinterpret_cast<void *>(uintptr_t(cycle + 1));
        assert(ring.push(value));
        out = nullptr;
        assert(ring.pop(&out));
        assert(out == value);
    }
}

static void testConcurrentMpmcTraffic()
{
    constexpr uint32_t kProducerCount = 8;
    constexpr uint32_t kItemsPerProducer = 6000;
    constexpr uint32_t kTotal = kProducerCount * kItemsPerProducer;
    RTW88WCLMbufRing<void *, 128> ring;
    ring.reset();

    std::vector<std::atomic<uint32_t>> seen(kTotal);
    for (auto &entry : seen)
        entry.store(0, std::memory_order_relaxed);

    std::atomic<uint32_t> produced{0};
    std::atomic<uint32_t> consumed{0};
    std::vector<std::thread> producers;
    producers.reserve(kProducerCount);

    for (uint32_t thread = 0; thread < kProducerCount; ++thread) {
        producers.emplace_back([&, thread] {
            for (uint32_t n = 0; n < kItemsPerProducer; ++n) {
                const uint32_t id = thread * kItemsPerProducer + n;
                void *value = reinterpret_cast<void *>(uintptr_t(id + 1));
                while (!ring.push(value))
                    sched_yield();
                produced.fetch_add(1, std::memory_order_release);
            }
        });
    }

    std::vector<std::thread> consumers;
    consumers.emplace_back([&] {
        while (consumed.load(std::memory_order_acquire) < kTotal) {
            void *value = nullptr;
            if (!ring.pop(&value)) {
                sched_yield();
                continue;
            }
            const uintptr_t raw = reinterpret_cast<uintptr_t>(value);
            assert(raw >= 1 && raw <= kTotal);
            const uint32_t id = static_cast<uint32_t>(raw - 1);
            uint32_t expected = 0;
            assert(seen[id].compare_exchange_strong(expected, 1,
                                                    std::memory_order_acq_rel));
            consumed.fetch_add(1, std::memory_order_release);
        }
    });

    for (auto &producer : producers)
        producer.join();
    consumers.front().join();

    assert(produced.load(std::memory_order_acquire) == kTotal);
    assert(consumed.load(std::memory_order_acquire) == kTotal);
    assert(ring.empty());
    for (const auto &entry : seen)
        assert(entry.load(std::memory_order_acquire) == 1);
}

int main()
{
    testCapacityAndWrap();
    testConcurrentMpmcTraffic();
    return 0;
}
