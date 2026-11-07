# Stage169 — event-source dispatch and reference-edge audit

## Purpose
Stage168 confirmed that the IO80211WorkQueue wrapper dispatches into IOWorkLoop event-source methods. It also captured kernel code for IOWorkLoop attachment/detachment, IOEventSource work-loop association, and timer source cleanup. However, several important calls are indirect vtable dispatches, and the report does not yet establish the ownership effects for the work-loop pointer versus the event-source pointer.

Stage169 maps the class vtables around the exact offsets used by Stage168 and inspects IOWorkLoop initialization/cleanup, IOEventSource association, IOTimerEventSource association and timeout cleanup, IOCommandPool/IOCommandGate lifecycle, and OSObject retain/release paths.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Source checkout HEAD: `3d02ef10e353bb80d032980ffe2e7d28b90fd7da`.
- Stage165 report blob SHA: `97a0a664c5ed0f53bcf3f1204bd0c8f2b5a74277`.
- Stage166 report blob SHA: `7ad1c896b9d7ded57c40e0898a02c5c15ce1a28c`.
- Stage167 report blob SHA: `0af39ae31f8519131c8b1fe42cf1835def44e167`.
- Stage168 report blob SHA: `976cdc2bc96f69706c9257d07bc99f3ae4fd801e`.
- Read-only KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit operations
1. Verify the exact target, BootKC SHA, source HEAD, prior report blob SHAs, and pinned read-only KC reader.
2. Carve only `com.apple.kernel` and `com.apple.iokit.IO80211Family` into temporary files.
3. Map IOWorkLoop, IOEventSource, IOTimerEventSource, IOCommandPool, IOCommandGate, IO80211TimerSource, and IO80211WorkQueue vtable entries around the offsets observed in Stage168.
4. Inspect IOWorkLoop init/free/add/remove/releaseEventChain, IOEventSource init/setWorkLoop/getWorkLoop/free, IOTimerEventSource init/setWorkLoop/free/cancel/timeout paths, and relevant command-pool/gate and OSObject retain/release methods.
5. Inventory alternate lifecycle symbols and report direct references to the relevant methods.
6. Preserve the local Git status fingerprint and upload/verify a timestamped report under `Development/Logs/`.

## Interpretation rules
- A vtable slot mapping is a candidate dispatch target; associate it with an actual object only when the caller's object construction/field path supports that identity.
- Keep the two ownership directions separate: a work-loop reference held by an event source is not the same as an event-source reference held by a work loop.
- A direct `retain` or `release` acts on the object passed at that call site. Do not transfer its meaning to adjacent arguments or containing objects.
- If indirect calls or lifecycle edges remain unresolved, record the uncertainty.
- Do not copy private Apple layouts or offsets into the driver.

## Safety boundary
Read-only static analysis of the target BootKC and pinned GitHub evidence. Temporary carved files and report are created under TMPDIR and removed on exit. No project source/build outputs, branch/index state, OpenCore/EFI/SIP/NVRAM/security settings are changed. No build, signing, install, load/unload, AuxKC staging, hardware test, or reboot is performed.
