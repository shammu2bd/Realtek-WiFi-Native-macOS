## Sequoia WCL development — Stage 12.1 (2026-11-01; ABI collector parser repair)

- Accept exact Itanium mangled symbol tokens embedded in kcabi method-list rows.
- Add class-owned `INDEX.txt` fallback when method lists contain no mangled tokens.
- Preserve and identify temporary pass data when Stage 12 extraction fails.
- Expand parser regression tests for inline symbols and index fallback.
- No kext datapath or registration behavior changed.

# Changelog

## Sequoia WCL development — Stage 12 (2026-11-01; ABI evidence collector)

Adds a two-pass, read-only Sequoia 24H32 `kcabi` collector. It first reads
method lists, then expands the disassembly reference to every exact method in
`IOSkywalkPacketQueue`, `IOSkywalkPacketBufferPool`, `IOSkywalkQueueSet`, and
`IOSkywalkLogicalLink`, preserving the existing registration ABI targets.
Host tests validate symbol extraction and seed-reference preservation. No
Skywalk queue/pool creation, ownership transfer, registration call, BSD
publication, RX delivery, or TX completion is enabled. Details:
[Stage 12 ABI notes](docs/24H32-SKYWALK-QUEUE-POOL-ABI-STAGE12.md).

## Sequoia WCL development — Stage 11 (2026-11-01; compile-only)

Adds persistent 8-byte-aligned `0x130`-byte opaque `RegistrationInfo` storage
and a guarded builder that calls the audited 24H32 initializer before applying
only the post-initializer writes observed in Apple's caller. Host C++/Python
tests verify the storage, byte preservation, and fail-closed integration.

The builder remains disconnected from `start()`. Registration calls, Skywalk
queue activation, pool ownership transfer, BSD publication, RX delivery, TX
completion, and radio start remain disabled. No macOS kernel build or runtime
Wi-Fi validation is claimed. Details:
[Stage 11 ABI notes](docs/24H32-SKYWALK-REGISTRATION-INFO-STAGE11.md).

## 1.0.11 — 2026-10-31 (unofficial community fix, not by the original author)

Build identity `1.0.11-rtl88wifi-r22-20261031`. Host-side source tests cover
the selector routing and existing mode logic; **no macOS kernel build or
physical Settings-menu test has been performed**. Details:
[CHANGELOG-1.0.11.md](CHANGELOG-1.0.11.md).

- Adds the missing Skywalk split GET handler for `APPLE80211_IOC_PRIVATE_MAC`
  (selector 238), plus the Skywalk split SET handler. Adds the corresponding
  Legacy split GET override and routes all paths through the same strict
  28-byte payload validator and Off/Fixed/Rotating state handler.
- Adds explicit GET/SET ingress diagnostics (`PRIVATE_MAC GET/SET ingress=...`)
  so the next report can show whether System Settings reached the controller.
- Keeps the working open-network association fix, WPA2, scan/roaming behavior,
  country passthrough and aggregation logic unchanged. WPA3-SAE remains disabled.
- Does not invent a capability bit or force a country code. If macOS management
  profiles restrict the setting, the driver cannot override that host policy.

## 1.0.10 — 2026-10-31 (unofficial community fix, not by the original author)

Build identity `1.0.10-rtl88wifi-r21-20261031`. Host-side tests cover the open
ASSOCIATE decoder and PRIVATE_MAC mode handler; **no macOS kernel build or
physical Wi-Fi test has been performed**. Details:
[CHANGELOG-1.0.10.md](CHANGELOG-1.0.10.md).

- Accepts the version-0 empty key object used by an open-network host32
  ASSOCIATE request, preventing the observed `lower=0, upper=1, ssidLen=0`
  Ventura-ABI misinterpretation. WPA2 key validation remains strict.
- Adds a narrowly scoped modern Apple80211 PRIVATE_MAC GET/SET bridge plus
  Off/Fixed/Rotating handling. Rotations occur only when the radio is idle;
  active joins and links are not disrupted. Host-supplied addresses are kept
  unchanged; locally generated addresses are unicast and locally administered.
- Does not force a country code. macOS currently supplies `US`; this build
  preserves host regulatory selection rather than falsely forcing `BD`.
- WPA3-SAE remains disabled, WPA2 remains supported, and mesh/roaming changes
  from prior builds are retained.

## 1.0.9 — 2026-10-31 (unofficial community fix, not by the original author)

Build identity `1.0.9-rtl88wifi-r20-20261031`. **Host tests only; no macOS
kernel build or physical Wi-Fi test has been performed.** Details:
[CHANGELOG-1.0.9.md](CHANGELOG-1.0.9.md).

- Decodes the newer 32-bit ASSOCIATE payload before it reaches the older
  16-bit Ventura structure handler. This fixes the specific malformed open
  join signature observed on hardware (`lower=0`, `upper=1`, `ssidLen=0`).
- Keeps WPA3-SAE disabled, preserves WPA2-PSK fallback for eligible transition
  requests, and corrects diagnostic interpretation so a non-open lower-auth
  value alone is not misreported as SAE.
- Records early association-header rejections and validates the freshness of
  the reported join result, preventing an old successful WPA2 result from
  being presented as the result of a newer failed attempt.
- Country selection remains dynamic: no US or BD country is hardcoded. The
  driver follows a valid country supplied by Apple80211; if macOS supplies US,
  the driver reports and applies US rather than inventing BD.

## 1.0.7 — 2026-10-31 (unofficial community fix, not by the original author)

Build identity `1.0.7-rtl88wifi-r18-20261031`. **Source-level tests only; not yet
built with the macOS SDK or run on Wi-Fi hardware.**

- **Connected mesh scans are no longer cache-only.** When CoreWiFi requests a
  scan while associated, the driver now performs a bounded software scan on
  up to eight channels: known alternate BSS channels for the current SSID and
  security class are prioritized, then remaining CoreWiFi-requested channels
  fill the budget. Each off-channel dwell is short and the STA is returned to
  its home channel between channels. Full-band scans remain unchanged while
  disconnected.
- **Partial scans preserve the complete BSS cache.** A connected scan does not
  advance the full-scan generation or age/prune BSS entries on channels it did
  not visit. This prevents a partial result from deleting other mesh nodes.
- **Missing mesh BSSID recovery.** If CoreWiFi asks to join a BSSID that is
  absent from the current cache, the driver performs one full enabled-channel
  scan and retries the exact same request. It never substitutes a different
  BSSID just because it shares the SSID; the request fails explicitly if the
  named node is still not found.
- **Safer 5 GHz upgrade.** A requested 2.4 GHz BSSID is upgraded only when a
  same-security 5 GHz candidate is fresh (at most one full scan old), at least
  -72 dBm, not recently failed, and scores better than the requested node.
- **802.11k/v/r are still unsupported.** The driver does not implement Neighbor
  Report, BSS Transition Management, or Fast BSS Transition/FT key hierarchy.
  The new path is ordinary scan-assisted roaming through CoreWiFi, not an
  11k/v/r implementation.

This does not guarantee an immediate handoff: CoreWiFi chooses whether and
when to reassociate, and the updated path needs real mesh/router testing.

## 1.0.6 — 2026-10-25 (unofficial community fix, not by the original author)

Follow-up to a tester's report on a mesh network: the connection is normal at
first, then becomes slow or unstable after roughly 40 to 60 minutes. Build
identity `1.0.6-rtl88wifi-r17-20261025`. **Not yet run on hardware.**

- **Uplink aggregation is now re-negotiated when the AP tears it down.** The
  driver set up the uplink Block Ack agreement (which is what makes transmit
  A-MPDU aggregation possible) exactly once, right after the keys were
  installed. If the AP later sent a DELBA, declined the request, or the response
  was lost, aggregation stayed off for the rest of the association: the link
  stayed up but uploads ran as un-aggregated frames, slow and erratic. The
  driver now asks again, from the existing 5-second diagnostic tick (which
  already runs inside the guard against power transitions), with backoff
  (1, 2, 5, 10, 30, then 60 seconds, restarting after an agreement has proven
  stable for a minute) so an AP that accepts and immediately tears down again
  cannot cause a request storm. A response that never arrives is treated as a
  failure after 3 seconds.
- **The DELBA log line now includes the reason code** (37 declined, 38 unknown
  block ack, 39 timeout), which says why an AP tore the agreement down.
- **`tools/rtl88wifi-join-report.sh` gained two sections**: uplink aggregation
  (events, whether aggregation is on in the latest heartbeat, how many
  heartbeats while connected had it off) and key rekeys and key errors.

This is a defect that fits the symptom, **not a confirmed cause**. Other
candidates that also produce a delay of about an hour are listed in the docs
(key rotation intervals, radio drift with the periodic watchdog disabled,
mesh steering), and the report is meant to tell them apart.

## 1.0.5 — 2026-10-25 (unofficial community fix, not by the original author)

Follow-up to a tester's report on 1.0.4 (RTL8821CE, OpenCore): the 5 GHz
preference works; the "Private Wi-Fi address" control in Network settings is
greyed out showing only "Fixed"; and the hotspot report contained no driver
lines. Build identity `1.0.5-rtl88wifi-r16-20261025`. **Not yet run on
hardware.**

- **Private Wi-Fi address: the request behind the control is now answered.**
  macOS reads and writes the mode with `APPLE80211_IOC_PRIVATE_MAC` (238). The
  driver replaces the family's own dispatcher and answered that request
  "unsupported", so System Settings could not read the current mode. It is now
  answered the way Apple's own driver does it: a 28-byte payload (enabled flag,
  flags, rotation interval, current address) whose layout and size were read
  from Apple's IO80211FamilyLegacy and AirPort_BrcmNIC binaries. The driver
  stores the mode macOS sets and reports it back. It does **not** change the
  radio's address from this request: the per-network address is still applied
  by the existing `setHardwareAddress` path before each join. Whether this makes
  the control usable is **unconfirmed**; every request is logged
  (`PRIVATE_MAC get/set`) so the next report shows what macOS sends.
- **The report tool could never see the driver log, and now can.** The driver
  does not write its lines to the macOS system log (macOS shows kernel text from
  kexts as `<private>`); it keeps them in a 32 KB ring buffer published as the
  `DiagnosticLog` registry property. `tools/rtl88wifi-join-report.sh` read the
  system log, which is why every earlier report held no driver lines. It now
  reads the ring (via `ioreg -a`, with a text fallback), shows how long before
  the newest line each event happened, lists every join attempt and every
  Private Wi-Fi address change, and flags a wrapped buffer. Its line arguments
  changed: a number of lines or `all` (no time windows).
- **Fixed in the tool while testing:** one output section printed full MAC
  addresses; all log output now goes through a single redaction step.

Not changed: the iPhone hotspot problem (still no evidence; see the docs for the
one thing to do before rebooting), WPA3, AirDrop/Continuity, TX rate starting low
after idle.

## 1.0.4 — 2026-10-24 (unofficial community fix, not by the original author)

Follow-up to a tester's report on 1.0.3 (RTL8821CE, OpenCore): after boot or a
Wi-Fi off/on the card often joined the 2.4 GHz node of a dual-band network
instead of the 5 GHz one, sometimes needing several tries to reach 5 GHz. Build
identity `1.0.4-rtl88wifi-r15-20261024`. **Not yet run on hardware.**

- **Likely cause was 1.0.2's own change, now fixed.** Node selection gave 5 GHz
  only +5 dB over 2.4 GHz, but 2.4 GHz is usually a few dB *stronger* at the
  same spot, so the winner flipped between bands with small signal changes
  between scans. A usable 5 GHz node (>= -72 dBm, seen in the latest scan) now
  beats any 2.4 GHz node; marginal 5 GHz still loses to a good 2.4 GHz link.
- **1.0.2's "requested BSSID not in the scan cache, use any other node" is
  removed.** It could silently turn a request for the 5 GHz node into a 2.4 GHz
  join. An unknown BSSID reports "not found" again, as the original driver did.
- **New, switchable: a requested 2.4 GHz node is upgraded to 5 GHz.** If macOS
  itself names a 2.4 GHz node but a fresh, usable 5 GHz node of the same SSID
  and security type is known (and has not just failed), the driver joins the
  5 GHz node. If it then fails, the node macOS asked for is the fallback. Set
  the Info.plist key `RTL88WiFiPrefer5GHz` to `false` to honour the requested
  BSSID exactly (`PREFER_5GHZ_POLICY` in the registry shows the setting).
- **Every join request is now logged**, including the reason for each early
  refusal (for example a WPA3-only request), plus one line per join saying
  whether macOS named a BSSID, how many 2.4/5 GHz nodes were known, and which
  band was chosen. Lengths and flags only: no key bytes, no BSSID.
- **`tools/rtl88wifi-join-report.sh` fixed**: its filter could pick up an
  unrelated macOS message that merely mentioned the folder name, so a report
  could contain no driver lines at all. It now matches the driver's own prefix,
  summarises each join attempt found in the log, and accepts a longer window
  or `boot`.

Not changed: the iPhone hotspot problem (cause still unknown, evidence now
captured per attempt), WPA3, AirDrop/Continuity, TX rate starting low after
idle.

## 1.0.3 — 2026-10-24 (unofficial community fix, not by the original author)

Follow-up to 1.0.2 after a tester's report on an RTL8821CE: 1.0.2 built and
loaded, the noise value now shows, and upload speed improved; mesh joining has
not been tested yet and an iPhone hotspot still does not connect. Build
identity `1.0.3-rtl88wifi-r14-20261024`. **1.0.3 itself has not been run on
hardware.** Details: [docs/FIXES-1.0.2.md](docs/FIXES-1.0.2.md).

- **Protected joins no longer fall back to "no security".** If macOS asked for
  a protected PSK join and supplied the 32-byte key, but the driver's simple
  beacon parser did not recognise the AP's security, the driver associated with
  no RSN element and then declared the link up with no keys. No protected AP
  accepts that. A PMK on a protected BSS is now trusted as WPA2-CCMP-PSK, since
  macOS parsed the AP's full RSN element before asking. Open networks and joins
  without a PMK are unchanged.
- **One log line per join shows what the AP advertises**: channel, signal,
  capability bits, and the AP's RSN element (AKM list and capability bits),
  plus whether the driver chose WPA2. No network name and no BSSID is logged.
- **New tool `tools/rtl88wifi-join-report.sh`** (read-only): run right after a
  failed join; it shows what macOS asked the driver for, decodes a refusal
  (for example a WPA3-only request) in plain words, and prints the driver log
  with MAC addresses and the network name redacted.

The iPhone hotspot problem is **not** fixed: no defect that explains it was
found by reading the code, and the report tool exists to find out which of the
likely causes it is (see the docs). Also unchanged: the TX rate that starts low
after the link has been idle (firmware rate adaptation; see the docs).

## 1.0.2 — 2026-10-23 (unofficial community fix, not by the original author)

Targets the instability reported on RTL8821CE: noise shown as 0, upload speed
dropping, and mesh Wi-Fi sometimes failing to connect. Build identity
`1.0.2-rtl88wifi-r13-20261023`. Details, reasoning and limits:
[docs/FIXES-1.0.2.md](docs/FIXES-1.0.2.md).

**Status:** one tester has built and run this on an RTL8821CE (noise shows,
upload improved; mesh not yet tested). The author of the changes has no Mac or
card of their own: they were checked by reading the code and by host tests that
compile the changed functions (`tests/test-join-policy.py`, plus the existing
suites). Keep the previous EFI kext as a backup.

- **Noise no longer shows 0.** The RTL8821C parser never read the per-path RX
  SNR that its PHY status already carries (the field macros existed in
  `rtw8821c.h`); it now does, as the 8822C parser does. When no plausible SNR is
  available (idle 2.4 GHz link, no samples yet), noise falls back to the thermal
  noise floor for the channel width (−95 / −92 / −89 / −86 dBm for 20 / 40 / 80 /
  160 MHz). This is an estimate; `RADIO_NOISE_SOURCE` in the registry says
  `measured` or `estimated`. Other networks in the list now carry the same
  estimate instead of 0.
- **Upload drops and stalls: AWDL no longer takes the radio.** While the
  `awdl0` interface existed, the AWDL scheduler put the NIC in near-promiscuous
  receive mode and repeatedly retuned the radio to channels 6/44/149; during
  those windows en0 transmit was stalled, so a full-rate upload overflowed the
  256-packet output queue. AWDL has never found a peer on this driver, so the
  cost bought nothing. By default the AWDL interface now exists but never
  touches the radio, the RX filter, or the scheduler timer. Set the Info.plist
  key `RTL88WiFiAWDLRadio` to `true` to restore the old behaviour
  (`AWDL_RADIO_POLICY` in the registry shows the active policy).
- **Mesh: joining picks the best node.** The driver used to join the first
  list entry with a matching SSID, even if it was weak or stale. It now ranks
  nodes by signal, freshness and band, and demotes nodes that just failed.
- **Mesh: join failures are reported and retried on another node.** A rejected
  authentication or association (for example status 17 or 30 from a node that
  is band-steering or full) used to leave the driver silently idle, so macOS
  never learned the join had failed and retried the same node. Now the driver
  moves to the next node of the same SSID (up to 3 nodes per join, never
  crossing between protected and open), and only then reports the failure. A
  BSSID that macOS requests but that has aged out of the scan cache falls back
  to another node of that SSID instead of failing. Single-AP networks behave as
  before.

Not fixed (see the docs for why): WPA3/SAE, PMF-required networks, AirDrop and
Continuity, roaming between nodes while connected, 802.11k/v/r.

## 1.0.1 — 2026-10-14

Final maintenance release. It only corrects what macOS shows in System
Information (`system_profiler SPAirPortDataType`) and the Option-click Wi-Fi
menu. Throughput, connecting, sleep/wake and the data path are unchanged.
Build identity `1.0.1-rtl88wifi-r12-20261014`.

- **Transmit Rate and MCS Index** now show the card's real current transmit
  rate (for example 866 Mbps, MCS 9 on an 80 MHz 802.11ac link). Before, they
  showed the router's fastest basic rate (displayed as 108) and MCS 0. Right
  after joining, both stay empty for a moment until the card reports its
  first rate; no placeholder value is shown.
- **Signal / Noise** no longer shows a fixed −95 dBm noise. On RTL8822BE and
  RTL8822CE the noise value comes from the signal-to-noise ratio the card
  measures on the connected network (noise = signal − SNR; the cards have no
  direct noise-floor measurement, so this is an estimate). RTL8821CE does not
  measure SNR, so it reports no noise value. Other networks in the list show
  no noise value (0) instead of −95 dBm.
- **Channel width of nearby networks** now shows 40 or 80 MHz when the network
  uses it, instead of always 20 MHz.
- **Supported Channels** now follow the Wi-Fi country code: channel 14 is
  listed only in Japan, and channels 12–13 are hidden in the US, Canada and US
  territories. Elsewhere (for example Brazil) channels 1–13 are listed. When
  macOS has not set a country, the full list is shown as before.

Not changed in 1.0.1:

- **Card Type** shows the Realtek vendor ID and the card's PCI subsystem ID
  (for example `0x10EC, 0xC123` on some RTL8822CE boards). The value comes
  from the card itself; the driver does not set it.
- **AirDrop and Auto Unlock** are still listed as "Supported" although they
  do not work. The capability flags behind them are kept because changing
  them risks breaking driver loading.

These fixes have been built and checked for compilation only; they have not
been tested on hardware.

## Discontinued — 2026-10-06

Development has stopped. 1.0.0 is the final release; the kext in `Kexts/` is
unchanged. The README lists the remaining issues, which will not be fixed.

- Removed unused source files (Linux-only chip, transport and optional
  feature code, unreachable compatibility headers, an unbuilt kext class).
  The driver still builds to the same binary.
- Test fixtures use generic network names and addresses.

## 1.0.0 — 2026-10-02

First release under the RTL88WiFi name.

- Driver, executable and bundle renamed to `RTL88WiFi`
  (`io.github.x1ren41l.RTL88WiFi`), with native controller/interface classes
  `RTL88WiFi` / `RTL88WiFiInterface`. Build identity
  `1.0.0-rtl88wifi-r11-20261002`.
- WPA2 handshake retries, key installation and group rekeys fixed; stable
  SNonce; idempotent key install.
- Router HT/VHT capabilities parsed and used (5 GHz at line rate).
- Memory, firmware-bounds and station-lifetime fixes.
- Correct disconnect reasons, Sonoma-format network info, SSIDs kept in scan
  results, AP IE list ABI fix.
- Beacon TIM kept for the connected network and scan padding no longer
  copied (hidden-network label after wakes and network switches).
- Undecrypted/plaintext frames on protected links dropped; FragAttacks
  A-MSDU check; multicast and NoAck QoS traffic bypass RX reordering.
- Output-pull limit and two experimental output gates. On the current
  IO80211 push data path these gates do not engage; they are kept for
  diagnostics.
- Built-in `DiagnosticLog` with queue drop/stall counters.
- Added `tools/rtl88wifi-check.sh`, `docs/COMPATIBILITY.md` and issue
  templates for compatibility reports.

Hardware verification (RTL8821CE, Sonoma 14.8.9): load and join, ~15 minutes
of load and idle without link drops, 0% idle ping loss, `networkQuality`
86–87 down / 89–105 up Mbps. Known remaining issue: queue drops under heavy
parallel uploads (see README).
