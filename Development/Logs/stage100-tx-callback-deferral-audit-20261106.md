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

These are source and host-model checks plus a clean target-Mac compile-only validation. The clean build ran on macOS 15.8.1 (24H32) with Xcode 16.4 and compiled both Airport and native object graphs: 49 unique objects (25 driver, 4 compat, 9 Airport, 4 native, 7 WCL 24H32), zero compiler errors. The legacy object also passed the check for no direct WCL-only adapter symbol. The compile was performed at source commit d196bc1d4cf24825861443ecf70d03cad71f7e76; the seven Stage100 source files plus Makefile have identical blob hashes at the current PR head. Non-fatal compiler warnings remain. This is not a full kext link, signing, installation, loading, native activation, hardware TX/RX, throughput test, or runtime XNU lock-order proof. PR #4 remains open, draft, and unmerged.

## Actions verification (2026-11-06)

- Stage100 Actions run [42162937670](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42162937670): success; **17 source assertions passed, 0 failed**.
- Portable MPSC stress: **12 producers, 36,000 unique nodes, exactly-once consumption passed**.
- Stage94 compatibility run [42162937646](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42162937646): success; **39 checks passed, 0 blockers**.
- Target-Mac clean dual-object compile remains pending. XNU runtime thread-call and lock-order behavior remains unproven.

## Target-Mac clean dual-object compile (2026-11-06)

- Detail log: [stage100-clean-dual-object-compile-20261106T043340Z.log](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/blob/work/stage91-tx-submission-callback-v1/Development/Logs/stage100-clean-dual-object-compile-20261106T043340Z.log)
- Environment: macOS 15.8.1 build 24H32, Xcode 16.4, x86_64.
- Build source commit: `d196bc1d4cf24825861443ecf70d03cad71f7e76`.
- Airport object graph PASS; native object graph PASS; combined object-only target PASS.
- 49 unique objects: driver 25, compat 4, Airport 9, native 4, WCL 24H32 7.
- Compiler errors: 0. Non-fatal warnings remain.
- Legacy object check: no direct WCL-only adapter symbol reference.
- Relevant Stage100 source and Makefile blob hashes match at build and current PR source.
- No full link, bundle, sign, install, or load occurred.
