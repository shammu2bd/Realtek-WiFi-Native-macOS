# Private Sequoia WCL implementation status

**Scope:** private engineering work only. No public-release work is in scope.

**Target:** macOS Sequoia 15.8.1 (24H32), Intel x86_64.

**Radio backends to preserve:** RTL8821CE, RTL8822BE, RTL8822CE. RTL8821CE is
first for physical testing; all three backends remain in the existing source
and build selection.

## Implemented layers

### RTW88 radio bridge

Files:

- `driver/RTL88WiFi/src/kext/RTW88WCLRadioBridge.hpp`
- `driver/RTL88WiFi/src/kext/RTW88WCLRadioBridge.cpp`

This adapter is independent of Apple's private WCL ABI and forwards scan,
abort-scan, association, abort-join, leave, RSN IE, optional external-key
installation, BSS/channel/state/RSSI queries and Ethernet `mbuf_t` output to the
existing `RTW88IEEE80211` state machine. Native WCL association currently
selects the backend's internal supplicant; the WCL protocol's PMK/PMKSA/MSK
`setCIPHER_KEY` path is not yet implemented by this backend. The bridge also
forwards backend events to an event sink. It refuses to replace an already-
installed backend event delegate and is non-owning: callers must quiesce the
radio before detaching or destroying it.

### Serialized WCL event queue

Files:

- `driver/RTL88WiFi/src/kext/RTW88WCLRadioEventRing.hpp`
- `driver/RTL88WiFi/src/kext/RTW88WCLWorkQueue.hpp`
- `driver/RTL88WiFi/src/kext/RTW88WCLWorkQueue.cpp`
- `tests/wcl-event-ring-test.cpp`

The producer copies fixed-size events into a 128-entry ring under an
interrupt-safe spin lock and signals an IOKit `IOEventSource`. The consumer is
scheduled by `IOWorkLoop`, processes at most 32 events per pass, preserves
ordering around scan/link transitions, coalesces only adjacent RSSI telemetry,
and evicts RSSI samples before dropping state-transition events. There is no
allocation on the producer path. The queue exists in the linked bridge target,
but it is not yet attached to a native controller or translating WCL messages.

### Sequoia 24H32 controller ABI shell

Files:

- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32ABI.hpp`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.hpp`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.cpp`

The ABI declaration carries the Sequoia V2 controller virtual declaration
order and the reviewed `IO80211Controller` size assertion (`0x128`). The
controller shell implements the required pure virtual methods identified in
the ABI declaration, reports unsupported/not-ready operations conservatively,
and owns an `IOWorkLoop`.

**Isolation is intentional:** `make rtl88wifi` compiles this controller
translation unit into `build/wcl24h32`, but the object is *not* linked into the
existing Kext. The existing target still includes the legacy global
`IO80211Controller` declaration. Mixing the legacy and 24H32 class definitions
in one Kext would violate the ABI boundary. The native service has no IOKit
personality and cannot currently be activated through the existing target.

### ABI-neutral PCI/MMIO/DMA backend owner (new isolated slice)

Files:

- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLPCIBackend.hpp`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLPCIBackend.cpp`
- `tests/test-wcl-pci-backend-owner.py`

The new `RTW88WCLPCIBackend` derives from `OSObject` and the ABI-neutral
`RTW88HwOps` contract; it does not inherit from or include the legacy/native
`IO80211Controller` classes. It owns a retained `IOPCIDevice`, BAR2 mapping,
compat `pci_dev`, DMA descriptor ledger (including deferred frees), interrupt
event source and the RTW88 compat-runtime lease. `open()` acquires resources
in order and unwinds through one cleanup path on failure. The lease is
exclusive through the process-global RTW88 hardware callback pointer, so this
owner refuses to replace an existing legacy backend. `setRadioRunning(false)`
requires the RTW88 core to have been stopped first, disables the interrupt
source and fences PCI bus mastering; `close()` refuses to dismantle resources
while the radio is marked running.

**This is still a compile-only owner, not an active native PCI service.** The
controller now transactionally instantiates it during its isolated `start()`
path, opens the PCI/MMIO/DMA owner, creates the RTW88 state-machine object with
native RX/event/client delegates, and then unwinds all acquired resources in
reverse dependency order. The native controller deliberately returns failure
at the publication gate because Skywalk registration and RX/TX queues are not
ready. No native IOKit personality exists and the controller/backend/interface
objects remain excluded from the active legacy Kext link. The user's last
Xcode 16.4 build compiled the prior backend and interface versions; the newly
integrated controller lifecycle still needs its own Xcode 16.4 compile.

### Native controller mbuf TX handoff gate (new isolated slice)

Files:

- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.hpp`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.cpp`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp`
- `tests/test-wcl-mbuf-tx-boundary.py`

The native controller now overrides the standard IONetworkController
`outputPacket(mbuf_t, void *)` entry and forwards an admitted Ethernet mbuf to
`RTW88IEEE80211::outputPacket()`. The path is guarded by an atomic activation
state and in-flight counter. An inactive path consumes and drops the mbuf;
activation is rejected unless the controller has a started radio and open PCI
backend. The infrastructure interface powers RTW88 first and then activates
the gate; on failure it rolls power back. Disable quiesces new TX admission and
waits for synchronous submissions to leave before powering down. Controller
resource teardown also quiesces this gate before stopping the radio or releasing
PCI resources.

**This is an mbuf TX handoff seam, not the Skywalk datapath.** It does not
create/register Skywalk packet pools or submission/completion queues, decode
`IOSkywalkNetworkPacket` objects, or deliver RX packets. RX mbufs are still
consumed and dropped until the exact 24H32 RX packet/queue ownership path is
implemented. The API gate is currently unreachable in the staged controller
start path, which still refuses publication; this slice only defines the
ownership boundary needed by later Skywalk queue callbacks. The object remains
compile-only and excluded from the legacy Kext.

### Sequoia 24H32 infrastructure protocol slice

Files:

- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.hpp`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLRequestDecoder.hpp`
- `tests/wcl-request-decoder-test.cpp`

The isolated ABI declaration includes the Sequoia Skywalk/Infrastructure
class hierarchy and size assertions (`IO80211SkywalkInterface` 0x118,
`IO80211InfraInterface` 0x120, `IO80211InfraProtocol` 0x120). The concrete
protocol class has a method for each pure virtual selector in the reviewed
24H32 declaration; unimplemented optional features return
`kIOReturnUnsupported` rather than reporting fabricated capabilities.

The first request-handler slice includes bounds-checked WCL scan/join decoders,
active and FAST scan requests with channel/SSID/BSSID filtering, scan-result and completion
messages, open and PMK-backed WPA2-PSK association, abort/leave operations,
channel/RSSI/supported-channel queries, link-state updates, and serialized
association/connected/deauth/disconnect notifications. The RTW88 backend now
emits a distinct fully-connected event after an open association or successful
internal WPA2 four-way handshake. The interface reports association separately
from the later controlled-port-ready connection event.

Important limits: active scans are supported directly; FAST scan requests are
currently serviced as a fresh active scan (the backend does not yet expose a
separate cached-fast-scan transaction). Passive/background scans are rejected.
Only open and WPA2-PSK-with-32-byte-PMK join modes are accepted. WEP, SAE,
passphrase conversion, enterprise/SHA256 AKMs and optional WCL selectors are
rejected or unsupported. The native
WCL `setCIPHER_KEY` method is deliberately not mapped to legacy PTK/GTK
semantics: this ABI path expects PMK/PMKSA/MSK handling, and the backend does
not yet provide the corresponding PMKSA/MSK API. `setCLEAR_PMKSA_CACHE` is
also unsupported.

**Isolation remains intentional:** `RTW88WCLInfraInterface.cpp` is compiled
with `__IO80211_TARGET=__MAC_15_2` into `build/wcl24h32`, but it is not linked
into the existing Kext. Its `start()` still refuses publication until native
controller ownership, Skywalk registration and RX/TX queues are ready.
`attachRadio()` is still a guarded adapter hook only; the controller creates
and owns the RTW88 core object but does not attach an infrastructure interface
or activate the radio before the Skywalk datapath is complete.


### Stage 2: packet bounds and RTW88 TX terminal-outcome hook

New files:

- `driver/RTL88WiFi/src/compat/linux/skbuff_tx_completion.h`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLPacketSpanValidation.hpp`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLPacketView.hpp`
- `tests/rtw88_skb_tx_completion_test.cpp`
- `tests/wcl_packet_span_test.cpp`
- `tests/test-wcl-packet-path-stage2.py`

The RTW88 `sk_buff` now contains only an optional pointer to an independently
allocated completion token (callback, context, cookie and matching release
function). `RTW88IEEE80211::outputPacketWithCompletion()` allocates and attaches
the token immediately before `rtw88` takes ownership. The normal PCI TX-status
path claims and dispatches the hardware descriptor outcome; any earlier
`kfree_skb` path (including queue purge/reset) claims and dispatches a drop.
The atomic exchange detaches the token from the skb before any callback state is
read. This matters because the losing concurrent free path may reclaim the skb
while the winning status path is still dispatching; the winner no longer
accesses skb memory and owns the detached token until its release function
runs. The existing `outputPacket()` API uses a null callback and preserves
legacy behavior. The callback contract is strict: it may run in interrupt or
teardown context and must only enqueue a bounded record; it must not sleep or
call Skywalk APIs directly.

The new Skywalk packet view accepts only a one-buffer network packet from the
expected pool. It checks packet/buffer length and offset consistency, validates
buffer and data ranges using subtraction-based overflow-safe arithmetic,
validates the memory-segment mapping range before forming the data pointer, and
limits Ethernet TX frames to the backend's existing 14..2048-byte bounds. The
TX submission callback now performs this validation for every supplied packet
before returning `kIOReturnNotReady`; it still does not consume, complete or
register any packet.

Host tests cover normal completion, early-free drop, a 32-thread completion vs
free race, detached-token dispatch after simulated skb reclamation, valid/exact-
end packet spans, malformed/overflowing offsets, and Ethernet frame bounds.
The two changed kernel translation units also passed a
host Clang 17 x86_64-Apple-target syntax check against the pinned MacKernelSDK;
`RTW88IEEE80211.cpp` emitted two pre-existing compat-header warnings. The
queue and backend translation units both passed the host Clang 17
x86_64-Apple-target syntax check. The focused Stage 2, Skywalk resource-owner,
controller-lifecycle and mbuf TX-boundary tests passed. The existing host
regression scripts `test-handshake.py`, `test-rx-filter.py`, `test-scan-ssid.py`,
`test-join-policy.py`, `test-join-report.py`, `test-private-mac.py`,
`test-ba-recovery.py`, `test-roam-scan-policy.py`, `test-assoc-wire.py`,
`test-wcl-abi-surface.py` and `test-wcl-pci-backend-owner.py` also passed.
`test-focused.py` did not finish within the 120-second Linux-container limit;
`test-group-key.py` still requires Apple's CommonCrypto header and was not run
here. None of these host checks is the target Mac's Xcode 16.4 SDK build, a
Kext link, or a runtime test.

**Remaining gate:** the 24H32 `IOSkywalkEthernetInterface::RegistrationInfo`
layout and registration contract are still not present in the bundled SDK or
reviewed ABI notes. No queue is registered, no Skywalk packet is handed to the
radio yet, and the new RTW88 completion hook is not yet connected to a
Skywalk completion queue. RX refill/delivery remains disabled. The controller
publication gate remains closed.

## Stage 3 — Skywalk registration ABI safety audit

- Cross-checked the pinned public Skywalk SDK declarations and the Sequoia
  15.x private WCL reference headers. The SDK leaves both registration payload
  types opaque; the independent private reference uses an opaque 0x130-byte
  placeholder, but this size is not yet independently confirmed from the
  target 24H32 function bodies.
- Found a return-type disagreement for the non-virtual
  `registerEthernetInterface()` entry point: the pinned SDK declares
  `IOReturn`, while the independent Sequoia private WCL header declares
  `bool`. Because this is not encoded in the C++ mangled symbol and can affect
  result handling, the Stage 3 ABI shim now deliberately omits the callable
  registration APIs until the exact target binary is checked.
- Made the base and derived registration payload declarations and both
  framework-owned expansion-data blocks opaque. No speculative payload size,
  allocation, copy, or registration call is available to native driver code.
- Added `tests/test-wcl-registration-contract.py` to guard the opaque payloads,
  the registration call fence, and the existing no-publication/no-legacy-link
  boundary. Added `tools/audit-skywalk-registration-24H32.py`, a read-only
  collector that scans the original 24H32 kcabi archive for registration
  symbols and nearby disassembly without extracting untrusted archive paths.
- This is a fail-closed ABI correction. It does not register queues, publish
  the BSD interface, activate TX/RX callbacks, or alter the working legacy
  frontend. The target 24H32 disassembly and Xcode 16.4 compile still have to
  validate the next registration probe.

## Stage 4 — bounded Skywalk TX-to-RTW88 adapter

Files:

- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.hpp`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp`
- `driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLTxCompletionSlots.hpp`
- `tests/wcl_tx_completion_slots_test.cpp`
- `tests/test-wcl-tx-adapter-stage4.py`

The isolated adapter validates each single-buffer Skywalk Ethernet packet with
the Stage 2 packet-view checks, copies its bytes into an RTW88-owned mbuf using
`mbuf_allocpacket(MBUF_DONTWAIT)` and `mbuf_copyback()`, and hands ownership to
`RTW88IEEE80211::outputPacketWithCompletion()`. A fixed 128-entry ticket pool
correlates the hardware terminal outcome with the retained Skywalk packet. The
RTW88 completion callback publishes only a boolean result through bounded
atomic operations; it performs no allocation, sleeping, object release or
Skywalk call. A serialized `drainCompletions()` consumer runs the supplied sink
and releases the packet only after the sink returns.

**This adapter is a conversion/completion seam, not an active Skywalk TX path.**
It is compiled as its own object but remains excluded from
`AIRPORT_ALL_OBJS`; `RTW88WCLSkywalkQueues::txSubmissionAction()` still validates
descriptors and returns `kIOReturnNotReady`. The drain sink is not yet connected
to a verified 24H32 Skywalk TX-completion queue operation, and no queue has been
registered or published. No packets are currently submitted through this
adapter from a live queue callback.

Host validation passed the 128-ticket capacity/backpressure, duplicate
completion, concurrent producer and exactly-once drain tests. The adapter also
compiled to a Mach-O x86_64 object with host Clang 17 against the pinned
MacKernelSDK headers. The user's latest GitHub `output.log` is still the Stage 3
Xcode build; a new Xcode 16.4 build is required to confirm this Stage 4 source on
the target machine. This is not a native Kext link, queue-registration, load or
hardware test.

## Not implemented yet

This snapshot is **not a functioning native WCL driver** and is not ready to
load. Outstanding work:

1. Integrate the new Stage 4 adapter into the native TX submission callback
   only after the 24H32 TX-completion queue handoff is verified. Wire a bounded
   deferred drain, real completion queue enqueue/complete semantics, queue
   backpressure and teardown fencing; then implement RX packet conversion,
   metadata, refill and delivery. The adapter currently remains compile-only.
2. Attach the native infrastructure interface and `RTW88WCLWorkQueue` from
   the controller lifecycle after Skywalk registration exists. Implement the
   first-beacon and any required WCL message transitions.
3. Implement WCL PMK/PMKSA/MSK key management and PMKSA-cache teardown, then
   verify supported WPA2-PSK behavior end-to-end. Enterprise, SAE and
   passphrase paths remain unavailable until separately implemented.
4. Create a separate native Kext link target that excludes all legacy
   `IO80211Controller` translation units and has a dedicated WCL personality.
5. Build that target with Xcode 16.4 on macOS 15.8.1, validate the Kext and
   dependencies, then test RTL8821CE hardware. RTL8822BE/RTL8822CE require
   separate hardware validation.

The existing legacy frontend and its `IO80211FamilyLegacy` dependency remain
unchanged. Do not load this private development snapshot, add the experimental
controller to OpenCore, or remove/alter the currently working OpenCore
configuration.

## Current Skywalk queue-resource slice

- Added `RTW88WCLSkywalkQueues`, a native 24H32 resource owner for separate
  TX/RX packet-buffer pools and the four standard Skywalk queue types
  (TX submission/completion and RX submission/completion). It uses 128 packet
  slots per queue and 2048-byte single-buffer entries as an initial, bounded
  allocation profile; the MTU/maximum-buffer policy must be checked against
  the eventual registration contract before exposing the interface.
- Controller startup now allocates the queue owner after acquiring the PCI
  backend and RTW88 state-machine object. Any failure rolls back queue objects
  before releasing the RTW88 owner and PCI backend. Controller startup still
  deliberately refuses service publication and unwinds, because queue
  descriptors, mbuf conversion, completion correlation, RX refill and BSD
  registration are not yet implemented.
- All four queue callbacks currently return `kIOReturnNotReady` without
  modifying or completing packet arrays. The queues are not added to a workloop
  and are not passed to `registerEthernetInterface`; therefore they cannot be
  mistaken for a live datapath. This stage is resource-allocation groundwork,
  not an RX/TX implementation.
- Fixed a syntax defect in the bundled MacKernelSDK copy of
  `IOSkywalkRxSubmissionQueue.h`: the `initWithPool` declaration lacked its
  terminating semicolon. The fix is source-only and preserves the declared
  signature/layout. The header still reports six unnamed reserved-member
  warnings in host Clang, which do not affect object generation.
- `RTW88WCLSkywalkQueues.cpp` and the updated controller compile to Mach-O
  x86_64 objects with host Clang 17 targeting macOS 13+ and the pinned
  MacKernelSDK headers. This is not the user's Xcode 16.4 build, SDK runtime
  validation, or an ABI test. The source audit is
  `tests/test-wcl-skywalk-queues.py`.

## Current verification

- Stage 4 host checks passed: `test-wcl-tx-adapter-stage4.py`,
  `test-wcl-registration-contract.py`, `test-wcl-abi-surface.py`,
  `test-wcl-skywalk-queues.py`, `test-wcl-controller-lifecycle.py`,
  `test-wcl-pci-backend-owner.py`, and `test-wcl-packet-path-stage2.py`. The
  WCL event-ring and request-decoder C++ tests also pass.
- Legacy regression scripts re-run in the Stage 4 worktree and passed:
  `test-assoc-wire.py`, `test-handshake.py`, `test-rx-filter.py`,
  `test-scan-ssid.py`, `test-join-policy.py`, `test-join-report.py`,
  `test-private-mac.py`, `test-ba-recovery.py`, and
  `test-roam-scan-policy.py`.
- Host Clang 17 cross-compiled `RTW88WCLSkywalkTxAdapter.cpp` to a Mach-O
  x86_64 object with the pinned MacKernelSDK. The latest user's Xcode build
  predates Stage 4, so the new adapter still requires a target Xcode 16.4 build.

- The host tests `tests/wcl-event-ring-test.cpp` and
  `tests/wcl-request-decoder-test.cpp` pass with
  `c++ -std=c++17 -Wall -Wextra -Werror -O2`.
- Host regression tests for association wire format, BA recovery, focused core
  behavior, handshake, join policy/report, private MAC, roam scan policy, RX
  filtering and scan SSID all pass. `test-group-key.py` is not runnable in the
  Linux host because Apple's CommonCrypto headers are unavailable; it still
  requires macOS/Xcode validation.
- The user's `output.log` confirms successful compilation of
  `RTW88WCLRadioBridge.cpp` and `RTW88WCLWorkQueue.cpp`, successful Kext linking,
  and final synchronization of `build/out/RTL88WiFi.kext`. That remains the
  legacy/bridge Kext, not a native WCL Kext.
- The latest checked GitHub `output.log` (blob SHA
  `7589e893ba6a41c7d4b9efb407ff81b53850742e`, 2026-11-01) has no compiler or
  linker errors and ends with `OK build/out/RTL88WiFi.kext`. It contains 34
  `warnings generated` summaries totalling 1,098 warnings; these did not
  prevent the legacy/bridge Kext link and should be triaged separately.
- The user confirmed the generated executable was Mach-O 64-bit x86_64,
  `Info.plist` passed `plutil -lint`, and the bundle identifier was
  `io.github.x1ren41l.RTL88WiFi`.
- The new controller ABI shell passes strict host C++ syntax checking against
  stub IOKit declarations. This only checks C++ syntax; it is **not** a
  substitute for compiling against Apple's actual macOS SDK.
- The `rtl88wifi-wcl-controller-abi-check` Make target now compiles the native
  controller, infrastructure interface and new ABI-neutral PCI backend as
  separate compile-only objects. The user's latest Xcode 16.4 build log confirms
  the controller and infrastructure-interface objects compiled without errors.
  The user's later `output.log` also confirms `RTW88WCLPCIBackend.cpp`
  compiled without an error and the legacy Kext linked. The newly integrated
  controller lifecycle in this snapshot is not yet covered by that Mac build.
- `tests/test-wcl-pci-backend-owner.py` checks the new backend ownership boundary,
  exclusive global compat lease, cleanup path and compile-only isolation. This
  is a source audit, not an IOKit runtime or ABI test.
- The new PCI backend source was also compiled to a Mach-O x86_64 object with
  host Clang 17 against the repository's pinned MacKernelSDK headers using
  kernel/Kext compile flags. This is a useful cross-target syntax/object check,
  but it is not the user's Xcode 16.4 SDK build or a link/runtime test.
- `tests/test-wcl-controller-lifecycle.py` checks staged PCI/radio ownership,
  publication gating, safe RX drop behavior and teardown ordering. It is a
  source-structure audit, not an IOKit runtime test.
- Host-side method-name coverage checked 191 pure protocol selectors and the
  inherited abstract methods; no selector name was left unimplemented. This is
  a source audit, not an ABI/vtable validation.
- Compile-only `.d` dependencies for the controller, infrastructure interface
  and PCI backend are included so header changes trigger recompilation.
- The integrated controller translation unit passes host Clang 17
  `--target=x86_64-apple-macosx13.0 -fsyntax-only` against the pinned
  MacKernelSDK headers. The infrastructure-interface and PCI-backend units
  also pass that check, with the previously observed offset/macro/extern-C
  compatibility warnings. This is not an Xcode 16.4 SDK build or runtime test.
- No native WCL Kext link, load, runtime, or hardware test has been performed.

## Next implementation sequence

1. Inspect the actual `build/24H32-registration-audit.txt` content from the
   target machine to settle the non-virtual registration entry points and
   completion-queue handoff semantics. The latest `output.log` only records
   that the audit was generated; it does not contain the audit text itself.
2. Run the Xcode 16.4 build after Stage 4 so the new TX adapter is checked by
   the target macOS SDK. Keep it compile-only until the completion-queue ABI and
   workloop drain ownership are verified.
3. Integrate TX submission, completion queue delivery, packet backpressure and
   teardown. Do not complete packets at enqueue time.
4. Implement RX submission buffer refill and RX completion delivery, including
   per-packet metadata, length/offset validation, FCS policy and teardown drain.
5. Implement the remaining WCL event and PMK/PMKSA/MSK lifecycle; then add a
   native Kext target without legacy controller objects and proceed to
   controlled RTL8821CE hardware validation.



## Stage 5 — bounded RX staging (implemented, not a Skywalk RX datapath)

- Added `RTW88WCLMbufRing`, a fixed 128-entry lock-free MPMC ring. Host stress
  coverage runs eight concurrent producers through 48,000 frames and verifies
  exact-once delivery without loss or duplicate pointers.
- Added `RTW88WCLSkywalkRxAdapter`, an `IOEventSource` on the native controller
  workloop. It validates mbuf length bounds, takes ownership on every enqueue
  result, signals the workloop without blocking, drains at most 32 frames per
  pass, and frees frames after a borrowed sink callback.
- The native controller now uses `allocatePacket()` only while its packet-path
  gate is active and transfers RX mbufs into the bounded adapter. Teardown
  closes the packet gate, stops the radio, removes/drains the RX event source,
  releases the Skywalk queue owner, then fences PCI and releases backend state.
- The current sink is deliberately a no-op and the adapter frees each frame.
  It does **not** create an `IOSkywalkNetworkPacket`, enqueue the RX completion
  queue, refill RX submission buffers, or register/publish the interface.
- Stage 5 controller and RX adapter remain separate compile-only objects; the
  active legacy kext link has not changed.
- `tests/test-wcl-rx-adapter-stage5.py` and the controller lifecycle suite pass.
  Host Clang 17 cross-compiles the RX adapter and controller to Mach-O x86_64
  objects against the pinned MacKernelSDK; the controller compile retains the
  previously observed non-standard-layout `offsetof` warning. This is not the
  user's Xcode 16.4 target build or an IOKit runtime test.

## Latest user-provided ABI evidence and build log

- GitHub `output.log` blob `0d469613876e2f99c61f815ef90340965fc4238c` has
  5,827 lines, no compiler/linker errors, and ends with `OK build/out/RTL88WiFi.kext`.
  Its 35 warning summaries total 1,163 warnings. It includes the Stage 4 TX
  adapter compile-only object, but predates Stage 5.
- `24H32-registration-audit.txt` blob
  `64540749cb0d621bf27037244196fabcb60abb8d` confirms that
  `initRegistrationInfo()` accepts option `1` and requires a `0x130`-byte
  registration-info buffer. The audit does not include a complete body/call-site
  analysis sufficient to settle the `registerEthernetInterface()` return type
  or queue-registration runtime contract. Those calls remain fenced.
- User preference: check only the single GitHub file `output.log` for each
  future build review; do not request separate Desktop log files.


## Stage 6 — native RX packet conversion (2026-11-01)

The Stage 5 build log was checked from the GitHub root `output.log`: it contained no compiler/linker error, the RX adapter compile-only step ran, and the legacy Kext ended with `OK build/out/RTL88WiFi.kext`. Stage 6 now adds pool-backed RX packet construction after the bounded mbuf staging ring. The RX pool is 4 KiB per packet (TX remains 2 KiB); workloop conversion validates the packet/buffer/pool relationship and memory bounds, copies full possibly-fragmented mbuf chains with `mbuf_copydata()`, sets packet length/status, and offers the native packet to a sink. The sink still returns false, so packets are recycled to the pool. No native packet reaches a completion queue.

The Stage 6 source is compile-only and is still excluded from `AIRPORT_ALL_OBJS`. It does not enable registration, BSD publication, radio start, or OpenCore changes. The `registerEthernetInterface` implementation/return convention and RX completion ownership semantics remain unverified in the uploaded ABI audit; do not remove those fences. Target Xcode 16.4 build validation is the next required check after applying this package.


## Stage 7 — bounded controller-owned RX packet retention (2026-11-01)

The user-provided corrected Stage 6 Xcode 16.4 log now completes successfully:
no compiler/linker/make errors, the controller, infrastructure interface, PCI
backend, queue owner, TX adapter and pool-backed RX adapter all compile as
separate 24H32 compile-only objects, and the legacy target ends in
`OK build/out/RTL88WiFi.kext`. The RX/TX native objects remain outside the
legacy Kext link.

Stage 7 changes the RX sink from immediate rejection to ownership transfer into
a bounded 128-entry controller-owned MPMC packet ring. This ring is intentionally
limited to the configured 128-packet RX pool. During teardown, after the RX
producer and event source stop, packets are returned to the live RX pool before
the queue/pool owner is released. If an individual packet deallocation fails after all RX producers have been
quiesced, the controller falls back to the pool's `disposeAllPackets()` method
before pool memory segments are released. Ring-full packets are rejected and
recycled by the Stage 6 adapter.

No Skywalk queue enqueue, interface registration, BSD publication or radio
start is enabled. The 24H32 registration result/ownership ABI is still the
blocking evidence item. Stage 7 remains compile-only and is not runtime or
hardware validation.

## Stage 8 — focused 24H32 registration ABI evidence (2026-11-01)

The latest GitHub root `output.log` (updated 2026-11-01 01:01:41 UTC) was
checked after Stage 7. It has no compiler, linker, or `make` errors; all six
native WCL compile-only units are present (controller, infrastructure
interface, PCI backend, Skywalk queues, TX adapter, and pool-backed RX
adapter), and the legacy Kext completes with `OK build/out/RTL88WiFi.kext`.
The WCL objects are absent from the legacy Kext link line.

Stage 8 does not activate an unverified ABI. It expands
`tools/audit-skywalk-registration-24H32.py` with a focused full-disassembly
mode for both `registerEthernetInterface` overloads, matching network
registration/deregistration methods, and the known Apple interface start call
paths. It also emits matching symbol-index rows and explicit found/missing
coverage for each focused filename pattern. The script reads only safe regular
tar members in memory, enforces per-member and total-output bounds, and does
not extract archive paths.

The new `make wcl-abi-audit-24h32` target defaults to the archive location used
in the prior audit (`$HOME/Downloads/RTL88WiFi-Sequoia-24H32-kcabi.tar.gz`) and
writes the full report to stdout. This allows the report to be appended to the
one project-root `output.log` with `tee -a`; no separate Desktop log is needed.
The previous context-only audit mode and its default output-file behavior are
preserved.

`tests/test-wcl-registration-abi-extractor-stage8.py` passes its synthetic
archive checks for complete registration/call-path body emission, symbol-index
association, old-mode compatibility, safe-member handling, bounded output,
and Makefile integration. The Stage 7 ownership suite, Stage 5 RX staging
suite, controller lifecycle, queue/PCI owners, TX adapter, packet-path,
registration-contract, ABI surface, and all runnable legacy protocol
regressions pass. The Linux host cannot run the Apple CommonCrypto-dependent
group-key test; this is an environment limitation, not a passing result.

**Next action:** after applying Stage 8, run the normal Xcode 16.4 `rtl88wifi`
build, then run `make wcl-abi-audit-24h32 2>&1 | tee -a ../../output.log` from
`driver/RTL88WiFi`, and upload only the root `output.log`. Review the complete
24H32 bodies before changing any registration or RX-completion code. Native
controller/queues/RX/TX remain compile-only, queues unregistered, the radio
stopped, and the existing legacy Kext/OpenCore configuration untouched.

## Stage 9 — force collection of exact 24H32 registration methods (2026-11-01)

The latest GitHub root `output.log` (modified 2026-11-01 01:10:08 UTC) has a
successful Stage 8 legacy Kext build (`OK build/out/RTL88WiFi.kext`) with no
compiler, linker, or `make` errors. The Stage 8 ABI audit itself also completed
without errors. Its important limitation is that its methods lists include
`IO80211InfraInterface::registerInfraEthernetInterface`, both
`IOSkywalkEthernetInterface::registerEthernetInterface` overloads and the
AppleBCMWLAN registration `start`, while the archive did not contain those
function bodies in `asm/`.

Stage 9 improves only evidence collection. It prepares a temporary kcabi
reference dump containing 14 exact 24H32 mangled methods, merges any existing
`KCABI_REF` symbols, and passes it to `dump.py --ref`. The kcabi clone is not
modified. The audit also resolves the `[vtable + 0xc00]` indirect call in the
complete `IO80211InfraInterface::start` body by extracting the matching row
from `IO80211InfraInterface.vtable.txt`.

The Stage 9 helper, vtable-dispatch fixture, Stage 8 audit regression, all WCL
lifecycle/ownership/packet/queue/PCI/registration tests, and runnable legacy
protocol regressions pass. This is an evidence-generation step, not a native
Wi-Fi datapath activation. Do not enable registration, packet completion,
interface publication, or radio start until actual method bodies and their
return/ownership/cleanup behavior are established.


## Stage 10 — 24H32 registration status contract (2026-11-01)

- Stage 9 target audit includes 11 complete focused assembly members (77,610
  bytes), including both Ethernet registration overloads, network registration,
  both deregistration paths, `registerInfraEthernetInterface`,
  `AppleBCMWLANSkywalkInterface::start`, and `IO80211InfraInterface::start`.
- Apple start directly calls `IO80211InfraInterface::registerInfraEthernetInterface`;
  it saves EAX, tests it, and branches on zero as success. The infra wrapper
  saves the Ethernet registration result in `r14d` and returns it in EAX. The
  Ethernet wrapper in turn calls the network registration path. This proves
  the callable status convention is `IOReturn`, not `bool`.
- Corrected the Stage 9 vtable interpretation: `IO80211InfraInterface::start`'s
  indirect call at `[vtable + 0xc00]` resolves to
  `setInterfaceOFDMDesense(apple80211_channel, long long)`. It is not the
  registration call. Registration is a separate direct call from the Apple
  Skywalk start routine.
- Added non-virtual callable declarations for the observed 24H32 registration
  and deregistration methods to the ABI shim. Their declarations do not add
  vtable slots; opaque `RegistrationInfo` and expansion layouts remain opaque.
- **Still fenced:** no call to registration is enabled. The code has not yet
  reproduced Apple's complete 0x130-byte registration payload, queue set
  construction options, pool roles/refills, completion handoff, BSD publication,
  or rollback/stop ordering. Interface start continues to fail closed; no radio
  start, installation, or OpenCore change is authorized by this stage.
