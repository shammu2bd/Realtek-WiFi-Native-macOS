# Stage143 — Apple Wi-Fi POWER selector dispatch audit

Read-only audit of the pinned macOS Sequoia 15.8.1 build 24H32 x86_64 BootKernelExtensions collection.

This stage examines exact symbols, vtable entries, and bounded method bodies for IO80211Controller, IO80211SkywalkInterface, IO80211InfraInterface, IOSkywalkEthernetInterface, and IOSkywalkNetworkInterface. It traces Apple interface command and POWER selector-related methods, including getPOWER/setPOWER callbacks, so the interface-to-controller dispatch can be distinguished from the separate Skywalk interface enabled-state path.

The runner pins the BootKC SHA-256 and upstream KC reader Git blob SHA. It uploads a timestamped report to Development/Logs/ on main and verifies the Git blob SHA.

Strictly read-only: no source edits, build, signing, installation, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. It makes no claim about runtime power or menu visibility.
