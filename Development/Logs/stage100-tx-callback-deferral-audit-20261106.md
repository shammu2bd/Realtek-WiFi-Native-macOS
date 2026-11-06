# Stage100 — TX-status skb deferred free and callback logging audit

Date: 2026-11-06
Branch: work/stage91-tx-submission-callback-v1
Target: macOS Sequoia 15.8.1 (24H32), Intel x86_64

## Ownership and call-path findings

Normal PCI completion and firmware CCX report paths dispatch TX status synchronously while their respective queue locks are held. The shared radio callback previously called txStatus(skb) and then kfree_skb(skb); kfree_skb reaches kfree()/IOFree(). The TX-status method also emitted an IOLog diagnostic through the compatibility logger, including diagnostic-ring IOKit simple-lock acquisition.

The shared radio callback is linked by both legacy Airport and native WCL object graphs. The deferred-free implementation therefore belongs in the shared compat runtime, not in a WCL-only object.

## Stage100 source changes

- Added an intrusive, C-compatible lock-free MPSC retire stack and embedded one node in each sk_buff.
- Added a generic compat-runtime XNU kernel-priority thread-call reaper.
- TX-status callback now atomically publishes skb ownership and returns; it does not call kfree_skb, allocate, log, take an IOKit lock, or call IOFree.
- Missing-callback fallback in ieee80211_tx_status_irqsafe also transfers the skb to deferred-free.
- TX completion token publication remains synchronous and one-shot. Diagnostic frame classification and IOLog text were removed from this locked callback.
- Compat teardown stops workqueue producers, closes admission, waits active producers, joins the reaper, drains residual skb nodes, checks outstanding count, then releases the reaper and runtime locks.
- Legacy Airport startup checks rtw88_compat_init; native WCL already checked it. Legacy teardown calls compat exit only when its runtime initialization succeeded.

If a callback arrives after admission closes, its skb is deliberately quarantined instead of being freed in an unsafe context. Rejected requests are counted and reported at teardown.

## Validation

The source audit checks producer no-free/no-lock boundaries, callback ownership transfer, fallback behavior, logging removal, reaper handshake, initialization rollback, and teardown order.

The portable MPSC stress uses 12 producers and one consumer across 36,000 unique nodes, requiring exactly-once consumption.

These are source and host-model checks only. A clean target-Mac 24H32 dual-object compile remains required. No kext link, signing, installation, loading, native activation, hardware TX/RX, throughput, or runtime XNU lock-order proof is included. PR #4 remains open, draft, and unmerged.
