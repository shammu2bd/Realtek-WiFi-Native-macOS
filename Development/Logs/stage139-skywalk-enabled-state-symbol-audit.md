# Stage139 — Skywalk enabled-state symbol resolution

Read-only audit for macOS Sequoia 15.8.1 build 24H32 x86_64.

Stage138 attempted four assumed exact C++ symbol spellings and received `SYMBOL_NOT_FOUND` for each. Stage139 resolves actual exported BootKC symbols instead of assuming their mangled names. It inventories relevant methods for `IOSkywalkInterface`, `IOSkywalkNetworkInterface`, and `IOSkywalkEthernetInterface`, scans the `IOSkywalkFamily` owner for enabled/advisory callbacks, correlates relevant targets in those classes' vtables, and performs exact-start/next-symbol-bounded disassembly for candidate methods in the IOSkywalkFamily image.

The runner pins the local BootKernelExtensions.kc SHA-256 and upstream KC reader Git blob SHA. It publishes a timestamped report into `Development/Logs/` on `main` and verifies the resulting Git blob SHA.

This stage is strictly read-only: no source edits, build, signing, installation, loading/unloading, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot. A Skywalk software enabled flag is not treated as proof of physical Realtek radio power.
