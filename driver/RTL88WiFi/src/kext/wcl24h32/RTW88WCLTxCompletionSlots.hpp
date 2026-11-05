/* SPDX-License-Identifier: GPL-2.0-only
 * Fixed-capacity completion tickets for the native WCL TX adapter.
 *
 * Multiple RTW88 completion contexts may publish concurrently. The Skywalk
 * packet operations are deliberately kept out of complete(); a workloop-side
 * consumer claims completed tickets and performs the deferred queue handoff.
 */
#pragma once

#include <stdint.h>

/* Freestanding so the state machine can be stress-tested outside the kernel. */
template <uint32_t Capacity>
class RTW88WCLTxCompletionSlots {
    static_assert(Capacity > 0, "completion slot capacity must be non-zero");

public:
    enum : uint32_t {
        kFree = 0,
        kReserved,
        kSubmitted,
        kCompleting,
        kCompleted,
        kDraining
    };

    struct Ticket {
        volatile uint32_t state;
        void *packet;
        uint32_t transmitted;
    };

    void reset()
    {
        for (uint32_t i = 0; i < Capacity; ++i) {
            _slots[i].packet = nullptr;
            _slots[i].transmitted = 0;
            __atomic_store_n(&_slots[i].state, kFree, __ATOMIC_RELAXED);
        }
    }

    /* Called before handing a packet to RTW88. The caller owns the packet
     * retain associated with the returned ticket. */
    Ticket *reserve(void *packet)
    {
        if (!packet)
            return nullptr;

        for (uint32_t i = 0; i < Capacity; ++i) {
            Ticket *ticket = &_slots[i];
            uint32_t expected = kFree;
            if (!__atomic_compare_exchange_n(&ticket->state, &expected,
                                             kReserved, false,
                                             __ATOMIC_ACQ_REL,
                                             __ATOMIC_ACQUIRE))
                continue;

            ticket->packet = packet;
            ticket->transmitted = 0;
            __atomic_store_n(&ticket->state, kSubmitted, __ATOMIC_RELEASE);
            return ticket;
        }
        return nullptr;
    }

    /* Safe for the RTW88 completion callback: bounded atomics only, no
     * allocation, locks, Skywalk calls, or packet release. */
    static bool complete(Ticket *ticket, bool transmitted)
    {
        if (!ticket)
            return false;
        uint32_t expected = kSubmitted;
        if (!__atomic_compare_exchange_n(&ticket->state, &expected,
                                         kCompleting, false,
                                         __ATOMIC_ACQ_REL,
                                         __ATOMIC_ACQUIRE))
            return false;
        ticket->transmitted = transmitted ? 1U : 0U;
        __atomic_store_n(&ticket->state, kCompleted, __ATOMIC_RELEASE);
        return true;
    }

    /* Single consumer, called from the adapter's deferred/workloop context. */
    Ticket *claimCompleted()
    {
        for (uint32_t i = 0; i < Capacity; ++i) {
            Ticket *ticket = &_slots[i];
            uint32_t expected = kCompleted;
            if (__atomic_compare_exchange_n(&ticket->state, &expected,
                                            kDraining, false,
                                            __ATOMIC_ACQ_REL,
                                            __ATOMIC_ACQUIRE))
                return ticket;
        }
        return nullptr;
    }

    /* A failed deferred Skywalk handoff is not terminal. Return the
     * ticket to Completed without changing its packet or result so the
     * serialized consumer can retry later. */
    static bool retry(Ticket *ticket)
    {
        if (!ticket)
            return false;
        uint32_t expected = kDraining;
        return __atomic_compare_exchange_n(&ticket->state, &expected,
                                           kCompleted, false,
                                           __ATOMIC_RELEASE,
                                           __ATOMIC_ACQUIRE);
    }

    static void finish(Ticket *ticket)
    {
        if (!ticket)
            return;
        ticket->packet = nullptr;
        ticket->transmitted = 0;
        __atomic_store_n(&ticket->state, kFree, __ATOMIC_RELEASE);
    }

    static void *packet(const Ticket *ticket)
    {
        return ticket ? ticket->packet : nullptr;
    }

    static bool transmitted(const Ticket *ticket)
    {
        return ticket && ticket->transmitted != 0;
    }

    bool hasOutstanding() const
    {
        for (uint32_t i = 0; i < Capacity; ++i) {
            if (__atomic_load_n(&_slots[i].state, __ATOMIC_ACQUIRE) != kFree)
                return true;
        }
        return false;
    }

    uint32_t outstandingCount() const
    {
        uint32_t count = 0;
        for (uint32_t i = 0; i < Capacity; ++i) {
            if (__atomic_load_n(&_slots[i].state, __ATOMIC_ACQUIRE) != kFree)
                ++count;
        }
        return count;
    }

    static constexpr uint32_t capacity() { return Capacity; }

private:
    Ticket _slots[Capacity] = {};
};
