# Stage126 — Apple 24H32 power-state ABI audit

**Runner:** `Development/stage126-apple-power-state-abi-audit.sh` on `main`. Fetch the SHA-verified runner directly from GitHub `main`; it does not switch branches or require a clean worktree.

**Scope:** read-only disassembly of the exact Apple IO80211Family power-state methods on macOS 15.8.1 build 24H32 x86_64.

Stage125 found a possible mismatch: the native interface's `getPOWER` reads Apple's `isInterfaceEnabled()`, while the custom `enable()` / `disable()` path controls RTW88 radio and packet-path state. This audit gathers Apple's method bodies before any driver source change.

## Prior attempts rejected

1. The initial runner used `--dis-symname`; Xcode 16.4's bundled `llvm-objdump` rejected that option.
2. Switching to `--disassemble-symbols` did not isolate the requested Mach-O methods and the trace ended with exit 141 after an early-closing `head` pipeline.
3. An address-bounded `llvm-objdump --start-address/--stop-address` attempt was also rejected: the user's installed Mach-O disassembler emitted the generic `__start` prelude instead of honoring the target range. The audit correctly marked all eight methods incomplete.

## Current method-isolation strategy

The runner now uses macOS `otool` with its documented symbol-start option:

```sh
otool -arch x86_64 -tvV -p <first-target-symbol> <IO80211Family.macho>
```

The first target symbol is selected by numeric address from the exact `llvm-nm` entries. The resulting disassembly is captured once into a temporary file; Python then selects instruction lines only inside each requested method's exact nm-derived address interval. The interval ends at the next global text symbol, capped at 0x600 bytes.

A method is marked verified only if the disassembly contains instructions beginning exactly at that method's nm address and within the calculated interval. Missing symbols, missing instructions, a disassembler failure, or a start-address mismatch remain unverified. No method is marked passed merely because a tool exited with status zero.

The report is uploaded to `main/Development/Logs/`, and its Git blob SHA is checked. If an upload request times out, the runner checks the exact destination before retrying, avoiding an accidental duplicate write after a successful-but-delayed server response.

## Strict exclusions

No driver source changes, build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, security bypass, or reboot.

**Decision rule:** static disassembly alone does not authorize a power-state patch. The method bodies and call order must be reviewed before proposing source changes.
