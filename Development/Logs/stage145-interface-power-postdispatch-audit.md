# Stage145 — interface POWER post-dispatch audit

Read-only audit for macOS Sequoia 15.8.1 build 24H32 x86_64.

Stage143 shows the successful `apple80211setPOWER` path issuing a final virtual call through the interface object at byte offset `0xB10`. Stage144 resolved the controller callback slots `0xCD8` and `0xCE0` correctly, but its additional `0xB10` lookup was performed against `IO80211Controller`; that result (`IONetworkController` reserved slot 31) is not the interface post-dispatch target.

Stage145 corrects the receiver/class mapping. It resolves `0xB10` on both `IO80211SkywalkInterface` and `IO80211InfraInterface`, prints exact symbol and image ownership, and attempts bounded disassembly of the resolved interface target. It also reprints the local driver POWER callback implementations for source-level correlation. Controller slots `0xCD8` and `0xCE0` are retained only as context.

The runner pins the 24H32 BootKC SHA-256 and upstream KC reader Git blob SHA. It reads the current local checkout without changing its source files, index, branch, or working tree. It publishes only a timestamped report to `Development/Logs/` on `main`, then verifies the Git blob SHA.

No source edits, build, signing, install, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. Static ABI mapping only.
