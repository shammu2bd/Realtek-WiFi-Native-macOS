# Stage 17 — queue lifecycle and RX/TX ownership evidence

## Purpose

Stage 17 collects exact macOS 15.8.1 (24H32), x86_64 method lists and disassembly for the generic Skywalk packet queues, pools, packet/buffer/memory-segment objects, and Ethernet interface registration lifecycle. It also verifies that the project continues to hold the pre-activation safety fences.

This is an evidence-collection and source-audit stage. A Stage 17 `PASS` means that the linked Stage 14/15/16 inputs are consistent, the targeted class method lists and method bodies were collected for the exact same kernel collection, and the current source still refuses to activate the native datapath. It does **not** mean that queue ownership semantics have been fully proved or that the datapath is ready to enable.

## Inputs and linkage

The collector requires the Stage 14 kcabi archive, Stage 15 packet accessor audit archive, and Stage 16 packet semantics audit archive in their normal `build/sequoia-abi-24H32-stageNN` directories. The audit checks SHA-256 linkage and requires prior-stage PASS records. It then prepares a method reference set from the Stage 14 class member lists and disassembles the additional queue/interface methods from the current 24H32 `BootKernelExtensions.kc`.

The temporary kcabi checkout is patched only in a disposable copy so `IOSkywalkMemorySegment` is included in the class inventory. The original `~/src/kcabi` checkout is not modified. The archive records the kcabi source commit and kernel collection SHA-256.

## Source safety checks

The source audit verifies fail-closed TX/RX queue callbacks; validation before TX rejection; queue/pool allocation and teardown order; RX packet acceptance/rejection ownership; source-mbuf release; bounded RX staging ring behavior; in-flight packet-path quiescence; and deferred TX completion ticket lifetime.

`RTW88WCLInfraInterface::start()` intentionally returns `false` without calling `super::start()`. The `enable()` method contains the single latent call to `activatePacketPath(this)`, reached only from the interface lifecycle after `start()` succeeds. Since `start()` refuses publication, the native interface is not started. The audit checks this actual lifecycle gate rather than incorrectly requiring the method name to be absent from source.

## Still unresolved after Stage 17

The collector records exact method bodies but does not infer ownership from method names. The following contracts still require manual analysis of their implementations and call relationships:

- RX completion enqueue ownership transition and callback packet-array semantics.
- RX submission dequeue/replenishment ownership and retry semantics.
- TX completion queue acceptance and packet-retain transfer semantics.
- Packet-buffer and memory-segment prepare/complete requirements for configured pool options.
- Ethernet interface registration success/failure ownership and deregistration order.
- Queue enable/disable/synchronize and teardown ordering with in-flight callbacks.

## Safety boundary

No queue is registered, no packet is submitted or enqueued, no native queue callback accepts ownership, no radio starts, and no Ethernet interface is published in this stage. The generated report always marks `activation_gate` as `BLOCKED`.
