# Stage130 — Apple 24H32 association-state method audit

**Runner:** `Development/stage130-apple-assoc-state-audit.sh` on `main`.

Stage129 resolved vtable byte offset `0xD58` to exact `getAssocState()` text symbols for both `IO80211InfraInterface` and `IO80211SkywalkInterface`. Stage126 showed that `IO80211InfraInterface::setInterfaceEnable(true)` invokes the slot before calling the Skywalk interface setter.

Stage130 disassembles four exact Apple methods from the same SHA-pinned Mach-O: both `getAssocState()` implementations, `IO80211InfraInterface::setInterfaceEnable(bool)`, and `IO80211SkywalkInterface::setInterfaceEnable(bool)`. It revalidates the Stage126 call-site address directly, then lists exact direct setter references from the complete symbolized dump.

Read-only only. No driver source changes, build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, security bypass, or reboot.
