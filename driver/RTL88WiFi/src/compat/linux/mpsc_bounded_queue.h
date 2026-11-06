/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * Bounded sequence-numbered MPSC pointer queue.
 *
 * Multiple producers may publish concurrently; exactly one consumer may pop.
 * Per-slot sequence values prevent the ABA/reuse race inherent in a Treiber
 * stack whose consumer detaches and frees nodes while producers retain an
 * observed head pointer. Queue-full is explicit and never triggers sync free.
 */
#ifndef _RTW88_MPSC_BOUNDED_QUEUE_H
#define _RTW88_MPSC_BOUNDED_QUEUE_H

#include <stdbool.h>
#include <stdint.h>

#define RTW88_MPSC_QUEUE_CAPACITY 2048U
#define RTW88_MPSC_QUEUE_MASK (RTW88_MPSC_QUEUE_CAPACITY - 1U)

struct rtw88_mpsc_queue_slot {
    volatile uint32_t sequence;
    void *value;
};

struct rtw88_mpsc_bounded_queue {
    volatile uint32_t enqueue_pos;
    uint32_t dequeue_pos; /* single consumer only */
    struct rtw88_mpsc_queue_slot slots[RTW88_MPSC_QUEUE_CAPACITY];
};

static inline void
rtw88_mpsc_bounded_queue_init(struct rtw88_mpsc_bounded_queue *queue)
{
    __atomic_store_n(&queue->enqueue_pos, 0U, __ATOMIC_RELAXED);
    queue->dequeue_pos = 0U;
    for (uint32_t i = 0; i < RTW88_MPSC_QUEUE_CAPACITY; ++i) {
        queue->slots[i].value = 0;
        __atomic_store_n(&queue->slots[i].sequence, i, __ATOMIC_RELAXED);
    }
}

/* Lock-free MPSC producer. Returns false without reserving a slot when full. */
static inline bool
rtw88_mpsc_bounded_queue_enqueue(struct rtw88_mpsc_bounded_queue *queue,
                                void *value)
{
    if (!value)
        return false;

    uint32_t position =
        __atomic_load_n(&queue->enqueue_pos, __ATOMIC_RELAXED);
    struct rtw88_mpsc_queue_slot *slot;
    for (;;) {
        slot = &queue->slots[position & RTW88_MPSC_QUEUE_MASK];
        const uint32_t sequence =
            __atomic_load_n(&slot->sequence, __ATOMIC_ACQUIRE);
        const int32_t difference = (int32_t)(sequence - position);

        if (difference == 0) {
            if (__atomic_compare_exchange_n(&queue->enqueue_pos, &position,
                                            position + 1U, false,
                                            __ATOMIC_RELAXED,
                                            __ATOMIC_RELAXED))
                break;
        } else if (difference < 0) {
            return false;
        } else {
            position =
                __atomic_load_n(&queue->enqueue_pos, __ATOMIC_RELAXED);
        }
    }

    slot->value = value;
    __atomic_store_n(&slot->sequence, position + 1U, __ATOMIC_RELEASE);
    return true;
}

/* Exactly one consumer: the returned value is no longer owned by the queue. */
static inline void *
rtw88_mpsc_bounded_queue_dequeue(struct rtw88_mpsc_bounded_queue *queue)
{
    const uint32_t position = queue->dequeue_pos;
    struct rtw88_mpsc_queue_slot *slot =
        &queue->slots[position & RTW88_MPSC_QUEUE_MASK];
    const uint32_t sequence =
        __atomic_load_n(&slot->sequence, __ATOMIC_ACQUIRE);
    const int32_t difference = (int32_t)(sequence - (position + 1U));

    if (difference != 0)
        return 0;

    void *value = slot->value;
    slot->value = 0;
    __atomic_store_n(&slot->sequence,
                     position + RTW88_MPSC_QUEUE_CAPACITY,
                     __ATOMIC_RELEASE);
    queue->dequeue_pos = position + 1U;
    return value;
}

/* Call only after all producers and the sole consumer have been joined. */
static inline bool
rtw88_mpsc_bounded_queue_empty(const struct rtw88_mpsc_bounded_queue *queue)
{
    return __atomic_load_n(&queue->enqueue_pos, __ATOMIC_ACQUIRE) ==
           queue->dequeue_pos;
}

#endif /* _RTW88_MPSC_BOUNDED_QUEUE_H */
