#include "../driver/RTL88WiFi/src/compat/linux/mpsc_bounded_queue.h"
#include <atomic>
#include <cassert>
#include <cstdint>
#include <memory>
#include <thread>
#include <vector>
#include <sched.h>

struct ReusedNode {
    std::atomic<uint32_t> queued{0};
    uint32_t ticket = 0;
};
int main() {
    constexpr uint32_t producers = 12, perProducer = 3000;
    constexpr uint32_t total = producers * perProducer;
    constexpr uint32_t poolSize = 256;
    rtw88_mpsc_bounded_queue queue;
    rtw88_mpsc_bounded_queue_init(&queue);

    uint32_t markers[RTW88_MPSC_QUEUE_CAPACITY + 1U] = {};
    for (uint32_t i = 0; i < RTW88_MPSC_QUEUE_CAPACITY; ++i)
        assert(rtw88_mpsc_bounded_queue_enqueue(&queue, &markers[i]));
    assert(!rtw88_mpsc_bounded_queue_enqueue(&queue, &markers[RTW88_MPSC_QUEUE_CAPACITY]));
    for (uint32_t i = 0; i < RTW88_MPSC_QUEUE_CAPACITY; ++i)
        assert(rtw88_mpsc_bounded_queue_dequeue(&queue) == &markers[i]);
    assert(rtw88_mpsc_bounded_queue_empty(&queue));

    rtw88_mpsc_bounded_queue_init(&queue);
    ReusedNode pool[poolSize];
    std::unique_ptr<std::atomic<uint32_t>[]> seen(new std::atomic<uint32_t>[total]);
    for (uint32_t i=0; i<total; ++i) seen[i].store(0, std::memory_order_relaxed);

    std::atomic<uint32_t> nextTicket{0}, consumed{0};
    std::vector<std::thread> workers;
    for (uint32_t p=0; p<producers; ++p) workers.emplace_back([&, p] {
        for (uint32_t n=0; n<perProducer; ++n) {
            ReusedNode *node = &pool[(p * 17U + n) % poolSize];
            uint32_t expected = 0;
            while (!node->queued.compare_exchange_weak(expected, 1U,
                       std::memory_order_acq_rel)) { expected = 0; sched_yield(); }
            node->ticket = nextTicket.fetch_add(1, std::memory_order_relaxed);
            while (!rtw88_mpsc_bounded_queue_enqueue(&queue, node)) sched_yield();
        }
    });
    while (consumed.load(std::memory_order_acquire) < total) {
        auto *node = static_cast<ReusedNode *>(rtw88_mpsc_bounded_queue_dequeue(&queue));
        if (!node) { sched_yield(); continue; }
        assert(node->ticket < total);
        seen[node->ticket].fetch_add(1, std::memory_order_relaxed);
        uint32_t expected = 1U;
        assert(node->queued.compare_exchange_strong(expected, 0U,
               std::memory_order_release, std::memory_order_relaxed));
        consumed.fetch_add(1, std::memory_order_release);
    }
    for (auto &worker : workers) worker.join();
    assert(nextTicket.load(std::memory_order_acquire) == total);
    assert(consumed.load(std::memory_order_acquire) == total);
    assert(rtw88_mpsc_bounded_queue_empty(&queue));
    for (uint32_t i=0; i<total; ++i)
        assert(seen[i].load(std::memory_order_relaxed) == 1U);
    for (const auto &node : pool)
        assert(node.queued.load(std::memory_order_relaxed) == 0U);
}
