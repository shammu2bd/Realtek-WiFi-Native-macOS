# Stage122 — Read-only native primary-interface runtime diagnostics

## Purpose
Observe the currently running macOS state of the Stage121 native driver without loading, unloading, installing, activating, or changing any driver or system configuration.

Target: Intel x86_64 Hackintosh, macOS Sequoia 15.8.1 (24H32), RTL8821CE PCIe (10EC:C821).

## Evidence collected
- OS build and architecture.
- `kmutil showloaded` matches for the native bundle and known Realtek Wi-Fi bundle names.
- I/O Registry records for `RTW88WCLController` and `RTW88WCLInfraInterface`.
- PCI provider context for vendor 0x10EC / device 0xC821.
- Stage121 `RTW88WCLControllerStage` property on the PCI provider and `RTW88WCLInfraInterfaceStage` property on the controller.
- Recent `rtl88wifi-wcl` kernel log messages, including the exact attach/getter and detach/getter success markers.
- Current network hardware-port list, interface list, and AirPort system-profiler view.

## Interpretation rules
1. `Apple primary Skywalk interface attached and getter-verified` is runtime evidence that the Stage121 attach path called Apple's getter and confirmed pointer equality with the native interface object.
2. `native 24H32 infrastructure interface registered` is the source's registration success marker.
3. `native 24H32 infrastructure interface published` and/or the `RTW88WCLControllerStage` property are evidence that controller start reached its final publication point.
4. `Apple primary Skywalk interface detached and getter-verified` proves teardown getter verification only when a detach/stop event actually occurred. Absence is NOT_OBSERVED, not a failure.
5. An I/O Registry node or a BSD/network interface on its own does not prove primary-interface pointer identity.
6. Missing log entries may reflect log retention or logging visibility; classify them as NOT_OBSERVED rather than FAIL unless a corresponding explicit failure marker is present.

## Read-only boundary
The runner uses read-only inspection commands only: `sw_vers`, `uname`, `sysctl`, `kmutil showloaded`, `ioreg`, `log show`, `ifconfig -a`, `networksetup -listallhardwareports`, and `system_profiler`.

It does not invoke privileged commands, change network state, load/unload kexts, install bundles, reboot, write EFI/OpenCore/SIP/NVRAM settings, or modify the driver source. The only writes are its own report and canonical Git evidence, which it commits and pushes to this Stage122 branch.

## Completion criteria
A diagnostic run is PASS as a collector when all read-only commands were attempted and the report was published/read back. Runtime attachment itself is reported separately as VERIFIED, FAILED, or NOT_OBSERVED. A collector PASS must never be interpreted as a runtime attachment PASS.
