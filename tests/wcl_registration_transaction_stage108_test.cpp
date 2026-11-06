#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLRegistrationTransaction.hpp"

#include <cassert>

using RTW88WCLRegistrationTransaction::State;
using RTW88WCLRegistrationTransaction::Transaction;

int main()
{
    Transaction transaction;

    assert(transaction.state() == State::kUnregistered);
    assert(!transaction.isRegistered());
    assert(!transaction.ownsQueues());

    /* Registration is exclusive and pins queue/pool owners before entering
     * Apple's registration wrapper. */
    assert(transaction.beginRegistration());
    assert(transaction.state() == State::kRegistering);
    assert(transaction.ownsQueues());
    assert(transaction.isInProgress());
    assert(!transaction.beginRegistration());
    assert(!transaction.commitDeregistration());

    /* A registration failure returns to the only state in which queue
     * acquisition rollback is permitted. */
    assert(transaction.abortRegistration());
    assert(transaction.state() == State::kUnregistered);
    assert(!transaction.ownsQueues());

    /* Successful registration is committed only after the Apple wrapper
     * returns success. */
    assert(transaction.beginRegistration());
    assert(transaction.commitRegistration());
    assert(transaction.isRegistered());
    assert(transaction.ownsQueues());
    assert(!transaction.commitRegistration());
    assert(!transaction.beginRegistration());

    /* A failed Apple deregistration restores Registered so teardown can retry. */
    assert(transaction.beginDeregistration());
    assert(transaction.state() == State::kDeregistering);
    assert(transaction.ownsQueues());
    assert(transaction.abortDeregistration());
    assert(transaction.isRegistered());

    /* A later successful deregistration releases the queue-owner pin. */
    assert(transaction.beginDeregistration());
    assert(transaction.commitDeregistration());
    assert(transaction.state() == State::kUnregistered);
    assert(!transaction.ownsQueues());

    /* If an external rollback cannot be reconciled, quarantine is terminal
     * and continues to pin the queue/pool callback context. */
    assert(transaction.beginRegistration());
    transaction.quarantine();
    assert(transaction.isQuarantined());
    assert(transaction.ownsQueues());
    assert(!transaction.isRegistered());
    assert(!transaction.beginDeregistration());
    assert(!transaction.abortRegistration());

    return 0;
}
