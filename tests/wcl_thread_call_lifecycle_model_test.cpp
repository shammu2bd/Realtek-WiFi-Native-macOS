#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

/* Portable model of the lifecycle contract; this is not an XNU runtime test. */
class AdmissionGate {
public:
    static constexpr uint32_t Closed = 0x80000000U;
    static constexpr uint32_t Active = 0x7FFFFFFFU;

    bool enter() {
        uint32_t state = gate.load(std::memory_order_acquire);
        for (;;) {
            if (state & Closed) return false;
            if ((state & Active) == Active) return false;
            if (gate.compare_exchange_weak(state, state + 1U,
                    std::memory_order_acq_rel, std::memory_order_acquire))
                return true;
        }
    }
    void leave() { gate.fetch_sub(1U, std::memory_order_release); }
    void closeAndJoinProducers() {
        gate.fetch_or(Closed, std::memory_order_acq_rel);
        while ((gate.load(std::memory_order_acquire) & Active) != 0)
            std::this_thread::yield();
    }
    bool closedAndIdle() const {
        const auto state = gate.load(std::memory_order_acquire);
        return (state & Closed) && (state & Active) == 0;
    }
private:
    std::atomic<uint32_t> gate{0};
};

/* Models the documented non-ONCE XNU case: cancel_wait may cancel a queued
 * submission and return while a separate invocation is still executing. */
class NonOnceThreadCallModel {
public:
    void submit() {
        std::lock_guard<std::mutex> guard(lock);
        assert(!freed);
        ++pending;
        ++submitted;
    }
    void beginOne() {
        std::lock_guard<std::mutex> guard(lock);
        assert(pending);
        --pending;
        ++active;
    }
    bool cancelWait() {
        std::lock_guard<std::mutex> guard(lock);
        if (pending) {
            --pending; // cancelled=true: this path does not join active work
            return true;
        }
        while (active)
            changed.wait(lock);
        return false;
    }
    bool isActive() {
        std::lock_guard<std::mutex> guard(lock);
        return pending != 0 || active != 0;
    }
    void finishOne() {
        std::lock_guard<std::mutex> guard(lock);
        assert(active);
        --active;
        ++finished;
        changed.notify_all();
    }
    bool freeIfIdle() {
        std::lock_guard<std::mutex> guard(lock);
        if (pending || active) return false;
        freed = true;
        return true;
    }
    uint64_t submitCount() const { return submitted; }
    uint64_t finishCount() const { return finished; }
private:
    mutable std::mutex lock;
    std::condition_variable changed;
    uint32_t pending = 0;
    uint32_t active = 0;
    uint64_t submitted = 0;
    uint64_t finished = 0;
    bool freed = false;
};

int main() {
    /* Deterministic proof of the cancel-wait edge: one call is executing,
     * another submission is pending; cancellation returns but isActive stays
     * true until the active invocation completes.
     */
    NonOnceThreadCallModel call;
    AdmissionGate callProducers;
    assert(callProducers.enter());
    call.submit();
    callProducers.leave();
    call.beginOne();
    call.submit();                 // a re-enqueue while callback 1 is in flight
    assert(call.cancelWait());     // pending call cancelled
    assert(call.isActive());       // active invocation was not joined
    assert(!call.freeIfIdle());    // storage must remain live
    call.finishOne();
    while (call.isActive()) std::this_thread::yield();
    assert(call.freeIfIdle());
    assert(call.submitCount() == 2);
    assert(call.finishCount() == 1); // one invocation cancelled, one finished
    callProducers.closeAndJoinProducers();
    assert(callProducers.closedAndIdle());
    assert(!callProducers.enter());

    /* Race many producers with shutdown. After closeAndJoinProducers returns,
     * no producer may remain between admission and its thread_call_enter.
     */
    AdmissionGate gate;
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> accepted{0};
    std::vector<std::thread> producers;
    for (unsigned p = 0; p < 12; ++p) {
        producers.emplace_back([&] {
            while (!stop.load(std::memory_order_acquire)) {
                if (gate.enter()) {
                    accepted.fetch_add(1, std::memory_order_relaxed);
                    std::this_thread::yield();
                    gate.leave();
                } else {
                    break;
                }
            }
        });
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    gate.closeAndJoinProducers();
    stop.store(true, std::memory_order_release);
    for (auto &thread : producers) thread.join();
    const auto acceptedAtClose = accepted.load(std::memory_order_acquire);
    assert(gate.closedAndIdle());
    assert(!gate.enter());
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    assert(accepted.load(std::memory_order_acquire) == acceptedAtClose);
    return 0;
}
