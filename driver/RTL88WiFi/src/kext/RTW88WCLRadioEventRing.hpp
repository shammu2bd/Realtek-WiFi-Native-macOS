/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * Fixed-capacity event ring shared by the private WCL event dispatcher.
 * This header is deliberately independent of IOKit so its queue semantics
 * can be tested on the host toolchain.
 */
#pragma once

#include <stddef.h>

/* Single-owner ring: callers must provide external synchronization when the
 * producer and consumer can run concurrently. No allocation occurs after
 * construction, and enqueue/dequeue are O(1). */
template <typename T, size_t Capacity>
class RTW88WCLRadioEventRing final {
    static_assert(Capacity > 1, "event ring must have at least two slots");

public:
    bool push(const T &value)
    {
        if (_count == Capacity)
            return false;
        _items[_tail] = value;
        _tail = next(_tail);
        ++_count;
        return true;
    }

    bool pop(T *out)
    {
        if (!out || _count == 0)
            return false;
        *out = _items[_head];
        _head = next(_head);
        --_count;
        return true;
    }

    /* Replace the newest slot only when it matches. Restricting coalescing
     * to adjacent telemetry preserves ordering around scan/link transitions. */
    template <typename Predicate>
    bool replaceLast(Predicate predicate, const T &value)
    {
        if (_count == 0)
            return false;
        const size_t index = (_tail + Capacity - 1) % Capacity;
        if (!predicate(_items[index]))
            return false;
        _items[index] = value;
        return true;
    }

    /* Remove a logical (head-relative) slot while preserving FIFO order. */
    bool removeAt(size_t offset)
    {
        if (offset >= _count)
            return false;
        for (size_t i = offset; i + 1 < _count; ++i) {
            const size_t dst = (_head + i) % Capacity;
            const size_t src = (_head + i + 1) % Capacity;
            _items[dst] = _items[src];
        }
        _tail = (_tail + Capacity - 1) % Capacity;
        --_count;
        return true;
    }

    template <typename Predicate>
    bool removeFirst(Predicate predicate)
    {
        for (size_t offset = 0; offset < _count; ++offset) {
            const size_t index = (_head + offset) % Capacity;
            if (predicate(_items[index]))
                return removeAt(offset);
        }
        return false;
    }

    void clear()
    {
        _head = 0;
        _tail = 0;
        _count = 0;
    }

    size_t size() const { return _count; }
    bool empty() const { return _count == 0; }
    bool full() const { return _count == Capacity; }

private:
    static size_t next(size_t index) { return (index + 1) % Capacity; }

    T _items[Capacity] = {};
    size_t _head = 0;
    size_t _tail = 0;
    size_t _count = 0;
};
