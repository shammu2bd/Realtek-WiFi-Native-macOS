# Sequoia 15.8.1 (24H32) ABI review

## Archive verification

The supplied archive `RTL88WiFi-Sequoia-24H32-kcabi.tar.gz` was retrieved from the public `shammu2bd/BDIX-TV` repository, decompressed, and its tar directory parsed successfully.

- Compressed archive size: 402,248 bytes (about 393 KiB)
- Archive entries: 486
- Uncompressed tar payload: 2,612,224 bytes
- Target product version: macOS 15.8.1
- Target build: 24H32
- Architecture: x86_64
- Kernel collection: `/System/Library/KernelCollections/BootKernelExtensions.kc`
- Recorded kernel: Darwin 24.6.0, `xnu-11417.140.69.712.69`
- Kernel collection SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`

The archive contains method lists, vtables, class-size records, selected disassemblies, WCL dispatch tables, callback arrays, and source metadata. `rtl88wifi-target.txt` and `source.json` agree on the target. `missing-functions.txt` is empty; the dump metadata reports 362 functions dumped and zero missing relative to its reference list. That is an ABI-dump result, not a driver build or hardware-validation result.

## Framework versions recorded by the dump

| Bundle | Recorded version |
|---|---:|
| `com.apple.iokit.IO80211Family` | 1200.13.1 |
| `com.apple.iokit.IOSkywalkFamily` | 1.0 |
| `com.apple.iokit.IONetworkingFamily` | 3.4 |
| `com.apple.driver.corecapture` | 1.0.4 |
| `com.apple.driver.AppleBCMWLANCoreMac` | 1.0.0 |

The collection contains the in-box `IO80211Family` and `IOSkywalkFamily` components needed by the native path. This supports targeting those system frameworks; it does not support injecting a downgraded copy of either framework.

## Class sizes and vtable spans

The following values are read from `24H32/sizes.txt` and the matching vtable reports in the supplied archive.

| Class | Size | Vtable slots | Vtable bytes |
|---|---:|---:|---:|
| `IO80211Controller` | `0x128` | 466 | `0xE90` |
| `IO80211InfraInterface` | `0x120` | 468 | `0xEA0` |
| `IO80211SkywalkInterface` | `0x118` | 463 | `0xE78` |
| `IOSkywalkNetworkInterface` | `0xD0` | 335 | `0xA78` |
| `IOSkywalkEthernetInterface` | `0x110` | — | — |
| `IO80211InfraProtocol` | `0x120` | — | — |
| `AppleBCMWLANCore` | `0x130` | — | — |
| `AppleBCMWLANSkywalkInterface` | `0x130` | 659 | `0x1498` |
| `AppleBCMWLANInfraProtocol` | `0x128` | 658 | `0x1490` |

Important `IOSkywalkNetworkInterface` methods found in the method list include `registerNetworkInterface(...)`, `deregisterNetworkInterface(...)`, `registerNetworkInterfaceWithLogicalLink(...)`, BSD-interface preparation/finalization, BSD command processing, and link-status reporting. The `IO80211SkywalkInterface` method list includes interface initialization/start/stop, MAC-address access, link state, scan state, controller access, datapath enable/disable, and RX/TX completion/queue accessors.

These sizes and slots are consistent with the Sequoia 15.2-era private headers used by the AirportRTW native target, but each declaration used in a build still needs to be checked against the 24H32 method list and vtable. A matching class size alone does not prove matching argument types or method order.

## What this means for RTL88WiFi

The current 1.0.11 controller is a Ventura-era `IO80211FamilyLegacy` implementation. Its source uses the legacy `apple80211_ioctl` / `apple80211Request` transport and an `IO80211Interface` subclass. The current bundle plist declares `com.apple.iokit.IO80211FamilyLegacy`.

A native Sequoia port therefore needs a separate Apple-facing frontend. It must not be implemented by simply deleting the `IO80211FamilyLegacy` dependency key. The ABI evidence supports this architecture:

1. Keep the Realtek radio backend and its existing firmware, PCI, DMA, interrupt, rate-control, aggregation, and `RTW88IEEE80211` logic.
2. Add a native controller implementation against the Sequoia `IO80211Controller` ABI and its required controller callbacks.
3. Add an infrastructure interface deriving from the native `IO80211InfraProtocol` / `IO80211InfraInterface` path, backed by `IO80211SkywalkInterface` and `IOSkywalkNetworkInterface`.
4. Register the native Skywalk interface and BSD interface using the registration information and expansion-data layout required by this build.
5. Implement WCL scan, join/associate, abort, leave, key, channel, BSS, RSSI, and link-state requests. Deliver the WCL event messages in the expected order; the existing five-event `RTW88EventDelegate` is not a complete WCL event interface.
6. Adapt the Skywalk TX/RX queues and packet-completion/flow-control lifecycle to the existing backend's `mbuf_t` API. Packet ownership and metadata must be explicit; an `outputPacket(mbuf_t)` implementation by itself does not provide the Skywalk datapath.
7. Add a hard build guard for the validated target (`15.8.1`, `24H32`, `x86_64`) so a mismatched private ABI cannot be loaded accidentally.

The AirportRTW Sequoia target currently uses a two-personality provider pattern:
an `IOPCIDevice` personality creates an `IOPCIEDeviceWrapper`, then a
`NetworkController` personality (with `IOMatchCategory = WiFiDriver` and
`IONetworkRootType = airport`) matches that wrapper. RTL88WiFi currently starts
directly from `IOPCIDevice`; decide whether a wrapper is required for native
controller registration on 24H32 before changing the IOKit personalities. Do
not assume that copying the plist alone is sufficient.

The AirportRTW WCL source is a useful implementation reference for native controller startup, `IO80211InfraProtocol` methods, WCL requests/events, registration, and queue handling. It is GPL-2.0 at the repository root, not GPL-3.0. Its WCL implementation is tied to AirportRTW's `ItlHalService` / `net80211` types, so it cannot be copied wholesale into this driver: preserve its required copyright/license notices and adapt the behavior to the existing `RTW88IEEE80211` API. Review any separately licensed bundled components before reuse.

## Dependency and OpenCore decision

**Current 1.0.11 binary:** keep its matching legacy stack and existing OpenCore settings. Do not remove `IO80211FamilyLegacy.kext`, do not remove the replacement Skywalk kext, and do not unblock Apple's Skywalk bundle while booting this binary.

**Future native WCL binary, only after it is implemented and tested:** its bundle should depend on the in-box `com.apple.iokit.IO80211Family` and `com.apple.iokit.IOSkywalkFamily` (plus the other actual dependencies used by the build), and should not declare `com.apple.iokit.IO80211FamilyLegacy`. OpenCore should then stop injecting the legacy/replacement frameworks and stop blocking Apple's native Skywalk bundle. This is a target-state description, not an installation instruction for the present kext.

## Validation status

- [x] Archive retrieved, decompressed, and 486 tar entries parsed
- [x] Exact OS build, architecture, kernel collection hash, and framework versions read
- [x] Key class sizes and vtable spans extracted
- [x] Native vs legacy dependency boundary identified
- [ ] Native WCL controller/interface implementation
- [x] Existing host-side RTL88WiFi validation scripts run (see below)
- [ ] 24H32 compile and static vtable/ABI verification with Apple's macOS SDK
- [ ] RTL8821CE physical scan, WPA2 join, TX/RX, sleep/wake, and panic-log tests

### Existing host-side checks

The following existing host tests passed in this environment: `test-focused.py`,
`test-assoc-wire.py`, `test-handshake.py`, `test-rx-filter.py`,
`test-scan-ssid.py`, `test-join-policy.py`, `test-join-report.py`,
`test-private-mac.py`, `test-ba-recovery.py`, and `test-roam-scan-policy.py`.
`test-group-key.py` could not compile here because the Linux container does not
provide Apple's `CommonCrypto/CommonSymmetricKeywrap.h`; run it on the target
macOS build host. These are existing backend host checks, not native-WCL tests.

No kext was compiled or installed as part of this ABI review.
