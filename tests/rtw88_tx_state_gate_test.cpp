#include "../driver/RTL88WiFi/src/kext/RTW88TxStateGate.hpp"
#include "../driver/RTL88WiFi/src/kext/RTW88TxFrameProtection.hpp"

#include <atomic>
#include <cassert>
#include <cstdio>
#include <thread>
#include <vector>

static void testBasicAdmissionAndDrain()
{
    RTW88TxStateGate gate;
    auto first = gate.tryEnterTransmit();
    auto second = gate.tryEnterTransmit();
    assert(first && second);
    assert(gate.activeTransmitters() == 2);

    auto writer = gate.tryBeginMutation();
    assert(writer);
    assert(gate.mutationPending());
    assert(!writer.ready());
    auto denied = gate.tryEnterTransmit();
    assert(!denied);

    first.reset();
    assert(!writer.ready());
    second.reset();
    assert(writer.ready());
    assert(writer.finish());

    auto after = gate.tryEnterTransmit();
    assert(after);
    after.reset();
    assert(gate.activeTransmitters() == 0);
}

static void testSingleWriterAndCancellation()
{
    RTW88TxStateGate gate;
    auto writer = gate.tryBeginMutation();
    assert(writer);
    auto otherWriter = gate.tryBeginMutation();
    assert(!otherWriter);
    auto denied = gate.tryEnterTransmit();
    assert(!denied);
    writer.cancel();

    auto admitted = gate.tryEnterTransmit();
    assert(admitted);
    auto writerWithReader = gate.tryBeginMutation();
    assert(writerWithReader);
    assert(!writerWithReader.ready());
    assert(gate.activeTransmitters() == 1);
    writerWithReader.cancel();

    auto secondReader = gate.tryEnterTransmit();
    assert(secondReader);
    admitted.reset();
    secondReader.reset();
}

static void testWriterDowngradeIsGapFree()
{
    RTW88TxStateGate gate;
    auto writer = gate.tryBeginMutation();
    assert(writer && writer.ready());

    auto downgraded = writer.downgrade();
    assert(downgraded);
    assert(!gate.mutationPending());
    assert(gate.activeTransmitters() == 1);

    /* A new writer may close admission, but it must see the downgraded reader
     * and wait until the handshake submit completes. */
    auto nextWriter = gate.tryBeginMutation();
    assert(nextWriter);
    assert(!nextWriter.ready());
    assert(!gate.tryEnterTransmit());

    downgraded.reset();
    assert(nextWriter.ready());
    assert(nextWriter.finish());
    assert(gate.activeTransmitters() == 0);
    assert(!gate.mutationPending());
}

static void testPerCallEapolProtectionDoesNotLeakAcrossTransmitters()
{
    std::atomic<unsigned> incorrect{0};
    std::thread groupM2([&]() {
        for (unsigned i = 0; i < 200000; ++i) {
            const bool protectedFrame = RTW88ShouldProtectTxFrame(
                true, true, 0x888e, 0x888e, true);
            if (!protectedFrame)
                incorrect.fetch_add(1, std::memory_order_relaxed);
        }
    });
    std::thread ordinaryEapol([&]() {
        for (unsigned i = 0; i < 200000; ++i) {
            const bool protectedFrame = RTW88ShouldProtectTxFrame(
                true, true, 0x888e, 0x888e, false);
            if (protectedFrame)
                incorrect.fetch_add(1, std::memory_order_relaxed);
        }
    });
    groupM2.join();
    ordinaryEapol.join();
    assert(incorrect.load(std::memory_order_relaxed) == 0);
}

static void testFourACStressWithWriterBarriers()
{
    RTW88TxStateGate gate;
    std::atomic<unsigned> liveReaders{0};
    std::atomic<unsigned> liveWriters{0};
    std::atomic<unsigned> overlapFailures{0};
    std::atomic<unsigned> accepted{0};
    std::atomic<bool> start{false};
    constexpr unsigned kThreads = 4;
    constexpr unsigned kIterations = 100000;
    std::vector<std::thread> workers;

    for (unsigned ac = 0; ac < kThreads; ++ac) {
        workers.emplace_back([&]() {
            while (!start.load(std::memory_order_acquire))
                std::this_thread::yield();
            for (unsigned i = 0; i < kIterations; ++i) {
                auto lease = gate.tryEnterTransmit();
                if (!lease) {
                    std::this_thread::yield();
                    continue;
                }
                const unsigned n =
                    liveReaders.fetch_add(1, std::memory_order_acq_rel) + 1;
                if (liveWriters.load(std::memory_order_acquire) != 0)
                    overlapFailures.fetch_add(1, std::memory_order_relaxed);
                accepted.fetch_add(1, std::memory_order_relaxed);
                if ((i & 31U) == 0)
                    std::this_thread::yield();
                if (n == 0)
                    overlapFailures.fetch_add(1, std::memory_order_relaxed);
                liveReaders.fetch_sub(1, std::memory_order_acq_rel);
            }
        });
    }

    std::thread writerThread([&]() {
        start.store(true, std::memory_order_release);
        unsigned completed = 0;
        while (completed < 2000) {
            auto writer = gate.tryBeginMutation();
            if (!writer) {
                std::this_thread::yield();
                continue;
            }
            while (!writer.ready())
                std::this_thread::yield();
            liveWriters.fetch_add(1, std::memory_order_acq_rel);
            if (liveReaders.load(std::memory_order_acquire) != 0 ||
                gate.activeTransmitters() != 0)
                overlapFailures.fetch_add(1, std::memory_order_relaxed);
            std::this_thread::yield();
            liveWriters.fetch_sub(1, std::memory_order_acq_rel);
            assert(writer.finish());
            ++completed;
        }
    });

    writerThread.join();
    for (auto &worker : workers)
        worker.join();

    assert(accepted.load(std::memory_order_relaxed) > 0);
    assert(overlapFailures.load(std::memory_order_relaxed) == 0);
    assert(liveReaders.load(std::memory_order_relaxed) == 0);
    assert(liveWriters.load(std::memory_order_relaxed) == 0);
    assert(gate.activeTransmitters() == 0);
    assert(!gate.mutationPending());
}

int main()
{
    testBasicAdmissionAndDrain();
    testSingleWriterAndCancellation();
    testWriterDowngradeIsGapFree();
    testPerCallEapolProtectionDoesNotLeakAcrossTransmitters();
    testFourACStressWithWriterBarriers();
    std::puts("PASS: admission/drain, writer exclusivity/cancellation, gap-free writer downgrade, per-frame EAPOL policy, four-AC stress");
    return 0;
}
