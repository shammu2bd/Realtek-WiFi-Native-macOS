# Stage146 — Apple POWER message semantics audit

Read-only audit for macOS Sequoia 15.8.1 build 24H32 x86_64.

Stage143 showed that a successful Apple `apple80211setPOWER` controller callback is followed by a virtual interface call at byte offset `0xB10`. Stage145 identified that interface method as `IO80211SkywalkInterface::postMessage` and the Infra override `IO80211InfraInterface::postMessage`; the wrapper supplies message ID 1, a null data pointer, zero length, and a true final boolean argument.

Stage146 correlates the exact Apple get/set POWER helpers and the generic static `setPOWER` IOCTL wrapper (the caller that issues the `0xB10` call) with those message methods, inspects the Infra dispatcher's message-ID comparisons and relevant control flow, resolves `postMessageInternal`, and reports local driver source references to POWER data and postMessage. It is intended to clarify the post-success notification semantics and to prevent confusing this interface notification with controller POWER callback slots.

The runner pins the 24H32 BootKC SHA-256 and upstream KC reader Git blob SHA. It reads the existing local checkout without changing source files, branch, index, or working tree. It publishes only a timestamped report to `Development/Logs/` on `main`, then verifies the Git blob SHA.

No source edits, build, signing, install, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. Static ABI/source correlation only.
