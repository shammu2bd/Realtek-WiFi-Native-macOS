# Sequoia 24H32 Skywalk RX packet conversion — Stage 6

**Status:** compile-only preparation slice; no packet delivery, registration, or radio start.

## What changed

- The RX pool now has one 4 KiB buffer per packet, while the TX pool remains at 2 KiB.
- The workloop-side RX adapter allocates a single-buffer `IOSkywalkPacket` from the RX pool with non-blocking allocation.
- It validates packet type, pool identity, buffer count, memory-segment extent, virtual address arithmetic, and packet/buffer data offsets and lengths.
- It uses `mbuf_copydata()` to copy a full mbuf chain, including frames split across mbuf segments, into the validated Skywalk buffer.
- A prepared packet is offered to the sink. A future sink may return true only after a verified RX-completion enqueue accepts ownership. The current controller sink returns false, so the adapter recycles the packet to the RX pool and counts the frame as dropped.
- The original RTW88 mbuf is freed after the copy/offer path. Queue overflow, invalid packet length, pool exhaustion, invalid descriptors, and rejected sink all terminate without leaking the mbuf or native packet.
- The controller creates the RX adapter only after the queue owner has created the RX packet pool. Teardown still removes the workloop source before destroying the queues/pools.

## Safety boundary that remains

This stage does **not** call `enqueuePackets()`, does not call `registerEthernetInterface()`, does not publish a BSD interface, does not start the radio, and does not add any native object to the legacy Kext link. The `stagedRxFrame()` sink deliberately rejects every packet. Therefore this is not a working RX datapath; it is a bounded native-packet construction step that is ready for a later, ABI-verified completion-queue handoff.

The uploaded 24H32 audit still lacks the body of `registerEthernetInterface()` and does not resolve the registration return/ownership contract. Keep registration fenced until that is established from the exact 24H32 target binary.

## Validation

- `tests/test-wcl-rx-adapter-stage5.py` now runs the existing MPMC ring stress test and a new host test for buffer-address overflow and extent validation.
- Existing queue, packet-view, controller-lifecycle, TX-adapter, registration-contract, ABI-surface, PCI-owner, and legacy regression tests are rerun for this slice.
- A successful target Mac Xcode 16.4 compile is still required from the user-provided `output.log`. Host cross-compilation is not a substitute for the target build or device test.
