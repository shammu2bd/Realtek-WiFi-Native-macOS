"""Exercise the 1.0.2 multi-BSS (mesh) join selection/fallback and the noise
reporting helper, using the code that ships in the kext.

Part A compiles the real header-only RTW88JoinPolicy.hpp and
RTW88LinkMetrics.hpp.  Part B extracts the real RTW88IEEE80211 member functions
(selectBssLocked, hasUntriedAlternativeLocked, applyAssocRsnOverride,
retryOtherBss, joinAttemptFailed, matchesPendingJoin) from the driver source and
runs them against host substitutes for IOLock, thread_call, the clock and
failJoin().  ASan/UBSan check the fuzz section.  This is not a kernel or
hardware test: it checks the decision logic, not radio behaviour.
"""
from pathlib import Path
import subprocess, tempfile
import shutil

root = Path(__file__).resolve().parents[1] / 'driver/RTL88WiFi'
kext = root / 'src/kext'
s = (kext / 'RTW88IEEE80211.cpp').read_text()
h = (kext / 'RTW88IEEE80211.hpp').read_text()


def fn(signature, src=s):
    start = src.index(signature)
    i = src.index('{', start) + 1
    depth = 1
    while depth:
        depth += (src[i] == '{') - (src[i] == '}')
        i += 1
    return src[start:i]


bss_struct = fn('struct RTW88BSS {', h) + ';'

# Regression guards on cmdConnect itself (it is too entangled with IOKit to extract):
# 1.0.2 silently substituted another node when the requested BSSID was not in the
# scan cache, which could turn a 5 GHz request into a 2.4 GHz join.
conn = fn('IOReturn RTW88IEEE80211::cmdConnect(')
assoc_req = fn('bool RTW88IEEE80211::buildAssocReq(')
assert 'RTW88Join::associationCapability(_wpa2)' in assoc_req, 'association request must use the open/protected capability helper'
assert 'uint16_t cap = 0x0431' not in assoc_req, 'open association must not set the Privacy bit'
assert '_targetBSS.rsn_pmf_required' in conn, 'PMF-required APs must be rejected until PMF/BIP exists'
assert '_targetBSS.rsn_has_sae && _targetBSS.akm != 0x000FAC02' in conn, 'SAE-only APs must not be mistaken for WPA2-PSK'
assert 'WPA2-PSK fallback' in conn, 'transition-mode fallback must be logged explicitly'
assert 'requested BSSID not in scan cache, using' not in conn, 'pinned-BSSID substitution is back in cmdConnect'
assert 'selectBssLocked(ssid, wantedLen, nullptr' not in conn, 'cmdConnect retries unpinned after a pinned miss'
assert 'selectBssForJoinLocked(ssid, wantedLen, bssid, &upgraded)' in conn, 'join must retain the exact requested BSSID'
assert 'if (!target) {\n        IOLockUnlock(_bssLock);\n        if (!_missingBssRescanAttempted)' in conn, 'cache miss must trigger at most one refresh'
assert 'IOReturn scanRet = cmdScan();' in conn, 'cache miss refresh must use the normal full scan path'
assert '_deferredBSSIDValid = bssid != nullptr;' in conn, 'deferred retry must preserve the requested BSSID'
assert 'return kIOReturnNotFound;' in conn, 'unknown pinned BSSID must fail after the one refresh, not substitute another node'

prefix = r'''
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <cassert>
#include <vector>
#include <string>
#include <algorithm>
#include <cstdarg>
#include "RTW88JoinPolicy.hpp"
#include "RTW88LinkMetrics.hpp"

static int logs = 0;
static char lastLog[2048];
static void rtwLog(const char *f, ...) { va_list ap; va_start(ap, f); vsnprintf(lastLog, sizeof(lastLog), f, ap); va_end(ap); logs++; }
#define IOLog(...) rtwLog(__VA_ARGS__)
#define WLAN_EID_RSN 48
#define WLAN_CIPHER_SUITE_CCMP 0x000fac04
#define WLAN_CIPHER_SUITE_TKIP 0x000fac02
typedef int IOReturn;

struct IOLock { int held; };
static int lockImbalance = 0;
static void IOLockLock(IOLock *l)   { assert(!l->held); l->held = 1; }
static void IOLockUnlock(IOLock *l) { assert(l->held);  l->held = 0; }

/* controllable clock */
static uint64_t fakeNowNS = 1000ULL * 1000 * 1000;
static uint64_t mach_absolute_time() { return fakeNowNS; }
static void absolutetime_to_nanoseconds(uint64_t a, uint64_t *ns) { *ns = a; }

static int tcEnters = 0;
static void thread_call_enter(void *) { tcEnters++; }
struct FakeTimer { int cancels = 0; void cancelTimeout() { cancels++; } };

enum { RTW88_STATE_IDLE, RTW88_STATE_SCANNING, RTW88_STATE_AUTHENTICATING,
       RTW88_STATE_ASSOCIATING, RTW88_STATE_HANDSHAKING, RTW88_STATE_CONNECTED };
''' + bss_struct + r'''

class RTW88IEEE80211 {
public:
    RTW88BSS *_bssList = nullptr;
    IOLock lk{0};
    IOLock *_bssLock = &lk;
    uint32_t _scanGeneration = 10;
    RTW88BSS _targetBSS{};
    RTW88Join::FailMemory _joinFail;
    RTW88Join::TriedSet   _joinTried;
    bool _prefer5GHzUpgrade = true, _joinHasRequested = false;
    uint8_t _joinRequestedBssid[6] = {};
    volatile bool _curBssTim = false;
    int16_t _rssi = 0;
    uint8_t _authAttempts = 0;
    bool _externalSupplicant = false, _pmkProvided = true, _powered = true;
    char _password[64] = {};
    uint8_t _pmk[32] = {};
    uint8_t _assocRsnIE[258] = {};
    uint16_t _assocRsnIELen = 0;
    int _state = RTW88_STATE_AUTHENTICATING;
    FakeTimer ft; FakeTimer *_timer = &ft;
    void *_connectTC = (void *)1;
    bool cancelled = false;
    std::vector<std::string> failed;

    RTW88IEEE80211() { _joinFail.clear(); _joinTried.clear(); }
    ~RTW88IEEE80211() { while (_bssList) { RTW88BSS *n = _bssList->next; free(_bssList); _bssList = n; } }
    bool authenticationCancelled() const { return cancelled; }
    void failJoin(const char *stage) { failed.push_back(stage); _state = RTW88_STATE_IDLE; }

    RTW88BSS *add(const char *ssid, uint8_t last, uint8_t ch, int rssi, uint32_t seenScan, bool privacy = true) {
        RTW88BSS *b = (RTW88BSS *)calloc(1, sizeof(RTW88BSS));
        b->ssid_len = (uint8_t)strlen(ssid); memcpy(b->ssid, ssid, b->ssid_len);
        memset(b->bssid, 0x02, 6); b->bssid[5] = last;
        b->channel = ch; b->rssi = (int16_t)rssi; b->last_seen_scan = seenScan;
        b->capabilities = privacy ? 0x0411 : 0x0401;
        RTW88BSS **pp = &_bssList; while (*pp) pp = &(*pp)->next; *pp = b;   /* append: list order = call order */
        return b;
    }
    RTW88BSS *sel(const char *ssid, const uint8_t *pin = nullptr, bool skip = false, int priv = -1) {
        IOLockLock(_bssLock);
        RTW88BSS *r = selectBssLocked(ssid, strlen(ssid), pin, skip, priv);
        IOLockUnlock(_bssLock);
        return r;
    }
    void startJoin(RTW88BSS *t) {
        memcpy(&_targetBSS, t, sizeof(_targetBSS));
        _joinTried.clear(); _joinTried.add(_targetBSS.bssid);
        _state = RTW88_STATE_AUTHENTICATING;
    }

    RTW88BSS *selectBssLocked(const char *, size_t, const uint8_t *, bool, int);
    RTW88BSS *selectBssForJoinLocked(const char *, size_t, const uint8_t *, bool *);
    bool hasUntriedAlternativeLocked();
    void applyAssocRsnOverride(bool, bool, bool);
    bool retryOtherBss(const char *);
    void joinAttemptFailed(const char *);
    bool matchesPendingJoin(const char *, const uint8_t *, const uint8_t *) const;
};

static uint32_t rtw88ReadSuite_dummy_unused;
'''

main = r'''
static const uint8_t A6[6] = {2,2,2,2,2,0xA}, B6[6] = {2,2,2,2,2,0xB}, C6[6] = {2,2,2,2,2,0xC}, X6[6] = {2,2,2,2,2,0xEE};
static bool eq(const uint8_t *a, const uint8_t *b) { return memcmp(a, b, 6) == 0; }

int main() {
    using namespace RTW88Join;

    /* ================= Part A1: score() ================= */
    assert(score(-50, 36, 0, false) > score(-60, 36, 0, false));        // stronger wins within a band
    assert(score(-50, 6, 0, false) > score(-60, 6, 0, false));
    /* the reported bug: 2.4 GHz a few dB stronger than 5 GHz must NOT win (1.0.2 flipped with fluctuation) */
    assert(score(-45, 36, 0, false) > score(-38, 6, 0, false));         // 5 GHz -45 beats 2.4 GHz -38
    for (int d = -5; d <= 12; d++)                                      // any plausible 2.4-vs-5 gap, every RSSI jitter
        for (int r = -60; r <= -35; r++)
            assert(score(r, 149, 0, false) > score(r + d, 6, 0, false) || d > 38);
    assert(score(-65, 36, 0, false) > score(-35, 6, 0, false));         // usable 5 GHz beats a very strong 2.4 GHz
    assert(score(-72, 36, 0, false) > score(-40, 6, 0, false));         // boundary: -72 still counts as usable
    assert(score(-73, 36, 0, false) < score(-60, 6, 0, false));         // marginal 5 GHz (+5 only) loses to decent 2.4 GHz
    assert(score(-85, 36, 0, false) < score(-60, 6, 0, false));
    assert(score(-80, 36, 0, false) == -75);                            // weak 5 GHz: base + 5
    assert(score(-45, 36, 2, false) < score(-60, 36, 0, false));        // a 5 GHz node two scans old: no band bonus, loses
    assert(score(-45, 36, 2, false) < score(-60, 6, 0, false));         // ... even to a weaker fresh 2.4 GHz node
    assert(score(-45, 36, 99, false) == score(-45, 36, 3, false));      // staleness capped
    assert(score(-30, 36, 0, true) < score(-90, 6, 0, false));          // failed node behind any healthy one
    assert(score(0, 6, 0, false) == score(-100, 6, 0, false));          // invalid rssi => -100
    assert(score(50, 6, 0, false) == score(-100, 6, 0, false));
    assert(score(-200, 6, 0, false) == score(-100, 6, 0, false));

    /* ================= Part A2: FailMemory ================= */
    {
        FailMemory f; f.clear();
        assert(!f.blocked(A6, 5));
        f.note(A6, 100, 50);                       // until 150
        assert(f.blocked(A6, 100) && f.blocked(A6, 149));
        assert(!f.blocked(A6, 150) && !f.blocked(A6, 1000));   // expires
        assert(!f.blocked(B6, 120));
        f.note(A6, 200, 50); f.note(A6, 210, 100);              // re-fail extends, no duplicate slot
        unsigned used = 0; for (unsigned i = 0; i < FailMemory::kSlots; i++) used += f.slot[i].untilUS != 0;
        assert(used == 1 && f.blocked(A6, 300) && !f.blocked(A6, 310));
        f.forget(A6); assert(!f.blocked(A6, 220));
        /* table overflow keeps working (round-robin) and never crashes */
        for (unsigned i = 0; i < 100; i++) { uint8_t m[6] = {1,2,3,4,5,(uint8_t)i}; f.note(m, 1000, 500); }
        uint8_t last[6] = {1,2,3,4,5,99}; assert(f.blocked(last, 1100));
    }

    /* ================= Part A3: TriedSet ================= */
    {
        TriedSet t; t.clear();
        assert(!t.contains(A6) && t.add(A6) && t.contains(A6) && t.count == 1);
        assert(t.add(A6) && t.count == 1);                      // idempotent
        for (unsigned i = 0; i < TriedSet::kMax - 1; i++) { uint8_t m[6] = {9,9,9,9,9,(uint8_t)i}; assert(t.add(m)); }
        assert(t.count == TriedSet::kMax && !t.add(X6));       // full => false, no overflow
    }

    /* ================= Part A4: noise estimate ================= */
    {
        using namespace RTW88Metrics;
        assert(estimatedNoiseDbm(20) == -95 && estimatedNoiseDbm(40) == -92 &&
               estimatedNoiseDbm(80) == -89 && estimatedNoiseDbm(160) == -86 && estimatedNoiseDbm(0) == -95);
        LinkNoise n = linkNoise(-60, false, 0, 20);             // no SNR at all -> estimate, never 0
        assert(n.source == kSourceEstimated && n.noise == -95 && n.snr == 35 && n.noise != 0);
        n = linkNoise(-60, true, 30, 20);                       // plausible measurement -> used
        assert(n.source == kSourceMeasured && n.noise == -90 && n.snr == 30);
        n = linkNoise(-50, true, 20, 20);                       // implausible (-70 dBm floor) -> rejected
        assert(n.source == kSourceEstimated && n.noise == -95 && n.snr == 45);
        n = linkNoise(-60, true, 0, 80);                        // zero SNR sample -> estimate for width
        assert(n.source == kSourceEstimated && n.noise == -89);
        n = linkNoise(-60, true, -5, 40);                       // negative -> estimate
        assert(n.source == kSourceEstimated && n.noise == -92);
        n = linkNoise(-97, false, 0, 20);                       // RSSI below floor: snr clamps to 0, not negative
        assert(n.noise == -95 && n.snr == 0);
        n = linkNoise(-75, true, 10, 20);                       // -85 dBm measured floor (busy 2.4 GHz): kept
        assert(n.source == kSourceMeasured && n.noise == -85);
        for (int rssi = -127; rssi <= 0; rssi++)
            for (int snr = -3; snr <= 70; snr++)
                for (unsigned w : {0u, 20u, 40u, 80u, 160u}) {
                    n = linkNoise(rssi, true, snr, w);
                    assert(n.noise < 0 && n.noise >= -110 && n.snr >= 0);
                    assert(n.snr == std::max(0, rssi - n.noise));
                }
    }

    /* ================= Part A5: useWpa2() decision table ================= */
    {
        const uint16_t PRIV = 0x0411, OPEN = 0x0401;
        assert( useWpa2(false, true,  false, PRIV));  // parser saw CCMP-PSK on a protected BSS
        assert( useWpa2(true,  false, false, PRIV));  // external supplicant on a protected BSS
        assert( useWpa2(false, false, true,  PRIV));  // PMK supplied, parser unsure, protected BSS
        assert(!useWpa2(false, false, true,  OPEN)); // open BSS stays open even with a stale PMK
        assert(!useWpa2(false, false, false, PRIV));// no PMK and parser unsure
        assert(!useWpa2(false, false, false, OPEN));
        assert(!useWpa2(false, true,  true,  OPEN)); // stale security hint cannot override open capability
        assert(associationCapability(false) == 0x0421); // Privacy bit clear for open
        assert(associationCapability(true)  == 0x0431); // Privacy bit set for protected WPA2
    }

    /* ================= Part B1: selection (real selectBssLocked) ================= */
    {   /* list order is weakest-first: the old "first match" would pick C */
        RTW88IEEE80211 c;
        c.add("Mesh", 0xC, 1, -75, 10); c.add("Mesh", 0xB, 6, -60, 10); c.add("Mesh", 0xA, 36, -50, 10);
        c.add("Other", 0xD, 11, -30, 10);                       // different SSID, strongest overall
        assert(eq(c.sel("Mesh")->bssid, A6));                   // strongest node of the SSID
        assert(eq(c.sel("Mesh", C6)->bssid, C6));               // pinned BSSID honoured exactly
        assert(c.sel("Mesh", X6) == nullptr);                   // pinned but unknown -> null (caller decides)
        assert(c.sel("Nope") == nullptr);
        assert(c.sel("Mes") == nullptr);                        // SSID match is exact, not prefix
        assert(c.lk.held == 0);
    }
    {   /* stale-but-strong loses to fresh */
        RTW88IEEE80211 c;
        c.add("Mesh", 0xA, 36, -45, 7);                         // scan gen 10 -> 3 scans old
        c.add("Mesh", 0xB, 36, -60, 10);
        assert(eq(c.sel("Mesh")->bssid, B6));
    }
    {   /* recently failed node is demoted, but still used when it is the only one */
        RTW88IEEE80211 c;
        c.add("Mesh", 0xA, 36, -50, 10); c.add("Mesh", 0xB, 6, -65, 10);
        c._joinFail.note(A6, 1000000, kFailHoldUS);
        fakeNowNS = 1000ULL * 1000 * 1000;                      // = 1,000,000 us: inside the hold
        assert(eq(c.sel("Mesh")->bssid, B6));
        fakeNowNS += (kFailHoldUS + 10) * 1000;                  // hold expired
        assert(eq(c.sel("Mesh")->bssid, A6));
        fakeNowNS = 1000ULL * 1000 * 1000;
        c._joinFail.note(B6, 1000000, kFailHoldUS);              // both failed: best of the failed
        assert(eq(c.sel("Mesh")->bssid, A6));
    }
    {   /* privacy filter: never fall back from a protected join to an open node (or reverse) */
        RTW88IEEE80211 c;
        c.add("Mesh", 0xA, 36, -40, 10, /*privacy=*/false);     // strongest but open
        c.add("Mesh", 0xB, 6, -70, 10, true);
        assert(eq(c.sel("Mesh", nullptr, false, 1)->bssid, B6));
        assert(eq(c.sel("Mesh", nullptr, false, 0)->bssid, A6));
        assert(eq(c.sel("Mesh", nullptr, false, -1)->bssid, A6));
    }

    {   /* the reported case: dual-band SSID, 2.4 GHz a few dB STRONGER than 5 GHz, signals jitter between scans */
        uint32_t seed = 4242;
        auto rnd = [&](uint32_t n) { seed = seed * 1664525u + 1013904223u; return (seed >> 8) % n; };
        unsigned picked5 = 0;
        for (unsigned iter = 0; iter < 5000; iter++) {
            RTW88IEEE80211 c;
            c.add("Home", 0x24, 6,   -38 - (int)rnd(7) + 3, 10);        // 2.4 GHz around -38..-41 dBm (listed first)
            c.add("Home", 0x50, 153, -45 - (int)rnd(7) + 3, 10);        // 5 GHz   around -45..-48 dBm
            RTW88BSS *t = c.sel("Home");
            picked5 += t->channel > 14;
            if (rnd(2)) std::swap(c._bssList->next->rssi, c._bssList->rssi);   // order/jitter must not matter either
        }
        assert(picked5 == 5000);                                  // 1.0.2 flipped between bands on this input
    }
    {   /* marginal 5 GHz: 2.4 GHz is the better link */
        RTW88IEEE80211 c;
        c.add("Home", 0x24, 6, -55, 10); c.add("Home", 0x50, 153, -80, 10);
        assert(eq(c.sel("Home")->bssid, c._bssList->bssid));
    }
    {   /* an explicitly requested BSSID is still honoured exactly, even on 2.4 GHz */
        RTW88IEEE80211 c;
        c.add("Home", 0x24, 6, -40, 10); c.add("Home", 0x50, 153, -45, 10);
        assert(c.sel("Home", c._bssList->bssid)->channel == 6);
    }
    {   /* a 5 GHz node that disappeared two scans ago must not win on band preference */
        RTW88IEEE80211 c;
        c.add("Home", 0x50, 153, -45, 8);                         // gen is 10: two scans old
        c.add("Home", 0x24, 6, -50, 10);
        assert(c.sel("Home")->channel == 6);
    }

    /* ================= Part B1b: 5 GHz upgrade of a requested 2.4 GHz node (real selectBssForJoinLocked) ================= */
    {
        auto join = [](RTW88IEEE80211 &c, const char *ssid, const uint8_t *pin, bool *up) {
            IOLockLock(c._bssLock);
            RTW88BSS *t = c.selectBssForJoinLocked(ssid, strlen(ssid), pin, up);
            IOLockUnlock(c._bssLock);
            return t;
        };
        bool up;
        {   /* macOS names the 2.4 GHz node, a usable 5 GHz sibling exists -> join 5 GHz */
            RTW88IEEE80211 c;
            RTW88BSS *n24 = c.add("Home", 0x24, 6, -38, 10); RTW88BSS *n5 = c.add("Home", 0x50, 153, -46, 10);
            RTW88BSS *t = join(c, "Home", n24->bssid, &up);
            assert(t == n5 && up && c._joinHasRequested && eq(c._joinRequestedBssid, n24->bssid));
            /* macOS repeats the same request while the join is in progress: same join, do not restart it */
            c._pmkProvided = false; c.startJoin(t);
            assert(c.matchesPendingJoin("Home", n24->bssid, nullptr));
            c._state = RTW88_STATE_CONNECTED;                    // once connected a request for it is a real, new one
            assert(!c.matchesPendingJoin("Home", n24->bssid, nullptr));
            /* if the upgraded node then fails, the node macOS actually asked for is still available as a fallback */
            c._state = RTW88_STATE_AUTHENTICATING;
            c.joinAttemptFailed("auth-rejected");
            assert(c.failed.empty() && eq(c._targetBSS.bssid, n24->bssid));
        }
        {   /* marginal 5 GHz: keep what macOS asked for */
            RTW88IEEE80211 c;
            RTW88BSS *n24 = c.add("Home", 0x24, 6, -50, 10); c.add("Home", 0x50, 153, -80, 10);
            assert(join(c, "Home", n24->bssid, &up) == n24 && !up && !c._joinHasRequested);
        }
        {   /* 5 GHz just below the usable threshold is not an upgrade target */
            RTW88IEEE80211 c;
            RTW88BSS *n24 = c.add("Home", 0x24, 6, -50, 10); c.add("Home", 0x50, 153, -73, 10);
            assert(join(c, "Home", n24->bssid, &up) == n24 && !up);
        }
        {   /* even a usable 5 GHz signal must beat a very strong requested 2.4 GHz node */
            RTW88IEEE80211 c;
            RTW88BSS *n24 = c.add("Home", 0x24, 6, -20, 10); c.add("Home", 0x50, 153, -70, 10);
            assert(join(c, "Home", n24->bssid, &up) == n24 && !up);
        }
        {   /* macOS already named the 5 GHz node: untouched, even if a 2.4 GHz node is stronger */
            RTW88IEEE80211 c;
            c.add("Home", 0x24, 6, -30, 10); RTW88BSS *n5 = c.add("Home", 0x50, 153, -60, 10);
            assert(join(c, "Home", n5->bssid, &up) == n5 && !up);
        }
        {   /* policy switched off: exact BSSID, as in 1.0.1 */
            RTW88IEEE80211 c; c._prefer5GHzUpgrade = false;
            RTW88BSS *n24 = c.add("Home", 0x24, 6, -38, 10); c.add("Home", 0x50, 153, -46, 10);
            assert(join(c, "Home", n24->bssid, &up) == n24 && !up);
        }
        {   /* the 5 GHz node just failed: do not go back to it */
            RTW88IEEE80211 c; fakeNowNS = 1000ULL * 1000 * 1000;
            RTW88BSS *n24 = c.add("Home", 0x24, 6, -38, 10); RTW88BSS *n5 = c.add("Home", 0x50, 153, -46, 10);
            c._joinFail.note(n5->bssid, 1000000, kFailHoldUS);
            assert(join(c, "Home", n24->bssid, &up) == n24 && !up);
        }
        {   /* stale and failed candidates are not upgraded even when their RSSI is high */
            RTW88IEEE80211 c; fakeNowNS = 1000ULL * 1000 * 1000;
            RTW88BSS *n24 = c.add("Home", 0x24, 6, -38, 10); RTW88BSS *n5 = c.add("Home", 0x50, 153, -45, 10);
            c._joinFail.note(n5->bssid, 1000000, kFailHoldUS);
            assert(join(c, "Home", n24->bssid, &up) == n24 && !up);
        }
        {   /* the 5 GHz sibling is an open network while the requested one is protected: never cross security types */
            RTW88IEEE80211 c;
            RTW88BSS *n24 = c.add("Home", 0x24, 6, -38, 10, true); c.add("Home", 0x50, 153, -46, 10, false);
            assert(join(c, "Home", n24->bssid, &up) == n24 && !up);
        }
        {   /* a 5 GHz sibling that is two scans old is not trusted */
            RTW88IEEE80211 c;
            RTW88BSS *n24 = c.add("Home", 0x24, 6, -38, 10); c.add("Home", 0x50, 153, -46, 8);
            assert(join(c, "Home", n24->bssid, &up) == n24 && !up);
        }
        {   /* a different SSID on 5 GHz is not a sibling; an unknown requested BSSID stays "not found" */
            RTW88IEEE80211 c;
            RTW88BSS *n24 = c.add("Home", 0x24, 6, -38, 10); c.add("Neighbour", 0x50, 153, -40, 10);
            assert(join(c, "Home", n24->bssid, &up) == n24 && !up);
            assert(join(c, "Home", X6, &up) == nullptr && !up);
            assert(c.lk.held == 0);
        }
        {   /* no pin: plain best-node selection, never reports an upgrade */
            RTW88IEEE80211 c;
            c.add("Home", 0x24, 6, -38, 10); RTW88BSS *n5 = c.add("Home", 0x50, 153, -46, 10);
            assert(join(c, "Home", nullptr, &up) == n5 && !up);
        }
    }

    /* ================= Part B2: fallback (real retryOtherBss / joinAttemptFailed) ================= */
    {
        RTW88IEEE80211 c;
        c.add("Mesh", 0xC, 1, -75, 10); c.add("Mesh", 0xB, 6, -60, 10); c.add("Mesh", 0xA, 36, -50, 10);
        fakeNowNS = 1000ULL * 1000 * 1000;
        c.startJoin(c.sel("Mesh"));                             // A
        assert(eq(c._targetBSS.bssid, A6));
        tcEnters = 0;
        c._authAttempts = 2;
        c.joinAttemptFailed("auth-rejected");                   // A rejected -> B
        assert(c.failed.empty() && eq(c._targetBSS.bssid, B6) && c._state == RTW88_STATE_AUTHENTICATING);
        assert(c._authAttempts == 0 && tcEnters == 1 && c._timer->cancels >= 1);
        assert(c._joinFail.blocked(A6, 1000000));
        c.joinAttemptFailed("assoc-rejected");                  // B rejected -> C
        assert(c.failed.empty() && eq(c._targetBSS.bssid, C6) && tcEnters == 2);
        c.joinAttemptFailed("assoc-timeout");                   // 3 nodes tried: report to macOS
        assert(c.failed.size() == 1 && c.failed[0] == "assoc-timeout" && c._state == RTW88_STATE_IDLE);
        assert(tcEnters == 2 && c.lk.held == 0);
        assert(c._joinTried.count == 3);
    }
    {   /* single-AP network: no alternative -> straight to failJoin, behaviour as before */
        RTW88IEEE80211 c;
        c.add("Home", 0xA, 6, -50, 10);
        c.startJoin(c.sel("Home")); tcEnters = 0;
        IOLockLock(c._bssLock); bool alt = c.hasUntriedAlternativeLocked(); IOLockUnlock(c._bssLock);
        assert(!alt);
        c.joinAttemptFailed("auth-retry-limit");
        assert(c.failed.size() == 1 && c.failed[0] == "auth-retry-limit" && tcEnters == 0);
    }
    {   /* alternative detection drives the 2-vs-3 attempt cap */
        RTW88IEEE80211 c;
        c.add("Mesh", 0xA, 36, -50, 10); c.add("Mesh", 0xB, 6, -60, 10);
        c.startJoin(c.sel("Mesh"));
        IOLockLock(c._bssLock); assert(c.hasUntriedAlternativeLocked()); IOLockUnlock(c._bssLock);
        c._joinTried.add(B6);
        IOLockLock(c._bssLock); assert(!c.hasUntriedAlternativeLocked()); IOLockUnlock(c._bssLock);
    }
    {   /* a cancelled join (host disassociate) is neither retried nor reported */
        RTW88IEEE80211 c;
        c.add("Mesh", 0xA, 36, -50, 10); c.add("Mesh", 0xB, 6, -60, 10);
        c.startJoin(c.sel("Mesh")); c.cancelled = true; tcEnters = 0;
        c.joinAttemptFailed("assoc-timeout");
        assert(c.failed.empty() && tcEnters == 0 && eq(c._targetBSS.bssid, A6));
    }
    {   /* powered off: no retry */
        RTW88IEEE80211 c;
        c.add("Mesh", 0xA, 36, -50, 10); c.add("Mesh", 0xB, 6, -60, 10);
        c.startJoin(c.sel("Mesh")); c._powered = false;
        assert(!c.retryOtherBss("x"));
    }
    {   /* the fallback never crosses security type */
        RTW88IEEE80211 c;
        c.add("Mesh", 0xA, 36, -50, 10, true);
        c.add("Mesh", 0xB, 6, -40, 10, false);                  // open twin, stronger
        c.startJoin(c.sel("Mesh", nullptr, false, 1));
        assert(eq(c._targetBSS.bssid, A6));
        c.joinAttemptFailed("assoc-rejected");
        assert(c.failed.size() == 1);                           // no protected alternative -> fail, not open node
    }

    /* ================= Part B3: pending-join coalescing ================= */
    {
        RTW88IEEE80211 c;
        c.add("Mesh", 0xA, 36, -50, 10); c.add("Mesh", 0xB, 6, -60, 10);
        c._pmkProvided = false;
        c.startJoin(c.sel("Mesh"));                             // A
        c.joinAttemptFailed("auth-rejected");                   // now on B, A tried
        assert(c.matchesPendingJoin("Mesh", A6, nullptr));       // macOS re-asks for A: same join
        assert(c.matchesPendingJoin("Mesh", B6, nullptr) && c.matchesPendingJoin("Mesh", nullptr, nullptr));
        assert(!c.matchesPendingJoin("Mesh", C6, nullptr));      // unknown node: genuinely new join
        assert(!c.matchesPendingJoin("Other", A6, nullptr));
        c._state = RTW88_STATE_CONNECTED;                        // after connect, a roam request to A is NOT swallowed
        assert(!c.matchesPendingJoin("Mesh", A6, nullptr));
        assert(c.matchesPendingJoin("Mesh", B6, nullptr));
    }

    /* ================= Part B4: RSN override survives a node switch ================= */
    {
        RTW88IEEE80211 c;
        /* RSN IE: ver 1, group CCMP, 1 pairwise CCMP, 1 AKM PSK, caps 0 */
        const uint8_t rsn[] = {48, 20, 1,0, 0x00,0x0f,0xac,4, 1,0, 0x00,0x0f,0xac,4, 1,0, 0x00,0x0f,0xac,2, 0,0};
        memcpy(c._assocRsnIE, rsn, sizeof(rsn)); c._assocRsnIELen = sizeof(rsn);
        c.add("Mesh", 0xA, 36, -50, 10);
        c._targetBSS = *c._bssList;
        c._targetBSS.cipher = 0; c._targetBSS.akm = 0;
        c.applyAssocRsnOverride(false, true, false);
        assert(c._targetBSS.cipher == WLAN_CIPHER_SUITE_CCMP && c._targetBSS.akm == 0x000FAC02);
        /* SAE-only IE must not be turned into PSK */
        const uint8_t sae[] = {48, 20, 1,0, 0x00,0x0f,0xac,4, 1,0, 0x00,0x0f,0xac,4, 1,0, 0x00,0x0f,0xac,8, 0,0};
        memcpy(c._assocRsnIE, sae, sizeof(sae)); c._assocRsnIELen = sizeof(sae);
        c._targetBSS.cipher = 0; c._targetBSS.akm = 0;
        c.applyAssocRsnOverride(false, true, false);
        assert(c._targetBSS.akm == 0);
    }

    /* ================= Part B5: randomized invariants ================= */
    {
        uint32_t seed = 12345;
        auto rnd = [&](uint32_t n) { seed = seed * 1664525u + 1013904223u; return (seed >> 8) % n; };
        for (unsigned iter = 0; iter < 20000; iter++) {
            RTW88IEEE80211 c;
            const unsigned n = 1 + rnd(7);
            for (unsigned i = 0; i < n; i++)
                c.add(rnd(5) ? "Mesh" : "Guest", (uint8_t)(0x10 + i), rnd(2) ? 36 : 6,
                      -(int)(30 + rnd(70)), 10 - rnd(5), rnd(8) != 0);
            fakeNowNS += (uint64_t)rnd(30) * 1000ULL * 1000 * 1000;
            if (rnd(3) == 0) c._joinFail.note(c._bssList->bssid, fakeNowNS / 1000, kFailHoldUS);
            RTW88BSS *t = c.sel("Mesh");
            if (!t) { assert(c.lk.held == 0); continue; }
            c.startJoin(t);
            const int privacy = (t->capabilities & 0x10) ? 1 : 0;
            std::vector<std::vector<uint8_t>> seen{std::vector<uint8_t>(t->bssid, t->bssid + 6)};
            unsigned guard = 0;
            while (c.failed.empty()) {
                assert(++guard <= 4);                           // original + at most 3 total nodes (kMaxNodesPerJoin)
                c.joinAttemptFailed("x");
                if (!c.failed.empty()) break;
                std::vector<uint8_t> cur(c._targetBSS.bssid, c._targetBSS.bssid + 6);
                assert(std::find(seen.begin(), seen.end(), cur) == seen.end());   // never revisit a node
                seen.push_back(cur);
                assert(c._targetBSS.ssid_len == 4 && memcmp(c._targetBSS.ssid, "Mesh", 4) == 0);
                assert((((c._targetBSS.capabilities & 0x10) != 0) ? 1 : 0) == privacy);
            }
            assert(seen.size() <= RTW88Join::kMaxNodesPerJoin);
            assert(c._joinTried.count <= RTW88Join::kMaxNodesPerJoin);
            assert(c.lk.held == 0);
        }
    }

    /* ================= Part C: RSN/SAE/PMF classification and security log ================= */
    {
        /* WPA2/WPA3 transition: PSK + SAE, PMF capable but not required. */
        const uint8_t transition[] = {
            1,0, 0x00,0x0f,0xac,4, 1,0, 0x00,0x0f,0xac,4,
            2,0, 0x00,0x0f,0xac,2, 0x00,0x0f,0xac,8, 0x80,0x00
        };
        uint32_t pairwise = 0, group = 0;
        bool hasSae = false, pmfRequired = false;
        assert(rtw88RsnSelectCcmpPsk(transition, sizeof(transition),
                                     &pairwise, &group, &hasSae, &pmfRequired));
        assert(pairwise == WLAN_CIPHER_SUITE_CCMP && group == WLAN_CIPHER_SUITE_CCMP);
        assert(hasSae && !pmfRequired);

        /* MFPR prevents WPA2 fallback because PMF/BIP is not implemented. */
        uint8_t transitionPmfRequired[sizeof(transition)];
        memcpy(transitionPmfRequired, transition, sizeof(transition));
        transitionPmfRequired[22] = 0xc0;
        hasSae = false; pmfRequired = false;
        assert(!rtw88RsnSelectCcmpPsk(transitionPmfRequired,
                                      sizeof(transitionPmfRequired),
                                      &pairwise, &group, &hasSae, &pmfRequired));
        assert(hasSae && pmfRequired);

        /* SAE-only is never mislabelled as PSK. */
        const uint8_t saeOnly[] = {
            1,0, 0x00,0x0f,0xac,4, 1,0, 0x00,0x0f,0xac,4,
            1,0, 0x00,0x0f,0xac,8, 0xc0,0x00
        };
        hasSae = false; pmfRequired = false;
        assert(!rtw88RsnSelectCcmpPsk(saeOnly, sizeof(saeOnly),
                                     &pairwise, &group, &hasSae, &pmfRequired));
        assert(hasSae && pmfRequired);

        const uint8_t wpa2Only[] = {
            1,0, 0x00,0x0f,0xac,4, 1,0, 0x00,0x0f,0xac,4,
            1,0, 0x00,0x0f,0xac,2, 0x00,0x00
        };
        hasSae = true; pmfRequired = true;
        assert(rtw88RsnSelectCcmpPsk(wpa2Only, sizeof(wpa2Only),
                                     &pairwise, &group, &hasSae, &pmfRequired));
        assert(!hasSae && !pmfRequired);
        /* typical WPA2/WPA3 transition RSN element incl. PMF-capable caps, PMKID count and BIP group-mgmt cipher */
        const uint8_t rsn[] = {48, 26, 1,0, 0x00,0x0f,0xac,4, 1,0, 0x00,0x0f,0xac,4, 2,0, 0x00,0x0f,0xac,2, 0x00,0x0f,0xac,8,
                               0xc0,0x00, 0,0, 0x00,0x0f,0xac,6};
        RTW88BSS *b = (RTW88BSS *)calloc(1, sizeof(RTW88BSS));
        memcpy(b->ies, rsn, sizeof(rsn)); b->ies_len = sizeof(rsn);
        b->channel = 149; b->rssi = -31; b->capabilities = 0x0411; b->cipher = 0x000fac04; b->akm = 0x000fac02;
        rtw88LogTargetSecurity(*b, true, true);
        assert(strstr(lastLog, "ch=149 rssi=-31 caps=0x0411") && strstr(lastLog, "wpa2=1 pmk=1 rsnLen=26 rsnxe=0"));
        assert(strstr(lastLog, "rsn=010000"));                              // dump starts with version + group suite
        assert(strstr(lastLog, "000fac08"));                                 // SAE AKM visible in the dump
        assert(strlen(strstr(lastLog, "rsn=") + 4) <= 2 * 40 + 1);            // dump capped at 40 bytes
        b->ies_len = 0; rtw88LogTargetSecurity(*b, false, false);
        assert(strstr(lastLog, "rsnLen=0") && strstr(lastLog, "rsn=none"));
        free(b);

        /* fuzz: random and truncated element lists must never read outside ies[] (ASan) or overflow the dump */
        uint32_t seed = 777;
        auto rnd = [&](uint32_t n) { seed = seed * 1664525u + 1013904223u; return (seed >> 8) % n; };
        for (unsigned iter = 0; iter < 30000; iter++) {
            RTW88BSS *f = (RTW88BSS *)malloc(sizeof(RTW88BSS));
            memset(f, 0, sizeof(*f));
            const unsigned n = rnd(sizeof(f->ies) + 1);
            for (unsigned i = 0; i < n; i++) f->ies[i] = (uint8_t)(rnd(4) == 0 ? 48 + rnd(2) * 196 : rnd(256));
            f->ies_len = (uint16_t)n;
            rtw88LogTargetSecurity(*f, rnd(2), rnd(2));
            assert(strlen(lastLog) < sizeof(lastLog) - 1);
            free(f);
        }
    }

    puts("PASS: join ranking (strongest/freshest, 5 GHz bonus, stale and failed-node demotion, exact pinning, privacy match), "
         "failed-BSS memory expiry/forget/overflow, tried-set bounds, fallback walks at most 3 distinct nodes then reports failure, "
         "single-AP behaviour unchanged, cancelled/powered-off joins left alone, pending-join coalescing, RSN override re-applied "
         "(SAE-only never mistaken for PSK), protected PSK join with a PMK now uses WPA2 even when the beacon parser is unsure (open/no-PMK joins unchanged), \
         open association Privacy bit clear / WPA2 bit set, WPA2/WPA3 transition falls back only when PMF is optional, SAE-only and PMF-required rejected, target-security log line (shows the AKM list, capped, never overruns on 30,000 random/truncated element lists), noise estimate (-95/-92/-89/-86, plausibility window, never 0, snr never negative), "
         "20,000 randomized joins, locks always balanced");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='rtw88-join-') as td:
    p = Path(td)
    body = '\n'.join([
        fn('static uint32_t rtw88ReadSuite('),
        fn('static bool rtw88RsnSelectCcmpPsk('),
        fn('static int rtw88IeFind('),
        fn('static void rtw88LogTargetSecurity('),
        fn('static uint64_t rtw88JoinNowUS('),
        fn('RTW88BSS *RTW88IEEE80211::selectBssLocked('),
        fn('RTW88BSS *RTW88IEEE80211::selectBssForJoinLocked('),
        fn('bool RTW88IEEE80211::hasUntriedAlternativeLocked('),
        fn('void RTW88IEEE80211::applyAssocRsnOverride('),
        fn('bool RTW88IEEE80211::retryOtherBss('),
        fn('void RTW88IEEE80211::joinAttemptFailed('),
        fn('bool RTW88IEEE80211::matchesPendingJoin('),
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
