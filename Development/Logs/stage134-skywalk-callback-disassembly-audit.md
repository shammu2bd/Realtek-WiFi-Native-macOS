# Stage134 — Apple Skywalk enable/disable callback disassembly

**Runner:** `Development/stage134-skywalk-callback-disassembly-audit.sh` on `main`.

Stage133 resolved the shared dispatch table to `com.apple.iokit.IOSkywalkFamily` and identified the exact callback methods:

- Enable slot `+0x860`: `IOSkywalkEthernetInterface::enable(unsigned int)`.
- Disable slot `+0x868`: `IOSkywalkNetworkInterface::disable(unsigned int)`.

Stage134 uses the full BootKernelExtensions fileset reader to verify callback owner and executable segment, list related enable/disable methods in the owning classes, carve only the owning `IOSkywalkFamily` fileset image to temporary storage, and disassemble the two exact method bodies. It preserves each call and tail-call instruction for control-flow review.

BootKC SHA-256 pin: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`. Upstream reader: `watchthelight-labs/WTLKcAbi@cea28a5297633118177cee6a75e86d8bc57f1960`, `kcfile.py` blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

Read-only only. No driver source changes, build, signing, installation, load/unload, hardware activation, security bypass, OpenCore/EFI/SIP/NVRAM modifications, or reboot.
