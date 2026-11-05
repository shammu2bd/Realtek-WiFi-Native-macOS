/* SPDX-License-Identifier: GPL-2.0-only
 * Freestanding bind/quiesce gate for the native TX submission adapter.
 *
 * A successful enterSubmission() pins the bound radio/pool pair until the
 * matching leaveSubmission(). Unbind first closes admission, then waits for
 * entrants and completion tickets before releasing either dependency.
 */
#pragma once

#include <stdint.h>

class RTW88WCLTxSubmissionGate {
public:
    enum : uint32_t {
        kUnbound = 0,
        kBinding,
        kBound,
        kQuiescing
    };

    bool beginBind()
    {
        uint32_t expected = kUnbound;
        return __atomic_compare_exchange_n(&_state, &expected, kBinding,
                                           false, __ATOMIC_ACQ_REL,
                                           __ATOMIC_ACQUIRE);
    }

    bool finishBind()
    {
        uint32_t expected = kBinding;
        return __atomic_compare_exchange_n(&_state, &expected, kBound,
                                           false, __ATOMIC_ACQ_REL,
                                           __ATOMIC_ACQUIRE);
    }

    void abortBind()
    {
        uint32_t expected = kBinding;
        (void)__atomic_compare_exchange_n(&_state, &expected, kUnbound,
                                          false, __ATOMIC_ACQ_REL,
                                          __ATOMIC_ACQUIRE);
    }

    bool enterSubmission()
    {
        if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) != kBound)
            return false;

        __atomic_add_fetch(&_inFlight, 1U, __ATOMIC_ACQ_REL);
        if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == kBound)
            return true;

        __atomic_sub_fetch(&_inFlight, 1U, __ATOMIC_ACQ_REL);
        return false;
    }

    void leaveSubmission()
    {
        __atomic_sub_fetch(&_inFlight, 1U, __ATOMIC_ACQ_REL);
    }

    /* Idempotent once quiescing. Binding may not be interrupted or unbound. */
    bool beginUnbind()
    {
        for (;;) {
            const uint32_t state =
                __atomic_load_n(&_state, __ATOMIC_ACQUIRE);
            if (state == kUnbound)
                return __atomic_load_n(&_inFlight, __ATOMIC_ACQUIRE) == 0;
            if (state == kQuiescing)
                return true;
            if (state != kBound)
                return false;

            uint32_t expected = kBound;
            if (__atomic_compare_exchange_n(&_state, &expected, kQuiescing,
                                            false, __ATOMIC_ACQ_REL,
                                            __ATOMIC_ACQUIRE))
                return true;
        }
    }

    bool canFinishUnbind() const
    {
        return __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == kQuiescing &&
               __atomic_load_n(&_inFlight, __ATOMIC_ACQUIRE) == 0;
    }

    bool finishUnbind()
    {
        if (!canFinishUnbind())
            return false;
        uint32_t expected = kQuiescing;
        return __atomic_compare_exchange_n(&_state, &expected, kUnbound,
                                           false, __ATOMIC_ACQ_REL,
                                           __ATOMIC_ACQUIRE);
    }

    uint32_t state() const
    {
        return __atomic_load_n(&_state, __ATOMIC_ACQUIRE);
    }

    uint32_t inFlight() const
    {
        return __atomic_load_n(&_inFlight, __ATOMIC_ACQUIRE);
    }

    bool isBound() const { return state() == kBound; }
    bool isUnbound() const { return state() == kUnbound && inFlight() == 0; }

private:
    volatile uint32_t _state = kUnbound;
    volatile uint32_t _inFlight = 0;
};
