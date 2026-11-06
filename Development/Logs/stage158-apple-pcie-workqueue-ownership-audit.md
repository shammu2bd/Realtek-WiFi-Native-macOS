# Stage158 — Apple PCIe bus workqueue ownership audit

## Purpose
Stage157 resolved the common bus interface callbacks and found a separate concrete override, `AppleBCMWLANBusInterfacePCIe::getWorkQueue()`, in the Apple PCIe bus extension. The base `needWorkQueue()` returns false and base `getWorkQueue()` returns null. The Apple core then takes the bus-supplied path and retains the returned queue.

Stage158 maps the concrete PCIe bus class vtable, inspects its workqueue getter and lifecycle methods, examines the PCIe doorbell queue accessor and creation paths, inventories relevant symbols in the PCIe bundle, and correlates the results with Apple core's queue-selection path. It is focused on the exact RTL8821CE/PCIe-style bus implementation pattern, not a USB or generic workqueue guess.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Stage157 report: `Development/Logs/stage157-apple-bus-workqueue-contract-20261106T214304Z.log`, Git blob SHA `46b7200ee8dc3107d3e1f1e3420afe3f53c18bb2`.
- KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit
1. Verify the Stage157 report and BootKC hashes.
2. Resolve `AppleBCMWLANBusInterfacePCIe` vtable slots `+0x860` and `+0x868`, including exact fileset ownership.
3. Disassemble PCIe bus queue callbacks, object initialization/start/stop/free, ring creation and teardown paths.
4. Resolve `AppleBCMWLANPCIeDoorbell` queue accessors and lifecycle, including queue ownership and any retain/release behavior.
5. Inventory queue/workloop/command-gate/timer symbols in the PCIe bundle.
6. Reconfirm Apple core's queue-selection branch and publish the report with Git blob SHA verification.

## Safety and interpretation
Read-only static analysis only. No source, branch, index, or worktree changes; no build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. Do not copy private Apple queue wiring or infer ownership from a field accessor alone. Any driver source change still requires explicit authorization and complete queue lifetime / API compatibility evidence.
