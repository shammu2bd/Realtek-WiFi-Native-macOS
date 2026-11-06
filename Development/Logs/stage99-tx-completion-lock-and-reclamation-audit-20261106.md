# Stage99 — TX completion callback lock and deferred reclamation audit

Date: 2026-11-06
Branch: `work/stage91-tx-submission-callback-v1`
Target profile: macOS Sequoia 15.8.1 (24H32), Intel x86_64

## Trace findings

The normal PCI TX-completion path calls `ieee80211_tx_status_irqsafe()` from `rtw_pci_tx_isr()` while `rtw_pci_interrupt_threadfn()` still holds `rtwpci->irq_lock`. The firmware CCX TX-report path also invokes TX status while `rtw_tx_report_handle()` holds `tx_report->q_lock`. The macOS compatibility implementation dispatches `g_hw_cbs->tx_status()` synchronously.

`RTW88IEEE80211::txStatus()` calls `rtw88_skb_tx_completion_report()`. The reporter atomically claims its token, copies callback fields, then dispatches the release and completion callbacks. Before this change the release callback called `kfree(token)`. The compatibility `kfree()` reaches `IOFree()`. Apple documents that `IOFree()` may block; it should not be called from interrupt level or while an XNU simple lock is held: https://developer.apple.com/documentation/kernel/1575290-iofree.

The port's `spinlock_t` shim uses `IORecursiveLock`, and the compatibility IRQ thread is run on the ordered datapath workqueue. Therefore this source trace establishes that token freeing was synchronous inside the driver callback/lock critical sections, but it is not a claim that these particular locks are native XNU simple spin locks or that a deadlock was reproduced.

## Stage99 correction

- Added `deferred_next` to the completion token and a freestanding lock-free MPSC intrusive retire list.
- The reporter now calls the release hook before the backend callback. The release hook atomically publishes the token and increments the adapter's outstanding-retirement count; it performs no allocation, lock acquisition, `kfree()` or `IOFree()`.
- The backend completion callback then publishes the ticket and signals the worker. This ordering ensures the token is counted as retired before the completed ticket can wake drain/teardown.
- The worker owns a kernel-priority XNU thread call. Its workloop check schedules the thread call with a scheduled/resignal handshake; only the thread-call consumer detaches and `kfree()`s retired tokens.
- Adapter `unbind()` and `free()` fail closed while ticket callbacks or retired tokens remain. Worker `stop()` refuses live ownership, removes the workloop source, cancels/waits/frees its thread call, and only then drops adapter/queue retains.
- Controller cleanup now checks the worker stop result and retains its owners if the deferred reaper has not stopped cleanly.

## Validation

- Stage99 Actions run [42160090258](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42160090258): success; **19 source assertions passed, 0 failed**.
- Portable MPSC stress in the same run: **12 producers**, **36,000 distinct nodes**, one consumer; exactly-once node consumption passed.
- Stage98 native object graph / callback source audit [42160062019](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42160062019): success; **13 passed, 0 failed**.
- Stage94 radio TX integration [42160090224](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42160090224): success; **39 passed, 0 blockers**.

These are Linux-hosted source/model tests only. The Stage99 target-Mac compile has not yet been run.

## Remaining review items

1. Run a fresh macOS 24H32 `native-compile-only` build against the Stage99 branch head. No kext link, signing, installation, loading or activation is part of this gate.
2. Verify the target XNU thread-call/workloop scheduling and teardown behavior on macOS. Static code/model tests do not prove runtime lock ordering or deadlock freedom.
3. A separate synchronous free remains: `compat_tx_status()` calls `kfree_skb(skb)` after `txStatus()` returns, and `txStatus()` may emit `IOLog` while called from the locked PCI/firmware report paths. Stage99 moves the separate completion-token `IOFree()` out of the callback; it does not move the skb's own reclamation or logging. This remains a distinct lock-duration review item.
4. No full kext link, signing, install/load, RTL8821CE hardware TX/RX, throughput test, native queue activation, interface publication or radio start has been performed.

PR #4 remains draft, open and unmerged. Native activation and PR merge remain blocked.