# Stage133 — BootKernelExtensions dispatch-table owner and callback resolution

**Runner:** `Development/stage133-bootkc-dispatch-resolution-audit.sh` on `main`.

Stage132 decoded the global pointer to `0xffffff80029b1168`, but the separately extracted `.macho` files did not include the image containing that table. Stage53 previously parsed the complete `/System/Library/KernelCollections/BootKernelExtensions.kc` using a pinned, read-only fileset reader.

Stage133 reuses that exact upstream parser, verifies its Git blob SHA, parses the full BootKernelExtensions collection, confirms the Stage129 vtable entries, resolves the GOT pointer using the collection base, locates the fileset owner of the table and resolves callback slots `+0x860` and `+0x868` against exact symbols from the full collection symbol index. It does not treat a nearest-symbol match as proof.

Upstream reader: `watchthelight-labs/WTLKcAbi` commit `cea28a5297633118177cee6a75e86d8bc57f1960`, `kcfile.py` Git blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

Read-only only. No driver source modifications, build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, security bypass, or reboot.
