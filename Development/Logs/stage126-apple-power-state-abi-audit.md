# Stage126 — Apple 24H32 power-state ABI audit

**Scope:** read-only disassembly of Apple IO80211Family power-state methods on macOS 15.8.1 build 24H32 x86_64.

Stage125 found that the native controller reports power through `isInterfaceEnabled()`, while the custom interface's `enable()` / `disable()` methods manipulate RTW88 radio and packet-path state. The ABI shim declares `setInterfaceEnable(bool)`. This stage collects target-kernel disassembly so the call/state semantics can be reviewed before any source change.

The Stage120 extracted Apple IO80211Family Mach-O is reused if present. Otherwise set `STAGE126_KC_MACHO` to its exact path. The report records its SHA-256.

**Strict exclusions:** no driver source changes, build, signing, install, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, security bypass, or reboot.

**Decision rule:** a missing symbol or incomplete disassembly is `NOT_PROVEN`; no guessed power-state patch is permitted. Stage126 does not itself change readiness status or authorize runtime activation.
