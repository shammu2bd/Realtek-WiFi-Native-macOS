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
- Changed `rtw88_compat_exit()` to return `bool` and made legacy/WCL PCI owners propagate failure instead of freeing hardware resources.
- Added a full TX-status callback admission gate around `ieee80211_tx_status_irqsafe()`. Teardown closes this gate and waits for callbacks to finish across completion publication and deferred skb enqueue. Legacy radio release and WCL completion-worker stop now occur only after that quiescence barrier.
- Legacy PCI stop now withholds superclass stop and preserves MMIO/PCI/DMA ownership if compat exit fails; its free path quarantines a live owner.
- WCL backend close returns busy on failed compat shutdown; closeResources/free preserve DMA and PCI lease state. The controller already retains its child backend and parent workloop when child close fails.
- The portable stress test reuses a 256-node pool across 36,000 publications, and separately checks capacity-full rejection, slot reuse and sequence wrap.

## Validation

Stage101 Actions passed 31 static source/lifecycle assertions and a 12-producer/36,000-item portable MPSC stress test with node-address reuse. The bounded 2048-slot queue's full rejection, slot recycling, and sequence wrap checks also passed. A clean target-Mac 24H32 dual-object compile remains required. Host tests do not prove XNU thread-call scheduling or runtime lock order. No full kext link, signing, installation, loading, native activation, or RTL8821CE hardware test is performed. PR #4 remains open, draft, and unmerged.

## Actions verification (2026-11-06)

- [Stage101 run 42164478976](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42164478976): success; **31 assertions passed, 0 failed**.
- MPSC stress: **12 producers, 36,000 publications, reused 256-node pool, exactly-once consumption**.
- Queue checks: 2048-slot capacity full rejection and sequence wrap passed.
- [Stage94 run 42164478898](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42164478898): success; **39 checks passed, 0 blockers**.
- [Stage100 callback audit run 42164476209](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42164476209): success; **31 assertions passed, 0 failed**.
- Target-Mac clean dual-object compile against this latest Stage101 source is still pending.
