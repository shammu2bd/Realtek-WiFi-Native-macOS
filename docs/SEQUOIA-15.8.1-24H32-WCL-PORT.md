# RTL88WiFi native WCL port — macOS Sequoia 15.8.1 (24H32)

## Objective

Keep the RTL88WiFi Realtek hardware implementation and its current TX/RX behavior,
while replacing only the Ventura-era Apple Wi-Fi frontend. The intended final
OpenCore setup has one project kext (`RTL88WiFi.kext`) and uses the Apple-supplied
Sequoia `IO80211Family` and `IOSkywalkFamily`. It must not inject
`IO80211FamilyLegacy.kext`, a replacement `IOSkywalkFamily.kext`, or block the
built-in Skywalk bundle.

This is **not** an AirportRTW migration. AirportRTW's Realtek backend is not being
substituted for this project's backend.

## Exact target

- macOS: 15.8.1
- Darwin build: 24H32
- Expected architecture: Intel x86_64

The native IO80211/WCL interfaces are private kernel interfaces. Build-specific
class sizes, vtable slots, symbols, and event/request tables must be checked
against the target kernel collection before compiling a native frontend.

## Source audit

The current 1.0.11 source is not a native Sequoia WCL driver yet:

- `driver/RTL88WiFi/src/kext/RTL88WiFi.hpp` declares `RTL88WiFi` as an
  `IO80211Controller` subclass and implements legacy `apple80211_ioctl`,
  `apple80211Request`, `apple80211_ioctl_get/set`, and Ventura-era virtual
  interface methods.
- `driver/RTL88WiFi/src/kext/RTL88WiFiInterface.hpp` subclasses
  `IO80211Interface`.
- `driver/RTL88WiFi/RTL88WiFi.kext/Contents/Info.plist` declares
  `com.apple.iokit.IO80211FamilyLegacy` and `com.apple.iokit.IOSkywalkFamily`.
- `RTL88WiFi.cpp` creates the existing backend with
  `RTW88IEEE80211::createAirport(this, _compatPciDev)`.

The parts to preserve are the PCI/Realtek hardware initialization, firmware,
DMA, interrupt handling, the `rtw88` code, and the existing packet engine in
`RTW88IEEE80211.*` / `RTW88HwOps.*`.

Useful existing adapter points include:

- `RTW88IEEE80211::cmdScan()`
- `RTW88IEEE80211::cmdConnect()`
- `RTW88IEEE80211::cmdDisconnect()`
- `RTW88IEEE80211::cmdInstallExternalKey()`
- `RTW88IEEE80211::copyScanBSS()` / `copyCurrentBSS()` / `copyChannels()`
- `RTW88IEEE80211::outputPacket(mbuf_t)`
- `RTW88RxDelegate::injectRxFrame(mbuf_t)` and `allocateInputPacket()`
- `RTW88EventDelegate::rtw88Event()`

These APIs make it possible to isolate new WCL/Skywalk glue from the Realtek
radio engine. They do not, by themselves, prove that the native frontend is
implemented; packet ownership, metadata, completion, event ordering, and WPA2
key/supplicant transitions still need to be implemented and tested.

## Native frontend work required

Implement a new, isolated Sequoia WCL frontend (for example, in new
`RTL88WiFiWCL*` and `RTL88WiFiSkywalk*` files) instead of deleting legacy method
signatures from the old controller. The frontend must provide:

1. A Sequoia-compatible IO80211 controller / infrastructure-interface path and
   the required WCL request handlers for scan, scan abort, join/associate,
   join abort, leave/disconnect, BSS details, channels, RSSI, rate, and link state.
2. The WCL driver-available notification and subscriber/event registration
   expected by this exact OS build.
3. A Skywalk TX path that safely adapts packets to the existing
   `RTW88IEEE80211::outputPacket(mbuf_t)` path, including packet completion and
   flow control.
4. A Skywalk RX path that adapts the backend's Ethernet `mbuf_t` frames into
   the native receive queue, preserving ownership, length, interface, and
   metadata rules.
5. WPA2 association and key-install behavior that continues to use the existing
   backend and its current supplicant/key policy.
6. A build-specific guard so unsupported kernel builds refuse to start the
   native frontend rather than using a mismatched private ABI.

Do not route TX/RX through AirportRTW's radio implementation. Do not change the
Realtek rate-control, aggregation, firmware, DMA, or chip initialization code
unless a measured integration issue requires it.

## Licensing and reference implementation

The supplied ABI archive has now been reviewed; see
[`SEQUOIA-15.8.1-24H32-ABI-REVIEW.md`](SEQUOIA-15.8.1-24H32-ABI-REVIEW.md).

The relevant native-WCL reference is `souissiak1-maker/AirportRTW`. Its
repository-root `LICENSE` is GNU GPL version 2, not GPL-3.0-or-later, so it is
not automatically incompatible with this GPLv2 project. Retain all upstream
copyright and license notices for any code reused. Do not copy the WCL frontend
wholesale: it is coupled to AirportRTW's `ItlHalService` and `net80211` stack,
whereas this project uses `RTW88IEEE80211`. Adapt only the native ABI and WCL
control/data-path behavior that can be mapped correctly to the existing RTW88
interfaces. Check the license of every separately bundled component before
reuse.

The ABI facts in the review were generated from this machine's own
`BootKernelExtensions.kc` dump using the `kcabi` tooling; the dump is build
specific and must not be generalized to another macOS build without a fresh
capture.

## ABI capture

Run from this workbench on the target Hackintosh:

```sh
bash tools/collect-sequoia-abi-24H32.sh
```

The script verifies macOS 15.8.1 / build 24H32 / x86_64, uses
`watchthelight-labs/kcabi` to read `/System/Library/KernelCollections/BootKernelExtensions.kc`,
and creates:

`build/sequoia-abi-24H32/RTL88WiFi-Sequoia-24H32-kcabi.tar.gz`

The dump contains kernel ABI facts, not private user data. Upload that archive
back with this source tree so the WCL class layout, vtables, method names,
request/event tables, and linkable symbols can be generated and checked for
24H32.

Requirements: Python 3.9+, Git, and `llvm-objdump`. The `kcabi` README documents
MacPorts LLVM 20 as its tested `llvm-objdump` provider. The script does not
install packages, alter the EFI, change NVRAM, or modify the kernel collection.

## OpenCore safety rule

Until a newly built native-WCL RTL88WiFi kext has passed static link/ABI checks
and physical Wi-Fi scan, WPA2 join, TX/RX, sleep/wake, and panic-log testing,
keep the current known-good EFI backup and current legacy configuration intact.
Do not remove the existing legacy dependencies or Skywalk block while using the
current 1.0.11 binary: that binary still targets the legacy stack.

After the native port is completed and validated, the intended config is to
remove the injected `IO80211FamilyLegacy.kext` and replacement
`IOSkywalkFamily.kext`, remove the Apple Skywalk block, and declare the
built-in `IO80211Family` / `IOSkywalkFamily` as system dependencies in the new
kext's `OSBundleLibraries`. This is a future target state, not an instruction
for the current binary.

## Status

This workbench contains the source audit and an ABI collection helper. It does
**not** contain a completed native WCL implementation or a compiled kext yet.
A driver build cannot be honestly claimed until the 24H32 ABI dump is reviewed,
the new frontend is implemented, it compiles with Apple's macOS SDK, and it is
tested on the RTL8821CE hardware.

## Private implementation progress

The initial RTW88 radio bridge has been added in the private development snapshot. See `PRIVATE-WCL-IMPLEMENTATION-STATUS.md` for exact scope and remaining work. The bridge is not itself a native WCL frontend and must not be installed or loaded as one.
