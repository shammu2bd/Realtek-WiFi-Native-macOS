# Sequoia 24H32 WCL — Stage 7: bounded RX packet ownership

## Scope

Stage 7 connects the pool-backed packet builder from Stage 6 to an explicit,
controller-owned 128-entry MPMC ready-packet ring. A successful RX sink call
transfers ownership of the `IOSkywalkPacket` to that ring. If the ring is full,
the sink rejects it and Stage 6 returns the packet to the RX pool immediately.

The ring is bounded to the configured RX packet-pool capacity (128 packets).
It performs no allocation during enqueue and does not invoke any Skywalk queue
API. This creates a deterministic ownership point for a future verified RX
completion handoff without pretending the current completion queue is ready.

## Teardown

Shutdown first closes/quiesces the packet path, stops the RTW88 producer, and
removes the RX adapter workloop source. It then dequeues retained native packets
and returns them to the still-live RX pool. Only after successful recycle are
the queue owner and its packet pools released. If an individual `deallocatePacket()` fails, the radio and RX consumer are
already quiesced and the queues were never registered, so the controller falls
back to `disposeAllPackets()` for the RX pool before releasing its memory
segments. This keeps the packet-pool cleanup path bounded and centralized.

## Explicit limitations

- The ring is a staging owner only, not an RX completion queue.
- No `enqueuePackets()` or `registerEthernetInterface()` call is made.
- The RX sink may retain packets only in this bounded ring; it does not publish
  frames to the BSD interface or SystemConfiguration.
- Native controller, RX adapter, queue owner and PCI backend remain separate
  compile-only objects outside the active legacy Kext link.
- Radio start, interface publication, OpenCore changes and driver installation
  remain disabled.
- The 24H32 registration return convention and RX completion ownership contract
  must still be proven from complete target function bodies before the next
  datapath step.

## Validation

`tests/test-wcl-rx-packet-retention-stage7.py` stress-tests the fixed-capacity
MPMC pointer ring (8 producers, 48,000 unique pointers) and audits ownership
transfer, failure rollback, pool recycle and teardown ordering. The existing RX,
controller, queue, TX and protocol regression suites remain required.
