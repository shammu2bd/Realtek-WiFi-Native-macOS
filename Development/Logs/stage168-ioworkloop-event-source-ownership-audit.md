# Stage168 — IOWorkLoop event-source attach/detach and ownership audit

## Purpose
Stage167 resolved the IO80211WorkQueue wrapper dispatch: its add/remove work-source methods route through the IOWorkLoop event-source slots. Stage166 showed that IO80211TimerSource stores the queue pointer and removes itself from the queue during free, while PostOffice frees its timer source but does not directly release the queue pointer. The missing question is what the kernel's IOWorkLoop and IOEventSource attach/detach implementations retain, release, or clear.

Stage168 inspects the exact 24H32 kernel methods and vtable slots that implement event-source attachment, detachment, work-loop association, timer-source cleanup, and OSObject retain/release.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Source checkout HEAD: `3d02ef10e353bb80d032980ffe2e7d28b90fd7da`.
- Stage165 report blob SHA: `97a0a664c5ed0f53bcf3f1204bd0c8f2b5a74277`.
- Stage166 report blob SHA: `7ad1c896b9d7ded57c40e0898a02c5c15ce1a28c`.
- Stage167 report blob SHA: `0af39ae31f8519131c8b1fe42cf1835def44e167`.
- Read-only KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit operations
1. Verify the exact OS/build/architecture, BootKC SHA, source HEAD, three prior report blob SHAs, and pinned read-only KC reader.
2. Carve only `com.apple.kernel` and `com.apple.iokit.IO80211Family` into temporary files.
3. Resolve the vtable entries used by Stage167's static `__ZTV10IOWorkLoop` and `__ZTV18IOTimerEventSource` dispatches, keeping symbol-base offsets distinct from object-vptr-relative offsets.
4. Disassemble `IOWorkLoop::addEventSource/removeEventSource`, `IOEventSource::setWorkLoop/free`, and IOWorkLoop lifecycle methods.
5. Inventory and inspect relevant `IOTimerEventSource`, `IO80211TimerSource`, `IO80211WorkQueue`, and `OSObject` init/free/timeout/retain/release methods available in this exact kernel.
6. Scan direct references in both carved fileset images. Absence of a direct reference is not treated as proof about indirect dispatch.
7. Reconfirm PostOffice/TimerSource queue handling and verify the local Git working-tree status fingerprint is unchanged.
8. Upload and verify a timestamped report under `Development/Logs/`.

## Interpretation rules
- Distinguish vtable-symbol-start offsets from object-vptr-relative offsets; a 16-byte Itanium ABI vtable prefix changes the apparent byte offset.
- Identify retain/release only for the object passed at the call site. A queue pointer, timer source, and event source are distinct objects.
- A field assignment or an indirect virtual call does not, by itself, prove ownership.
- Do not copy Apple's private expansion layouts or offsets into the driver.
- If the static disassembly does not resolve a specific retain/release edge, mark it unresolved rather than guessing.

## Safety boundary
Read-only static analysis of the target's existing BootKC and pinned GitHub evidence. Temporary carved images and reports are created under TMPDIR and removed on exit. No project source, build outputs, branch/index state, OpenCore/EFI/SIP/NVRAM/security settings are changed. No build, signing, install, load/unload, AuxKC staging, hardware test, or reboot is performed.
