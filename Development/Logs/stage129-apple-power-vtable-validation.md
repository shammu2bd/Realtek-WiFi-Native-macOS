# Stage129 — Apple 24H32 vtable pointer and full call-site validation

**Runner:** `Development/stage129-apple-power-vtable-validation.sh` on `main`.

Stage128 produced kernel-cache qwords whose low 30 bits resemble Mach-O file offsets. This is a testable hypothesis, not yet an accepted decoding. Stage126 also contains a known direct call at `0xffffff80022dc483` to `IO80211SkywalkInterface::setInterfaceEnable(bool)` at `0xffffff8002265a04`; Stage128's zero-call result did not find it.

Stage129 therefore validates a specific mapping: take the low 30-bit qword value, subtract the `__TEXT` segment's file offset, then add its VM address. The result is compared with exact text symbols and the `__TEXT` VM range. This is considered validated only when an exact text-symbol start is found; no arbitrary mask or nearest-symbol result is accepted as proof.

The runner also performs a full `otool -tvV` symbolized text disassembly, explicitly checks the Stage126 known call-site, and scans direct calls to the two setters. It pins the Apple Mach-O SHA-256 to `8e95c4ec87ed99e3732354f32ad9eed45b7607e7bc7034f32ff7437e0c6ec878`.

Read-only only: no source edits, build, signing, installation, load/unload, hardware activation, security bypass, OpenCore/EFI/SIP/NVRAM changes, or reboot.
