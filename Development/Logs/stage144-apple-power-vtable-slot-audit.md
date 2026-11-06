# Stage144 — Apple POWER vtable slot resolution

Read-only audit for macOS Sequoia 15.8.1 build 24H32 x86_64.

Stage143 found that Apple POWER wrappers call the interface's controller accessor and then dispatch getPOWER at controller vtable byte offset 0xCD8 and setPOWER at 0xCE0. Stage144 resolves these exact IO80211Controller vtable entries in the pinned BootKernelExtensions collection, also records interface vtable slots used by the wrappers (0xBA8 and 0xCC0), prints exact symbol and owner identities, and compares the local 24H32 ABI declarations with the driver's RTW88WCLController declarations.

The runner pins the BootKC SHA-256 and upstream KC reader Git blob SHA. It writes no source files in the checkout and publishes only a timestamped report to Development/Logs/ on main, verifying the Git blob SHA.

No source edits, build, signing, install, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. Static ABI mapping only.
