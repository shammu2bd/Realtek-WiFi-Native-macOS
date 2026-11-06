/* SPDX-License-Identifier: GPL-2.0-only
 * Portable stress for the bounded sequence-numbered token retirement queue.
 * This is a host model, not an XNU runtime test.
 */
#include "../driver/RTL88WiFi/src/compat/linux/mpsc_bounded_queue.h"

#include <atomic>
#include <cassert>
#include <cstdint>
#include <memory>
#include <thread>
#include <vector>
#include <sched.h>

struct TokenModel {
    uint32_t id = 0;
};

static void testCapacityAndWrap()
{
    rtw88_mpsc_bounded_queue queue;
    rtw88_mpsc_bounded_queue_init(&queue);
    TokenModel markers[RTW88_MPSC_QUEUE_CAPACITY + 1U];

    for (uint32_t i = 0; i < RTW88_MPSC_QUEUE_CAPACITY; ++i) {
        markers[i].id = i;
        assert(rtw88_mpsc_bounded_queue_enqueue(&queue, &markers[i]));
    }
    assert(!rtw88_mpsc_bounded_queue_enqueue(
        &queue, &markers[RTW88_MPSC_QUEUE_CAPACITY]));
    for (uint32_t i = 0; i < RTW88_MPSC_QUEUE_CAPACITY; ++i) {
        auto *token = static_cast<TokenModel *>(
            rtw88_mpsc_bounded_queue_dequeue(&queue));
        assert(token == &markers[i]);
        assert(token->id == i);
    }
    assert(rtw88_mpsc_bounded_queue_empty(&queue));
}

static void testManyProducersOneDeferredConsumer()
{
    constexpr uint32_t kProducerCount = 12;
    constexpr uint32_t kTokensPerProducer = 3000;
    constexpr uint32_t kTotal = kProducerCount * kTokensPerProducer;

    rtw88_mpsc_bounded_queue queue;
    rtw88_mpsc_bounded_queue_init(&queue);
    std::unique_ptr<TokenModel[]> tokens(new TokenModel[kTotal]);
    std::unique_ptr<std::atomic<uint32_t>[]> seen(
        new std::atomic<uint32_t>[kTotal]);
    for (uint32_t i = 0; i < kTotal; ++i) {
        tokens[i].id = i;
        seen[i].store(0, std::memory_order_relaxed);
    }

    std::atomic<uint32_t> produced{0};
    std::atomic<uint32_t> consumed{0};
    std::vector<std::thread> producers;
    producers.reserve(kProducerCount);

    for (uint32_t p = 0; p < kProducerCount; ++p) {
        producers.emplace_back([&, p] {
            const uint32_t begin = p * kTokensPerProducer;
            for (uint32_t i = 0; i < kTokensPerProducer; ++i) {
                TokenModel *token = &tokens[begin + i];
                while (!rtw88_mpsc_bounded_queue_enqueue(&queue, token))
                    sched_yield();
                produced.fetch_add(1, std::memory_order_release);
            }
        });
    }

    /* A sole deferred consumer retires every token while producers publish. */
    while (consumed.load(std::memory_order_acquire) < kTotal) {
        auto *token = static_cast<TokenModel *>(
            rtw88_mpsc_bounded_queue_dequeue(&queue));
        if (!token) {
            sched_yield();
            continue;
        }
        assert(token->id < kTotal);
        seen[token->id].fetch_add(1, std::memory_order_relaxed);
        consumed.fetch_add(1, std::memory_order_release);
    }

    for (auto &producer : producers)
        producer.join();

    assert(produced.load(std::memory_order_acquire) == kTotal);
    assert(consumed.load(std::memory_order_acquire) == kTotal);
    assert(rtw88_mpsc_bounded_queue_empty(&queue));
    for (uint32_t i = 0; i < kTotal; ++i)
        assert(seen[i].load(std::memory_order_relaxed) == 1U);
}

int main()
{
    testCapacityAndWrap();
    testManyProducersOneDeferredConsumer();
    return 0;
}
