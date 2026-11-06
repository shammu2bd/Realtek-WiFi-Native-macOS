# Stage160 — PostOffice and controller workqueue ownership audit

## Purpose
Stage159 statically correlated the PCIe bus queue lifetime: PCIe bus start creates an `IO80211WorkQueue`, stores it in private bus expansion field `+0xDD0`, returns it through `getWorkQueue()`, and releases/clears that field in `freeResources()`. Apple core's controller workqueue callback obtains the bus queue and retains it. `IO80211Controller::CreatePostOffice()` obtains the controller's `getWorkQueue()` result and calls `IO80211PostOffice::allocWithParams()`.

Stage160 inspects the next ownership layer: PostOffice allocation, initialization, storage of the workqueue, timer creation, PostOffice destruction, controller expansion storage/free, and Apple core's private retained queue cleanup. This should establish the release chain or clearly mark remaining gaps before any driver implementation proposal.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Stage159 report: `Development/Logs/stage159-apple-pcie-workqueue-lifecycle-20261106T214754Z.log`, Git blob SHA `58469c3e1e1b06c3b6f06a072f6278b044650196`.
- KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit
1. Verify Stage159 report and BootKC hashes.
2. Inventory PostOffice and controller class methods and vtable slots.
3. Disassemble PostOffice allocation/init/free/message paths; identify whether it retains or otherwise owns the supplied queue and how its timer source lifecycle is handled.
4. Disassemble controller start/free and identify its PostOffice pointer storage/release.
5. Disassemble Apple core queue creation/free/freeResources and search for the retained queue field `+0x7898) cleanup.
6. Reconfirm the IO80211WorkQueue factory and report any gaps in the reference-count chain.
7. Upload report under `Development/Logs/` and verify Git blob SHA.

## Safety and interpretation
Read-only static analysis only. No source, branch, index, or worktree changes; no build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. This does not authorize copying Apple's private object layouts or refcounting assumptions. Driver changes require explicit authorization and a fully supported public/header ABI ownership design.
