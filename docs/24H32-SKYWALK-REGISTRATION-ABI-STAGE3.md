# Sequoia 15.8.1 (24H32) Skywalk registration ABI audit — Stage 3

**Target:** macOS 15.8.1, Darwin build 24H32, Intel x86_64
**Purpose:** prevent the native WCL path from registering or publishing an
interface using an unverified private Skywalk registration contract.

## Findings

### Facts recorded from the target machine's ABI archive review

The ABI review for the archive in `shammu2bd/Realtek-WIFI-Native-macOS` records these target
facts: Darwin 24.6.0 / `xnu-11417.140.69.712.69`, x86_64, and the following
class sizes / vtable spans:

| Class | Size | Vtable slots |
|---|---:|---:|
| `IOSkywalkInterface` | `0xb0` | — |
| `IOSkywalkNetworkInterface` | `0xd0` | 335 |
| `IOSkywalkEthernetInterface` | `0x110` | — |
| `IO80211SkywalkInterface` | `0x118` | 463 |

The reviewed method list contains the base network-interface registration,
deregistration, logical-link registration, BSD-interface preparation and
finalization, BSD command handling, and link-status methods. The wireless
Skywalk class exposes link/scan/datapath and queue/completion accessors. These
class-size and vtable facts do not, by themselves, establish the private
registration payload's fields or the return-value convention of a
non-virtual registration method.

### Pinned SDK declarations

The bundled `MacKernelSDK/Headers/IOKit/skywalk` headers declare both
`IOSkywalkNetworkInterface::RegistrationInfo` and
`IOSkywalkEthernetInterface::RegistrationInfo` only as forward declarations.
The public methods are declared with `IOReturn` for
`registerNetworkInterface()` and `registerEthernetInterface()`, while
`initRegistrationInfo()` returns `bool`.

### Independent Sequoia private-header cross-check

The Sequoia 15.x private WCL headers in the GPL-2.0 AirportRTW reference tree
represent each registration payload as an opaque `0x130`-byte buffer. They
also declare `registerEthernetInterface()` as returning `bool`, which conflicts
with the bundled SDK declaration's `IOReturn`. This is a real callable-ABI
ambiguity: the C++ symbol name does not encode the return type, and the method
is non-virtual, so class size and vtable comparisons cannot settle it.

This cross-check is useful evidence, but it is not a substitute for directly
checking the matching function body in this target machine's 24H32 kernel
collection. The payload's field-level meaning is still unknown. The `0x130`
size is therefore recorded as a reference value, not used as an allocation
size in this source slice.

Reference files inspected at AirportRTW commit
`82c78d0b1c300b25a6706c433170c1c635293670`:

- `include/Airport/macOS15/IOSkywalkNetworkInterface.h`
- `include/Airport/macOS15/IOSkywalkEthernetInterface.h`
- `AirportRTW/WCL/AirportRTWV2.cpp` (startup/registration sequence)

No AirportRTW source implementation was copied into RTL88WiFi in this stage.

## Stage 3 source changes

`RTW88WCL24H32InterfaceABI.hpp` now treats both registration payload types and
both expansion-data blocks as opaque. It no longer models either payload as a
made-up C++ byte-array object, and it does not expose the disputed callable
registration methods to native driver code. This prevents accidental
`sizeof(RegistrationInfo)`, allocation, copy, or registration calls until the
24H32 callable ABI and lifecycle are proven.

The source continues to declare the 24H32 virtual logical-link method because
that is part of the vtable surface. The existing object-size assertions remain.
No queue is registered, no queue callback is activated, and no BSD or WCL
service is published.

## Registration sequence reference — not yet adopted

The AirportRTW Sequoia WCL implementation illustrates a startup sequence that
sets the Skywalk interface role and ID, attaches it to the controller, attaches
a BSD interface, initializes registration information, allocates the base and
derived expansion-data payloads, optionally defers BSD attach, starts the
Skywalk interface, and then publishes the BSD and controller services.

That is an architectural reference only. RTL88WiFi must not copy that sequence
until the following have been audited for 24H32: the exact private payload
size/alignment, both expansion-data allocation extents and ownership, the
registration function return convention, role/ID semantics, attach ordering,
BSD publication ordering, queue-to-pool association, and every rollback path.
The RTL88WiFi controller also has its own PCI/radio ownership model and cannot
simply transplant the reference driver lifecycle.

## Current safety fence

- `RTW88WCLController::start()` deliberately tears down and returns `false`
  instead of publishing the controller while the packet path is incomplete.
- `RTW88WCLInfraInterface::start()` deliberately returns `false`.
- BSD interface parameters are not implemented and return
  `kIOReturnUnsupported`.
- The four queue callbacks remain fail-closed (`kIOReturnNotReady`).
- The queue objects remain compile-only and unregistered; the native objects
  remain outside `AIRPORT_ALL_OBJS` and the legacy kext link.
- The current legacy kext and its OpenCore dependencies are unchanged.

## What will close this ABI gate

1. Run the included read-only collector against the original 24H32 archive:
   `python3 tools/audit-skywalk-registration-24H32.py /path/to/RTL88WiFi-Sequoia-24H32-kcabi.tar.gz --output build/24H32-registration-audit.txt`.
   Inspect the actual disassembly for
   `IOSkywalkEthernetInterface::initRegistrationInfo`,
   `registerEthernetInterface`, `deregisterEthernetInterface`, and the base
   network registration/deregistration methods. Resolve the return convention
   and parameter/flag behavior from the target binary rather than guessing.
2. Resolve the target's registration payload allocation size/alignment and
   both expansion-data allocation requirements. Confirm all fields consumed by
   the kernel before allocating or copying into them.
3. Compare the relevant method implementations and vtable slots to the
   target-machine archive, then build a minimal registration probe that keeps
   TX/RX callbacks inert and can be safely rolled back.
4. Only after the probe is ABI-clean should TX/RX queue submission, packet
   completion, and BSD publication be enabled in separate tested stages.

This Stage 3 slice is an ABI safety correction and audit, **not** an interface
registration implementation or a driver-ready milestone.

## Validation performed for this slice

Passed host checks:

- `tests/test-wcl-registration-contract.py`
- `tests/test-wcl-abi-surface.py`
- `tests/test-wcl-skywalk-queues.py`
- `tests/test-wcl-controller-lifecycle.py`
- `tests/test-wcl-pci-backend-owner.py`
- `tests/test-wcl-packet-path-stage2.py`
- `tests/wcl-event-ring-test.cpp`
- `tests/wcl-request-decoder-test.cpp`

Host Clang 17 with an `x86_64-apple-macosx13.0` target, `-mkernel`, and
`-fapple-kext` also generated Mach-O x86_64 objects for the native controller,
infrastructure interface, PCI backend and Skywalk queue owner. This is a host
compiler cross-target check against the pinned headers; it is not the target
Mac's Xcode 16.4 build, native kext link, kernel load, or physical Wi-Fi test.
The two compatibility warnings in the PCI backend and the non-standard-layout
`offsetof` warning remain visible and were not suppressed.
