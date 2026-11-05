/* SPDX-License-Identifier: GPL-2.0-only
 * Atomic publication of the active uplink TX Block Ack agreement.
 *
 * The active bit and TID are one indivisible snapshot. TX submitters on
 * different WMM queues must never observe an active flag paired with a TID
 * from another ADDBA/DELBA generation.
 */
#pragma once
#include <stdint.h>

class RTW88TxBAState {
public:
    static constexpr uint32_t kActiveBit = 0x80000000U;
    static constexpr uint32_t kTidMask = 0x0000000fU;

    RTW88TxBAState() : _state(0) {}
    RTW88TxBAState(const RTW88TxBAState &) = delete;
    RTW88TxBAState &operator=(const RTW88TxBAState &) = delete;

    uint32_t snapshot() const
    {
        return __atomic_load_n(&_state, __ATOMIC_ACQUIRE);
    }

    bool active() const
    {
        return (snapshot() & kActiveBit) != 0;
    }

    uint8_t tid() const
    {
        return static_cast<uint8_t>(snapshot() & kTidMask);
    }

    bool activeForTid(uint8_t tid) const
    {
        const uint32_t state = snapshot();
        return (state & kActiveBit) != 0 &&
               (state & kTidMask) == (static_cast<uint32_t>(tid) & kTidMask);
    }

    void activate(uint8_t tid)
    {
        __atomic_store_n(&_state, kActiveBit |
                         (static_cast<uint32_t>(tid) & kTidMask),
                         __ATOMIC_RELEASE);
    }

    void clear()
    {
        __atomic_store_n(&_state, 0U, __ATOMIC_RELEASE);
    }

private:
    volatile uint32_t _state;
};
