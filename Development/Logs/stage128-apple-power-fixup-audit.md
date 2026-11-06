# Stage128 — Apple 24H32 power call-site and vtable-fixup audit

**Runner:** `Development/stage128-apple-power-fixup-audit.sh` on `main`.

Stage127 reported no direct setter callers from its selected-symbol disassembly and produced raw vtable qwords that are not ordinary canonical x86_64 kernel addresses. Stage128 therefore expands the caller search to the entire Apple IO80211Family text and investigates kernel-cache fixup metadata before accepting any pointer decoding.

## Scope

- Disassemble the complete pinned Apple IO80211Family text and search direct call instructions for the infrastructure and Skywalk setters.
- Match only the exact class vtable symbols `__ZTV23IO80211SkywalkInterface` and `__ZTV21IO80211InfraInterface`, excluding MetaClass vtables.
- Inspect the Itanium address point (`vtable symbol + 0x10`) plus `0xD58`.
- Record raw qwords, load commands, optional `dyld_info -fixups` output, and relocation output.
- Compare low-bit pointer candidates with the image text segment and symbol table, but do not label a candidate as a verified method address until the kernel-cache fixup format is established.

Exact Apple Mach-O SHA-256 pin: `8e95c4ec87ed99e3732354f32ad9eed45b7607e7bc7034f32ff7437e0c6ec878`.

## Safety

Read-only inspection only. No driver source edits, build, signing, installation, load/unload, hardware activation, security bypass, OpenCore/EFI/SIP/NVRAM modifications, or reboot. Do not implement power-state changes based on unverified pointer candidates or incomplete caller results.
