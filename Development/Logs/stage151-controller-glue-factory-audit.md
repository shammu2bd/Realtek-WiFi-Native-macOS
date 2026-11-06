# Stage151 — Controller glue factory dispatch audit

## Purpose
Stage150 identified the exact store of the controller's glue pointer: `IO80211Controller::start()` calls an indirect target through the controller-expansion object at vtable byte offset `+0xDC0`, then stores the returned pointer at expansion offset `+0xB08`. `IO80211Controller::postMessage()` later loads `+0xB08` and dispatches through the returned object's vtable at `+0x120`.

Stage151 resolves the `+0xDC0` slot against every discoverable BootKC vtable and audits the matching target, controller lifetime methods, and IO80211Glue initialization/free paths. This is needed to determine the exact Apple-owned glue factory and lifetime contract before considering any driver changes.

## Pinned inputs
- Target: macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Stage150 source report: `Development/Logs/stage150-controller-glue-lifecycle-20261106T212334Z.log`, Git blob SHA `617b4883a151bbf7ec6f82e30c63881faef98609`.
- KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`.
- KC reader Git blob SHA: `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit method
1. Verify the pinned Stage150 report and BootKC hashes.
2. Enumerate class vtables and inspect vtable byte offset `+0xDC0` (reader word index `2 + 0xDC0/8`).
3. Resolve candidate targets to exact symbols and Apple fileset owners, then disassemble those targets.
4. Inspect `IO80211Controller::start/stop/free/init` for the `+0xB08` lifecycle and inspect `IO80211Glue::initWithOptions/freeResources/stop`.
5. Upload the complete read-only report to `Development/Logs/` on `main`, then verify the Git blob SHA.

## Safety and scope
Read-only audit only. The runner does not change source, branches, index, or working tree and does not build, sign, install, load/unload, activate hardware, alter OpenCore/EFI/SIP/NVRAM, or reboot. It records the current branch, HEAD, and worktree-status count so local changes remain visible and untouched.

A matching static vtable target is ABI evidence, not proof of a runtime pointer value or object instance identity. Any unresolved or ambiguous vtable mapping must remain explicitly unresolved; do not infer a safe driver-side implementation from a near-match.
