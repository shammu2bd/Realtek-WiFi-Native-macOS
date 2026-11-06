# Stage95 — independent PCI key-retirement and TXQ admission audit

Date: 2026-11-06  
Branch: `work/stage91-tx-submission-callback-v1`  
Source baseline: Stage94 final validated source `b667bfc4aac0f2ceacf8239a00e20551b45674df`

## Result

**BLOCKED — two source-level key-retirement findings.** This was a read-only review. No driver source, kext build configuration, OpenCore configuration, or activation state was modified.

## Finding 1 — HI0 is omitted from the synchronous PCI drain

The RTW88 TX queue mapper routes broadcast and multicast data frames to `RTW_TX_QUEUE_HI0`. The PCI transport has a dedicated `RTK_PCI_TXBD_IDX_HI0Q` doorbell and a corresponding entry in `tx_rings[RTK_MAX_TX_QUEUE_NUM]`; `rtw_pci_tx_write()` selects the ring returned by that mapper.

However, `rtw_pci_flush_queues_sync()` unconditionally skips `RTW_TX_QUEUE_HI0`. The HCI wrapper requests all queues during `DISABLE_KEY`, but the PCI layer then omits this live data ring. That means the current source cannot prove that multicast/broadcast descriptors using a GTK CAM entry have retired before `rtw_sec_clear_cam()` clears that slot.

**Disposition: BLOCKER.** The all-queues drain must account for every live data ring. Skipping beacon/H2C may be valid for their distinct purposes, but HI0 is a real data ring and needs an explicit retirement contract.

## Finding 2 — synchronous VO TXQ execution bypasses flush_work()

`rtw_ops_set_key()` calls `flush_work(&rtwdev->tx_work)` before polling the hardware. But `rtw_ops_wake_tx_queue()` calls `__rtw_tx_work(rtwdev)` directly and synchronously for `IEEE80211_AC_VO`; only the other ACs are submitted to `rtwdev->tx_work`.

The inline VO path uses the same `__rtw_tx_work()` -> `rtw_txq_push()` -> `rtw_hci_tx_write()` path, so it can submit descriptors without being represented by the queued `tx_work` item that `flush_work()` waits for. The source reviewed here does not show a TXQ-admission close/drain barrier shared with this inline path. The Stage94 native WCL reader gate covers its direct `ops->tx` submitters, but that does not by itself establish that this separate mac80211 TXQ entry path is quiesced.

**Disposition: BLOCKER pending reachability proof or a shared TXQ admission barrier.** A safe implementation must either prove this TXQ path cannot be entered for the target native VIF, with a regression assertion, or close and drain both the queued worker and synchronous VO producer before reading ring pointers.

## Mutex/deadlock review

`rtw_ops_set_key()` holds `rtwdev->mutex` while waiting for `flush_work()`. The audited `rtw_tx_work()` / `__rtw_tx_work()` and per-SKB enqueue functions do not directly acquire that mutex. This review therefore does **not** claim a proven mutex deadlock. The full lower-level HCI call-chain and target runtime behavior remain open and should be checked during the next implementation review.

## Confirmed safe parts retained

- The target PCI HCI ops table registers `rtw_pci_flush_queues_sync`.
- A missing synchronous HCI callback fails closed.
- `DISABLE_KEY` requires both the HCI/PCI drain and MAC firmware FIFO drain to succeed before CAM clear.
- Drain failure returns `-ETIMEDOUT`, preserving the fail-closed behavior.

## Validation

- Audit runner: `tools/run-stage95-key-retirement-audit.sh`
- Source checks: `tests/test-wcl-stage95-key-retirement.py`
- Validation type: Python syntax check and deterministic read-only source-structure checks.
- Expected audit disposition: **2 blockers**; the workflow's successful completion means the audit ran and identified the blockers, not that key retirement is cleared.
- No macOS kernel/IOKit compile, full kext link, signing, install, load, running-24H32 disassembly, PCI DMA runtime test, Wi-Fi hardware test, or throughput test was performed.

## Required next work

1. Correct and independently retest PCI drain coverage for HI0, including multicast GTK traffic.
2. Establish reachability of mac80211 `wake_tx_queue` for the target native VIF. If reachable, add a shared admission-close and quiescence contract that covers both queued work and inline VO execution; if unreachable, encode that invariant in source and tests.
3. Audit the complete worker-to-HCI call chain and mutex/lock ordering before changing the drain sequence.
4. Re-run the combined portable tests and target-Mac compile-only checks after implementation. Native queue activation, interface publication, radio start, install/load, and PR merge remain blocked.
