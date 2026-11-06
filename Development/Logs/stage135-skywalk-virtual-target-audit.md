# Stage135 — Apple Skywalk virtual target resolution

## Purpose
Resolve and disassemble the four exact virtual-call destinations observed in Stage134. This is a read-only analysis of the pinned macOS 15.8.1 (24H32) BootKernelExtensions collection.

## Stage134 call sites and requested slots
- `IOSkywalkEthernetInterface::enable(unsigned int)` calls the receiver's vtable at address-point offset `0x8F8`, then calls the `IOSkywalkNetworkInterface` vtable at `0x860`, and conditionally calls the Ethernet-interface vtable at `0xA90`.
- `IOSkywalkNetworkInterface::disable(unsigned int)` calls the receiver's vtable at `0x928`.

The runner converts address-point offsets to the KC reader's vtable index by including the two-qword vtable header (`(0x10 + offset) / 8`). It requires an exact symbol, an owning fileset entry, and an executable segment before disassembling a target. It prints exact-start-bounded method bodies only.

## Pinned inputs
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`
- Reader: `watchthelight-labs/WTLKcAbi@cea28a5297633118177cee6a75e86d8bc57f1960`
- Reader Git blob SHA: `5d31e8a73e5cb175851e7407529456f223683589`

## Execution
Run the published `Development/stage135-skywalk-virtual-target-audit.sh` from the existing checkout. It uploads the timestamped report to `Development/Logs/` on `main` and verifies the uploaded Git blob SHA.

## Safety boundary
Read-only BootKC parsing and temporary files only. No driver source changes, build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot.
