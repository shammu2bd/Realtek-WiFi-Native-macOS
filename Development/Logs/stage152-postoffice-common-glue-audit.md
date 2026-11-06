# Stage152 — IO80211PostOffice and CommonGlue interface audit

## Purpose
Stage151 mapped the controller's expansion vtable slot `+0xDC0` to `IO80211Controller::CreatePostOffice()`. That factory calls `IO80211PostOffice::allocWithParams(IO80211WorkQueue*)`. The returned pointer is stored by `IO80211Controller::start()` at expansion offset `+0xB08`, and the controller's `postMessage()` relay dispatches through object vtable byte offset `+0x120`.

Stage152 checks whether `IO80211PostOffice` exposes the same `+0x120` message interface as `CommonGlue::sendMessage()`, inventories its allocation/initialization/lifetime methods, and compares its vtable against `CommonGlue` and `IO80211Glue`. It does not assume that matching slots prove runtime object identity.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Stage151 report: `Development/Logs/stage151-controller-glue-factory-20261106T212809Z.log`, Git blob SHA `d53e563dabadc21ce48b0c2147611f1bc2ab616c`.
- KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit
1. Verify Stage151 report and BootKC hashes.
2. Locate PostOffice classes, sizes, vtables, allocation and lifetime methods.
3. Compare PostOffice vtable slots `+0x120/+0x128` to CommonGlue and IO80211Glue.
4. Disassemble the exact factory and relay methods.
5. Upload the full read-only report to `Development/Logs/` and verify the Git blob SHA.

## Safety
Read-only. No source, branch, index, or working-tree changes; no build/sign/install/load/unload/hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. The audit records the pre-existing worktree status count and leaves all local changes untouched. Static ABI mapping alone does not prove a runtime pointer's class or object identity.
