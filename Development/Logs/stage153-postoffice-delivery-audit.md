# Stage153 — PostOffice delivery and controller ownership audit

## Purpose
Stage152 established that the controller's `+0xB08` object is an `IO80211PostOffice`, not `IO80211Glue`. Its vtable uses `sendMail()` at `+0x120`, `sendMailSync()` at `+0x128`, and `deliverMessage()` at `+0x130`.

Stage153 traces the PostOffice allocation/initialization, send and delivery paths, queue-drain/timer callbacks, and free path. It also maps controller vtable slots used by the factory, and inspects `getPostOffice()`, controller `start/stop/free`, and the two postMessage relays to determine the static ownership/lifetime contract.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Stage152 report: `Development/Logs/stage152-postoffice-common-glue-20261106T213032Z.log`, Git blob SHA `e4f7baab619ec0c4236cda34b1490eb50045f332`.
- KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit
1. Verify Stage152 report and BootKC hashes.
2. Resolve controller vtable offsets `+0xC58/+0xC60/+0xC68/+0xDC0`.
3. Disassemble PostOffice alloc/init/send/sendSync/deliver/drain/timer/free methods.
4. Inspect controller factory/getter/start/stop/free and postMessage relays.
5. Inventory related PostOffice and workqueue symbols.
6. Publish the complete report to `Development/Logs/` and verify its Git blob SHA.

## Safety
Read-only only. No source, branch, index, or working-tree modifications; no build, signing, installation, loading/unloading, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. A static call graph cannot prove runtime retain counts, queue ordering, or which path executes on the test machine.
