/* SPDX-License-Identifier: GPL-2.0-only */
#include "../driver/RTL88WiFi/src/kext/RTW88TxSequenceNumbers.hpp"

#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <thread>
#include <vector>

static void testIndependentQoSTIDSpaces()
{
    RTW88TxSequenceNumbers sequences;
    assert(sequences.nextQoS(0) == 0);
    assert(sequences.nextQoS(1) == 0);
    assert(sequences.nextQoS(0) == 1);
    assert(sequences.currentQoS(0) == 2);
    assert(sequences.currentQoS(1) == 1);
    assert(sequences.nextQoS(8) == 0);

    sequences.resetQoS();
    assert(sequences.nextQoS(0) == 0);
    assert(sequences.nextQoS(1) == 0);
}

static void testConcurrentSameTIDSequenceAllocation()
{
    constexpr uint32_t kThreads = 8;
    constexpr uint32_t kPerThread = 400;
    constexpr uint32_t kTotal = kThreads * kPerThread;

    RTW88TxSequenceNumbers sequences;
    std::vector<uint16_t> values(kTotal);
    std::vector<std::thread> threads;
    threads.reserve(kThreads);

    for (uint32_t t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t] {
            for (uint32_t i = 0; i < kPerThread; ++i)
                values[t * kPerThread + i] = sequences.nextQoS(5);
        });
    }
    for (auto &thread : threads)
        thread.join();

    std::sort(values.begin(), values.end());
    for (uint32_t i = 0; i < kTotal; ++i)
        assert(values[i] == i);
}

static void testConcurrentCCMPPacketNumbers()
{
    constexpr uint32_t kThreads = 8;
    constexpr uint32_t kPerThread = 400;
    constexpr uint32_t kTotal = kThreads * kPerThread;

    RTW88TxSequenceNumbers sequences;
    std::vector<uint64_t> values(kTotal);
    std::vector<std::thread> threads;
    threads.reserve(kThreads);
    for (uint32_t t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t] {
            for (uint32_t i = 0; i < kPerThread; ++i) {
                uint64_t packetNumber = 0;
                assert(sequences.nextCCMP(&packetNumber));
                values[t * kPerThread + i] = packetNumber;
            }
        });
    }
    for (auto &thread : threads)
        thread.join();

    std::sort(values.begin(), values.end());
    for (uint32_t i = 0; i < kTotal; ++i)
        assert(values[i] == static_cast<uint64_t>(i) + 1);
    assert(!sequences.nextCCMP(nullptr));

    sequences.resetCCMP();
    uint64_t packetNumber = 0;
    assert(sequences.nextCCMP(&packetNumber));
    assert(packetNumber == 1);
}

int main()
{
    testIndependentQoSTIDSpaces();
    testConcurrentSameTIDSequenceAllocation();
    testConcurrentCCMPPacketNumbers();
    return 0;
}
