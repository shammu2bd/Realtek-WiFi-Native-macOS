# Sequoia 15.8.1 (24H32) Skywalk TX adapter — Stage 4

**Target:** macOS 15.8.1, Darwin 24H32, Intel x86_64.

## Implemented

- Added `RTW88WCLSkywalkTxAdapter`, isolated from the active legacy frontend.
- Reuses the Stage 2 single-buffer packet validator: packet type, expected TX
  pool, one-buffer requirement, segment mapping, offsets, capacity and Ethernet
  frame-size bounds are checked before copying.
- Copies frame bytes into an RTW88-owned mbuf using `mbuf_allocpacket()` and
  `mbuf_copyback()` with `MBUF_DONTWAIT`. This is chain-safe and will not block
  in a queue callback.
- Submits the mbuf to the preserved `RTW88IEEE80211::outputPacketWithCompletion()`
  path. The existing backend consumes the mbuf on all return paths and reports
  one terminal hardware/drop callback.
- Adds a fixed 128-ticket completion pool. Multiple hardware completion
  callbacks can publish status with bounded atomics only. They do not allocate,
  sleep, release packet objects, or invoke Skywalk APIs.
- Adds `drainCompletions()` for a serialized/deferred consumer. Its sink is
  called with the retained packet and success/drop outcome; the retained packet
  is released only after the sink returns.
- Adds a host concurrency stress test covering full-capacity backpressure,
  exactly-once completion and multiple producer threads.

## Deliberately not enabled

- The adapter is compiled as a separate 24H32 object and is **not** added to
  `AIRPORT_ALL_OBJS`; the current legacy kext link remains unchanged.
- `RTW88WCLSkywalkQueues::txSubmissionAction()` remains fail-closed and returns
  `kIOReturnNotReady`. No Skywalk submission packet is consumed yet.
- No call to `IOSkywalkTxCompletionQueue::enqueuePackets()` or
  `completePackets()` is made. The sink seam is ready for that next integration
  after the exact 24H32 completion-queue handoff semantics and interface
  registration lifecycle are confirmed.
- No BSD interface or WCL service is published, no radio is started by the
  native controller, and no OpenCore change is made.

## Validation performed here

Passed:

- `tests/test-wcl-tx-adapter-stage4.py`
- `tests/test-wcl-registration-contract.py`
- `tests/test-wcl-abi-surface.py`
- `tests/test-wcl-skywalk-queues.py`
- `tests/test-wcl-controller-lifecycle.py`
- `tests/test-wcl-pci-backend-owner.py`
- `tests/test-wcl-packet-path-stage2.py`
- `tests/wcl-event-ring-test.cpp`
- Host Clang 17 cross-compiled `RTW88WCLSkywalkTxAdapter.cpp` to a Mach-O x86_64
  object using the pinned MacKernelSDK headers.

This is not the target Mac's Xcode 16.4 compile, a native kext link, Skywalk
queue registration, a kernel load, or physical hardware validation.
