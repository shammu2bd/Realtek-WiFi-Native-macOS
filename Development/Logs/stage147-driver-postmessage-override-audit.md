# Stage147 — driver postMessage override audit

Read-only audit for macOS Sequoia 15.8.1 build 24H32 x86_64.

Stage146 identified the Apple POWER wrapper's post-success virtual call through interface slot `0xB10`, and found local driver source references indicating that `RTW88WCLInfraInterface::postMessage` forwards through `_controller->postMessage(...)`. The Apple base-class method and the actual most-derived driver override must not be conflated.

Stage147 prints the local driver declarations and implementations for the Infra interface, controller, ABI protocol classes, and POWER callbacks. It reports source hashes, class declarations, method signatures, forwarding code, and whether a matching controller `postMessage` declaration/definition is present. This is source-level evidence only; it does not compile a vtable or prove runtime dispatch.

The runner reads the existing working tree without changing source files, branch, index, or working tree. It publishes only a timestamped report to `Development/Logs/` on `main`, then verifies the Git blob SHA.

No source edits, build, signing, install, load/unload, hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot.
