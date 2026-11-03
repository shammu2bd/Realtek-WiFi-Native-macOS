"""Uplink Block Ack recovery (1.0.6): the AP tears down or declines the agreement
and the driver must ask again, with backoff.

Part A compiles the real header-only RTW88BaPolicy.hpp.  Part B extracts the real
startTxAggregation / housekeeping / handleBackAction from RTW88IEEE80211.cpp and
runs them against a shim with a controllable clock and fake management-frame TX.
Before 1.0.6 a DELBA, a declined ADDBA or a lost response left uplink aggregation
off for the rest of the association (link up, uploads slow and erratic).
This tests decision logic, not radio behaviour.
"""
from pathlib import Path
import subprocess, tempfile
import shutil

kext = Path(__file__).resolve().parents[1] / 'driver/RTL88WiFi/src/kext'
s = (kext / 'RTW88IEEE80211.cpp').read_text()


def fn(signature):
    start = s.index(signature)
    i = s.index('{', start) + 1
    depth = 1
    while depth:
        depth += (s[i] == '{') - (s[i] == '}')
        i += 1
    return s[start:i]


prefix = r'''
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <cassert>
#include <vector>
#include "RTW88BaPolicy.hpp"

static int logs = 0;
#define IOLog(...) (logs++)
static uint64_t fakeNowNS = 1000ULL * 1000 * 1000;
static uint64_t mach_absolute_time() { return fakeNowNS; }
static void absolutetime_to_nanoseconds(uint64_t a, uint64_t *ns) { *ns = a; }

enum { RTW88_STATE_IDLE, RTW88_STATE_SCANNING, RTW88_STATE_AUTHENTICATING,
       RTW88_STATE_ASSOCIATING, RTW88_STATE_HANDSHAKING, RTW88_STATE_CONNECTED };
#define WLAN_ACTION_ADDBA_REQ 0
#define WLAN_ACTION_ADDBA_RESP 1
#define WLAN_ACTION_DELBA 2

struct HtCap { bool ht_supported; };
struct Link { HtCap ht_cap; };
struct Sta { Link deflink; };

class RTW88IEEE80211 {
public:
    static const unsigned kRxBaNumTid = 8;
    int _state = RTW88_STATE_CONNECTED;
    bool _associatedVisible = true, _handshakePending = false;
    Sta sta{{{true}}}; Sta *_sta = &sta;
    bool _txBaActive = false, _txBaPending = false;
    RTW88Ba::Recovery _baRecovery;
    uint8_t _baTid = 0, _baDialog = 0;

    /* fakes */
    bool htOk = true, txOk = true;
    int addbaSent = 0, rxSetups = 0, rxTeardowns = 0, responses = 0;
    RTW88IEEE80211() { _baRecovery.reset(); }
    bool htAllowed() const { return htOk; }
    void sendAddbaRequest(uint8_t) { ++_baDialog; addbaSent++; _txBaPending = txOk; }
    void sendAddbaResponse(uint8_t, uint8_t, uint16_t, uint16_t, uint16_t = 0) { responses++; }
    void rxBaSetup(uint8_t, uint16_t, uint16_t) { rxSetups++; }
    void rxBaTeardown(uint8_t) { rxTeardowns++; }

    void startTxAggregation();
    void housekeeping();
    void handleBackAction(const uint8_t *b, uint32_t len);
};
'''

main = r'''
static const uint64_t SEC = 1000ULL * 1000 * 1000;          /* fake clock is in ns */
static void advance(double sec) { fakeNowNS += (uint64_t)(sec * 1e9); }

static void respond(RTW88IEEE80211 &c, uint16_t status, uint8_t dialog) {
    uint8_t f[9] = {3, WLAN_ACTION_ADDBA_RESP, dialog, (uint8_t)status, (uint8_t)(status >> 8),
                    (uint8_t)((1u << 1) | (c._baTid << 2)), 0, 0, 0};
    c.handleBackAction(f, sizeof(f));
}
static void delba(RTW88IEEE80211 &c, uint8_t tid, bool initiator, uint16_t reason) {
    uint16_t p = (uint16_t)((initiator ? (1u << 11) : 0) | (tid << 12));
    uint8_t f[6] = {3, WLAN_ACTION_DELBA, (uint8_t)p, (uint8_t)(p >> 8), (uint8_t)reason, (uint8_t)(reason >> 8)};
    c.handleBackAction(f, sizeof(f));
}

int main() {
    using namespace RTW88Ba;

    /* ================= Part A: the policy ================= */
    assert(retryDelayUS(0) == 1 * 1000000ULL && retryDelayUS(1) == 2 * 1000000ULL && retryDelayUS(2) == 5 * 1000000ULL &&
           retryDelayUS(3) == 10 * 1000000ULL && retryDelayUS(4) == 30 * 1000000ULL && retryDelayUS(5) == 60 * 1000000ULL &&
           retryDelayUS(99) == 60 * 1000000ULL);
    {
        Recovery r; r.reset();
        assert(!r.due(1) && !r.responseOverdue(1));
        r.onFailed(0); assert(r.wanted && !r.due(999999) && r.due(1000000));                // first retry after 1 s
        r.onFailed(1000000); assert(r.dueUS == 1000000 + 2000000);                           // then 2 s
        r.onFailed(0); assert(r.dueUS == 5000000);
        r.onFailed(0); assert(r.dueUS == 10000000);
        r.onFailed(0); assert(r.dueUS == 30000000);
        r.onFailed(0); assert(r.dueUS == 60000000);
        r.onFailed(0); assert(r.dueUS == 60000000);                                          // capped at 60 s
        r.cancel(); assert(!r.due(1ULL << 60));
        r.reset(); assert(r.failures == 0 && !r.wanted);
    }
    {   /* stable agreement restarts the backoff, a short-lived one does not */
        Recovery r; r.reset();
        for (int i = 0; i < 4; i++) r.onFailed(0);                                           // failures = 4
        r.onAccepted(100); assert(!r.wanted && r.activeSinceUS == 100);
        r.onTornDown(100 + kStableUS);   assert(r.failures == 1 && r.dueUS == 100 + kStableUS + 1000000);   // stable: 1 s
        Recovery q; q.reset(); q.onFailed(0); q.onFailed(0);                                  // failures = 2
        q.onAccepted(0); q.onTornDown(5 * 1000000ULL);                                        // lived 5 s: not stable
        assert(q.failures == 3 && q.dueUS == 5 * 1000000ULL + 5000000ULL);                    // grows: 5 s
        Recovery o; o.reset(); o.onRequestSent(10);
        assert(!o.responseOverdue(10 + kResponseTimeoutUS - 1) && o.responseOverdue(10 + kResponseTimeoutUS));
        o.onAccepted(20); assert(!o.responseOverdue(1ULL << 60));
    }

    /* ================= Part B: the real driver functions ================= */
    {   /* association: ADDBA sent and accepted */
        RTW88IEEE80211 c; c.startTxAggregation();
        assert(c.addbaSent == 1 && c._txBaPending && !c._txBaActive);
        respond(c, 0, c._baDialog);
        assert(c._txBaActive && !c._txBaPending && c._baRecovery.activeSinceUS != 0);
        c.housekeeping(); assert(c.addbaSent == 1);                                          // nothing to do while active
    }
    {   /* THE reported situation: agreement lost after a long time -> re-negotiated, uploads aggregate again */
        RTW88IEEE80211 c; c.startTxAggregation(); respond(c, 0, c._baDialog);
        advance(40 * 60);                                                                    // 40 minutes of normal operation
        delba(c, 0, false, 39);                                                              // AP: BA timeout
        assert(!c._txBaActive && c._baRecovery.wanted);
        advance(0.5); c.housekeeping(); assert(c.addbaSent == 1);                            // too early
        advance(0.6); c.housekeeping(); assert(c.addbaSent == 2 && c._txBaPending);          // after 1 s: asks again
        respond(c, 0, c._baDialog); assert(c._txBaActive);                                   // aggregating again
        assert(c._baRecovery.failures == 1);                                                 // stable before: backoff restarted
    }
    {   /* a mesh node that accepts and immediately tears down: backoff grows 1,2,5,10,30,60 and stays at 60 */
        RTW88IEEE80211 c; c.startTxAggregation(); respond(c, 0, c._baDialog);
        const double expect[] = {1, 2, 5, 10, 30, 60, 60, 60};
        int sent = c.addbaSent;
        for (double d : expect) {
            advance(2); delba(c, 0, false, 39);                                              // lived 2 s: short-lived
            advance(d - 0.05); c.housekeeping(); assert(c.addbaSent == sent);                // not yet
            advance(0.1);      c.housekeeping(); assert(c.addbaSent == sent + 1);            // exactly at the backoff
            sent = c.addbaSent; respond(c, 0, c._baDialog);
        }
    }
    {   /* AP declines (status 37): retried with backoff, never a storm */
        RTW88IEEE80211 c; c.startTxAggregation();
        respond(c, 37, c._baDialog);
        assert(!c._txBaActive && !c._txBaPending && c._baRecovery.wanted);
        for (int i = 0; i < 100; i++) {                                                       // 5 s of 50 ms ticks, AP declines every request
            advance(0.05); c.housekeeping();
            if (c._txBaPending) respond(c, 37, c._baDialog);
        }
        assert(c.addbaSent == 3);                                                            // sent at 0, +1 s, +3 s (1 s then 2 s backoff); next at +8 s
    }
    {   /* ADDBA response never arrives: timed out after 3 s, then retried; one request outstanding at a time */
        RTW88IEEE80211 c; c.startTxAggregation(); assert(c.addbaSent == 1);
        advance(2.9); c.housekeeping(); assert(c.addbaSent == 1 && c._txBaPending);          // still waiting
        advance(0.2); c.housekeeping(); assert(!c._txBaPending && c.addbaSent == 1);         // timed out, retry scheduled
        advance(1.1); c.housekeeping(); assert(c.addbaSent == 2 && c._txBaPending);
    }
    {   /* the request could not be transmitted: retried */
        RTW88IEEE80211 c; c.txOk = false; c.startTxAggregation();
        assert(c.addbaSent == 1 && !c._txBaPending && c._baRecovery.wanted);
        c.txOk = true; advance(1.1); c.housekeeping(); assert(c.addbaSent == 2 && c._txBaPending);
    }
    {   /* stale / mismatched responses are ignored */
        RTW88IEEE80211 c; c.startTxAggregation();
        respond(c, 0, (uint8_t)(c._baDialog + 5)); assert(!c._txBaActive && c._txBaPending);
    }
    {   /* DELBA for another TID, or one the AP initiated, does not touch the uplink agreement */
        RTW88IEEE80211 c; c.startTxAggregation(); respond(c, 0, c._baDialog);
        delba(c, 3, false, 39); assert(c._txBaActive);
        delba(c, 0, true, 39);  assert(c._txBaActive && c.rxTeardowns == 1);
        c.housekeeping(); assert(c.addbaSent == 1);
    }
    {   /* no upkeep unless the link is really up and not mid-handshake */
        RTW88IEEE80211 c; c.startTxAggregation(); respond(c, 0, c._baDialog); delba(c, 0, false, 39); advance(2);
        c._handshakePending = true; c.housekeeping(); assert(c.addbaSent == 1);
        c._handshakePending = false; c._state = RTW88_STATE_HANDSHAKING; c.housekeeping(); assert(c.addbaSent == 1);
        c._state = RTW88_STATE_IDLE; c.housekeeping(); assert(c.addbaSent == 1);
        c._state = RTW88_STATE_CONNECTED; c._associatedVisible = false; c.housekeeping(); assert(c.addbaSent == 1);
        c._associatedVisible = true; c._sta = nullptr; c.housekeeping(); assert(c.addbaSent == 1);
        c._sta = &c.sta; c.housekeeping(); assert(c.addbaSent == 2);                         // all conditions met: sends
    }
    {   /* a peer that cannot aggregate (no HT / unsupported cipher): never asked, nothing retried */
        RTW88IEEE80211 c; c.htOk = false; c.startTxAggregation();
        assert(c.addbaSent == 0 && !c._baRecovery.wanted);
        advance(600); c.housekeeping(); assert(c.addbaSent == 0);
        RTW88IEEE80211 d; d.sta.deflink.ht_cap.ht_supported = false; d.startTxAggregation();
        assert(d.addbaSent == 0 && !d._baRecovery.wanted);
    }
    {   /* defence in depth: even if state were inconsistent (a retry "due" while a request is still outstanding),
         * never put a second request on the air */
        RTW88IEEE80211 c; c.startTxAggregation(); assert(c._txBaPending && c.addbaSent == 1);
        c._baRecovery.wanted = true; c._baRecovery.dueUS = 0;
        c.housekeeping(); assert(c.addbaSent == 1);
    }
    {   /* "wanted" already set, then the peer turns out not to be able to aggregate: stop asking, do not loop forever */
        RTW88IEEE80211 c; c.startTxAggregation(); respond(c, 0, c._baDialog); delba(c, 0, false, 39);
        assert(c._baRecovery.wanted);
        c.htOk = false; advance(1.5); c.housekeeping();
        assert(c.addbaSent == 1 && !c._baRecovery.wanted);
        advance(600); c.housekeeping(); assert(c.addbaSent == 1);
    }
    {   /* AP-initiated ADDBA (downlink) still accepted as before */
        RTW88IEEE80211 c;
        uint8_t f[9] = {3, WLAN_ACTION_ADDBA_REQ, 7, (uint8_t)((1u << 1) | (2 << 2) | (64 << 6)), (uint8_t)((64 << 6) >> 8), 0, 0, 0, 0};
        c.handleBackAction(f, sizeof(f)); assert(c.rxSetups == 1 && c.responses == 1);
    }

    puts("PASS: ADDBA recovery policy (1,2,5,10,30,60 s backoff; stable agreement restarts it; response timeout 3 s); "
         "real driver functions: lost agreement after 40 min is re-negotiated, repeated tear-downs back off without a storm, "
         "declined and unanswered and unsendable requests are retried, one request outstanding at a time, stale responses and "
         "other-TID/AP-initiated DELBAs ignored, no upkeep unless connected and not mid-handshake, non-HT peers never asked");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='rtw88-ba-') as td:
    p = Path(td)
    body = '\n'.join([
        fn('static uint64_t rtw88JoinNowUS('),
        fn('void RTW88IEEE80211::startTxAggregation('),
        fn('void RTW88IEEE80211::housekeeping('),
        fn('void RTW88IEEE80211::handleBackAction('),
    ])
    (p / 'test.cpp').write_text(prefix + '\n' + body + '\n' + main)
    compiler = ['xcrun', 'clang++'] if shutil.which('xcrun') else ['clang++']
    subprocess.run(compiler + [ '-std=c++17', '-fsanitize=address,undefined',
                    '-fno-sanitize-recover=all', '-g', '-I', str(kext),
                    str(p / 'test.cpp'), '-o', str(p / 'test')], check=True)
    r = subprocess.run([str(p / 'test')], capture_output=True, text=True)
    print('\n'.join(l for l in r.stdout.splitlines() if l.startswith('PASS')))
    if r.returncode:
        print(r.stdout[-2000:], r.stderr[-3000:])
        raise SystemExit(r.returncode)
