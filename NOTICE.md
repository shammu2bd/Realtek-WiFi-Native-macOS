# Notice

RTL88WiFi is distributed under the GNU General Public License, version 2
(`LICENSE`). This file records the license notices that the GPL requires to
travel with the source.

## Derived source

RTL88WiFi is a derived work of GPL-2.0 licensed source:

- the AirPort_RTW88 native IO80211 driver (source release of 2026-09, GPLv2);
- the Sequoia 24H32 WCL ABI method/layout research documented by AirportRTW (GPLv2);
- the rtw88 macOS port it was built on;
- the Linux kernel `rtw88` driver, dual licensed GPL-2.0 OR BSD-3-Clause
  (`driver/rtw88-stable/COPYING`).

Individual source files keep their SPDX license identifiers and copyright
notices. Files changed for RTL88WiFi carry a "Modified by X1REN41L" line with
the date; the full change history is in the Git log and `CHANGELOG.md`.

Versions 1.0.2 to 1.0.6 are unofficial community modifications and was not made by the
original author. Files it changed carry an additional "Modified on 2026-10-23
for RTL88WiFi 1.0.2" line, and the new files `RTW88JoinPolicy.hpp`,
`RTW88LinkMetrics.hpp` and `RTW88BaPolicy.hpp` carry an "Added on" line. This includes a
three-line change to the vendored `rtw8821c.c` (reading RX SNR), which is why
the 1.0.0-era "rtw88 source unchanged" statement in `docs/` no longer holds for
this version.

## Separately licensed parts

- Kernel SDK headers in `driver/RTL88WiFi/MacKernelSDK/` keep their own
  notices and `LICENSE.txt`.
- Realtek firmware in `driver/RTL88WiFi/firmware/` keeps its original notices
  (`driver/RTL88WiFi/firmware/README`).
- `Kexts/AMFIPass.kext`, `Kexts/IOSkywalkFamily.kext` and
  `Kexts/IO80211FamilyLegacy.kext` are separate third-party or Apple binaries
  shipped for convenience. They are not RTL88WiFi code and are not relicensed
  by this repository.

The combined RTL88WiFi driver is distributed under GPLv2. This does not
relicense the SDK, the firmware or the bundled dependency kexts.
