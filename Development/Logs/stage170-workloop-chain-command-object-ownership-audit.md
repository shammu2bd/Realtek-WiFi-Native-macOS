# Stage170 — WorkLoop chain and command-object ownership audit

## Purpose
Stage169 showed that IOWorkLoop::releaseEventChain walks the event-source chain, clears associations, disables each event source, and releases it. The add path still needs a call-site-level audit to explain where that reference is acquired. The WorkLoop constructor also creates an IOCommandGate, attaches it to the loop and registers it as an event source. IOCommandPool lifecycle methods were identified but not decoded.

Stage170 audits those exact paths, plus the IO80211WorkQueue factory's virtual initialization and inherited cleanup slots, against macOS 15.8.1 build 24H32.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Source checkout HEAD: `3d02ef10e353bb80d032980ffe2e7d28b90fd7da`.
- Stage165 report blob SHA: `97a0a664c5ed0f53bcf3f1204bd0c8f2b5a74277`.
- Stage166 report blob SHA: `7ad1c896b9d7ded57c40e0898a02c5c15ce1a28c`.
- Stage167 report blob SHA: `0af39ae31f8519131c8b1fe42cf1835def44e167`.
- Stage168 report blob SHA: `976cdc2bc96f69706c9257d07bc99f3ae4fd801e`.
- Stage169 report blob SHA: `65916918e0d1fad4547b2fed8560a9c0b0966a32`.
- Read-only KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit operations
1. Verify the pinned OS/build/architecture, BootKC SHA, source HEAD, all preceding audit report SHAs and the read-only KC reader.
2. Carve only `com.apple.kernel` and `com.apple.iokit.IO80211Family` into temporary files.
3. Map IOWorkLoop, IO80211WorkQueue, IOEventSource, IOCommandGate and IOCommandPool vtable entries around retain/release, init/free, chain and gate dispatch offsets.
4. Disassemble WorkLoop init/free/add/remove/releaseEventChain, EventSource link/enable/disable, CommandGate init/setWorkLoop/free, CommandPool init/free and IO80211WorkQueue factory/default getter/setter.
5. Inventory exact method symbols for those classes so overloads and inherited methods are visible.
6. Map the IO80211WorkQueue factory's virtual init dispatch and its relevant inherited lifecycle slots.
7. Scan direct call references to the lifecycle functions and verify the project worktree status fingerprint is unchanged.
8. Upload and verify a timestamped report under `Development/Logs/`.

## Interpretation rules
- The event-source chain's release operation concerns the event-source object passed through that chain; do not assume it retains or releases the containing WorkLoop.
- A work-loop pointer stored in an event source is a separate relationship and must be evaluated independently from chain membership.
- Map vtable offsets relative to the actual object vptr address point; do not confuse symbol-base offsets with object-vptr offsets.
- Treat vtable mappings as targets, not ownership conclusions, until the caller's object identity and passed argument are established.
- Do not copy private Apple expansion layouts or offsets into the driver.
- Any ownership edge not proved by the call sequence must remain unresolved.

## Safety boundary
Read-only static analysis of the pinned target BootKC and GitHub evidence. Temporary carved images and report files are created under TMPDIR and removed on exit. No project source/build outputs, branch/index state, OpenCore/EFI/SIP/NVRAM/security settings are changed. No build, signing, installation, loading/unloading, AuxKC staging, hardware test or reboot is performed.
