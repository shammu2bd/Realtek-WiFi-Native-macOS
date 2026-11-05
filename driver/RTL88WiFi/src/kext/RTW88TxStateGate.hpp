/* SPDX-License-Identifier: GPL-2.0-only
 * Radio-wide admission barrier for concurrent native WMM TX submitters.
 *
 * Freestanding C++11: no allocation, sleeping, IOKit, locks, or callbacks.
 * A TX caller holds a TransmitLease from before it reads shared radio state
 * until the synchronous RTW88 ops->tx() call returns.
 *
 * A control writer obtains a MutationLease. Acquiring it closes TX admission
 * immediately; existing TX leases drain normally. The writer may mutate
 * protected state only after ready() reports zero active submitters.
 * Writers must poll/defer on a serialized passive control workloop rather
 * than wait or spin in a TX/interrupt callback.
 */
#pragma once
#include <stdint.h>

class RTW88TxStateGate {
public:
    static constexpr uint32_t kMutationBit = 0x80000000U;
    static constexpr uint32_t kReaderMask = 0x7fffffffU;

    class TransmitLease {
    public:
        TransmitLease() : _gate(nullptr) {}
        ~TransmitLease() { reset(); }
        TransmitLease(TransmitLease &&other) : _gate(other._gate) { other._gate = nullptr; }
        TransmitLease &operator=(TransmitLease &&other)
        {
            if (this != &other) {
                reset();
                _gate = other._gate;
                other._gate = nullptr;
            }
            return *this;
        }
        TransmitLease(const TransmitLease &) = delete;
        TransmitLease &operator=(const TransmitLease &) = delete;
        explicit operator bool() const { return _gate != nullptr; }
        void reset()
        {
            if (_gate) {
                __atomic_fetch_sub(&_gate->_state, 1U, __ATOMIC_RELEASE);
                _gate = nullptr;
            }
        }
    private:
        friend class RTW88TxStateGate;
        explicit TransmitLease(RTW88TxStateGate *gate) : _gate(gate) {}
        RTW88TxStateGate *_gate;
    };

    class MutationLease {
    public:
        MutationLease() : _gate(nullptr) {}
        ~MutationLease() { cancel(); }
        MutationLease(MutationLease &&other) : _gate(other._gate) { other._gate = nullptr; }
        MutationLease &operator=(MutationLease &&other)
        {
            if (this != &other) {
                cancel();
                _gate = other._gate;
                other._gate = nullptr;
            }
            return *this;
        }
        MutationLease(const MutationLease &) = delete;
        MutationLease &operator=(const MutationLease &) = delete;
        explicit operator bool() const { return _gate != nullptr; }
        bool ready() const
        {
            return _gate &&
                __atomic_load_n(&_gate->_state, __ATOMIC_ACQUIRE) == kMutationBit;
        }
        bool finish()
        {
            if (!ready())
                return false;
            __atomic_store_n(&_gate->_state, 0U, __ATOMIC_RELEASE);
            _gate = nullptr;
            return true;
        }
        void cancel()
        {
            if (!_gate)
                return;
            __atomic_fetch_and(&_gate->_state, kReaderMask, __ATOMIC_RELEASE);
            _gate = nullptr;
        }
    private:
        friend class RTW88TxStateGate;
        explicit MutationLease(RTW88TxStateGate *gate) : _gate(gate) {}
        RTW88TxStateGate *_gate;
    };

    RTW88TxStateGate() : _state(0) {}
    RTW88TxStateGate(const RTW88TxStateGate &) = delete;
    RTW88TxStateGate &operator=(const RTW88TxStateGate &) = delete;

    TransmitLease tryEnterTransmit()
    {
        uint32_t observed = __atomic_load_n(&_state, __ATOMIC_ACQUIRE);
        for (;;) {
            if (observed & kMutationBit)
                return TransmitLease();
            if ((observed & kReaderMask) == kReaderMask)
                return TransmitLease();
            const uint32_t desired = observed + 1U;
            if (__atomic_compare_exchange_n(&_state, &observed, desired, false,
                                            __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
                return TransmitLease(this);
        }
    }

    MutationLease tryBeginMutation()
    {
        uint32_t observed = __atomic_load_n(&_state, __ATOMIC_ACQUIRE);
        for (;;) {
            if (observed & kMutationBit)
                return MutationLease();
            const uint32_t desired = observed | kMutationBit;
            if (__atomic_compare_exchange_n(&_state, &observed, desired, false,
                                            __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
                return MutationLease(this);
        }
    }

    uint32_t activeTransmitters() const
    {
        return __atomic_load_n(&_state, __ATOMIC_ACQUIRE) & kReaderMask;
    }
    bool mutationPending() const
    {
        return (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) & kMutationBit) != 0;
    }

private:
    volatile uint32_t _state;
};
