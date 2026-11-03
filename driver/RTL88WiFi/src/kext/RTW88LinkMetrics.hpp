/* Added on 2026-10-23 for RTL88WiFi 1.0.2; see the repository NOTICE.md. */
/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * RTW88LinkMetrics.hpp — noise / SNR reporting for System Information.
 *
 * Header-only and free of kernel/IOKit dependencies so the exact code that
 * ships in the kext is also compiled by the host tests (tests/test-link-
 * metrics.py).
 *
 * Why this exists: the Realtek chips have no direct noise-floor register.
 * rtw88 reports a per-path RX SNR in the PHY status of received frames, from
 * which noise = RSSI - SNR.  That value is not always available:
 *   - RTL8821C: the original port never read the SNR field (fixed in
 *     rtw8821c.c), and
 *   - on any chip the SNR EWMA is empty until OFDM/HT/VHT frames addressed to
 *     us have been received (a link that is idle on 2.4 GHz only ever sees
 *     CCK beacons, which carry no SNR sample).
 * Returning "unknown" makes macOS display "0 dBm".  Instead, fall back to the
 * thermal noise floor for the operating channel width, which is what a real
 * receiver cannot do better than:
 *
 *     N = -174 dBm/Hz + 10*log10(BW_Hz) + NF
 *
 * with a typical consumer Wi-Fi receiver noise figure NF of about 6 dB:
 *     20 MHz -> -95,  40 MHz -> -92,  80 MHz -> -89,  160 MHz -> -86 dBm.
 * This is an estimate, not a measurement, and is reported as such through the
 * IORegistry property RADIO_NOISE_SOURCE.
 */
#pragma once

#include <stdint.h>

namespace RTW88Metrics {

/* Thermal-noise estimate (dBm) for a channel width in MHz.  Unknown widths are
 * treated as 20 MHz. */
static inline int estimatedNoiseDbm(unsigned widthMHz)
{
    switch (widthMHz) {
    case 160: return -86;
    case 80:  return -89;
    case 40:  return -92;
    default:  return -95;
    }
}

/* A measured noise value is accepted only when it is physically plausible for
 * the channel width: not below the thermal floor plus a little measurement
 * slack, and not absurdly high.  This guards against an SNR field whose units
 * or validity differ from what the parser assumed (for example the 8821C
 * field, which could not be verified against hardware when it was added). */
static inline bool measuredNoisePlausible(int noiseDbm, unsigned widthMHz)
{
    const int est = estimatedNoiseDbm(widthMHz);
    return noiseDbm >= est - 8 && noiseDbm <= est + 15;
}

enum Source : uint8_t {
    kSourceMeasured  = 0,   /* RSSI - measured SNR                      */
    kSourceEstimated = 1,   /* thermal noise floor for the channel width */
};

struct LinkNoise {
    int    noise;   /* dBm, always filled */
    int    snr;     /* dB, = rssi - noise, never negative */
    Source source;
};

/* rssi: link RSSI in dBm.  haveSnr/measuredSnr: the chip's averaged RX SNR in
 * dB when available.  widthMHz: current operating channel width. */
static inline LinkNoise linkNoise(int rssi, bool haveSnr, int measuredSnr, unsigned widthMHz)
{
    LinkNoise out;
    out.source = kSourceEstimated;
    out.noise = estimatedNoiseDbm(widthMHz);

    if (haveSnr && measuredSnr > 0) {
        const int n = rssi - measuredSnr;
        if (measuredNoisePlausible(n, widthMHz)) {
            out.noise = n;
            out.source = kSourceMeasured;
        }
    }

    int snr = rssi - out.noise;
    out.snr = snr > 0 ? snr : 0;
    return out;
}

} // namespace RTW88Metrics
