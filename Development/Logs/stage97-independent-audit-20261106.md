# Stage97 — independent CAM bounds and TXQ concurrency audit

Date: 2026-11-06  
Branch: `work/stage91-tx-submission-callback-v1`

## Independent finding and correction

The Stage96 review exposed an additional CAM boundary defect. `rtw_sec_get_free_cam()` searches a 32-entry bitmap and returns 32 as its sentinel when every slot is occupied. The previous `rtw_ops_set_key()` check used `hw_key_idx > sec->total_cam_num`, allowing index 32 through even though valid array indices are 0–31. Both `rtw_sec_write_cam()` and `rtw_sec_clear_cam()` indexed `cam_table[hw_key_idx]` without their own bounds checks.

Stage97 changes:
- `rtw_ops_set_key()` rejects `hw_key_idx >= sec->total_cam_num` and `>= RTW_MAX_SEC_CAM_NUM` before any CAM access. Invalid DISABLE_KEY indices return `-EINVAL`; exhausted SET_KEY allocation returns `-ENOSPC`.
- `rtw_sec_write_cam()` and `rtw_sec_clear_cam()` independently guard the physical array bound and configured CAM count before dereferencing the table.
- Added a static audit for the full-bitmap sentinel, call-site validation, low-level defensive checks, both TXQ dispatch paths, quiesce/resume ordering, and HI0 inclusion.

## Lock-order / teardown review

Confirmed from source:
- VO inline dispatch and queued work both enter `__rtw_tx_work()`.
- The worker holds `txq_lock` across dequeue, HCI write and kick-off; `rtw_txq_quiesce()` takes the same lock before setting the gate, then flushes the queued worker.
- `rtw_ops_set_key()` holds `rtwdev->mutex` across quiesce and hardware drains. The inspected TXQ worker and `rtw_txq_push_skb()` do not directly acquire that mutex.
- PCI drain covers every non-beacon/non-H2C hardware ring, including HI0, and compares hardware RP with software WP.

Still open:
- This source inspection is not a runtime lockdep proof. Full HCI callback call-chain lock ordering against PCI `irq_lock`, interrupt completion/wake-queue callbacks, and mac80211 key-removal context must be independently validated on the target kernel.
- The current code holds `txq_lock` across `ieee80211_txq_get_depth()`, dequeue, HCI write and kick-off. Whether every target mac80211/PCI callback is safe under this lock remains an explicit review item.
- Hardware RP/WP wrap semantics and the exact firmware meaning of FIFO reserved/available page equality need target-chip runtime confirmation.

## Validation

- Added `tests/test-wcl-stage97-independent-audit.py`, `tools/run-stage97-independent-audit.sh`, and `.github/workflows/stage97-independent-audit.yml`.
- Expected result: static source invariants only. A passing workflow does not prove kernel compilation or runtime locking correctness.

## Explicit limits

No target macOS 24H32 compile, full kext link, signing, install, load, target disassembly, hardware TX/RX, throughput test, native queue activation, interface publication, radio start, or EFI/OpenCore/SIP/NVRAM change. PR #4 remains draft and unmerged. Native activation remains blocked pending target-Mac compile-only validation and independent runtime lock-order review.
