/* Added on 2026-10-23 for RTL88WiFi 1.0.2; see the repository NOTICE.md. */
/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * RTW88JoinPolicy.hpp — which BSS to join when an SSID has several.
 *
 * Header-only and free of kernel/IOKit dependencies so the code that ships in
 * the kext is also compiled by the host tests (tests/test-join-policy.py).
 *
 * Mesh systems (Eero, Deco, Orbi, Nest, FRITZ!, UniFi, OpenWrt, ...) advertise
 * one SSID from several BSSIDs.  Before 1.0.2 the driver joined the *first*
 * list entry with a matching SSID: not the strongest, possibly a stale entry
 * from an earlier scan, and after a rejected join macOS retried the very same
 * node again.  This policy ranks candidates and remembers nodes that just
 * failed, so a retry (or the driver's own fallback) moves on to the next best
 * node instead.  Failed nodes are demoted, never excluded: if they are the
 * only choice they are still tried.
 */
#pragma once

#include <stdint.h>
#include <string.h>

namespace RTW88Join {

/* How long a node that failed to authenticate/associate stays demoted. */
static const uint64_t kFailHoldUS = 20ULL * 1000000ULL;

/* At most this many different nodes are tried for one join request.  A join
 * that has failed on three nodes is reported to macOS instead of spending a
 * minute walking the whole list. */
static const unsigned kMaxNodesPerJoin = 3;

/* A 5 GHz signal at or above this (dBm) is strong enough to be worth more than
 * any 2.4 GHz signal: 5 GHz at -72 dBm still carries a VHT80 link well above
 * what 2.4 GHz manages even when it is far stronger. */
static const int kUsable5GHzDbm = -72;

/* Candidate score; higher is better.
 *  - RSSI is the base (dBm; invalid values count as -100).
 *  - Band: a *fresh* 5 GHz node with a usable signal (>= kUsable5GHzDbm) gets
 *    +40, which makes it beat a 2.4 GHz node of the same SSID unless that one
 *    is 40 dB stronger.  1.0.2 gave 5 GHz only +5 dB; 2.4 GHz is usually a few
 *    dB stronger than 5 GHz at the same spot, so the winner flipped between
 *    bands with small fluctuations between scans ("connects to 2.4 GHz, works
 *    on the 2nd to 5th try").  A weak 5 GHz node gets only +5, so the stronger
 *    2.4 GHz node still wins when 5 GHz is marginal.
 *  - A BSS not seen in the most recent scans loses 8 dB per missed scan (at
 *    most 3), and gets no band bonus once it is two or more scans old, so a
 *    node that is gone cannot win on band preference alone.
 *  - A node that recently failed is pushed behind every healthy candidate. */
static inline int score(int rssi, uint8_t channel, uint32_t scansSinceSeen, bool recentlyFailed)
{
    int s = (rssi < 0 && rssi >= -127) ? rssi : -100;
    if (channel > 14 && scansSinceSeen <= 1)
        s += (s >= kUsable5GHzDbm) ? 40 : 5;
    s -= (int)(scansSinceSeen > 3 ? 3 : scansSinceSeen) * 8;
    if (recentlyFailed) s -= 1000;
    return s;
}

/* Should this join use WPA2 (RSN element in the association request and the
 * 4-way handshake)?  Before 1.0.2 this followed only our lightweight beacon
 * parser.  When that parser did not recognise a protected AP's security, the
 * driver associated with no RSN element at all and then declared the link up
 * with no keys; no protected AP accepts that.  macOS parsed the AP's complete
 * RSN element before asking for a protected PSK join and handed over the
 * 32-byte PMK, so a PMK on a BSS with the privacy bit set is trusted as
 * WPA2-CCMP-PSK.  An open BSS, or a join without a PMK, is unchanged. */
static inline bool useWpa2(bool externalSupplicant, bool scanSawCcmpPsk,
                           bool havePmk, uint16_t capabilities)
{
    /* The 802.11 Privacy capability bit is authoritative for an open BSS.
     * A stale/misparsed RSN hint or a PMK left in the caller must never turn
     * an open association into a protected one. */
    if ((capabilities & 0x0010) == 0)
        return false;
    return externalSupplicant || scanSawCcmpPsk || havePmk;
}

/* Capability information sent in an association request.  0x0421 is ESS,
 * short preamble and short slot; bit 4 (Privacy) is added only for a protected
 * WPA2 association.  The previous 0x0431 base accidentally set Privacy for
 * every open network. */
static inline uint16_t associationCapability(bool protectedNetwork)
{
    return (uint16_t)(0x0421 | (protectedNetwork ? 0x0010 : 0));
}

/* Small fixed table of recently failed BSSIDs.  Time is a monotonic
 * microsecond counter supplied by the caller (0 means "never"). */
struct FailMemory {
    static const unsigned kSlots = 8;
    struct Slot { uint8_t bssid[6]; uint64_t untilUS; };
    Slot slot[kSlots];
    unsigned next;

    void clear() { memset(slot, 0, sizeof(slot)); next = 0; }

    /* Record a failure.  Re-failing a known node extends its hold. */
    void note(const uint8_t *bssid, uint64_t nowUS, uint64_t holdUS)
    {
        for (unsigned i = 0; i < kSlots; i++) {
            if (slot[i].untilUS && memcmp(slot[i].bssid, bssid, 6) == 0) {
                slot[i].untilUS = nowUS + holdUS;
                return;
            }
        }
        for (unsigned i = 0; i < kSlots; i++) {          /* reuse an expired slot */
            if (!slot[i].untilUS || slot[i].untilUS <= nowUS) {
                memcpy(slot[i].bssid, bssid, 6);
                slot[i].untilUS = nowUS + holdUS;
                return;
            }
        }
        memcpy(slot[next].bssid, bssid, 6);               /* table full: round-robin */
        slot[next].untilUS = nowUS + holdUS;
        next = (next + 1) % kSlots;
    }

    bool blocked(const uint8_t *bssid, uint64_t nowUS) const
    {
        for (unsigned i = 0; i < kSlots; i++)
            if (slot[i].untilUS > nowUS && memcmp(slot[i].bssid, bssid, 6) == 0)
                return true;
        return false;
    }

    /* A node that just worked is no longer suspect. */
    void forget(const uint8_t *bssid)
    {
        for (unsigned i = 0; i < kSlots; i++)
            if (slot[i].untilUS && memcmp(slot[i].bssid, bssid, 6) == 0)
                slot[i].untilUS = 0;
    }
};

/* BSSIDs already attempted during the current join, so the fallback can never
 * cycle between two bad nodes. */
struct TriedSet {
    static const unsigned kMax = 8;
    uint8_t bssid[kMax][6];
    unsigned count;

    void clear() { memset(bssid, 0, sizeof(bssid)); count = 0; }

    bool contains(const uint8_t *b) const
    {
        for (unsigned i = 0; i < count; i++)
            if (memcmp(bssid[i], b, 6) == 0) return true;
        return false;
    }

    /* Returns false when the set is full (the join then gives up). */
    bool add(const uint8_t *b)
    {
        if (contains(b)) return true;
        if (count >= kMax) return false;
        memcpy(bssid[count++], b, 6);
        return true;
    }
};

} // namespace RTW88Join
