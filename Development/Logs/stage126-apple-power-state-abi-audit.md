# Stage126 — Apple 24H32 power-state ABI audit

**Runner:** `Development/stage126-apple-power-state-abi-audit.sh` on `main`. Run the SHA-verified copy fetched from GitHub `main`; it does not switch branches or require a clean worktree.

**Scope:** read-only disassembly of exact Apple IO80211Family power-state methods on macOS 15.8.1 build 24H32 x86_64.

Stage125 found a potential mismatch: the native interface's `getPOWER` reads Apple's `isInterfaceEnabled()`, while the custom `enable()` / `disable()` path controls RTW88 radio and packet-path state. This stage gathers Apple method bodies before any source-level power-state decision.

## Why the previous disassembly attempt was rejected

The previous logs falsely marked output as verified even though Xcode 16.4's `llvm-objdump` rejected the Mach-O-only `--dis-symname` option. Replacing it with `--disassemble-symbols` did not establish isolated method bodies in the user's run. The resulting oversized disassembly pipeline also terminated with exit code 141 because `head` closed a pipe early under `pipefail`.

## Current method-isolation strategy

The runner now uses the exact symbol addresses from a numerically sorted `llvm-nm` listing. For each method it calculates a bounded address interval from the symbol's start up to the next global text symbol, capped at 0x600 bytes, and calls:

```sh
llvm-objdump --macho --disassemble --start-address=0xSTART --stop-address=0xEND <IO80211Family.macho>
```

The report marks a method verified only when the disassembler returns instruction addresses and every parsed instruction address lies inside that exact interval. An unsupported option, empty output, out-of-range address, missing symbol, or nonzero command exit is recorded as a failure, not as a pass. Output previews use `sed`, avoiding the SIGPIPE failure caused by `head` and `set -o pipefail`.

The uploader verifies the resulting Git blob SHA and retries transient GitHub API failures up to three times.

## Strict exclusions

No driver source changes, build, signing, install, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, security bypass, or reboot.

**Decision rule:** even a successful static disassembly does not itself authorize a power-state patch. The call graph and Apple's expected lifecycle order must be reviewed before proposing implementation changes.
