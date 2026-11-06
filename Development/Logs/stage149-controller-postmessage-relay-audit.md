# Stage149 — controller postMessage relay audit

Read-only audit for macOS Sequoia 15.8.1 build 24H32 x86_64.

Stage148 identified the concrete Apple method `IO80211Controller::postMessage`. Its bounded disassembly reads a pointer from the controller object at offset `0x120`, reads another pointer at offset `0xB08` from that object, then dispatches through the receiver's vtable at byte offset `0x120`.

Stage149 maps that relay path. It resolves the known `IO80211Glue` methods, checks candidate class vtables at the relevant slot, inspects controller initialization/start methods for assignments or uses involving those offsets, and inventories local driver declarations/call sites. It is intended to identify whether the receiver is an Apple glue object and which method services the forwarding call. The report will preserve unresolved pieces rather than infer a class from a field offset alone.

The runner pins the 24H32 BootKC SHA-256 and upstream KC reader Git blob SHA. It reads the existing checkout without changing source files, branch, index, or working tree. It publishes only a timestamped report to `Development/Logs/` on `main`, then verifies the Git blob SHA.

No source edits, build, signing, install, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot.
