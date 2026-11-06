# Stage148 — Apple controller postMessage symbol audit

Read-only audit for macOS Sequoia 15.8.1 build 24H32 x86_64.

Stage147 found that the driver helper is named `RTW88WCLInfraInterface::postWCLMessage`, not `RTW88WCLInfraInterface::postMessage`. Its call `_controller->postMessage(...)` is declared in the Apple `IO80211Controller` ABI declaration. The absence of a driver-specific `RTW88WCLController::postMessage` override is not, by itself, evidence of a broken call.

Stage148 resolves the exact Apple `IO80211Controller::postMessage(IO80211SkywalkInterface*, unsigned int, void*, unsigned long, bool)` symbol in the pinned 24H32 BootKC, records its owner, and disassembles it when the symbol and owner image are available. It also correlates the local base declaration, whether it is virtual, the driver helper definition and the absence/presence of a driver override.

The runner pins the BootKC SHA-256 and upstream KC reader Git blob SHA, reads only the existing checkout, and uploads only a timestamped report to `Development/Logs/` on `main`. No source, index, branch, or working-tree mutation; no build, signing, install, load/unload, hardware, OpenCore/EFI/SIP/NVRAM, or reboot.

Static symbol/source correlation only; no claim of compiled driver callsite or runtime behavior.
