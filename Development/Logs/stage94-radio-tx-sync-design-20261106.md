# Stage94 — shared radio TX synchronization design and model validation

Date: 2026-11-06  
Repository: shammu2bd/Realtek-WiFi-Native-macOS  
Branch: work/stage91-tx-submission-callback-v1  
PR: #4 (draft; must remain unmerged)  
Target: macOS Sequoia 15.8.1 / 24H32 / x86_64 / RTL8821CE PCIe

## Decision

A radio-wide, nonblocking TX-admission / deferred-writer barrier is the preferred design. It is safer than holding a spin lock or IOLock across the RTW88 submit call. The portable gate primitive and its concurrency model are implemented and tested in this stage.

IMPORTANT: this is a design/model checkpoint, not yet a driver integration. The new helper is not called from RTW88IEEE80211::txDataFrame, and key/station/BA mutation call sites have not been changed. Therefore Stage93 production-source blockers remain open and this stage does not authorize native queue activation or PR merge.

## Source path evidence

The native radio txDataFrame() reads radio/key/station/BA state and calls _hw->ops->tx(_hw, &ctrl, skb) synchronously.

The checked-in RTW88 TX implementation then calls rtw_tx_pkt_info_update() before rtw_hci_tx_write(). During this synchronous descriptor-build phase:

- rtw_tx_pkt_info_update_sec() dereferences info->control.hw_key to read the cipher.
- rtw_tx_data_pkt_info_update() dereferences the station and its driver-private fields to derive AMPDU/rate/bandwidth descriptor fields.
- rtw_tx_pkt_info_update() reads the VIF and station state to construct the packet descriptor.

For PCIe, rtw_pci_tx_write_data() fills the hardware descriptor and maps the packet for DMA before the skb is retained on the TX ring. The inspected TX interrupt path reads completion/status fields from the skb; this source slice did not show a later key/station dereference. A complete audit of every compat/status callback remains required before treating the lifetime boundary as fully closed.

This supports a shared read-side lease spanning the first shared-state read through the return of _hw->ops->tx(). No lock is held across the hardware's asynchronous transmission; the lease protects only the synchronous source-side dereferences and descriptor construction.

## Proposed radio-wide protocol

1. One RTW88TxStateGate belongs to the radio object, not to an AC queue. All four WMM TX submit paths use the same admission gate.
2. Before reading _ptkConf, _sta, _vif, _wpa2, _targetBSS, MAC/BSSID fields, or TX Block Ack state, txDataFrame() acquires a TransmitLease. It keeps that lease until _hw->ops->tx() returns, and releases it on every error/success path with RAII.
3. A control-plane writer obtains a MutationLease. The atomic transition closes new TX admission immediately. Existing transmitters finish normally. The writer may touch protected state only when MutationLease::ready() reports zero active submitters.
4. If the mutation is not ready, the control path defers/retries on a serialized passive control workloop. It must not spin, sleep, or wait in a TX callback or interrupt context. All writers are serialized; a second writer cannot take ownership while the first barrier is pending.
5. Key install/replace/clear, station/VIF teardown or replacement, association/BSSID changes, TX BA active/TID changes, and any TX sequence reset are writer operations. releaseSta() must still honor rtw88_unregister_sta() / sta_remove() quiescence semantics.
6. Read _txBaActive and _baTid under the same TX lease so one frame observes a stable BA decision. If those fields are later separated from the shared barrier, publish them as one packed atomic snapshot rather than independent unsynchronized reads.
7. Remove _eapolTxProtect as a shared mutable radio boolean. Pass an explicit per-frame protection argument from sendEAPOLKey() into the frame builder. Ordinary EAPOL and group-message-2 EAPOL then cannot observe each other's temporary flag. RTW88TxFrameProtection.hpp isolates the pure policy for testability.
8. Prefer never resetting the 48-bit CCMP PN allocator or per-TID sequence allocators during the lifetime of the radio object. The existing allocators already refuse CCMP PN exhaustion and naturally wrap the 12-bit 802.11 sequence space. Preserving the counters avoids reset-vs-submit races and avoids accidental reuse if identical key material is reinstalled. If a reset is retained for a demonstrated reason, it must be a writer operation and the key-generation / outstanding-DMA contract must be proved separately.

The gate intentionally does not choose an IOLock or spinlock. The unused _lock must not be repurposed until its IRQL/locking contract and lock ordering are proven. The model's reader side is bounded atomic admission; the writer side closes admission and polls/defer-drains without blocking a TX callback.

## Portable model tests

Added:

- driver/RTL88WiFi/src/kext/RTW88TxStateGate.hpp
- driver/RTL88WiFi/src/kext/RTW88TxFrameProtection.hpp
- tests/rtw88_tx_state_gate_test.cpp
- tools/run-stage94-radio-tx-sync-model-tests.sh

The host test covers admission, writer-close/drain, rejection of new TX during mutation, single-writer ownership, cancellation, per-call EAPOL policy isolation, and concurrent reader/writer stress representing the four AC submitters.

Observed validation in this environment:

- Compiler: Clang 17.0.0
- Host: Linux 6.18.57 x86_64 (not the target macOS machine)
- C++11 compile: PASS with -Wall -Wextra -Werror -pthread
- Test suite: PASS
- Repeated concurrency suite: 20/20 runs PASS

The test does not compile the production kext, exercise IOKit callback context, prove kernel atomic lock-freedom, test radio hardware, or verify the target runtime. The helper is not yet integrated into the radio implementation.

## Remaining production integration gates

- Wire one shared gate into every path that can submit a data TX frame, including all native WMM callbacks and any legacy/internal data TX entry points that can race them.
- Put the lease before the first shared-state read and release it after synchronous ops->tx() returns on every exit path.
- Convert every key/station/VIF/association/BA mutator to a serialized writer transaction; define how synchronous API callers are completed when the writer must defer.
- Remove _eapolTxProtect and pass a per-frame argument; use the pure helper in the actual frame builder.
- Remove runtime sequence/PN resets or prove each reset's key generation and quiescence contract.
- Audit all RTW88 and compat callbacks for any deferred dereference of control.hw_key, control.sta, or control.vif after ops->tx() returns.
- Re-run Stage93's independent audit after integration. Only then consider a target-Mac compile-only run. No link/sign/install/load/hardware test is authorized by this checkpoint.

## PR #4 merge check (before this Stage94 commit)

GitHub reported PR #4 as open, draft, merged=false, mergeable=false, with no submitted PR reviews or review threads. The compare against main reported the head branch as 112 commits ahead and 64 commits behind, status diverged. The head commit's combined status had no reported check entries and no workflow runs were returned. This is not merge-ready: the branch needs a careful update/rebase and conflict review, and the design/source blockers and stale validation summary must be resolved. Do not click Merge or mark ready for review.

The PR description also still says Stage92 tests/compile are pending, although the project's Development/output.log contains Stage92 host-test PASS and eight-object compile PASS entries. The PR body should be corrected before independent review, while keeping it draft until the Stage93 blockers are actually closed.

## Stage94 result

STAGE94_MODEL_TESTS=PASS  
STAGE94_DRIVER_INTEGRATION=NOT_DONE  
STAGE93_BLOCKERS=CARRY_FORWARD  
PR4_MERGE=NO  
NATIVE_ACTIVATION=BLOCKED
