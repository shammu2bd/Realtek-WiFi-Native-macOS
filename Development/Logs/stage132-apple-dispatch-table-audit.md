# Stage132 — Apple kernel-cache dispatch-table audit

**Runner:** `Development/stage132-apple-dispatch-table-audit.sh` on `main`.

Stage131 found that the Apple Skywalk `enable(uint32_t)` method calls through a table at byte offset `0x860`, while `disable(uint32_t)` tail-calls through offset `0x868`. Both load the same encoded global pointer from `0xffffff80023bc108`.

Apple's chained-fixup definition for `DYLD_CHAINED_PTR_X86_64_KERNEL_CACHE`/`DYLD_CHAINED_PTR_64_KERNEL_CACHE` stores a 30-bit target, 2-bit cache level, authentication metadata, and a chain-next field. XNU's fixup code resolves it as `basePointers[cacheLevel] + target`. The matching official sources are cited in the accompanying ChatGPT test report, and the runner validates the base against Stage129's two exact vtable-slot method symbols before using it.

Stage132 decodes the global GOT pointer, derives the table address, searches the extracted Stage53 kernel-cache run for the Mach-O image containing the table, reads the callback qwords at `+0x860` and `+0x868`, decodes them when the cache level is known, and matches their addresses against exact text symbols in the owning image.

Read-only only. No driver source changes, build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM modifications, security bypass, or reboot.
