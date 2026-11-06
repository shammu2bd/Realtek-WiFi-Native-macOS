# Stage127 — Apple 24H32 power call graph and vtable audit

**Runner:** `Development/stage127-apple-power-callgraph-audit.sh` on `main`.

**Purpose:** Continue Stage126's read-only investigation of `IO80211InfraInterface::setInterfaceEnable(bool)`. Stage126 confirmed that the enable path calls an indirect method at vtable byte offset `0xD58` and then calls `IO80211SkywalkInterface::setInterfaceEnable(bool)`.

## What this stage gathers

1. Direct, symbolized call sites for the infrastructure setter and Skywalk setter in the pinned Apple IO80211Family Mach-O.
2. Vtable symbols for `IO80211InfraInterface` and `IO80211SkywalkInterface`.
3. The raw pointer stored at byte offset `0xD58`, using the Itanium ABI vtable address point (vtable symbol plus two 8-byte header entries), and a raw-symbol-offset comparison.
4. The nearest symbol-table text name for each readable pointer. A nearest-symbol match alone does not prove the dynamic object's concrete class.
5. Power-related controller/interface entry points for later review.

The runner pins the same Apple Mach-O SHA-256 as Stage126: `8e95c4ec87ed99e3732354f32ad9eed45b7607e7bc7034f32ff7437e0c6ec878`.

## How to run

Fetch `Development/stage127-apple-power-callgraph-audit.sh` directly from GitHub `main`, verify its Git blob SHA, then run it from the existing Stage121/Stage125 project checkout. The runner does not switch branches, reset or clean the worktree, or modify staged changes.

The report is uploaded to `Development/Logs/` on `main`. If GitHub times out after accepting an upload, the runner checks the exact report path and blob SHA before retrying.

## Interpretation limits

- An absent direct call reference does not prove that no caller exists; a caller may dispatch through a vtable or another indirect path.
- The `0xD58` slot is interpreted from the Itanium ABI address point and reported beside the unadjusted symbol-relative value for comparison.
- A readable function pointer and nearest `nm` symbol are evidence for review, not a complete dynamic dispatch proof.
- Do not patch the driver's `enable()`/`disable()` path based solely on this report. Review the exact vtable owner, target, call order, and failure behavior first.

## Excluded operations

Read-only inspection only. No source edits, build, signing, installation, load/unload, hardware activation, security bypass, OpenCore/EFI/SIP/NVRAM changes, or reboot.
