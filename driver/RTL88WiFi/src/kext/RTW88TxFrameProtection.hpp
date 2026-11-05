/* SPDX-License-Identifier: GPL-2.0-only
 * Pure per-frame protected-port policy shared by the native TX path and tests.
 */
#pragma once
#include <stdint.h>

static inline bool RTW88ShouldProtectTxFrame(bool wpa2,
                                              bool hasPairwiseKey,
                                              uint16_t ethertype,
                                              uint16_t eapolEthertype,
                                              bool protectThisEapolFrame)
{
    return wpa2 && hasPairwiseKey &&
        (ethertype != eapolEthertype || protectThisEapolFrame);
}
