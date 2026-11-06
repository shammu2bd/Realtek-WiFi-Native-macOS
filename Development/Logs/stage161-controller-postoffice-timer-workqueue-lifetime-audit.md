# Stage161 — Controller, PostOffice and timer-source workqueue lifetime audit

## Purpose
Stage160 found that `IO80211PostOffice::initWithParams(IO80211WorkQueue*)` allocates private ivars, stores the supplied queue pointer in those ivars, and creates an `IO80211TimerSource` using the same queue. The PostOffice's `free()` releases its timer source and frees its ivars; it does not visibly release the stored workqueue pointer in that function. Apple core separately releases its retained bus queue reference at private field `+0x7898` in `freeResources()`.

Stage161 completes the adjacent lifetime paths by checking `IO80211Controller::stop()` and `free()` for the PostOffice field `+0xB08`, and checking the timer source allocator/init/free methods to determine how the queue pointer is used or retained. It also confirms PostOffice's own field and cleanup sequence. This is necessary to tell whether PostOffice borrows the controller queue, whether the timer source takes its own reference, and when controller teardown destroys the PostOffice.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Stage160 report: `Development/Logs/stage160-postoffice-controller-workqueue-ownership-20261106T214941Z.log`, Git blob SHA `9d352ed3378320bb666df884f36bbc8c4ed2bce7`.
- KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit
1. Verify Stage160 report and BootKC hashes.
2. Inspect controller start/stop/free/getPostOffice methods for creation, storage, use and release of `+0xB08).
3. Inspect IO80211TimerSource allocation/init/free and queue fields for any queue retain/release behavior.
4. Confirm PostOffice init/free behavior and whether the stored queue is only a borrowed pointer.
5. Reconfirm Apple core's queue retain/release at `+0x7898`.
6. Upload the report to `Development/Logs/` and verify its Git blob SHA.

## Safety and interpretation
Read-only static analysis only. No source, branch, index, or worktree changes; no build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. Static disassembly cannot establish all runtime ownership semantics if an allocator delegates to opaque code. Do not implement queue retain/release or teardown based on a partial call graph. Explicit source-change authorization remains necessary.
