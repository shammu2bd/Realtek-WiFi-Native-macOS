# Stage101 — bounded MPSC reclamation queue and teardown lifecycle

Date: 2026-11-06
Branch: work/stage91-tx-submission-callback-v1
Target: macOS Sequoia 15.8.1 (24H32), Intel x86_64

## Stage101 audit findings

1. Stage100 used an intrusive Treiber-style MPSC stack. A producer could retain an observed head pointer while the consumer atomically detached and reclaimed that node. If an allocation later reused the same address, the producer's compare/exchange could face an ABA hazard. The Stage100 stress test used unique nodes and did not recycle addresses.
2. Stage100 compat exit could return early on drain failure but had a void return type. The legacy and WCL PCI owners therefore could not distinguish failed cleanup and could continue releasing PCI/DMA resources.

## Stage101 changes

- Replaced the intrusive stack with a fixed 2048-slot sequence-numbered MPSC pointer ring. Per-slot generations protect reuse without retaining reclaimable node pointers.
- Queue-full is explicit. The callback never falls back to synchronous kfree/IOFree; it counts the rejected skb for quarantine.
- The single consumer drains queue entries. Final passive teardown drains only after producer admission is closed, active producers are joined, and the thread call has been joined.
- Changed `rtw88_compat_exit()` to return `bool`.
- Legacy PCI stop now withholds superclass stop and preserves MMIO/PCI/DMA ownership if compat exit fails; its free path quarantines a live owner.
- WCL backend close returns busy on failed compat shutdown; closeResources/free preserve DMA and PCI lease state. The controller already retains its child backend and parent workloop when child close fails.
- The portable stress test reuses a 256-node pool across 36,000 publications, and separately checks capacity-full rejection, slot reuse and sequence wrap.

## Validation

Stage101 Actions will run 24 static source assertions and a 12-producer/36,000-item portable MPSC stress test with node-address reuse. A clean target-Mac 24H32 dual-object compile remains required. Host tests do not prove XNU thread-call scheduling or runtime lock order. No full kext link, signing, installation, loading, native activation, or RTL8821CE hardware test is performed. PR #4 remains open, draft, and unmerged.
