# Stage125 — Native Wi‑Fi Menu Readiness Audit

**Audit type:** Read-only source / control-plane audit  
**Target:** macOS Sequoia 15.8.1 (24H32), x86_64, RTL8821CE PCIe  
**Source base:** Stage124 commit `92322c8d966929649fa4a648570a917ea25b3b31`  
**Audit branch:** `work/stage125-native-wifi-menu-readiness-audit`  
**Driver source modified:** No  
**Build / signing / install / load / hardware test:** Not run  
**OpenCore / EFI / SIP / NVRAM:** No changes

## Executive result

**STAGE125_READINESS = BLOCKED_PENDING_POWER_STATE_AND_REGULATORY_DOMAIN_REVIEW**

The source contains the main native publication structure required for a native macOS Wi‑Fi service: a PCI personality for RTL8821CE, direct IO80211Family + IOSkywalkFamily dependencies, Apple primary-interface attachment, the audited 24H32 Skywalk registration helper, and delegation of BSD interface parameter creation to Apple’s base implementation. The scan, join, link-event and Stage124 BSSID-cache paths are also present.

That is not yet proof that the macOS Wi‑Fi menu will be visible or fully functional. Two control-plane issues require resolution, and runtime BSD ifnet/CoreWLAN enumeration remains unobserved.

## Findings

| Area | Result | Evidence / interpretation |
|---|---|---|
| RTL8821CE PCI match | **PASS** | Native Info.plist declares `IOProviderClass=IOPCIDevice`, `IOClass=RTW88WCLController`, and PCI IDs `0xC82110EC` / `0xB82110EC`. |
| Native framework dependency | **PASS** | Native bundle depends on `IO80211Family`, `IOSkywalkFamily`, `IONetworkingFamily`, and `IOPCIFamily`; no `IO80211FamilyLegacy` dependency appears in the native personality. |
| Apple primary-interface ownership | **PASS — source contract** | Interface calls Apple base start, attaches through controller `attachInterface`, then verifies `getPrimarySkywalkInterface() == this`. |
| Skywalk registration | **PASS — source contract** | Registration uses `registerInfraEthernetInterface`, commits the queue transaction only after success, and sets `_registered` afterward. |
| BSD/ifnet initializer | **PASS — delegation only** | `initBSDInterfaceParameters` calls `IO80211InfraInterface::initBSDInterfaceParameters`; actual runtime ifnet creation and interface naming were not observed. |
| Service publication ordering | **PASS — source contract** | Controller calls interface start/registration before `registerService()`, then enables the PCI interrupt source. |
| Scan request / result path | **PARTIAL** | Active and FAST scans enter the radio bridge; scan results and completion are posted with scan-generation checks. Passive/background scan requests are explicitly rejected as unsupported. |
| Join / association path | **PARTIAL** | WCL association passes the selected SSID/BSSID and PMK/RSN data to the internal RTW88 supplicant; association, connection-complete and link-status events are emitted. This does not establish a successful over-the-air join. |
| Current AP / BSSID state | **PASS — source contract** | Stage124 writes the validated target BSSID to the inherited current-AP cache before link-up publication and clears it on leave/deauth/disconnect. |
| Channel / RSSI selectors | **PASS — source path** | `getCHANNEL`, `getRSSI` and `getSUPPORTED_CHANNELS` have success-return paths when backend data is available. |
| Power-state reporting | **GAP — high priority** | Controller `getPOWER()` reports inherited `isInterfaceEnabled()`. The custom interface `enable()` / `disable()` paths power the RTW88 bridge and packet path but do not explicitly call the ABI-declared `setInterfaceEnable(bool)` or the base enable/disable methods. The source therefore does not prove that Apple’s reported enabled state follows actual radio power. |
| Regulatory country callbacks | **GAP** | Controller `getCOUNTRY_CODE()` and `setCOUNTRY_CODE()` return `kIOReturnNotReady`. Regulatory-domain negotiation is not implemented in these callbacks. |
| WCL optional/current-BSS selectors | **LIMITED** | A number of optional selectors are deliberately fail-closed, including `getWCL_BSS_INFO`, `getWCL_EXTENDED_BSS_INFO`, background-scan cache and several rate/capability/statistics selectors. Core menu visibility is not inferred from these omissions, but richer current-network details, roaming and diagnostics are not established. |

## High-priority control-plane gap: power-state mirroring

The audited source has three separate state surfaces:

1. The RTW88 radio hardware state, changed through `_bridge.powerOn()` / `_bridge.powerOff()`.
2. The controller packet-path state, changed through `activatePacketPath()` / `quiescePacketPath()`.
3. Apple’s interface-enabled state, read by `getPOWER()` through `isInterfaceEnabled()`.

The subclass's `enable()` and `disable()` implementations visibly manipulate the first two surfaces, but do not visibly synchronize the third. The 24H32 ABI shim declares `setInterfaceEnable(bool)` on `IO80211SkywalkInterface`. This is a source-level consistency gap; the exact Apple base-class call path and state semantics must be confirmed from the target 24H32 implementation before changing code.

**Do not patch this by guesswork.** The correct method/order must be established from the 24H32 base-class implementation or a pinned target disassembly, followed by a focused source regression test.

## Regulatory-domain gap

The country-code callbacks are explicitly nonfunctional. The driver does publish a supported-channel list derived from RTW88's wiphy channel flags, but the Stage125 source review does not establish that this is sufficient for Apple’s country/regulatory flow. Do not assume the native menu can scan every locally permitted channel until the regulatory path is reviewed.

## What this audit does not prove

- The kext is not loaded in the running kernel.
- The controller and interface are not observed in I/O Registry.
- No BSD `enX` interface has been observed for the native driver.
- CoreWLAN / Wi‑Fi menu visibility has not been tested.
- No scan list, association, link-up, TX/RX, or hardware behavior has been observed.
- The single prior Stage123 transient load attempt was rejected by macOS validation (staging ownership and code-signature failure). Stage125 does not repeat that attempt or bypass security.

## Recommended next work

1. Stage126: pin and inspect the exact 24H32 Apple `enable`, `disable`, `setInterfaceEnable`, and `isInterfaceEnabled` call/state behavior. Decide the minimal safe synchronization only after the call graph is proven.
2. Inspect the Apple 24H32 country-code / regulatory request flow and determine which selectors are actually queried before scan/menu publication.
3. Audit the WCL current-BSS and scan-result selectors against Apple’s 24H32 consumer call sites; implement only proven requirements.
4. Keep all runtime activation blocked until these source gaps are resolved and the macOS kext ownership/signing path is separately authorized and valid.

## Pinned source blobs

| File | Git blob SHA |
|---|---|
| Native Info.plist | `7e2477a97fc10d504ba8566afb3200ce4feed112` |
| RTW88WCLController.cpp | `253f8f6136788f8e8a063811172c9ed8eb1a906e` |
| RTW88WCLController.hpp | `aab83ca0e963f85c4fd455ac82cfe50bf8fb6e54` |
| RTW88WCLInfraInterface.cpp | `7621f15b25d94e882c3a89cc6d90f980bdde6dcc` |
| RTW88WCLInfraInterface.hpp | `f27344296e669defa0b46e0721ff4098d2a0e73c` |
| RTW88WCL24H32InterfaceABI.hpp | `0e155ec7dda26701bf962bb1442d6a54be0becb2` |
| RTW88WCLRadioBridge.cpp | `d358c6e066f5191dd9f07da0a27a70a44666ffc5` |
| RTW88IEEE80211.cpp | `d5843f181554a13baefc91a7823827141244e955` |

The Stage125 runner verifies these exact source blob hashes before emitting the audit findings.
