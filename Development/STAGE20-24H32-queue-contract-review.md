# Stage 20 — 24H32 queue and packet ownership review ledger

**Date:** 2026-11-02  
**Inputs:** Stage 14–17 24H32 target ABI archives and the Stage 18/19 ownership review dossier.  
**Scope:** manual static review of the exact 24H32 disassembly already collected. This is not a new target-Mac run.

## Summary

Stage 20 records several narrower facts that can now be stated from the target disassembly. It does **not** close the six Stage 18/19 activation contracts.

- RX submission queue: queue-side refill/retry behavior and the dequeue callback's consumed-count return are visible. Packet ownership after the callback remains unresolved.
- RX completion: the packet-chain and packet-pointer-array overloads are distinct. The array route converts packets to a kern_packet chain and submits it to the network interface. Ownership/acceptance semantics remain unresolved.
- TX completion: a callback produces an array/count which the kernel completion worker processes; it notifies each source queue and calls the kernel TX-completion function. Reference/ownership matching with our ticket adapter remains unresolved.
- Pool and memory segments: prepare/complete operations involve packet and buffer virtual calls and memory-descriptor operations. Their complete DMA and lifetime contract remains unresolved.
- Registration: Stage 10's zero-success IOReturn and 0x130-byte RegistrationInfo constraints are retained; pool/queue-array ownership, rollback and deregistration semantics remain unresolved.
- Teardown: queue disable, synchronize and finalize are separate operations. The required cross-queue ordering and callback-quiescence guarantee remain unresolved.

**Activation gate: BLOCKED.** Do not call registration, enable queues, transfer packet ownership to Skywalk, publish a BSD interface, start the radio, install/load the experimental kext, or alter OpenCore on the basis of this review.

## 1. RX completion enqueue

### Evidence-backed observations

The target contains two overloads which must not be conflated:

1. IOSkywalkRxCompletionQueue::enqueuePackets(IOSkywalkPacket*, count, flags) accepts a packet-chain head. It walks getNextPacket() until the supplied count or a null next pointer, links the underlying kern_packet objects, calls packet virtual methods, and finally invokes _kern_netif_queue_rx_enqueue.
2. IOSkywalkRxCompletionQueue::enqueuePackets(IOSkywalkPacket**, count, flags) accepts a pointer array. It validates the array/count, closes the event-source gate, checks queue state and enabled state, and dispatches to the networking or KPipe helper. The networking helper iterates the array, builds a linked kern_packet chain, invokes packet virtual methods and optional BPF tap, and passes the chain to _kern_netif_queue_rx_enqueue.

The outer array overload returns zero on its success path and IOReturn-style errors on its validation/state error paths. The networking helper's accumulator is based on a per-packet virtual return and is not itself proof of the number of packets accepted by the network interface.

### Still unresolved

The disassembly alone does not establish the ownership/consumption contract of _kern_netif_queue_rx_enqueue, how a partial/failed network enqueue is represented, or the exact lifetime expected for the IOSkywalkPacket wrappers after the handoff. Do not assume the array overload and chain overload have identical ownership behavior.

**Status: MANUAL_REVIEW_REQUIRED.**

## 2. RX submission replenish and dequeue

### Evidence-backed observations

- IOSkywalkRxSubmissionQueue::refillRxRing computes free ring space, asks the associated packet pool to allocate a bounded batch, and prepares the allocated packets for the RX submission queue.
- When pool allocation fails, the queue increments retry state and schedules its delayed retry thread call using the configured Skywalk pool-allocation retry interval.
- The gated dequeue path may invoke refill before dispatching the dequeue callback.
- In the legacy dequeue path, the callback's EAX return is used as a consumed-packet count. The ring advances by that amount; a zero return leaves the offered entries unconsumed and updates the queue's counters.

### Still unresolved

The returned count establishes a consumed-count interface at this call site; it does not, by itself, prove whether our callback must retain each packet, complete it, or transfer it to hardware before returning. Packet descriptor preparation, hardware DMA ownership, completion correlation, and callback failure rollback remain to be mapped.

**Status: PARTIALLY RESOLVED — OWNERSHIP HANDOFF STILL MANUAL_REVIEW_REQUIRED.**

## 3. TX completion acceptance

### Evidence-backed observations

- The TX completion worker invokes an owner callback to obtain a completed packet array and count.
- When the callback returns a nonzero count, the worker calls completePackets(array, count).
- The completion routine iterates each packet, queries a packet metric through a virtual method, obtains its source queue, notifies that source queue, invokes the packet completion virtual method, and, when the queue's packet table is present, calls _kern_packet_tx_completion on the underlying kern_packet.
- The queue then updates completion statistics and invokes its reporting callback.
- The saved Stage19 TX adapter source uses a bounded ticket pool, retains the adapter during deferred draining, calls a sink with a retained packet, finishes its ticket, then releases the packet and adapter references.

### Still unresolved

The source adapter's ticket retain/release sequence is not yet reconciled against every kernel queue success, error, cancellation, timeout and stop path. The disassembly shows what the queue does after the owner callback returns an array; it does not authorize treating a packet as consumed before the driver's DMA and completion state are reconciled.

**Status: MANUAL_REVIEW_REQUIRED.**

## 4. Packet pool and memory-segment prepare/complete

### Evidence-backed observations

- The packet-pool allocation entry forwards through the pool vtable into the target's allocation implementation and returns an IOSkywalkPacket wrapper corresponding to an allocated kernel packet.
- completePreparedPacket obtains the packet transfer direction, calls a packet virtual completion method with the queue cleared, and may notify the packet's source queue through a queue callback.
- IOSkywalkMemorySegment::complete walks packet buffers associated with the segment, invokes buffer completion for each, and performs the corresponding memory-descriptor completion/release path.

### Still unresolved

A complete prepare/complete pairing for our exact memory-segment and DMA setup has not been established. We still need the exact queue flags, segment prepare options, map lifetime, packet-buffer range constraints, and cleanup behavior on partial preparation failures.

**Status: MANUAL_REVIEW_REQUIRED.**

## 5. Ethernet registration lifecycle

### Evidence-backed observations retained from Stage 10

- Registration methods use IOReturn; zero is success and nonzero is failure.
- The target's initRegistrationInfo accepts option value 1 and requires a 0x130-byte payload.
- The Ethernet registration wrapper copies/validates the RegistrationInfo and forwards to the network-interface registration implementation. Its copy failure path calls Ethernet deregistration and returns the error.
- The interface's deregisterInterfaceWithQueues clears stored queue/pool references and releases the references it owns.

### Still unresolved

The complete RegistrationInfo builder, exact queue-array ordering/count/flags, pool-role contract, ownership after successful registration, all failure rollback branches, and stop/deregister ordering have not been approved. Do not call registration.

**Status: MANUAL_REVIEW_REQUIRED.**

## 6. Queue disable, synchronize and teardown

### Evidence-backed observations

- IOSkywalkPacketQueue::disable may reset an ABFS-related state first, then dispatches through a base implementation.
- RX completion synchronize closes the event-source gate, consumes packets from the internal packet table, attaches the consumed packets to channel slots, advances the channel ring and statistics, and reopens the gate.
- RX completion finalize closes the gate, invokes the base finalize, and on success flushes its packet table back through the associated pool before clearing internal state.
- RX submission finalize closes the gate, invokes the base finalize, and on success purges outstanding packets / packet-table state before clearing queue flags.
- TX completion has a separate finalize implementation. Its success path clears packet-table state, while failure leaves the finalization error path visible.

### Still unresolved

These are distinct queue-local operations, not proof of one global teardown recipe. We have not established which stop/disable/synchronize/finalize/deregister calls must run first across the four queues and pool, whether a callback can still be active when a queue finalizes, or how to retry when a step fails.

**Status: MANUAL_REVIEW_REQUIRED.**

## 7. Activation checklist

| Gate | Review result | Activation allowed? |
|---|---|---:|
| Native/legacy object separation | Stage29a PASS | No; unrelated to runtime ABI |
| Native compile/link | Stage29c-v5 PASS | No; compile/link only |
| Kernel symbol provider resolution | Stage29e symbol resolution PASS; auth diagnostics failed | No |
| RX completion ownership | Array/chain distinction found; handoff unresolved | No |
| RX submission ownership | Consumed-count and refill mechanics found; handoff unresolved | No |
| TX completion ownership | Queue callback and kernel completion path found; ticket mapping unresolved | No |
| Pool/segment lifetime | Partial call chain found; DMA/map pairing unresolved | No |
| Registration lifecycle | Registration signature and size constraints known; payload/ownership incomplete | No |
| Cross-queue teardown | Queue-local paths found; global order unresolved | No |
| OpenCore test setup | EFI unmounted; config not inspected | No |

## 8. Next engineering sequence

1. Correlate the exact WCL callback typedefs and current Stage26 native source with the ABI call sites above. In particular, verify callback argument order, whether the kernel passes a linked packet list or an array, and the exact count contract.
2. Build a per-packet state/ownership table for RX and TX: allocated, prepared, submitted, returned by hardware, completed, enqueued to Skywalk, released/recycled. Every error and shutdown transition must have one owner.
3. Review all queue and segment prepare/complete variants and their rollback paths. Confirm the exact required cross-queue disable/synchronize/finalize ordering.
4. Only when all contracts have deterministic ownership and teardown should a minimal registration-only probe be considered. Keep radio start, packet callbacks and BSD publication disabled until that probe is independently validated.
5. Separately, after the user mounts the identified EFI and Stage29i reads the real config, prepare a test-only OpenCore configuration. Do not edit the daily EFI.

## Safety boundary

This document is a static review ledger of existing target disassembly and saved source evidence. It did not alter driver source, create/load a kext, register or schedule a queue, alter SIP/NVRAM, mount or edit EFI, change OpenCore, start the radio, or modify the user's working legacy kext.
