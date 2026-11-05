#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLAcquisitionJournal.hpp"

#include <cassert>
#include <cstdint>

using RTW88WCLAcquisitionJournal::Journal;
using RTW88WCLAcquisitionJournal::Phase;
using RTW88WCLAcquisitionJournal::Resource;
using RTW88WCLAcquisitionJournal::kAcquisitionOrder;
using RTW88WCLAcquisitionJournal::kResourceCount;

static void verifyRollback(Journal &journal, uint32_t acquired)
{
    assert(journal.beginRollback());
    assert(journal.phase() == Phase::kRollingBack);

    for (uint32_t i = acquired; i > 0; --i) {
        Resource released = Resource::kInvalid;
        assert(journal.popRollback(&released));
        assert(released == kAcquisitionOrder[i - 1]);
    }

    Resource extra = Resource::kInvalid;
    assert(!journal.popRollback(&extra));
    assert(journal.finishRollback());
    assert(journal.isEmpty());

    /* Repeated stop/free teardown must remain harmless after full rollback. */
    assert(journal.beginRollback());
    assert(journal.finishRollback());
    assert(journal.isEmpty());
}

int main()
{
    /* Fault injection: fail each acquisition point, including the first one.
     * Only successful prior acquisitions are journaled and rolled back.
     */
    for (uint32_t failAt = 0; failAt < kResourceCount; ++failAt) {
        Journal journal;
        assert(journal.begin());

        for (uint32_t i = 0; i < failAt; ++i)
            assert(journal.record(kAcquisitionOrder[i]));

        assert(!journal.commit());
        assert(journal.count() == failAt);
        verifyRollback(journal, failAt);
    }

    /* Full successful acquisition commits exactly once. */
    Journal committed;
    assert(committed.begin());
    for (uint32_t i = 0; i < kResourceCount; ++i)
        assert(committed.record(kAcquisitionOrder[i]));
    assert(committed.commit());
    assert(committed.isCommitted());
    assert(!committed.record(Resource::kTXPool));
    assert(!committed.commit());
    verifyRollback(committed, kResourceCount);

    /* Reject out-of-order, duplicate, and invalid TX-array index inputs. */
    Journal invalid;
    Resource txQueue = Resource::kInvalid;
    assert(invalid.begin());
    assert(!invalid.record(Resource::kRXPool));
    assert(invalid.record(Resource::kTXPool));
    assert(!invalid.record(Resource::kTXPool));
    assert(RTW88WCLAcquisitionJournal::txSubmissionResource(0, &txQueue));
    assert(txQueue == Resource::kTXSubmission0);
    assert(RTW88WCLAcquisitionJournal::txSubmissionResource(3, &txQueue));
    assert(txQueue == Resource::kTXSubmission3);
    assert(!RTW88WCLAcquisitionJournal::txSubmissionResource(4, &txQueue));
    assert(!RTW88WCLAcquisitionJournal::txSubmissionResource(1, nullptr));
    verifyRollback(invalid, 1);

    /* Commit is prohibited until every resource has been acquired. */
    Journal incomplete;
    assert(incomplete.begin());
    assert(incomplete.record(Resource::kTXPool));
    assert(!incomplete.commit());
    assert(!incomplete.begin());
    verifyRollback(incomplete, 1);

    return 0;
}
