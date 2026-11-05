# Stage91 — 24H32 TX submission callback

## Scope

Stage91 connects each of the four owner-resident WMM TX submission queues to one retained `RTW88WCLSkywalkTxAdapter`. It does not register or enable any Skywalk queue, start the radio, or expose a native network interface.

The exact target callback type is the Sequoia 15.8.1 / 24H32 x86_64 form:

```cpp
UInt32 (*)(OSObject *owner,
           IOSkywalkTxSubmissionQueue *queue,
           IOSkywalkPacket * const *packets,
           UInt32 packetCount,
           void *refCon)
```

This is intentionally distinct from the generic SDK typedef (`IOReturn`, `const IOSkywalkPacket **`). The Stage57 target `IOSkywalkTxSubmissionQueue::initWithPool` symbol encodes the explicit 24H32 action as a function pointer with a `UInt32` result and `IOSkywalkPacket * const *` packet slots; the target `packetSubmission` dispatch body consumes the action result as a count. The older Stage72 note described the earlier IOReturn source stub/generic declaration, not this target overload. The generic typedef remains untouched; the separately named 24H32 typedef and callback use the target ABI.

## Submission and packet ownership

The callback passes the packet array through a fixed maximum of 16 entries per invocation and accepts only a contiguous prefix.

For each candidate packet, the adapter:
1. Enters the atomic submission gate.
2. Validates network packet type, exact TX pool, single-buffer layout, segment/range arithmetic and Ethernet-frame bounds.
3. Copies the frame to a nonblocking mbuf.
4. Retains the original Skywalk packet and reserves a bounded completion ticket.
5. Retains the adapter for the ticket and invokes `outputPacketWithCompletion`.

A successful adapter return means the packet has been accepted by RTW88 and the adapter holds the packet retain/ticket until the deferred completion handoff. A validation, allocation, not-ready or ticket-capacity error returns a non-success status before ownership transfer; the packet is not retained and remains with Skywalk. The batch helper stops on the first failed/null packet and returns only the accepted prefix count, leaving that packet and the suffix untouched for Skywalk retry/rejection handling.

The RTW88 backend callback is limited to the ticket's atomic terminal-state transition. It does not call Skywalk, release OSObjects, allocate memory, or block. Stage91 does not complete packets or invoke `completeWithQueue`; Stage92 will implement the TX completion handoff and deferred drain.

## Teardown

Two atomic gates cover different lifetimes. The queue-owner callback gate is entered before `txSubmissionAction` reads the retained adapter pointer; the adapter gate is entered before the adapter touches its retained radio/pool. This closes the pointer-load-to-adapter-entry race as well as the packet-copy race. The controller calls `quiesceSubmissions()` before stopping RTW88 or fencing PCI/DMA, and returns without dismantling dependencies while a submission callback remains in flight.

After RTW88 is stopped and the PCI/DMA fence succeeds, `unbind()` releases radio/pool references only when there are no active submissions and no outstanding completion tickets. The queue owner then closes its callback gate, waits for the complete action callback to leave, and detaches its retained adapter context. It refuses queue/pool rollback while the adapter or callback gate remains attached. The controller also checks `resourcesReleased()` after rollback before releasing the queue owner or radio.

A ticket still awaiting the Stage92 completion drain makes teardown return busy and keeps adapter, radio, pool, queue owner and controller references alive for retry. No callback is allowed to access an already released pool or radio.

## Validation

The Stage91 combined runner covers:
- existing Stage89 four-queue ABI/array regressions;
- Stage90 acquisition-journal rollback and queue-owner integration;
- packet span validation and concurrent bounded TX completion-ticket regressions;
- submission-gate bind/quiesce/in-flight races;
- accepted-prefix bounds, null packet and failure-prefix behavior;
- source integration checks for target ABI, adapter binding, ownership and teardown order.

The target-Mac host/source runner and the native WCL compile-only target must both pass before Stage91 is ready to merge.

## Explicitly excluded

- `registerEthernetInterface()`, queue registration/enable, event-source attachment and BSD interface publication;
- radio start, hardware traffic or RTL8821CE functional testing;
- TX completion queue operations (Stage92);
- RX submission/refill or RX completion delivery (Stages93–94);
- full kext link, code signing, install/load, or OpenCore/SIP/NVRAM changes.
