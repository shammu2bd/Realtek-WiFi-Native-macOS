# Stage136 — corrected Skywalk network enable slot

Stage135 used the address-point formula for all four calls. The Stage134 instruction at `0xffffff8002988b25` is different: it executes `leaq __ZTV25IOSkywalkNetworkInterface(%rip), %rax` and then calls `*0x860(%rax)`. Therefore this particular offset is relative to the vtable symbol itself, not the object's vptr/address point.

Stage136 resolves the slot at symbol-relative offset `0x860` (index `0x860 / 8`) and requires the exact symbol `__ZN25IOSkywalkNetworkInterface6enableEj`, its IOSkywalkFamily owner, and an executable segment before bounded disassembly.

Pinned BootKC SHA-256: `cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3`.

Read-only only: no driver changes/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
