/* SPDX-License-Identifier: GPL-2.0-only
 * Atomic 802.11 sequence and CCMP packet-number allocation for concurrent ACs.
 *
 * This small state object is freestanding so its concurrency properties can
 * be tested on the host without IOKit or the kernel build environment.
 */
#pragma once

#include <stdint.h>

class RTW88TxSequenceNumbers {
public:
    static constexpr uint8_t kQoSTidCount = 8;
    static constexpr uint64_t kCCMPPacketNumberMax = 0x0000FFFFFFFFFFFFULL;

    uint16_t nextNonQoS()
    {
        return static_cast<uint16_t>(
            __atomic_fetch_add(&_nonQoS, 1, __ATOMIC_RELAXED) & 0x0fffU);
    }

    uint16_t nextQoS(uint8_t tid)
    {
        if (tid >= kQoSTidCount)
            return 0;
        return static_cast<uint16_t>(
            __atomic_fetch_add(&_qos[tid], 1, __ATOMIC_RELAXED) & 0x0fffU);
    }

    uint16_t currentQoS(uint8_t tid) const
    {
        if (tid >= kQoSTidCount)
            return 0;
        return static_cast<uint16_t>(
            __atomic_load_n(&_qos[tid], __ATOMIC_ACQUIRE) & 0x0fffU);
    }

    void resetQoS()
    {
        for (uint8_t tid = 0; tid < kQoSTidCount; ++tid)
            __atomic_store_n(&_qos[tid], 0, __ATOMIC_RELEASE);
    }

    void resetCCMP()
    {
        __atomic_store_n(&_ccmpPacketNumber, 0ULL, __ATOMIC_RELEASE);
    }

    /* CCMP uses a single 48-bit PN space for this key. The compare/exchange
     * guarantees unique values across concurrent BK/BE/VI/VO submitters.
     * Refuse exhaustion rather than wrapping and reusing a nonce. */
    bool nextCCMP(uint64_t *packetNumber)
    {
        if (!packetNumber)
            return false;

        uint64_t previous =
            __atomic_load_n(&_ccmpPacketNumber, __ATOMIC_RELAXED);
        for (;;) {
            if (previous >= kCCMPPacketNumberMax)
                return false;

            const uint64_t next = previous + 1;
            if (__atomic_compare_exchange_n(&_ccmpPacketNumber, &previous,
                                            next, false,
                                            __ATOMIC_ACQ_REL,
                                            __ATOMIC_RELAXED)) {
                *packetNumber = next;
                return true;
            }
        }
    }

private:
    uint16_t _nonQoS = 0;
    uint16_t _qos[kQoSTidCount] = {};
    uint64_t _ccmpPacketNumber = 0;
};
