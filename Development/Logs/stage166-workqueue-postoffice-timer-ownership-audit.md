# Stage166 — workqueue, PostOffice and TimerSource lifetime/ownership audit

## Purpose
Stage165 proved that the 24H32 kmutil libraries resolver reports IO80211WorkQueue::workQueue() from com.apple.iokit.IO80211Family for a temporary x86_64 KEXT. That resolves symbol-provider discovery only. It does not settle which object owns the returned queue or how its event sources must be detached.

Stage162 showed that IO80211PostOffice::initWithParams(queue) saves the queue pointer in its private expansion and creates an IO80211TimerSource with the same queue. TimerSource init/free issue indirect virtual calls through the queue. Stage166 decodes those exact virtual slots from the 24H32 vtable, inspects the add/remove work-source implementations, traces PostOffice and controller entry points, and narrows controller expansion +0xB08 references to actual memory operands.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3.
- Source checkout HEAD: 3d02ef10e353bb80d032980ffe2e7d28b90fd7da.
- Stage165 report: Development/Logs/stage165-kmutil-repository-bundle-discovery-20261107T061052Z.log, Git blob SHA 97a0a664c5ed0f53bcf3f1204bd0c8f2b5a74277.
- Read-only KC reader commit: cea28a5297633118177cee6a75e86d8bc57f1960, blob SHA 5d31e8a73e5cb175851e7407529456f223683589.

## Audit operations
1. Verify the exact OS/build/architecture, BootKC SHA, source HEAD, Stage165 report blob SHA and pinned KC reader blob SHA.
2. Carve only the com.apple.iokit.IO80211Family and com.apple.kernel fileset entries to temporary files.
3. Decode the IO80211WorkQueue vtable, mapping raw vtable indices to object-vptr byte offsets and resolving byte offsets 0x148 and 0x150.
4. Inspect IO80211WorkQueue::addWorkSource/removeWorkSource, IO80211TimerSource::init/free, IO80211PostOffice::initWithParams/free, IO80211Controller::CreatePostOffice/getPostOffice/createWorkQueue/getWorkQueue/stop/free, and IOEventSource::setWorkLoop/free.
5. Inventory related IO80211WorkQueue, IO80211TimerSource, IO80211PostOffice, IOEventSource and IOWorkLoop symbols.
6. Scan for exact 0xB08 memory operands only within IO80211Controller methods, rather than treating arbitrary hex literals as field xrefs.
7. Verify the worktree status fingerprint is unchanged and upload/verify a timestamped report under Development/Logs/.

## Interpretation rules
- A vtable slot name can identify which method TimerSource calls, but does not alone prove retain/release semantics.
- A field assignment of a queue pointer does not prove ownership.
- An explicit retain/release call is evidence only for the object passed at that call site; indirect dispatch and destructor behavior must be interpreted from the code.
- If controller PostOffice release is not found, record it as unresolved. Do not assume controller free releases PostOffice merely because it frees an expansion allocation.
- No private Apple expansion offsets/layouts may be copied into the driver.

## Safety boundary
Read-only static analysis of the target's existing BootKC and GitHub evidence. The runner creates and removes temporary carved images and a temporary report. It does not modify source, project build outputs, branch/index state, OpenCore/EFI/SIP/NVRAM/security settings; it does not build, sign, install, load/unload, stage an AuxKC, run a hardware test, or reboot.
