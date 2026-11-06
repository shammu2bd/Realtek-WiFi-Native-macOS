# Stage96 — HI0 and TXQ key-retirement barrier implementation

Date: 2026-11-06  
Branch: `work/stage91-tx-submission-callback-v1`

## Implementation

Stage96 addresses the two Stage95 source findings:

1. **HI0 drain coverage:** `rtw_pci_flush_queues_sync()` now excludes only beacon and H2C rings. HI0 remains in the all-queues mask and is polled using the same hardware consumer-pointer versus producer-pointer retirement test as the other data rings. HI0 is the PCI ring selected for multicast/broadcast data and can reference GTK CAM.
2. **Shared TXQ quiescence:** added `txq_quiescing`, protected by the existing `txq_lock`. `__rtw_tx_work()` checks the gate while holding that lock before dequeuing or submitting. `rtw_txq_quiesce()` closes the gate under the lock, thereby waiting for an already-running synchronous VO worker, then joins queued `tx_work`. Key disable performs both hardware drains and only then clears CAM. `rtw_txq_resume()` reopens admission, joins any worker that may have observed the closed gate, and re-kicks the retained TXQ list.
3. **Timeout behavior:** if either HCI/PCI or MAC firmware FIFO drain fails, CAM is not cleared; TXQ admission is still resumed so traffic is not stranded.

## Source-level review notes

- The shared lock is the admission and active-execution barrier because `__rtw_tx_work()` holds it across the complete dequeue, HCI write and kick-off sequence.
- Both synchronous VO and queued worker dispatches call `__rtw_tx_work()`; both therefore observe the same gate.
- This does not prove all external mac80211 call paths or every hardware/firmware completion semantic at runtime. The lower-level HCI lock ordering and target-kernel behavior remain review items.
- The existing `rtwdev->mutex` remains held by `rtw_ops_set_key()` across the quiesce/drain operation, as in the earlier flush implementation. The worker path inspected does not acquire that mutex directly; a target runtime lock-order check remains outstanding.

## Validation

- Added `tests/test-wcl-stage96-key-retirement.py` and `tools/run-stage96-key-retirement-tests.sh`.
- Added GitHub Actions workflow `.github/workflows/stage96-key-retirement.yml`.
- The workflow checks source invariants, ordering, fail-closed behavior and resume/re-kick ordering.
- A successful workflow is a static source-regression result only, not a kernel build or runtime proof.

## Explicitly not performed

No macOS kernel/IOKit compile, full kext link, signing, install, load, target 24H32 disassembly, hardware DMA/TX/RX/throughput test, native queue registration/enabling, interface publication, radio start, or OpenCore/SIP/NVRAM/EFI change. The known-good legacy kext and everyday EFI remain unchanged. Native activation and PR merge remain blocked pending independent review and target-Mac compile-only validation.
