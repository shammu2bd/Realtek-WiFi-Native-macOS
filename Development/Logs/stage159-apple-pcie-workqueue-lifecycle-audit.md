# Stage159 — Apple PCIe workqueue lifecycle confirmation

## Purpose
Stage158 identified a concrete Apple PCIe queue path:
- `AppleBCMWLANBusInterfacePCIe::start()` calls `IO80211WorkQueue::workQueue()` and stores the result in its expansion at `+0xDD0`.
- `AppleBCMWLANBusInterfacePCIe::getWorkQueue()` returns that `+0xDD0` object.
- `AppleBCMWLANBusInterfacePCIe::freeResources()` releases and clears the same field.

Stage159 rechecks these exact call sites and correlates them with the Apple core callback that retains the bus-provided queue, the PostOffice factory, and controller teardown. The aim is to distinguish the bus-owned queue reference from the core/PostOffice references and prevent a borrowed pointer or incorrect release from being introduced into the Realtek driver.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Stage158 report: `Development/Logs/stage158-apple-pcie-workqueue-ownership-20261106T214534Z.log`, Git blob SHA `f7d153bca56a1552160e46c4c61b3214b1670fda`.
- KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit
1. Verify Stage158 report and BootKC hashes.
2. Re-disassemble the PCIe bus `start()` path around the queue factory call and `+0xDD0) store.
3. Re-disassemble the PCIe getter and `freeResources()` release/clear at `+0xDD0`.
4. Reconfirm the IO80211WorkQueue factory, Apple core bus-provider callback/retain path, PostOffice factory and controller teardown.
5. Record the field/refcount sequence as a static correlation, without assuming that a third-party controller has the same bus-private expansion.
6. Upload the report under `Development/Logs/` and verify the Git blob SHA.

## Safety and interpretation
Read-only static analysis only. No source, branch, index, or worktree changes; no build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. Do not transplant Apple's private expansion offsets, object layout, or queue-provider subclass. A driver change still requires explicit authorization plus an API-compatible workqueue construction, retain/release and teardown design supported by the project's headers and runtime validation.
