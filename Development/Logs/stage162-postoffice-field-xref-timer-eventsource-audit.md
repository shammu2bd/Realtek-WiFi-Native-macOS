# Stage162 — PostOffice field xrefs and timer event-source ownership

## Why this stage follows Stage161
Stage161 confirms that controller start stores the PostOffice in controller expansion `+0xB08`, while `getPostOffice()` reads that field. It did not reveal a clear direct release in the inspected controller stop/free paths. PostOffice stores a workqueue pointer and creates an IO80211TimerSource using it, but neither PostOffice nor TimerSource's own visible free path directly proves ownership of the queue.

The timer initializer appears to connect the timer source to a workqueue through an indirect callback. Stage162 scans the entire IO80211Family text for all `+0xB08` field references, catalogs queue/timer methods, and disassembles the available IOWorkLoop / IOEventSource add/remove methods. The purpose is to determine whether controller cleanup is hidden in another helper and whether event-source registration itself retains the source or queue.

## Pinned inputs
- macOS 15.8.1, build 24H32, x86_64.
- BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.
- Stage161 report: `Development/Logs/stage161-controller-postoffice-timer-workqueue-lifetime-20261106T215127Z.log`, Git blob SHA `cc528f8f4a0ae16134e1ef893856ae3b54abfcdb`.
- KC reader commit: `cea28a5297633118177cee6a75e86d8bc57f1960`, blob SHA `5d31e8a73e5cb175851e7407529456f223683589`.

## Audit operations
1. Verify Stage161 report and BootKC hashes.
2. Scan the full IO80211Family text section for reads/writes to controller expansion offset `+0xB08` and nearby candidate fields.
3. Inventory IO80211WorkQueue, IO80211TimerSource and IO80211PostOffice methods.
4. Inspect timer source init/free and PostOffice init/free.
5. Resolve IOWorkLoop::addEventSource / removeEventSource and IOEventSource workloop methods when present in this kernel collection.
6. Recheck controller stop/free, then upload the timestamped report and verify its Git blob SHA.

## Safety and limits
Read-only static analysis only. No source, branch, index, or worktree changes; no build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. Some framework operations are indirect or live in separate kexts; missing symbols must be reported as unknown, not inferred. Do not implement the private Apple object layout or copy reference-management behavior until the complete ownership chain is demonstrated and runtime/API requirements are independently validated.
