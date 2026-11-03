# Changelog

## Sequoia WCL development — Stage 12.1 (2026-11-01; ABI collector parser repair)

- Accept exact Itanium mangled symbol tokens embedded in kcabi method-list rows.
- Add class-owned `INDEX.txt` fallback when method lists contain no mangled tokens.
- Preserve and identify temporary pass data when Stage 12 extraction fails.
- Expand parser regression tests for inline symbols and index fallback.
- No kext datapath or registration behavior changed.

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

## RTL88WiFi 1.0.11 — Private Wi-Fi Address Skywalk dispatch

Build identity: `1.0.11-rtl88wifi-r22-20261031`. This is an unofficial
community source update. The macOS kernel extension has not been built with
Apple’s Xcode kernel toolchain or tested against the Settings UI on physical
hardware. Host-side tests check selector dispatch structure and the existing
Off/Fixed/Rotating state machine.

### Changes

- **Skywalk GET:** adds `apple80211_ioctl_get(IO80211SkywalkInterface *, void *)`
  and routes primary-interface selector 238 to the private-MAC GET handler.
- **Skywalk SET:** routes selector 238 through the same strict 28-byte payload
  adapter in the Skywalk-only split SET ingress.
- **Legacy split GET:** adds the corresponding `IO80211Interface` GET override.
- **Unified marshalling:** legacy ioctl, Legacy split GET/SET, and Skywalk split
  GET/SET use one checked copyin/copyout adapter. Other selectors and virtual
  interfaces continue to the family implementation.
- **Diagnostics:** records `STA_PRIVATE_MAC_GET_SEEN`,
  `STA_PRIVATE_MAC_SET_SEEN`, `STA_PRIVATE_MAC_LAST_RET` and logs the exact
  ingress name without logging the MAC address.

### Why this change

Version 1.0.10 had a 28-byte selector handler and a Legacy BSD ioctl bridge, but
its source did not override the Skywalk split GET method and did not process
selector 238 in the Skywalk-only split SET method. That left a likely modern
macOS request path unhandled. This release fills those missing hooks. It is a
source-level diagnosis based on the available IO80211Controller SDK method
signatures and the user’s report showing no PRIVATE_MAC GET/SET events.

### What is not claimed

- This cannot override an MDM/configuration-profile restriction. Apple documents
  that a managed Mac may not allow this setting to be changed.
- This release does not add an undocumented CARD_CAPABILITIES bit.
- The dropdown becoming active and MAC changing correctly still require testing
  on the user's macOS version and adapter.
- WPA3-SAE remains disabled. Existing open Wi-Fi and WPA2 paths are preserved.
- Country code is not forced to US or BD.

### Validation

Host-side Python tests can verify source routing and the mode-state handler.
A real Xcode/macOS kernel build, Skywalk callback confirmation, System Settings
menu test, Off/Fixed/Rotating MAC transition test, and MDM-policy check remain
necessary. Keep a bootable EFI backup before installing.

## RTL88WiFi 1.0.10 — open association and Private Wi-Fi Address modes

Build identity: `1.0.10-rtl88wifi-r21-20261031`. This is an unofficial
community source update. The macOS kernel extension has not been built with
Apple's Xcode kernel toolchain or tested on physical Wi-Fi hardware; host tests
cover the changed decoder and PRIVATE_MAC handler only.

### Changes

- **Open-network association:** the newer 32-bit ASSOCIATE decoder now accepts
  an empty key object whose embedded key-version is zero, as supplied for an
  unsecured network. WPA2 still requires a version-1 key object and 32-byte
  PMK. This addresses the observed host request that otherwise fell through
  to the Ventura 16-bit parser and appeared as `lower=0, upper=1, ssidLen=0`.
- **PRIVATE_MAC transport:** added a narrowly scoped 28-byte GET/SET bridge for
  selector 238 on the primary interface where the restored family rejects the
  selector before forwarding it to the controller. The split SET hook uses the
  same validated payload handler.
- **Private Wi-Fi Address modes:** Off restores the EFuse/permanent station
  MAC; Fixed retains the host-supplied address or generates one if none is
  supplied; Rotating generates a new locally administered unicast address at
  the requested interval. Host-supplied unicast addresses are preserved as
  supplied, matching Apple's reference behavior.
- **Safe rotation:** changes are serialized through an IOKit workloop timer.
  A rotation that expires during a scan, authentication, association or an
  active link is deferred and retried rather than changing the station MAC
  mid-session. The requested interval is range-checked before milliseconds
  conversion.
- **MAC privacy in logs:** the backend no longer prints every full station
  address when programming it.
- **Country code:** no country is forced or hardcoded. The driver continues to
  use a valid regulatory country delivered by Apple80211 and reports the host
  value; this release does not make macOS replace its currently reported `US`
  with `BD`.
- **Security:** WPA3-SAE remains disabled; WPA2 and eligible transition-mode
  WPA2 fallback remain. This release does not implement OWE, SAE, PMF/BIP,
  or 802.11k/v/r.

### Validation

- `test-assoc-wire.py`: host32 open/no-key version-0 decode, 22-byte SSID,
  legacy misread reproduction, WPA2 and transition tests.
- `test-private-mac.py`: 28-byte ABI, Off/Fixed/Rotating state, supplied and
  generated addresses, interval bounds, pending workloop apply and source
  bridge guards.
- No macOS kernel compilation or over-the-air join validation was possible in
  this build environment. Treat the archive as experimental and retain a
  bootable EFI backup.

## RTL88WiFi 1.0.9 — host association ABI and open-network fix

Build identity: `1.0.9-rtl88wifi-r20-20261031`. This is an unofficial community
source update, not an upstream release. It has not been built with Apple's
macOS kernel SDK or verified against a physical access point in this
environment.

### Fixed / changed

- **Decode the newer 32-bit host ASSOCIATE payload.** The macOS 15/26 restored
  IO80211 path can pass a 32-bit field layout directly to the native
  `apple80211Request` callback. The driver previously interpreted it as the
  older Ventura structure, whose mode/auth fields are 16-bit. For an open
  network this produced the observed false values `auth lower=0`,
  `auth upper=1`, `SSID length=0`, causing the handler to reject the request
  before it reached the open-system association code. The new path validates
  the 108-byte common prefix with the existing strict `RTW88AssocWire` decoder,
  translates it to the legacy internal structure, and then uses the existing
  join path. The unknown request tail is not parsed.
- **WPA3-SAE remains disabled.** SAE-only requests remain rejected. A transition
  request may use the existing WPA2-PSK fallback only when WPA2-PSK is present
  and the decoded request includes the expected PMK.
- **Diagnostics are corrected.** A lower-auth value other than `1` is no longer
  automatically labelled WPA3. An empty SSID and the exact `lower=0 / upper=1`
  signature are reported as a possible 32-bit/16-bit ABI mismatch, not as proof
  of SAE. Early-rejected association headers are logged with lengths and flags
  only. The report now distinguishes a current result from a stale return value.
- **Country behavior remains host-driven.** The driver has no forced US or BD
  default. It continues to apply a valid country code supplied by Apple80211;
  this release does not claim to correct a country code that macOS itself
  reports as `US`.

### Validation

- Association wire decoder tests pass, including a regression reproducing the
  exact `lower=0 / upper=1 / SSID length=0` misread and verifying that the
  32-bit open request decodes to `lower=1 / upper=0 / SSID length=3`.
- Join-report tests pass.
- Roaming scan-policy source tests pass.
- Apple-only tests requiring `xcrun`/Xcode could not run in the Linux build
  environment. One unrelated test also hits a Linux `thread_t`/`NULL` type
  incompatibility. The macOS kext build and hardware join test remain required.

## RTL88WiFi 1.0.8 — open-network and WPA3-transition handling

### Fixed

- Corrected the Association Request Capability Information field. The old base value `0x0431` set the 802.11 Privacy bit even for open networks. Open joins now use `0x0421`; protected WPA2 joins use `0x0431`.
- Made the WPA2 selection policy require the BSS Privacy capability bit. A stale RSN hint or an unexpected PMK can no longer turn a genuinely open BSS into a protected association.
- Extended RSN AKM inspection to identify SAE/FT-SAE and the PMF Required (MFPR) bit.
- Added WPA2-PSK fallback for WPA2/WPA3 transition BSSs only when the AP permits a non-PMF WPA2 association.
- Rejects SAE-only or PMF-required networks clearly, because this driver does not yet implement SAE commit/confirm, PMF negotiation, or BIP management-frame keys.
- Allows the known WPA2-PSK + WPA3-SAE transition auth mask through the newer host association bridge, while keeping SAE-only requests unsupported.

### Security support status

- Open: supported by the open-system authentication path; association Privacy bit is now clear.
- WPA2-Personal (CCMP-PSK): supported by the existing PSK/4-way handshake path.
- WPA2/WPA3 transition: WPA2-PSK fallback only, where PSK is advertised and PMF is optional.
- WPA3-Personal (SAE-only): **not implemented**.
- PMF-required networks: **not implemented; rejected deliberately**.

This release does not claim full WPA3 support. Real WPA3-Personal needs a complete SAE exchange and PMF/BIP support, not just an RSN AKM flag.

### Validation

The host tests for association-wire parsing and join/security policy pass. The full macOS kernel extension build and hardware association tests still need to be run on macOS with Xcode and a supported PCIe adapter. Two unrelated host tests depend on Apple-only SDK facilities and cannot run in the Linux test container.

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
