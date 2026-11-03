/* Added on 2026-10-25 for RTL88WiFi 1.0.6; see the repository NOTICE.md. */
/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * RTW88BaPolicy.hpp — when to (re)negotiate the uplink Block Ack agreement.
 *
 * Header-only and free of kernel/IOKit dependencies so the code that ships in
 * the kext is also compiled by the host tests (tests/test-ba-recovery.py).
 *
 * Uplink A-MPDU aggregation exists only while a Block Ack agreement set up with
 * ADDBA is in force.  Before 1.0.6 the driver asked once, right after the keys
 * were installed.  If the AP later tore the agreement down (DELBA), declined
 * the request, or the response was lost, aggregation stayed off for the rest of
 * the association: the link stayed up but uploads ran as un-aggregated frames,
 * slow and erratic.  An AP can tear an agreement down for several reasons
 * (idle timeout, internal reset, steering).
 *
 * This keeps asking, with backoff, so a misbehaving AP that accepts and
 * immediately tears down again cannot turn into a request storm, and it starts
 * again from a short delay once an agreement has proven stable.
 */
#pragma once

#include <stdint.h>

namespace RTW88Ba {

/* How long to wait for an ADDBA response before treating it as lost. */
static const uint64_t kResponseTimeoutUS = 3ULL * 1000000ULL;

/* An agreement that lasted this long counts as stable: the backoff restarts. */
static const uint64_t kStableUS = 60ULL * 1000000ULL;

/* Delay before the next ADDBA request after `failures` consecutive failed or
 * short-lived agreements: 1, 2, 5, 10, 30, then 60 seconds. */
static inline uint64_t retryDelayUS(unsigned failures)
{
    static const uint32_t secs[] = {1, 2, 5, 10, 30, 60};
    return (uint64_t)secs[failures < 5 ? failures : 5] * 1000000ULL;
}

/* Plain data (no constructor), so it can live in an IOKit object and be reset
 * with reset().  Times are a monotonic microsecond counter from the caller. */
struct Recovery {
    bool     wanted;          /* an ADDBA should be sent when due            */
    uint64_t dueUS;           /* earliest time of that ADDBA                 */
    unsigned failures;        /* consecutive failed / short-lived agreements */
    uint64_t activeSinceUS;   /* when the current agreement began; 0 = none  */
    uint64_t sentAtUS;        /* when the outstanding request was sent; 0 = none */

    void reset()  { wanted = false; dueUS = 0; failures = 0; activeSinceUS = 0; sentAtUS = 0; }
    /* Aggregation is not applicable (non-HT peer, unsupported cipher): stop asking. */
    void cancel() { wanted = false; sentAtUS = 0; }

    /* A request went out; wait for the response (or the timeout). */
    void onRequestSent(uint64_t nowUS) { sentAtUS = nowUS; wanted = false; }

    /* The AP accepted. */
    void onAccepted(uint64_t nowUS) { activeSinceUS = nowUS; sentAtUS = 0; wanted = false; }

    /* Declined, timed out, or could not be sent: try again after a backoff. */
    void onFailed(uint64_t nowUS) { sentAtUS = 0; activeSinceUS = 0; schedule(nowUS); }

    /* The AP tore the agreement down (DELBA).  One that proved stable restarts
     * the backoff; a short-lived one keeps growing it. */
    void onTornDown(uint64_t nowUS)
    {
        if (activeSinceUS && nowUS - activeSinceUS >= kStableUS) failures = 0;
        sentAtUS = 0; activeSinceUS = 0;
        schedule(nowUS);
    }

    bool responseOverdue(uint64_t nowUS) const { return sentAtUS && nowUS - sentAtUS >= kResponseTimeoutUS; }
    bool due(uint64_t nowUS) const { return wanted && nowUS >= dueUS; }

    void schedule(uint64_t nowUS) { wanted = true; dueUS = nowUS + retryDelayUS(failures); failures++; }
};

} // namespace RTW88Ba
