# Stage157 — Apple bus workqueue contract audit

## Purpose
Stage156 confirmed that `AppleBCMWLANCore::createWorkQueue()` consults its `AppleBCMWLANBusInterface` object through virtual offsets `+0x860` and `+0x868`. Depending on the first result, it either calls `IO80211WorkQueue::workQueue()` or obtains a queue through the bus-interface callback, stores it in Apple core private state at `+0x7898`, and in the latter branch invokes the returned object's virtual slot `+0x20`.

Stage157 resolves those exact bus-interface vtable entries, inspects the bus-interface workqueue callbacks and lifecycle methods, maps the `IO80211WorkQueue` vtable slot used by Apple's indirect call, and inspects queue allocation/initialization/teardown symbols. It also rechecks Apple core queue teardown references. This is intended to distinguish the shared default-queue path from the bus-supplied queue path and identify what remains unproven about ownership.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Stage156 report: `Development/Logs/stage156-apple-workqueue-implementation-20261106T213942Z.log`, Git blob SHA `3f0b188f672f2c290787dad2c701bd48a0becb63`.
- KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit
1. Verify Stage156 report and BootKC hashes.
2. Map `AppleBCMWLANBusInterface` vtable offsets `+0x860` and `+0x868` to exact symbols and fileset owners.
3. Disassemble bus-interface `needWorkQueue()`, `getWorkQueue()`, and relevant init/start/stop/free methods.
4. Map `IO80211WorkQueue` vtable slots `+0x20`, `+0x28`, `+0x88`, `+0x90`, and `+0xA0`; inspect factory and lifecycle implementations.
5. Recheck AppleBCMWLANCore workqueue create/get/free/stop paths and inventory queue-related symbols across the kernel collection.
6. Upload the report under `Development/Logs/` and verify its Git blob SHA.

## Safety and interpretation
Read-only static analysis only. No source, branch, index, or worktree changes; no build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. The vendor driver's private queue implementation is not treated as a public recipe. Do not implement a queue factory, borrowed queue, retain/release rule, or teardown path from this report alone; runtime/API ownership validation and explicit source-change authorization remain required.
