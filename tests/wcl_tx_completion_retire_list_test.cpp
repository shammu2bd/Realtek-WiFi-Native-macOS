/* SPDX-License-Identifier: GPL-2.0-only */
#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLCompletionTokenRetireList.hpp"

#include <atomic>
#include <cassert>
#include <cstdint>
#include <thread>
#include <vector>
#include <sched.h>

struct Node {
    Node *deferred_next = nullptr;
    uint32_t id = 0;
    std::atomic<uint32_t> reclaimed{0};
};

static void testEmptyAndSingleNode()
{
    RTW88WCLCompletionTokenRetireList<Node> list;
    assert(list.empty());
    assert(list.takeAll() == nullptr);

    Node node;
    node.id = 7;
    list.push(&node);
    assert(!list.empty());

    Node *batch = list.takeAll();
    assert(batch == &node);
    assert(batch->deferred_next == nullptr);
    assert(list.empty());
    assert(list.takeAll() == nullptr);
}

static void testManyProducersAndOneDeferredConsumer()
{
    constexpr uint32_t kProducerCount = 12;
    constexpr uint32_t kNodesPerProducer = 3000;
    constexpr uint32_t kTotal = kProducerCount * kNodesPerProducer;

    RTW88WCLCompletionTokenRetireList<Node> list;
    std::vector<Node> nodes(kTotal);
    for (uint32_t i = 0; i < kTotal; ++i)
        nodes[i].id = i;

    std::atomic<uint32_t> produced{0};
    std::atomic<uint32_t> consumed{0};
    std::vector<std::thread> producers;
    producers.reserve(kProducerCount);

    for (uint32_t p = 0; p < kProducerCount; ++p) {
        producers.emplace_back([&, p] {
            const uint32_t begin = p * kNodesPerProducer;
            for (uint32_t n = 0; n < kNodesPerProducer; ++n) {
                list.push(&nodes[begin + n]);
                produced.fetch_add(1, std::memory_order_release);
            }
        });
    }

    /* One consumer models the serialized thread-call reaper. Producers may
     * publish during takeAll()/walk; every detached batch must be unique. */
    while (consumed.load(std::memory_order_acquire) < kTotal) {
        Node *node = list.takeAll();
        if (!node) {
            sched_yield();
            continue;
        }

        while (node) {
            Node *next = node->deferred_next;
            node->deferred_next = nullptr;
            uint32_t expected = 0;
            assert(node->reclaimed.compare_exchange_strong(
                expected, 1, std::memory_order_acq_rel));
            consumed.fetch_add(1, std::memory_order_release);
            node = next;
        }
    }

    for (auto &producer : producers)
        producer.join();

    assert(produced.load(std::memory_order_acquire) == kTotal);
    assert(consumed.load(std::memory_order_acquire) == kTotal);
    assert(list.empty());
    for (const auto &node : nodes)
        assert(node.reclaimed.load(std::memory_order_acquire) == 1);
}

int main()
{
    testEmptyAndSingleNode();
    testManyProducersAndOneDeferredConsumer();
    return 0;
}
