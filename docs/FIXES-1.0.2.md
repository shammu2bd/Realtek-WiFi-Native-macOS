# RTL88WiFi 1.0.2 to 1.0.7 — what changed, and what did not

Unofficial community changes on top of 1.0.1, aimed at a card that works but is
not stable. Read this before building.

> **Status.** The author of these changes has no Mac, Xcode toolchain or
> RTL8821CE card. Everything was checked by reading the code paths end to end
> and by host tests that compile the *actual* changed driver functions (the
> existing suites still pass, and the new ones were mutation-tested so they are
> known to fail when the code is broken). That proves decision logic, not radio
> behaviour.
>
> **Confirmed on real hardware (1.0.2 to 1.0.4, RTL8821CE, OpenCore):** it builds
> and loads, the noise value shows, upload speed is better, and 5 GHz is now
> preferred. **Not yet confirmed:** mesh joining, and everything new in 1.0.5, 1.0.6
> and 1.0.7. **Keep your current
> working `RTL88WiFi.kext` and a bootable EFI backup.**

## Summary

| Symptom | Result in 1.0.7 |
|---|---|
| Noise shows 0 | **Fixed, confirmed by a tester.** Real measurement when the card reports one, otherwise a labelled estimate. |
| Upload speed drops | **Root cause found and removed** (AWDL taking the radio). A tester reports upload is now the best they have seen. |
| Mesh Wi-Fi sometimes does not connect / roam | **Join fallback and cache-refresh fixes** plus bounded scan-assisted roaming. Still needs real mesh testing; 802.11k/v/r are not implemented. |
| iPhone hotspot does not connect | **Cause not yet known.** Does not connect with or without Maximize Compatibility. Every attempt is now logged; see section 6. |
| Joins the 2.4 GHz node after boot or Wi-Fi off/on | **Caused by my 1.0.2 change; fixed in 1.0.4, confirmed by the tester.** See section 8. |
| Private Wi-Fi address is greyed out ("Fixed" only) | **Cause found; fix in 1.0.5, effect unconfirmed.** See section 9. |
| Mesh: fine at first, slow or unstable after 40 to 60 minutes | **One real defect found and fixed in 1.0.6; not confirmed as your cause.** See section 10. |
| TX rate starts low (6 Mbps) when a transfer begins | **Explained, not changed.** Firmware rate adaptation after idle. See section 7. |
| WPA3 does not work | **Not fixed.** Needs a full SAE implementation. WPA2/WPA3 transition mode works. |
| AirDrop / Continuity do not work | **Not fixed.** AWDL has never found a peer on this driver. |

---

## 1. Noise shows 0

**Cause.** macOS shows noise from values the driver reports. The Realtek chips
have no noise-floor register, so the driver derives `noise = RSSI − SNR` from
the per-path SNR in each received frame's PHY status. Two problems:

1. On RTL8821C the parser (`rtw8821c.c`, `query_phy_status_page1`) never read
   the SNR field, although `rtw8821c.h` already defines it with the same layout
   as RTL8822C. `dm_info->rx_snr` therefore stayed 0 and no noise was available.
2. Even with SNR, a link that is idle on 2.4 GHz only sees CCK beacons, which
   carry no SNR sample, so there is a gap right after joining.

**Change.**

- `rtw8821c.c`: read `RXSNR_A` and store it in `rx_snr` (3 lines, same as the
  8822C parser).
- `RTW88LinkMetrics.hpp` (new): noise is `RSSI − SNR` when that is physically
  plausible for the channel width; otherwise the thermal noise floor
  `−174 dBm/Hz + 10·log10(BW) + 6 dB`: **−95 / −92 / −89 / −86 dBm** for
  20 / 40 / 80 / 160 MHz. SNR is never negative.
- Networks in the "other networks" list carry the same estimate for their
  width instead of 0.

**Honest limits.** The 8821C SNR layout is taken from the header and from the
8822C code; it could not be checked against a real card. If its units differ,
the plausibility window rejects the value and the estimate is shown instead, so
the display stays sensible, but it would then be an estimate rather than a
measurement. `ioreg` tells you which one you are getting (see *Verify*).
The estimate is a physical model, **not** a measured noise floor.

## 2. Upload speed drops

The 1.0.1 README lists this as "cause unknown". Reading the transmit path
explains it:

1. macOS enables the AWDL virtual interface `awdl0` shortly after boot.
2. That calls `setAWDLReceiveMode(true)`, which programs the RX filter with
   `FIF_OTHER_BSS | FIF_BCN_PRBRESP_PROMISC`: the NIC accepts essentially every
   frame on the channel. On a busy 2.4 GHz band, or a mesh with several nodes
   and many clients, that is a lot of unrelated traffic to process.
3. The AWDL scheduler then repeatedly parks the radio on channel 6 / 44 / 149.
   When associated, it sends a power-save Null frame to the router, retunes,
   and later returns.
4. While the radio is away, `outputPacket()` returns `kIOReturnOutputStall` for
   normal traffic. At ~100 Mbps a 10–50 ms stall is roughly 100–400 packets,
   which is enough to overflow macOS's 256-packet output queue. That matches
   the "slow transmit stalls of 10–50 ms" and "short bursts of UDP loss" in the
   old README.
5. All of this ran even though no AWDL peer has ever been seen.

**Change.** A policy flag (`RTL88WiFiAWDLRadio`, default `false`) is read from
the Info.plist personality at start. When it is false:

- `setAWDLReceiveMode(true)` is a no-op that reports success: normal RX filters
  stay in place.
- `setAWDLChannel()` refuses, so the radio never leaves the router's channel.
- The AWDL scheduler's `tick()` flushes whatever macOS queued and does **not**
  re-arm, so there is no 2–25 ms timer and no channel sweeping while idle.

The `awdl0` interface still exists, so macOS sees no missing component. To get
the old behaviour back for experiments, set `RTL88WiFiAWDLRadio` to `<true/>`
in each personality of the kext's `Info.plist`.

**Honest limits.** This removes the one cause I could demonstrate from the
code. Other causes of upload loss (the TX ring size, interrupt latency, the
family's own queue) are untouched and may still produce some drops under very
heavy parallel uploads. Whether it fully cures your drops needs a measurement
on your machine.

## 3. Mesh Wi-Fi sometimes does not connect

Three bugs in the join path, all in `RTW88IEEE80211.cpp`:

1. **First match wins / stale pinned BSSID.** `cmdConnect()` joined the first
   BSS in the list with a matching SSID. On a mesh that could be a weak or
   stale node. *Now:* candidates are ranked by signal, freshness and band,
   while recently failed nodes are demoted. When macOS requests a specific
   BSSID, the driver honours that exact BSSID. If it is missing from the cache,
   the driver performs one full scan and retries the same request. It does not
   silently substitute another mesh node; if the exact BSSID is still absent,
   the join fails explicitly. A requested 2.4 GHz BSSID may be upgraded to a
   same-security 5 GHz sibling only when that sibling is fresh, at least
   -72 dBm, not recently failed, and scores better than the requested node.
2. **Silent failure.** When a node rejected authentication or association
   (status 1, 12, 17, 30 and others are common from a mesh node that is
   band-steering or full), the driver dropped to idle **without telling macOS**.
   macOS then waited, retried the same node, and the same thing happened.
   *Now:* the failure is reported, and first the driver tries the next node.
3. **No fallback.** *Now:* a rejection, a silent node (two unanswered auth
   attempts when another node is available, otherwise three as before) or an
   association timeout moves the join to the next-best node of the same SSID,
   at most 3 nodes per join. It never crosses between a protected and an open
   network, never revisits a node, and reports failure to macOS if nothing
   works. A wrong password is **not** treated as a node failure (it fails in the
   4-way handshake, not here), so it does not hop between nodes.

Single-access-point networks behave as before apart from item 2 (the failure is
now reported instead of being silent).

Turning off the AWDL promiscuous receive mode (section 2) also removes a likely
extra load on busy mesh channels.

**1.0.7: bounded scan-assisted roaming and cache recovery.** When CoreWiFi
asks for a background scan while connected, the driver briefly scans up to
eight candidate channels. It prioritizes cached alternate BSSs for the current
SSID/security class, then uses remaining channels supplied by CoreWiFi. The
scanner returns to the home channel between channel visits and a partial scan
does not prune BSSs on channels it did not visit. When a join request names a
BSSID missing from the cache, one full scan is attempted before retrying the
same exact request. CoreWiFi still makes the final roam decision; this is not a
forced/instant roam and needs validation on a real multi-node mesh.

**Still not implemented:** 802.11k Neighbor Reports, 802.11v BSS Transition
Management, and 802.11r Fast BSS Transition (including FT authentication/IEs
and PMK-R0/PMK-R1 key handling). True 802.11s mesh-point mode is also not
supported. PMF-required networks remain unsupported.

## 4. WPA3 does not work — not fixed

WPA3-Personal uses SAE ("Dragonfly"), not a pre-shared key handshake. In this
driver macOS hands over a **pre-derived PMK** and the driver runs the WPA2
4-way handshake itself. The association request is only accepted with open
lower-auth, a PSK-type upper-auth and a 32-byte PMK; an SAE request fails that
validation (`RTL88WiFi.cpp`, around the `personal` auth mask). Supporting SAE means implementing, in kernel code:
P-256 elliptic-curve arithmetic and hash-to-curve, the SAE commit/confirm
exchange over authentication frames, PMKSA handling, **and** protected
management frames (BIP-CMAC, IGTK) in the key and RX paths, plus matching
whatever interface macOS uses to drive SAE, which I cannot inspect or run
here. Writing untested cryptography into a driver whose stated goal is
stability would be the wrong trade, so I did not.

**What works:** WPA2/WPA3 *transition* mode. The card joins as WPA2-PSK
(AES/CCMP).

If joining fails on a mesh in transition mode, check the router's
*Management Frame Protection / PMF* setting: it must be **Optional** (or
Disabled), not **Required**. Otherwise use WPA2-only (AES) for that SSID, or a
separate WPA2 SSID next to the WPA3 one.

## 5. AirDrop and Continuity do not work — not fixed

AirDrop, Handoff and Universal Clipboard rely on AWDL (a proprietary Apple
peer-to-peer Wi-Fi protocol) and, for discovery, Bluetooth LE. The driver has
an AWDL manager, but per the original notes no peer has ever been seen, and I
cannot make an Apple-protocol exchange work without the hardware and a second
Apple device to test against. I deliberately did **not** try, and section 2
turns the (non-functional) AWDL radio activity off by default because it costs
stability.

Also note that the RTL8821CE's Bluetooth is a separate device that this driver
does not cover, so Continuity features that need Bluetooth LE would not work
even if AWDL did.

If AirDrop/Handoff matter to you, the realistic route is a card macOS supports
natively (Broadcom-based; for example a Dell DW1560 for M.2 laptops or a Fenvi
T919 for PCIe desktops), keeping in mind that newer macOS versions need extra
patches even for those. Check a current guide for your macOS version before
buying.

---

## 6. iPhone hotspot does not connect — cause not yet known

This was a problem before these changes. I could not find a defect in the code
that explains it, and I will not guess and call it fixed. What I did find and
fix in 1.0.3 is a latent bug on the same path: when macOS asked for a protected
(PSK) join and the driver's simple beacon parser did not recognise the AP's
security, the driver associated with **no security element at all** and then
reported the link up with no keys. No protected AP accepts that. A protected BSS
joined with a PMK is now treated as WPA2-CCMP-PSK, because macOS has already
parsed the AP's complete security element before it asks. Whether this is what
stops your hotspot is unknown.

**Update.** The tester reports the hotspot does not connect with Maximize
Compatibility on *or* off, so cause 1 below (WPA3 on the 5 GHz hotspot) is less
likely, since Maximize Compatibility moves the hotspot to 2.4 GHz. The first
report captured nothing useful: it was run while connected to the home router,
and only the most recent request is shown at the top, so it described the
router join, not the hotspot attempt; its log section also held an unrelated
line because the filter was too loose (fixed in 1.0.4). From 1.0.4 every join
request and every refusal reason is written to the driver log, so the evidence
survives even if macOS reconnects to another network afterwards.

Three causes are plausible. Each has a two-minute test:

1. **The hotspot is WPA3.** Newer iPhones can offer WPA3 for Personal Hotspot.
   If macOS asks for WPA3-only, this driver refuses at once, before sending a
   single frame (see section 4). *Test:* on the iPhone, Settings → Personal
   Hotspot → turn **Maximize Compatibility** on. That forces 2.4 GHz and is
   Apple's setting for devices that have trouble with the default hotspot;
   whether it also changes the security mode depends on the iOS version, so
   treat success as a hint and confirm with the report below.
2. **The phone is too close.** A hotspot is normally used with the phone next to
   the laptop, which gives a very strong signal (−20 to −35 dBm). This port runs
   without rtw88's automatic receiver-gain control (the original author turned
   the periodic watchdog off: the port lacks the station tracking it needs, and
   a partial version retuned the radio under a live link), so the receiver gain
   stays at the chip's default and a very strong signal could overload it. *Test:* put the phone 3–5 metres
   away in the same room and try again.
3. **Something else.** That is what the report is for.

**Capture the evidence.** The first two reports contained no driver lines, and
that was a flaw in my tool, not evidence about your hotspot: it read the macOS
system log, but the driver does not write there (macOS shows kernel text from
kexts as `<private>`). The driver keeps its own 32 KB log in memory and
publishes it as the registry property `DiagnosticLog`; from 1.0.5 the report
reads that.

**Do this before you reboot, because the log lives in memory:** if you have
tried the hotspot since the last reboot, the attempts are probably still in it,
even on 1.0.4. The report script works on its own, so you can run the new one
against the build you already have:

```sh
bash tools/rtl88wifi-join-report.sh         # last 300 lines of the driver log
bash tools/rtl88wifi-join-report.sh all     # everything the driver kept
```

The section "Join attempts found in the log" lists each request macOS made, so
look for the hotspot attempt there even though the "Most recent join request"
at the top will show whatever network macOS joined last. Lines older than the
buffer (about the last few hundred events) are lost, so try the hotspot again
and run the report straight afterwards if the attempt is not in it.

It is read-only. It shows what macOS asked the driver to do and what the driver
answered, and says in plain words if the request was refused by design (WPA3,
no 32-byte key, not in the scan list). If the join was accepted it prints the
driver's log lines, including one new line per join, `rtw88: connect target ...`,
that shows the AP's channel, signal and security elements (an `rsn=` dump whose
AKM list tells WPA2, WPA3-transition and WPA3-only apart). MAC addresses are cut
to their last two bytes and the network name is never printed; only its length
and whether it has non-ASCII characters (such as the curly apostrophe in
"Name's iPhone") are kept. Paste the whole output.

## 7. The TX rate starts at 6 Mbps when a speed test begins

The rate macOS shows is the one the card's firmware reports, and the firmware
does its own rate adaptation. After the link has been idle it restarts from a
low rate and climbs as packets succeed, which takes a second or two; you saw it
settle at 300–433 Mbps, which is what a healthy 1x1 VHT80 link looks like.
This port also runs without rtw88's periodic watchdog (see section 6 for why
the original author turned it off), so the driver does not refresh the
firmware's signal hints. I did not change that: it needs station tracking the
port does not have, and switching it on blind risks destabilising a link that
works, which I cannot test. A short ramp
at the start of a transfer is expected and is not a stability problem.

## 8. Joins the 2.4 GHz node instead of 5 GHz

**Symptom (tester, 1.0.3):** after boot the card joins the 2.4 GHz node of the
dual-band network; turning Wi-Fi off and on sometimes lands on 5 GHz after the
2nd, sometimes the 4th or 5th try.

**Cause, and it was my 1.0.2 change.** Two things:

1. Node selection gave 5 GHz only +5 dB over 2.4 GHz. At the same spot 2.4 GHz
   is usually a few dB stronger (here about −40 vs −45 dBm), so which band won
   flipped with small signal changes between scans. The original driver picked
   the most recently scanned entry, which was reliably 5 GHz by accident, so I
   made it worse while "improving" it.
2. When macOS named a BSSID the driver did not have in its scan cache, 1.0.2
   joined any other node of the SSID instead of reporting "not found". Right
   after boot or a Wi-Fi power cycle (the cache is kept across power cycles but
   not complete until the 5 GHz channels have been scanned) that could silently
   turn a request for the 5 GHz node into a 2.4 GHz join.

**Fix (1.0.4).**

- A fresh 5 GHz node with a usable signal (−72 dBm or better) now gets +40, so
  it beats any realistic 2.4 GHz node of the same SSID. A weak 5 GHz node gets
  +5 only, so a good 2.4 GHz link still wins when 5 GHz is marginal. A node not
  seen in the last two scans gets no band bonus.
- An unknown requested BSSID is reported as "not found" again.
- If macOS itself names a 2.4 GHz node and a usable 5 GHz node of the same
  SSID and security type is known (and has not just failed), the driver joins
  the 5 GHz node. If that fails, the 2.4 GHz node macOS asked for is the
  fallback. Switch this off with `RTL88WiFiPrefer5GHz` = `<false/>` in the
  Info.plist (registry: `PREFER_5GHZ_POLICY`).

**Not known:** whether macOS names the BSSID itself on your machine. The driver
now logs one line per join, for example
`rtw88: connect pick pinned=1 nodes24=1 nodes5=1 upgraded=1 -> 5 GHz`, which
says whether it did, how many nodes of each band were known, and what was
chosen. If you still land on 2.4 GHz, send that line.

## 9. Private Wi-Fi address is greyed out and shows only "Fixed"

**What I found.** Two different mechanisms exist in macOS. Per-network address
changes arrive through `setHardwareAddress`, which this driver already handles
(the original author wrote it, and joins work). The control in Network settings
reads and writes a *separate* request, `APPLE80211_IOC_PRIVATE_MAC` (238). Apple's
IO80211 family has its own handlers for it (`getPrivateMAC`, `setPrivateMAC`),
but they only forward the request to the driver with a payload of exactly 28
bytes, and this driver replaces the family's dispatcher and answered
"unsupported". That fits a control that cannot read its current mode.

**Where the layout comes from.** The SDK defines only the number. I read the
layout from Apple's own binaries that ship in this repository: the family's
forwarders require 28 bytes, and the Broadcom driver's `getPRIVATE_MAC` /
`setPRIVATE_MAC` use: an *enabled* flag at +4, control flags at +8, a rotation
interval in seconds at +0xC (the driver multiplies it by 1000 for a timer; 0
means no rotation), and the 6-byte address at +0x10. Off, Fixed and Rotating map
to: not enabled; enabled with interval 0; enabled with a non-zero interval.

**What 1.0.5 does.** It answers the request like that: it keeps the mode macOS
sets and reports it back with the current address (default: enabled, no
rotation, which is what "Fixed" means). It does **not** change the radio's
address from this request, because `setMACAddress` rightly refuses to change the
address while connected, and the per-network path already works.

**What I do not know.**

- Whether this is enough for System Settings to enable the control. It may also
  depend on a capability bit that this SDK does not define. If it stays grey,
  that is where I would look next.
- Whether "Off" will make macOS put the real hardware address back. This driver
  reports its *current* address when asked for the hardware address, so after a
  private address has been programmed macOS might not know the real one. If Off
  does not restore it, send me the report: the "Station MAC address changes"
  section shows each address macOS set and each `PRIVATE_MAC get/set` it sent.
- "Rotating" is stored and reported but the driver does not rotate by itself.
- Whether the request reaches the driver at all on your setup. From Apple's own
  binary the route for the normal Wi-Fi interface is: the family's
  `getPrivateMAC` -> `apple80211RequestIoctl` -> the controller's command gate ->
  `apple80211Request`, which is where the new handler is (I checked that the
  slot it calls is `apple80211Request`). A different route exists for Skywalk
  interfaces (`apple80211SkywalkRequest`) that this driver does not implement;
  it should not be used because this driver only creates the legacy interface.
  If the report never shows a `PRIVATE_MAC` line after you open the network's
  details, the request is not arriving, and that route is the first place to look.

**To check.** After installing, open the network's details and look at the
control. Try Off, Fixed and Rotating one at a time, then run
`bash tools/rtl88wifi-join-report.sh` and send the whole output.

## 10. Mesh: fine at first, slow or unstable after 40 to 60 minutes

**Symptom (tester):** the connection is normal and fast at first, then becomes
slow or unstable after roughly 40 to 60 minutes. Only on the mesh network.

**What I found, and it is a real defect.** Transmit aggregation (sending several
frames in one burst) works only while a *Block Ack agreement* set up with an
ADDBA exchange is in force. The driver asked for it exactly once, right after
the keys were installed. If the AP later sent a DELBA (tear-down), declined the
request, or the response was lost, the driver set its flag to "off" and never
asked again for the rest of the connection. The link stays up, but every upload
frame goes out on its own, which is slow and erratic. This is consistent with
"fine, then slow", with a link that stays connected, and with a mesh: an access point can tear
these agreements down for several reasons (idle timeouts, internal resets,
steering), and a mesh has more of that going on than a single router. That last
point is a plausible expectation, not something I measured.

**What 1.0.6 does.** It keeps asking: when the AP tears the agreement down, or
declines it, or does not answer within 3 seconds, the driver sends a new request
after a backoff of 1, 2, 5, 10, 30, then 60 seconds. If an agreement lasted a
minute or more the backoff starts over. The backoff stops an AP that accepts and
immediately tears down again from causing a stream of requests. It does nothing
unless the link is up and not in a handshake. The retry runs from the existing
5-second diagnostic tick. The DELBA log line now carries the reason code
(37 declined, 38 unknown block ack, 39 timeout).

**What I do not know.** Whether this is *your* cause. A delay of about an hour
also fits other things, and I cannot tell them apart without evidence:

- **Key rotation.** Some routers and mesh systems rotate the group key about
  every hour (3600 seconds is a common setting). The driver handles group-key and pairwise rekeys with
  care (replay and integrity checks, the old key kept until the new one is
  authenticated), and I found no defect, but I cannot prove it works against
  every access point.
- **Radio drift.** The original author turned off rtw88's periodic watchdog,
  which among other things tracks temperature-related drift. A card that has been
  running for an hour is warmer than a fresh one. That could hurt the fastest
  rates most. I cannot test that and did not touch it.
- **The mesh itself**, for example steering the client between nodes or bands.

**How to tell them apart. Please do this the next time it gets slow, before you
turn Wi-Fi off and on:**

1. Run `bash tools/rtl88wifi-join-report.sh` (and send the whole output). Three
   things in it decide this:
   - **"Uplink aggregation"**: is aggregation OFF in the latest heartbeat, and is
     there an `RX DELBA ... reason=` line? If so, that is this defect, and the
     reason code says why the mesh did it.
   - **"Key rekeys and key errors"**: do group-key handshakes, or errors such as
     `MIC check failed`, line up with the time it got slow?
   - The times on the left are seconds before the newest line, so you can see
     what happened about an hour (3600 s) ago.
2. Is it **upload or download** that is slow? Run a speed test and note both.
3. Does **turning Wi-Fi off and on** fix it, and does it come back after the same
   40 to 60 minutes? If a full reboot is needed instead, that points at the radio
   rather than the link state.

The driver keeps only the last 32 KB of its log in memory, and it is erased at
reboot, so run the report while the problem is happening.

---

## Router settings that help (any Realtek card on this driver)

These are suggestions, not guarantees:

- **WPA2-PSK with AES/CCMP**, or WPA2/WPA3 transition with PMF *Optional*.
- **Separate SSIDs for 2.4 and 5 GHz**, or band steering off. A steering node
  answers with a rejection; 1.0.2 now copes, but avoiding it is cheaper.
- **Fixed 5 GHz channel outside the DFS range (36–48, 149–165)**. DFS channels
  need passive scanning and radar events make the AP change channel, which
  looks like a drop.
- If joins still fail, try disabling **802.11r (Fast Transition)** and
  **802.11k/v** for that SSID: the driver ignores them, and some mesh
  firmwares behave oddly when a client does not use them.

## Build, install, verify

```sh
cd driver/RTL88WiFi
make clean
make rtl88wifi            # output: build/out/RTL88WiFi.kext
```

Needs macOS with the Xcode Command Line Tools and `python3` (see the main
README). The zip you started from contained stale object files, hence
`make clean`.

**The path to the folder must not contain spaces.** The Makefile does not quote
paths, so a folder such as `rtl fix claude` makes `make` split it at the spaces
and fail with a flood of "circular dependency" warnings (and it leaves a stray
folder named after the second word behind). Rename the folder first.

1. Copy the new `build/out/RTL88WiFi.kext` over the one in `EFI/OC/Kexts/`,
   **keeping the old one somewhere safe**. Leave the other kexts and the config
   as they are. Do **not** use `Kexts/RTL88WiFi.kext` from the repository: that
   is an older prebuilt binary (it identifies as 1.0.0 r11) and does not contain
   any of these changes.
2. Reboot. Join your network.

**Verify it is the new build and the policies are active:**

```sh
ioreg -r -c RTL88WiFi -l -w0 | grep -E '"DriverBuild"|"AWDL_RADIO_POLICY"|"PREFER_5GHZ_POLICY"|"AWDL_SCHEDULER_STATE"|"RADIO_NOISE_SOURCE"'
```

Expected:

- `DriverBuild` = `1.0.7-rtl88wifi-r18-20261031` (earlier: `1.0.6-...-r17`, `1.0.5-...-r16`)
- `AWDL_RADIO_POLICY` = `disabled`
- `PREFER_5GHZ_POLICY` = `enabled`
- `AWDL_SCHEDULER_STATE` = `radio-disabled-by-policy` (may read `no-interface`
  until `awdl0` has come up)
- `RADIO_NOISE_SOURCE` = `measured` or `estimated`, present after the first
  noise query (open System Information → Wi-Fi, or Option-click the Wi-Fi menu).
  `measured` means the 8821C SNR field worked.

System Information → Wi-Fi → current network should now show a noise value such
as `-95 dBm` instead of `0 dBm`.

**Upload test.** Before and after, run `networkQuality` a few times on the same
network and compare the upload result and the drops figure. Runs vary a lot, so
compare several.

**Mesh.** With the kernel log open you should see, on a rejected node, a line
like `rtw88: join stage=assoc-rejected failed on aa:bb:... -- trying cc:dd:...`.
You can watch for it with:

```sh
log stream --predicate 'process == "kernel"' | grep -i rtw88
```

(Add `--info`/`--debug` if the lines do not appear.)

## Rolling back

Put the old `RTL88WiFi.kext` back in `EFI/OC/Kexts/` and reboot. To keep the new
build but bring back the old AWDL behaviour, set `RTL88WiFiAWDLRadio` to
`<true/>`.

## If it does not help

Please keep: the `ioreg` output above, `ioreg -l -w0 | grep DiagnosticLog`, and
the kernel lines containing `rtw88`. The most useful single piece of
information is whether `RADIO_NOISE_SOURCE` says `measured` and whether the
upload drops changed with `AWDL_RADIO_POLICY` = `disabled` versus `<true/>`.
