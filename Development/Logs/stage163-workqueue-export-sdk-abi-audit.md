# Stage163 — IO80211WorkQueue factory export and SDK ABI audit

## Purpose
Stage162 confirmed the factory implementation exists inside the 24H32 IO80211Family fileset, but did not prove that a third-party kext can link to it. Stage163 checks symbol-table visibility for the factory, default-queue accessors, constructor and metaclass; records the factory implementation; inspects available Mach-O export metadata; and searches the selected macOS SDK headers for a public declaration.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Base checkout HEAD: `3d02ef10e353bb80d032980ffe2e7d28b90fd7da`.
- KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA: `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit operations
1. Verify target OS/build/architecture, BootKC hash, checkout HEAD and pinned KC reader.
2. Carve only `com.apple.iokit.IO80211Family` from BootKC.
3. Inspect `nm -m` and global-defined `nm -gU` entries for `IO80211WorkQueue::workQueue()`, default queue accessors, constructor and metaclass.
4. Record the factory/default accessor disassembly and available `LC_DYLD_EXPORTS_TRIE` / `LC_DYLD_INFO_ONLY` metadata. If `dyld_info` is unavailable, explicitly report that limitation.
5. Search the selected Xcode macOS SDK IOKit and Kernel headers for a public `IO80211WorkQueue` class/factory declaration.
6. Publish the full report to `Development/Logs/` and verify its Git blob SHA.

## Interpretation
A symbol present in the kernel collection or in an external symbol table is not, by itself, proof of a supported third-party kext API. Report symbol visibility facts separately from SDK declaration and final linkability. Do not declare the factory usable solely because it is present in BootKC. Do not infer queue ownership or PostOffice/timer-source lifetime from this stage.

## Safety
Read-only static audit only. No source, branch, index, or worktree changes; no compilation/build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. The only repository write is the timestamped audit report under `Development/Logs/`.
