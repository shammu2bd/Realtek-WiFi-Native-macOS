/* SPDX-License-Identifier: GPL-2.0-only
 * Lock-free state for one 24H32 Skywalk registration/deregistration transaction.
 *
 * Queue/pool lifetime is pinned from the instant registration begins until
 * deregistration has completed. A failed rollback moves the owner to the
 * terminal quarantined state; it must not release callback or queue owners.
 */
#pragma once

#include <stdint.h>

namespace RTW88WCLRegistrationTransaction {

enum class State : uint32_t {
    kUnregistered = 0,
    kRegistering = 1,
    kRegistered = 2,
    kDeregistering = 3,
    kQuarantined = 4
};

class Transaction final {
public:
    Transaction() : _state(static_cast<uint32_t>(State::kUnregistered)) {}

    void resetForFreshOwner()
    {
        __atomic_store_n(&_state,
                         static_cast<uint32_t>(State::kUnregistered),
                         __ATOMIC_RELEASE);
    }

    bool beginRegistration()
    {
        return transition(State::kUnregistered, State::kRegistering);
    }

    bool commitRegistration()
    {
        return transition(State::kRegistering, State::kRegistered);
    }

    bool abortRegistration()
    {
        return transition(State::kRegistering, State::kUnregistered);
    }

    bool beginDeregistration()
    {
        return transition(State::kRegistered, State::kDeregistering);
    }

    bool commitDeregistration()
    {
        return transition(State::kDeregistering, State::kUnregistered);
    }

    /* A failed Apple deregistration leaves the QueueSet live. Restore the
     * registered state so a later stop can retry instead of freeing owners. */
    bool abortDeregistration()
    {
        return transition(State::kDeregistering, State::kRegistered);
    }

    /* The external side-effect may have completed while local state could not
     * be reconciled. Quarantine is intentionally terminal and owns resources. */
    void quarantine()
    {
        __atomic_store_n(&_state, static_cast<uint32_t>(State::kQuarantined),
                         __ATOMIC_RELEASE);
    }

    State state() const
    {
        return static_cast<State>(__atomic_load_n(&_state, __ATOMIC_ACQUIRE));
    }

    bool isRegistered() const
    {
        return state() == State::kRegistered;
    }

    bool ownsQueues() const
    {
        return state() != State::kUnregistered;
    }

    bool isInProgress() const
    {
        const State current = state();
        return current == State::kRegistering ||
               current == State::kDeregistering;
    }

    bool isQuarantined() const
    {
        return state() == State::kQuarantined;
    }

private:
    bool transition(State expectedState, State desiredState)
    {
        uint32_t expected = static_cast<uint32_t>(expectedState);
        return __atomic_compare_exchange_n(
            &_state, &expected, static_cast<uint32_t>(desiredState), false,
            __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    }

    volatile uint32_t _state;
};

} // namespace RTW88WCLRegistrationTransaction
