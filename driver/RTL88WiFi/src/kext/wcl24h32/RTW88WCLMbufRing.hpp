/* SPDX-License-Identifier: GPL-2.0-only
 * Fixed-capacity lock-free MPMC ring for owned pointers (mbufs or Skywalk packets).
 *
 * The ring does not allocate after reset(). It is safe for concurrent producers
 * and one or more consumers. reset() is lifecycle-only and must run after every
 * producer and consumer has been quiesced. A successful push transfers pointer
 * ownership to the ring; a failed push leaves ownership with the caller.
 */
#pragma once

#include <stdint.h>
#include <stddef.h>

// The bounded sequence algorithm uses a power-of-two capacity for masking.
template <typename T, uint32_t Capacity>
class RTW88WCLMbufRing final {
    static_assert(Capacity >= 2, "RX ring capacity must be at least two");
    static_assert((Capacity & (Capacity - 1)) == 0,
                  "RX ring capacity must be a power of two");

    struct Cell {
        volatile size_t sequence;
        T value;
    };

public:
    void reset()
    {
        for (size_t i = 0; i < Capacity; ++i) {
            _cells[i].value = T{};
            __atomic_store_n(&_cells[i].sequence, i, __ATOMIC_RELAXED);
        }
        __atomic_store_n(&_enqueuePosition, 0, __ATOMIC_RELAXED);
        __atomic_store_n(&_dequeuePosition, 0, __ATOMIC_RELAXED);
    }

    bool push(const T &value)
    {
        if (!value)
            return false;

        size_t position = __atomic_load_n(&_enqueuePosition, __ATOMIC_RELAXED);
        Cell *cell = nullptr;
        for (;;) {
            cell = &_cells[position & (Capacity - 1)];
            const size_t sequence = __atomic_load_n(&cell->sequence,
                                                    __ATOMIC_ACQUIRE);
            const intptr_t difference = static_cast<intptr_t>(sequence) -
                                       static_cast<intptr_t>(position);
            if (difference == 0) {
                size_t expected = position;
                if (__atomic_compare_exchange_n(&_enqueuePosition, &expected,
                                                position + 1, false,
                                                __ATOMIC_RELAXED,
                                                __ATOMIC_RELAXED))
                    break;
                position = expected;
            } else if (difference < 0) {
                return false; // bounded queue full; caller keeps ownership
            } else {
                position = __atomic_load_n(&_enqueuePosition,
                                           __ATOMIC_RELAXED);
            }
        }

        cell->value = value;
        __atomic_store_n(&cell->sequence, position + 1, __ATOMIC_RELEASE);
        return true;
    }

    bool pop(T *out)
    {
        if (!out)
            return false;

        size_t position = __atomic_load_n(&_dequeuePosition, __ATOMIC_RELAXED);
        Cell *cell = nullptr;
        for (;;) {
            cell = &_cells[position & (Capacity - 1)];
            const size_t sequence = __atomic_load_n(&cell->sequence,
                                                    __ATOMIC_ACQUIRE);
            const intptr_t difference = static_cast<intptr_t>(sequence) -
                                       static_cast<intptr_t>(position + 1);
            if (difference == 0) {
                size_t expected = position;
                if (__atomic_compare_exchange_n(&_dequeuePosition, &expected,
                                                position + 1, false,
                                                __ATOMIC_RELAXED,
                                                __ATOMIC_RELAXED))
                    break;
                position = expected;
            } else if (difference < 0) {
                return false; // empty or a producer has not published yet
            } else {
                position = __atomic_load_n(&_dequeuePosition,
                                           __ATOMIC_RELAXED);
            }
        }

        *out = cell->value;
        cell->value = T{};
        __atomic_store_n(&cell->sequence, position + Capacity,
                         __ATOMIC_RELEASE);
        return true;
    }

    bool empty() const
    {
        const size_t position = __atomic_load_n(&_dequeuePosition,
                                                __ATOMIC_RELAXED);
        const Cell *cell = &_cells[position & (Capacity - 1)];
        const size_t sequence = __atomic_load_n(&cell->sequence,
                                                __ATOMIC_ACQUIRE);
        const intptr_t difference = static_cast<intptr_t>(sequence) -
                                   static_cast<intptr_t>(position + 1);
        return difference < 0;
    }

    uint32_t approximateSize() const
    {
        const size_t enqueued = __atomic_load_n(&_enqueuePosition,
                                               __ATOMIC_ACQUIRE);
        const size_t dequeued = __atomic_load_n(&_dequeuePosition,
                                                __ATOMIC_ACQUIRE);
        const size_t count = enqueued >= dequeued ? enqueued - dequeued : 0;
        return count > Capacity ? Capacity : static_cast<uint32_t>(count);
    }

    static constexpr uint32_t capacity() { return Capacity; }

private:
    alignas(64) volatile size_t _enqueuePosition = 0;
    alignas(64) volatile size_t _dequeuePosition = 0;
    alignas(64) Cell _cells[Capacity] = {};
};
