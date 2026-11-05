/* SPDX-License-Identifier: GPL-2.0-only
 * Bounded prefix acceptance for a 24H32 TX submission callback.
 *
 * A callback accepts only a contiguous prefix. The first null packet or
 * failed submit stops the pass; that packet and the remainder remain owned
 * by Skywalk. The helper is freestanding for host fault-injection tests.
 */
#pragma once

#include <stdint.h>

namespace RTW88WCLTxSubmissionBatch {

static constexpr uint32_t kMaximumPacketsPerCallback = 16;
using Submit = int (*)(void *context, void *packet);

template <typename Packet>
static inline uint32_t submitPrefix(Packet * const *packets,
                                    uint32_t packetCount,
                                    Submit submit,
                                    void *context)
{
    if (!packets || packetCount == 0 || !submit)
        return 0;

    const uint32_t limit =
        packetCount < kMaximumPacketsPerCallback
            ? packetCount : kMaximumPacketsPerCallback;
    uint32_t accepted = 0;
    for (; accepted < limit; ++accepted) {
        Packet *packet = packets[accepted];
        if (!packet || submit(context, static_cast<void *>(packet)) != 0)
            break;
    }
    return accepted;
}

} // namespace RTW88WCLTxSubmissionBatch
