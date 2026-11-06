# Stage140 — Wi-Fi subclass virtual override audit

Read-only cross-family BootKernelExtensions audit for macOS Sequoia 15.8.1 build 24H32 x86_64.

Stage139 established that IOSkywalkNetworkInterface::isEnabled() reads object byte +0xC8, enable() invokes virtual slot +0x928 and sets +0xC8 when the setter succeeds, disable() clears +0xC8 and invokes the same setter, while the base setInterfaceEnable(bool) implementation is a no-op and base interfaceAdvisoryEnable(bool) returns unsupported. Stage140 determines whether IO80211SkywalkInterface or IO80211InfraInterface overrides the relevant enable, disable, state, or advisory virtual slots.

The runner inventories exact methods and vtable targets for IO80211SkywalkInterface, IO80211InfraInterface, IOSkywalkNetworkInterface, and IOSkywalkNetworkBSDClient. It examines object-vptr offsets 0x788, 0x850, 0x858, 0x920, and 0x928, resolves the owning fileset image, and disassembles exact-start/next-symbol-bounded method bodies.

The BootKC SHA-256 and upstream KC reader Git blob SHA are pinned. The timestamped report is uploaded to Development/Logs/ on main and its Git blob SHA is verified.

No source edits, build, signing, install, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. Software enabled flags are not treated as proof of physical radio power.
