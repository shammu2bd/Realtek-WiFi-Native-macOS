# Sequoia 15.8.1 (24H32) Skywalk RX staging — Stage 5

**Target:** macOS 15.8.1, Darwin 24H32, Intel x86_64.

## Implemented

- Added a fixed-capacity, lock-free MPMC mbuf ring with power-of-two capacity.
  It supports concurrent RTW88 RX producers and a workloop consumer without
  allocating or sleeping in the producer path.
- Added `RTW88WCLSkywalkRxAdapter`, an `IOEventSource` attached to the native
  controller workloop. It validates the packet-header and first-mbuf lengths,
  accepts frames only when capacity is available, coalesces workloop signals,
  and drains a bounded batch of 32 frames per workloop pass.
- Queue overflow, invalid lengths, stop-time races, and teardown all release
  the owned mbuf. The receive sink borrows the frame for one callback and the
  adapter frees it after the callback.
- Wired the native controller's `RTW88RxDelegate` into the RX adapter. RX mbufs
  are allocated with the inherited `IONetworkController::allocatePacket()`
  only while the packet-path gate is active.
- Teardown closes the packet-path gate, stops RTW88, removes/drains the RX
  workloop source, destroys the Skywalk queue/pool owner, fences PCI, and then
  releases the backend callback context.
- Added a host concurrency test covering ring capacity, wraparound, 8
  concurrent producers, exact-once delivery, and 48,000 frames without loss.

## Deliberately not enabled

- The RX sink currently drops frames after the deferred staging step. It does
  not construct an `IOSkywalkNetworkPacket`, publish an RX completion packet,
  or call `IOSkywalkRxCompletionQueue::enqueuePackets()`.
- The `RTW88WCLSkywalkQueues::rxSubmissionAction()` and
  `rxCompletionAction()` callbacks remain fail-closed. No RX queue is registered
  with `IOSkywalkEthernetInterface` and no controller or BSD interface is
  published.
- The native controller still does not start the radio. The new code is
  compiled separately and is not linked into the active legacy `RTL88WiFi.kext`.
- No OpenCore or installed kext changes are included.

## Validation performed in this workbench

- `tests/test-wcl-rx-adapter-stage5.py`
- `tests/test-wcl-controller-lifecycle.py`
- `tests/test-wcl-tx-adapter-stage4.py`
- `tests/test-wcl-registration-contract.py`
- `tests/test-wcl-abi-surface.py`
- `tests/test-wcl-skywalk-queues.py`
- `tests/test-wcl-pci-backend-owner.py`
- `tests/test-wcl-packet-path-stage2.py`
- `tests/wcl-event-ring-test.cpp`
- `tests/wcl-request-decoder-test.cpp`
- `tests/wcl-packet-span-test.cpp`
- `tests/wcl-tx-completion-slots-test.cpp`
- `tests/wcl_mbuf_ring_test.cpp`

The host ring test passes with 8 producers and 48,000 received frames, with no
lost or duplicate entries. A target-side Xcode 16.4 build and full native
kext/runtime/hardware RX testing are still required.
