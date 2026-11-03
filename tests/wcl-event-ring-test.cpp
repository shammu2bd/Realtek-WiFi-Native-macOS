/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * Host-side tests for the allocation-free WCL event ring.
 */
#include "../driver/RTL88WiFi/src/kext/RTW88WCLRadioEventRing.hpp"

#include <cassert>
#include <cstdint>
#include <cstdio>

struct TestEvent {
    uint32_t type;
    uint32_t generation;
    uint32_t value;
};

int main()
{
    RTW88WCLRadioEventRing<TestEvent, 4> ring;
    TestEvent out = {};

    assert(ring.empty());
    assert(!ring.pop(&out));
    assert(!ring.pop(nullptr));

    assert(ring.push({1, 1, 10}));
    assert(ring.push({2, 1, 20}));
    assert(ring.push({3, 1, 30}));
    assert(ring.push({4, 1, 40}));
    assert(ring.full());
    assert(!ring.push({5, 1, 50}));

    assert(ring.pop(&out) && out.type == 1 && out.value == 10);
    assert(ring.pop(&out) && out.type == 2 && out.value == 20);

    /* Wrap the tail, then verify logical remove preserves FIFO order. */
    assert(ring.push({5, 2, 50}));
    assert(ring.push({6, 2, 60}));
    assert(ring.size() == 4);
    assert(ring.removeAt(1));
    assert(ring.size() == 3);
    assert(ring.pop(&out) && out.type == 3);
    assert(ring.pop(&out) && out.type == 5);
    assert(ring.pop(&out) && out.type == 6);
    assert(ring.empty());

    /* replaceLast only coalesces adjacent telemetry, preserving ordering
     * around state-transition events. */
    assert(ring.push({7, 9, 70}));
    const bool replaced = ring.replaceLast(
        [](const TestEvent &event) { return event.type == 7; },
        TestEvent{7, 9, 99});
    assert(replaced);
    assert(ring.push({8, 9, 80}));
    const bool didNotCrossTransition = ring.replaceLast(
        [](const TestEvent &event) { return event.type == 7; },
        TestEvent{7, 9, 100});
    assert(!didNotCrossTransition);
    assert(ring.pop(&out) && out.type == 7 && out.value == 99);
    assert(ring.pop(&out) && out.type == 8 && out.value == 80);

    /* removeFirst can discard an advisory item to reserve room for a
     * higher-priority association/disconnect event. */
    assert(ring.push({9, 1, 1}));
    assert(ring.push({10, 1, 2}));
    assert(ring.push({11, 1, 3}));
    assert(ring.push({12, 1, 4}));
    assert(ring.removeFirst([](const TestEvent &event) { return event.type == 10; }));
    assert(ring.push({13, 1, 5}));
    assert(ring.pop(&out) && out.type == 9);
    assert(ring.pop(&out) && out.type == 11);
    assert(ring.pop(&out) && out.type == 12);
    assert(ring.pop(&out) && out.type == 13);

    ring.clear();
    assert(ring.empty());
    std::puts("WCL event ring: all tests passed");
    return 0;
}
