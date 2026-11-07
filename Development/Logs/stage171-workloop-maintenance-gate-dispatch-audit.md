# Stage171 — WorkLoop maintenance callback and CommandGate dispatch audit

## Purpose
Stage170 established that IOWorkLoop::init creates an internal IOCommandGate, associates it with the loop, and adds it to the event-source list. The add/remove wrappers dispatch through that gate; the actual gated maintenance callback and its chain mutations were not decoded. Stage170 also showed CommandGate and CommandPool lifecycle functions, but could not attribute the indirect vtable calls to their exact targets.

Stage171 resolves the WorkLoop maintenance callback, WorkLoop gated action path, CommandGate run/attempt paths, CommandPool callbacks, and the exact object-vptr targets used by these methods.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Source checkout HEAD: `3d02ef10e353bb80d032980ffe2e7d28b90fd7da`.
- Stage165 report blob SHA: `97a0a664c5ed0f53bcf3f1204bd0c8f2b5a74277`.
- Stage166 report blob SHA: `7ad1c896b9d7ded57c40e0898a02c5c15ce1a28c`.
- Stage167 report blob SHA: `0af39ae31f8519131c8b1fe42cf1835def44e167`.
- Stage168 report blob SHA: `976cdc2bc96f69706c9257d07bc99f3ae4fd801e`.
- Stage169 report blob SHA: `65916918e0d1fad4547b2fed8560a9c0b0966a32`.
- Stage170 report blob SHA: `8759f897a49144478bd3d9a3879fb4314394e401`.
- Read-only KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit operations
1. Verify the exact target, BootKC SHA, source HEAD, preceding audit report SHAs, and pinned KC reader.
2. Carve only `com.apple.kernel` and `com.apple.iokit.IO80211Family` into temporary files.
3. Map the object-vptr entries of IOWorkLoop, IOCommandGate, IOCommandPool, IOEventSource, IOTimerEventSource and IO80211WorkQueue around all virtual offsets used by the disassembled methods.
4. Disassemble WorkLoop maintenance, gated action, add/remove/release-chain and gate methods.
5. Disassemble CommandGate run/attempt/init/free and CommandPool factory/init/free methods.
6. Inspect IO80211WorkQueue constructors/destructors and factory/default getter/setter methods.
7. Inventory relevant methods and scan direct references, keeping virtual-call resolution separate from direct xrefs.
8. Verify the Git worktree status fingerprint is unchanged and upload a timestamped report under `Development/Logs/`.

## Interpretation rules
- Associate each indirect vtable call with the object whose vptr is loaded at that call site.
- A list node link, work-loop pointer, owner pointer and retained OSObject reference are distinct relationships.
- Identify the precise argument passed to retain/release before assigning ownership meaning.
- Do not treat a vtable mapping or missing direct xref as proof that a callback is unused.
- Do not copy Apple private object layouts or offsets into the driver.
- Unresolved reference edges must remain explicitly unresolved.

## Safety boundary
Read-only static analysis of the pinned BootKC and GitHub evidence. Temporary carved files and reports are created under TMPDIR and removed on exit. No project source/build outputs, branch/index state, OpenCore/EFI/SIP/NVRAM/security settings are changed. No build, signing, installation, loading/unloading, AuxKC staging, hardware test or reboot is performed.
