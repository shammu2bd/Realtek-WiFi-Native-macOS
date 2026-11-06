# Stage156 — AppleBCMWLANCore work-queue implementation audit

## Purpose
Stage155 found that AppleBCMWLANCore overrides `IO80211Controller::createWorkQueue()` and `getWorkQueue()` in the separate `com.apple.driver.AppleBCMWLANCoreMac` fileset. Stage155 did not disassemble those methods because its focused method carve was limited to IO80211Family.

Stage156 carves the actual AppleBCMWLANCore fileset and inspects both overrides, the class vtable and size, relevant constructor/init/start/stop/free methods, all workqueue-related symbols in that bundle, and the IO80211Family base/factory methods. It aims to establish the private implementation's static allocation, member storage, and release pattern. It does not treat the vendor driver's private pattern as a public API or a directly reusable recipe.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Stage155 report: `Development/Logs/stage155-workqueue-abi-20261106T213725Z.log`, Git blob SHA `558c1444ddc90924ef06dcf134fa48eaeb79b20e`.
- KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit
1. Verify Stage155 report and BootKC hashes.
2. Confirm AppleBCMWLANCore vtable targets and fileset owner.
3. Disassemble both workqueue overrides and the class lifecycle methods.
4. Inventory all workqueue-related symbols in the AppleBCMWLANCore bundle.
5. Recheck IO80211Family base methods and workqueue factory.
6. Upload the full report to `Development/Logs/` and verify its Git blob SHA.

## Safety
Read-only static analysis only. No source, branch, index, or worktree changes; no build, signing, install, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. Apple's private driver implementation may rely on private contracts; findings must not be used for driver changes until the allocation/ownership contract and all required lifecycle behavior are independently established.
