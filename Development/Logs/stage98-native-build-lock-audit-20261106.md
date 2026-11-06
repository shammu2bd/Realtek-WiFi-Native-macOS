# Stage98 — native object graph and TX callback lock audit

Date: 2026-11-06  
Branch: `work/stage91-tx-submission-callback-v1`  
Source head validated: `3cf34caa5074d30bda3a7312f33a3b06e0501b43`

## Finding: native link object omitted the TX completion worker

The native controller includes and constructs `RTW88WCLTxCompletionWorkQueue`, initializes it against the controller workloop and the Skywalk TX completion queue, and uses its deferred completion handoff. The native target's `NATIVE_ALL_OBJS` list did not include `WCL24H32_TX_COMPLETION_WORK_OBJ`. A future native link would therefore omit the implementation object required by the controller.

Stage98 correction:
- Added `$(WCL24H32_TX_COMPLETION_WORK_OBJ)` to `NATIVE_ALL_OBJS`.
- Added a `native-compile-only` target depending on the complete native object graph. It compiles objects only and has no link, bundle assembly, signing, installation or loading recipe.
- Added `NATIVE_CORE_OBJS` dependency files to `DEPFILES` so native core header changes trigger incremental rebuilds.

## TX callback / lock-order review

Confirmed:
- The TXQ worker holds `txq_lock` while it dequeues and calls the HCI TX write path.
- The PCI HCI descriptor submission path takes `irq_lock` during ring queue insertion.
- PCI interrupt-thread TX completion processing runs under `irq_lock`.
- In this macOS compatibility layer, `ieee80211_wake_queue()` is an empty stub; it does not call back into the TXQ wake handler. The Linux-style `irq_lock -> wake_queue -> txq_lock` inversion is therefore not established for this target path.
- The compatibility implementation of `ieee80211_tx_status_irqsafe()` calls the registered `tx_status` callback synchronously. That callback enters `RTW88IEEE80211::txStatus()`, which calls `rtw88_skb_tx_completion_report()`.

Still open:
- The complete internal implementation and synchronization behavior of `rtw88_skb_tx_completion_report()` must be traced to determine whether it can acquire a lock that participates in the TXQ/PCI lock graph or invoke a re-entrant backend callback.
- The target's actual interrupt/workloop scheduling and lock ordering require macOS runtime/lock instrumentation. Static source checks cannot prove deadlock freedom.
- No runtime lockdep or hardware lock stress was performed.

## Validation

Stage98 GitHub Actions run [42155869887](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42155869887): **success**, 9 checks passed, 0 failed.

The workflow is Linux-hosted and checks source/build-graph invariants only. It does not run the macOS compile-only target.

## Required target-Mac compile-only command

On the Sequoia 15.8.1 / 24H32 Intel Mac, from the project checkout:

```sh
cd "$HOME/Developer/Realtek-WiFi-Native-macOS-Stage91-PR4-Review" || exit 1
export DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
xcode-select -p
xcrun --show-sdk-path
make -C driver/RTL88WiFi native-compile-only
```

This target is object compilation only. Do not run `rtl88wifi-native`, `make kext`, `make install`, `make load`, signing, or any activation command as part of Stage98.

## Gate

`STAGE98_RESULT=PASS_STATIC_AUDIT_WITH_OPEN_RUNTIME_REVIEW`  
`TARGET_MAC_COMPILE_ONLY=NOT_RUN`  
`LOCK_ORDER_RUNTIME_PROOF=OPEN`  
`NATIVE_ACTIVATION=BLOCKED`

PR #4 remains draft, open and unmerged. No full kext link, signing, install/load, RTL8821CE hardware test, native queue registration/enable, interface publication, radio start, or EFI/OpenCore/SIP/NVRAM change was performed. The known-good legacy kext and everyday EFI remain untouched.
