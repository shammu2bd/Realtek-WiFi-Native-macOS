# Stage111 — AMFIPass, OpenCore and live-runtime audit

**Target:** macOS Sequoia 15.8.1 (24H32), x86_64, Intel Hackintosh, RTL8821CE PCIe.  
**Base:** Stage110 audit commit `df4b52378a60e9e2ea78654ffd05eaae4588382e`.  
**Scope:** read-only inspection of the already-mounted USB EFI config, configured and live AMFI boot arguments, loaded-kext inventory, exact IORegistry class instances, Wi-Fi interface inventory and recent relevant unified logs.

## What is inspected

- OpenCore `Kernel -> Add`: AMFIPass and Lilu presence, enabled state, executable/version/hash/architecture metadata, and whether an enabled Lilu entry precedes an enabled AMFIPass entry.
- Native Realtek entry: enabled count, executable SHA-256 compared with the Stage108 candidate, and other Realtek frontend entries in the same Add array.
- Configured AMFI-related boot-argument tokens and live `kern.bootargs`, reported separately.
- SIP status.
- `kmutil showloaded` matches for AMFIPass, Lilu, RTL88WiFi, AirportRTW and RTW88.
- Targeted `ioreg` queries for the exact classes `RTW88WCLController`, `RTW88WCLInfraInterface`, `RTL88WiFi` and `RTL88WiFiInterface`, plus the RTL8821CE PCI node. The former broad IOService-tree dump is removed; long diagnostic lines are capped in the report.
- AirPort system-profiler summary, network hardware-port inventory and relevant unified-log messages from the last six hours.

## Important interpretation limits

The legacy driver and native candidate share bundle identifier `io.github.x1ren41l.rtl88wifi`. Therefore, a matching `kmutil showloaded` bundle ID is reported as **`AMBIGUOUS_SHARED_BUNDLE_ID`**, never as proof that the Stage108 native frontend is loaded.

The native frontend is considered present in IORegistry only when both native class instances are found. A controller-only or interface-only match is reported separately. Finding both classes still does not prove successful association, scan, TX/RX, throughput or stable operation. A generic Wi-Fi interface or a USB backup adapter is not proof that the RTL8821CE PCIe device is working.

AMFIPass being present in OpenCore does not prove that it is loaded or that it makes this particular unsigned kext loadable. A loaded bundle identifier does not prove which on-disk executable version is running. The Stage110 report found no valid Developer ID kext-signing identity, SIP enabled, and an EFI native executable hash that did not match Stage108. Stage111 rechecks these observations but does not attempt to resolve the hash or signing mismatch.

## Safety boundaries

The runner does not mount an EFI volume, change config.plist or NVRAM, modify boot arguments, change SIP, sign/build/install/load/unload any kext, start the radio, or perform hardware TX/RX tests. It only observes the current boot. Its output explicitly records `LOAD_UNLOAD=NOT_PERFORMED_BY_RUNNER` so that a user-performed kext selection is not confused with an action by the audit. It writes a timestamped diagnostic log and a summary append to `Development/output.log`, then commits and pushes those audit records. It does not modify driver sources or PR state.

The runner is pinned by Git blob SHA-1 in `Development/Allowlist/stage111-runtime-amfipass-audit.gitblob`. Verify the pin before execution. PR #4 remains draft/open/unmerged.

## Reference notes

- [Apple Platform Security — securely extending the kernel](https://support.apple.com/guide/security/sec8e454101b/web)
- [Apple Technical Note TN2206 — macOS code signing in depth](https://developer.apple.com/library/archive/technotes/tn2206/)
- [Dortania OpenCore Install Guide — Kernel Add and dependency load order](https://dortania.github.io/OpenCore-Install-Guide/config.plist/skylake.html)
- [AirportRTW README — its own documented Lilu / AMFIPass / AirportRTW setup](https://github.com/souissiak1-maker/AirportRTW)
