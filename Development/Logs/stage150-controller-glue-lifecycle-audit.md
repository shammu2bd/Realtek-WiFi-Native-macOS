# Stage150 — controller glue lifecycle audit

Read-only audit for macOS Sequoia 15.8.1 build 24H32 x86_64.

Stage149 resolved the Apple `IO80211Controller::postMessage` relay. It loads an expansion pointer from controller offset `0x120`, reads a receiver pointer at expansion offset `0xB08`, then dispatches through receiver vtable offset `0x120`. The `IO80211Glue` vtable resolves that slot to `CommonGlue::sendMessage(CommonGlueMessage&)`.

Stage150 enumerates Apple IO80211Controller and IO80211Glue lifecycle symbols in the pinned 24H32 BootKC, inspects the relevant vtable slots, and disassembles bounded controller/glue lifecycle methods for assignments, uses, and calls related to the glue receiver and expansion offsets. It records evidence and leaves pointer initialization unresolved when static symbols do not establish it.

The runner pins BootKC SHA-256 and the upstream KC reader Git blob SHA. It reads the existing local checkout without changing source files, branch, index, or working tree, and publishes only a timestamped report to `Development/Logs/` on `main`, verifying the Git blob SHA.

No source edits, build, signing, install, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. Static Apple lifecycle analysis only.
