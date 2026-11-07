# Stage167 — WorkQueue global dispatch and PostOffice cross-reference audit

## Purpose
Stage166 mapped TimerSource deregistration to the WorkQueue/IOWorkLoop vtable and found that the controller's PostOffice field is stored once and read by message paths, but did not resolve the indirect global dispatches in WorkQueue add/remove or the full set of PostOffice factory/release callers.

Stage167 targets those unresolved dispatches and references using the pinned macOS 15.8.1 build 24H32 BootKC.

## Pinned inputs
- Source HEAD: 3d02ef10e353bb80d032980ffe2e7d28b90fd7da.
- Target: macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3.
- Stage165 report blob SHA: 97a0a664c5ed0f53bcf3f1204bd0c8f2b5a74277.
- Stage166 report blob SHA: 7ad1c896b9d7ded57c40e0898a02c5c15ce1a28c.
- KC reader commit: cea28a5297633118177cee6a75e86d8bc57f1960; blob SHA 5d31e8a73e5cb175851e7407529456f223683589.

## Audit operations
1. Verify target, BootKC, prior reports, source HEAD and the pinned read-only KC reader.
2. Carve IO80211Family and kernel fileset entries only into temporary storage.
3. Inspect IO80211WorkQueue add/remove, IO80211TimerSource init/free, factory/default getter/setter, PostOffice alloc/init/free and controller start/stop/free methods.
4. Resolve RIP-relative global references in WorkQueue and TimerSource methods, read pointer values from the target BootKC, and map object vptrs/vtable slots where possible.
5. Resolve the helper called while adding/removing IO80211WorkSource objects.
6. Scan full IO80211Family text for direct references to factory/default setter/getter, PostOffice alloc/free and controller getPostOffice.
7. Verify the Git working-tree status fingerprint remains unchanged and upload a timestamped report under Development/Logs/.

## Interpretation rules
- RIP-relative pointer reads and indirect targets must be recorded with the exact address and owner; do not assume an object owns a pointer merely because a field contains it.
- Vtable slot offsets are relative to the object vptr address point, not the start of the compiler-emitted vtable prefix.
- A direct retain or release on one object does not establish ownership of another object passed nearby.
- If symbol xrefs or a virtual call target cannot be recovered from the selected fileset symbol tables, report the ambiguity.
- Do not copy any private Apple class layout or expansion offsets into the driver.

## Safety
Read-only static analysis. Temporary carved files and report are created under TMPDIR and removed on exit. No project source/build artifact, worktree, branch/index, OpenCore/EFI/SIP/NVRAM/security settings are changed. No build, signing, install, load/unload, AuxKC staging, hardware test or reboot is performed.
