# Stage131 — Apple 24H32 Skywalk enable/disable dispatch audit

**Runner:** `Development/stage131-apple-skywalk-enable-dispatch-audit.sh` on `main`.

Stage130 verified the Apple state getters and setters. In particular, `IO80211SkywalkInterface::setInterfaceEnable(bool)` writes the enabled byte at expansion-data offset `0x71`, may notify `IO80211MacAddressAgent`, and may create IOReporters. The infrastructure setter invokes `getAssocState()` on its enable path and then invokes the Skywalk setter.

Stage131 inspects the separate `IO80211SkywalkInterface::enable(uint32_t)` and `disable(uint32_t)` entry points, plus datapath no-op methods, state getters/setters, and the Apple MAC-address agent setter. It calculates the RIP-relative global referenced by enable/disable and reports its symbol/section and raw backing qword where possible. It does not assume that those dispatch paths are the same as the enabled-byte setter.

The report will be uploaded to `Development/Logs/` on `main`. The source Mach-O is pinned to SHA-256 `8e95c4ec87ed99e3732354f32ad9eed45b7607e7bc7034f32ff7437e0c6ec878`.

Read-only only. No driver source modification, build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, security bypass, or reboot.
