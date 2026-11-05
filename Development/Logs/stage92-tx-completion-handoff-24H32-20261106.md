# Stage92 — 24H32 TX completion handoff and ownership lifecycle

Date: 2026-11-06  
Branch: `work/stage91-tx-submission-callback-v1`  
Source baseline: `5a1fe872661def012aedd1d721cfae25b8ed1851` (validated Stage91 source is its parent)  
Target: macOS Sequoia 15.8.1 / 24H32 / x86_64

## Target ABI evidence

The pinned generic `IOSkywalkTxCompletionQueue.h` declares its action typedef with an `IOReturn` result. The 24H32 binary's exact `initWithPool` symbol instead encodes the action callback as `UInt32`:

```
__ZN26IOSkywalkTxCompletionQueue12initWithPoolEP25IOSkywalkPacketBufferPooljjP8OSObjectPFjS3_PS_PP15IOSkywalkPacketjPvES8_j
```

For this target, that callback is a packet-count callback, not an IOReturn status callback. The queue's `enqueueAndCompletePackets` caller passes the callback's EAX value to `completePackets` as a count. The implementation now gives the callback a target-correct `UInt32` signature and returns zero (no packets from that callback); it uses a target-boundary function-pointer cast only because the pinned generic SDK typedef differs.

The real deferred handoff uses the public pointer-array overload:

```
IOSkywalkTxCompletionQueue::enqueuePackets(
    const IOSkywalkPacket ** packets, UInt32 packetCount, IOOptionBits options)
```

Captured 24H32 body:
`__ZN26IOSkywalkTxCompletionQueue14enqueuePacketsEPKP15IOSkywalkPacketjj`

Its observed sequence is: validate arguments and count; verify the queue packet table and readiness/action gates; copy the pointer array into the completion queue's internal array; call `completePackets` synchronously; then return success. The observed failure exits occur before the pointer-array copy and completion path. This makes its return status a usable ownership-handoff result for the deferred worker: success means the queue ran its completion path; a failure means no packet handoff was made and the ticket can be retried.

## Packet completion chain

The target `completePackets` body walks the internal completion array and invokes each packet's completion vtable path with TX direction (`1`) and options (`0`). Stage70/71 vtable reconciliation maps that call to:

```
IOSkywalkPacket::completeWithQueue(queue, kIOSkywalkPacketDirectionTx, 0)
```

The captured packet method iterates its packet buffers and invokes each buffer's `completeWithQueue(queue, direction, options)`, clears the packet's prepared-state bit, and dispatches the packet's virtual `complete(queue, options)` implementation. The driver does not call `completeWithQueue`, `complete`, or `disposePacket` directly; it delegates this lifecycle to the verified public queue API.

## New Stage92 ownership path

1. TX submission validates and copies the Ethernet frame. The adapter retains the original Skywalk packet, reserves a ticket, and takes the per-ticket adapter retain before submitting to RTW88.
2. The RTW88 terminal callback only atomically publishes the ticket result and signals the already-installed completion notifier. It does not call Skywalk, allocate, release OSObjects, or perform the packet handoff itself.
3. A dedicated `IOEventSource` runs on the controller's `IOWorkLoop`. It claims completed tickets and calls the public synchronous `enqueuePackets(packetArray, 1, 0)` overload.
4. Only a successful return lets the adapter finish the ticket and release its packet and per-ticket adapter retains. A failed preflight moves the ticket from Draining back to Completed without changing the packet or RTW88 result.
5. A timer retries outstanding Completed tickets after a short delay, avoiding a busy retry loop when the queue is not ready or its action gate is busy.

The worker retains both the adapter and completion queue. The adapter's notifier is non-owning and is cleared only after radio stop and an empty ticket table have been established. The controller does not remove the worker while tickets remain outstanding.

## Teardown ordering

The controller first closes TX submission admission, then stops the radio and establishes the PCI/DMA fence. Adapter `unbind()` remains busy while any ticket is outstanding; in that case the controller leaves the workloop worker, adapter, queue owner, pools and PCI/backend context alive so completions can continue draining. After the ticket table becomes empty, teardown stops/removes the worker and timer, clears the notifier, detaches the adapter from the retained queue owner, and only then rolls back the queue/pool acquisition journal.

## Deliberate limits and caveats

- The TX-completion queue API exposes packet ownership completion but no per-packet transmission-success argument. The RTW88 `transmitted` flag remains in the ticket while the sink runs; it is not stuffed into undocumented Skywalk option bits. Separate success/failure telemetry is not yet wired.
- The worker is attached only to the driver's controller workloop. This does not register or enable Skywalk queues.
- Queue registration, queue enable, native interface publication, radio start, full kext link, signing, installation, loading, hardware tests, and OpenCore/SIP/NVRAM changes remain out of scope and fenced.
- Target-Mac validation of the new Stage92 host/source suite and eight-object compile-only target is still pending. Stage91's PASS logs do not validate this new source.

## Source artifacts changed

- `RTW88WCLTxCompletionSlots.hpp`: counts terminal tickets ready for worker retry scheduling.
- `RTW88WCLSkywalkTxAdapter.hpp/.cpp`: completion notifier, ready-ticket count, and IRQ-safe signal-only terminal notification.
- `RTW88WCLSkywalkQueues.hpp/.cpp`: target-correct UInt32 completion-action callback and borrowed completion-queue accessor.
- New `RTW88WCLTxCompletionWorkQueue.hpp/.cpp`: serialized synchronous queue handoff, timer retry, and lifecycle teardown.
- `RTW88WCLController.hpp/.cpp`: owns/starts the worker before any future packet activation and preserves it until all tickets drain.
- `Makefile`: includes the worker as a compile-only WCL object.
- New Stage92 source/ABI test plus additional completed-ticket count assertions.

## Decision

**24H32 completion call sequence and ownership handoff are now represented in source using the observed public API. Source validation and eight-object target compile are pending; PR remains draft/unmerged and native activation remains blocked.**
