# Stage102 — XNU thread-call lifecycle and completion-token reclamation

Date: 2026-11-06
Branch: `work/stage91-tx-submission-callback-v1`
PR: [#4](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/pull/4)
Stage102 Actions source commit: `0af7a9c389e35487ecccc7bfb711c7a72403e909`
Current PR head at report time: `afbc6b08024d978bcd6230541ce2e9b5b5c602f5`

## Result

**Static lifecycle audit passed: 31 assertions, 0 failures.** The portable non-ONCE cancellation model and producer-admission shutdown race model passed. The target SDK/API review is source-grounded, but it is not a live kernel experiment. A fresh Stage102 target-Mac compile and actual XNU runtime test are still required.

## XNU contract verified

The checked-in target SDK is `driver/RTL88WiFi/MacKernelSDK/Headers/kern/thread_call.h`.

Its `thread_call_cancel_wait()` documentation says that it cancels a pending invocation, or waits for the current invocation if it has begun. It also expressly warns that invocations scheduled after the current invocation may still be in flight when it returns. Therefore `cancel_wait()` alone is not a complete teardown join for a reusable, non-ONCE call when later submissions are possible.

The SDK's `thread_call_isactive()` reports both pending and executing work. Stage102 consequently uses this ordering for both reapers:

1. Close the producer/callback admission gate.
2. Wait for active producers to leave the section that can enqueue or call `thread_call_enter()`.
3. Call `thread_call_cancel_wait()`.
4. Poll `thread_call_isactive()` until it reports no pending or executing invocation.
5. Perform one final passive-context drain and verify queue emptiness plus the outstanding-token count.
6. Free the thread-call and its owner context only after those checks pass.

References:
- [Apple — thread_call_cancel_wait](https://developer.apple.com/documentation/kernel/1444261-thread_call_cancel_wait)
- [Apple — thread_call_enter](https://developer.apple.com/documentation/kernel/1444247-thread_call_enter)
- [Apple — thread_call_isactive](https://developer.apple.com/documentation/kernel/1444253-thread_call_isactive)
- [Apple XNU — thread_call.h](https://github.com/apple/darwin-xnu/blob/main/osfmk/kern/thread_call.h)
- [Apple XNU — IOWorkLoop.cpp](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOWorkLoop.cpp)

## Generic skb reaper

- Producer admission is closed before the reaper join; its active-producer count covers enqueue and `thread_call_enter()`.
- `cancel_wait()` is followed by `thread_call_isactive()` polling.
- Final skb freeing is performed by a passive teardown consumer only after the reaper thread call is idle.
- If the queue or outstanding count is not zero, shutdown returns failure and the compat/PCI owner retains its state.

## WCL completion-token reaper

- Replaced the old intrusive token-retire list with the same sequence-numbered bounded MPSC queue used by the skb retire path.
- Token outstanding count increments before queue publication. Token queue overflow deliberately leaves the count elevated and quarantines that token; it never falls back to callback-context `kfree()/IOFree()`.
- The worker's workloop, notifier and retry-timer callbacks use an explicit admission/in-flight gate.
- Stop removes the retry timer and event source, closes and joins that callback gate, then joins the XNU thread call with `cancel_wait()` plus `isactive()`.
- One final passive token drain runs before the global release hook, adapter and completion queue are released.
- Adapter unbind checks outstanding tickets, backend completion callbacks and retired tokens before releasing the radio/pool ownership.

## Controller teardown order

The native controller now orders teardown as follows:

1. Stop RTW88 and fence PCI interrupts/bus mastering.
2. Close and join the full TX-status callback.
3. Close generic skb-free admission, join the generic XNU reaper, and final-drain skbs **while the WCL completion worker remains alive**. This is important because skb destruction can itself publish a WCL completion token.
4. Unbind the adapter only after ticket/backend callbacks/token ownership has drained.
5. Stop the WCL completion worker, join its own callbacks/thread call, final-drain tokens, then detach/release queue and PCI owners.

If any drain or join fails, cleanup returns busy/false and retains owners rather than releasing callback context or DMA-related resources.

## Validation

- [Stage102 Actions run 42166463980](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42166463980): success; **31 static assertions passed, 0 failed**.
- Portable model: pending cancellation while another non-ONCE invocation is executing behaved as expected; the worker remained active until the executing invocation finished.
- Portable producer shutdown model: **12 producers** raced the close gate; the join returned only after accepted producers had left, and subsequent admission was rejected.
- [Stage99 token-queue audit run 42166532642](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42166532642): success; **25 assertions passed, 0 failed**, plus 12-producer bounded MPSC token-queue stress.
- [Stage94 radio synchronization run 42166532656](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42166532656): success; **39 checks passed, 0 blockers**.
- The initial target-Mac clean dual-object build was subsequently attempted from source commit `f0ce12ca9b1265bda583f9443f42d6e4baba5d52` on Sequoia 15.8.1 (24H32) / Xcode 16.4. The build failed at `rtw88_compat.c:1340`: a diagnostic string contained a raw source newline, producing an unterminated string and `expected expression`.
- Corrected the diagnostic to use an escaped newline in commit `51ec80ac018328469613337ba7175642f55a9e0a`. Added a regression assertion in `tests/test-stage102-xnu-thread-call-lifecycle.py` to reject this exact malformed form; the final regression-test commit is `b6e7b9913f5781f38a5159cc5b7d7325b6c445f0`.
- Post-fix target-Mac run from source commit `bc85f74408787bde826f20e210706d0ae15584b5`: **PASS** on macOS 15.8.1 (24H32), x86_64, Xcode 16.4 (16F6).
- Post-fix Stage102 source/API suite: **32 checks passed, 0 failed**; the new malformed-string regression assertion passed.
- Portable thread-call cancellation and producer-admission models: **PASS**, including the 12-producer shutdown race.
- Stage99 bounded MPSC token-reclamation audit: **25 checks passed, 0 failed**; 12-producer retirement stress and exactly-once consumption passed.
- Clean dual-object build: `NATIVE_COMPILE_ONLY=PASS`, `ALL_OBJECT_COMPILE_ONLY=PASS`, **49 object files**, exit status **0**. The compile is object-only; no link, bundle, signing, install or load.
- Build transcript: [Stage102 post-fix clean dual-object compile](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/blob/work/stage91-tx-submission-callback-v1/Development/Logs/stage102-post-fix-clean-dual-object-compile-20261106T051547Z.log).

## Build failure and correction

The published clean-build log is `Development/Logs/stage102-clean-dual-object-compile-20261106T051059Z.log`. It records exit status 2 and one compiler error: `rtw88_compat.c:1340:29: error: expected expression`, preceded by `missing terminating '"' character`. The compiler stopped while building `build/compat/rtw88_compat.o`; the other displayed warnings are nonfatal and are not the cause of the failure.

The source and regression-test corrections are committed, and both the post-fix portable/source validation and the fresh target-Mac clean dual-object build now pass. The build source commit is recorded in the transcript as `bc85f74408787bde826f20e210706d0ae15584b5`.

## Still open — no runtime claim

- Fresh target-Mac 24H32 clean dual-object compile: **passed** (49 objects; object-only).
- Real XNU thread-call execution / cancellation / re-enqueue race testing on the Hackintosh: **not run**.
- Real IOWorkLoop/timer callback teardown under kernel scheduling: **not run**.
- Full kext link, signing, installation/loading, native activation and RTL8821CE hardware TX/RX: **not performed**.

The portable model and source audit support the ordering argument, but do not prove kernel scheduler behavior or runtime deadlock-freedom. PR #4 remains draft/open/unmerged; native activation remains blocked.
