# Stage114 — OpenCore native-kext load diagnostics

**Target:** macOS Sequoia 15.8.1 (24H32), x86_64, Intel Hackintosh, RTL8821CE PCIe.  
**Base:** Stage113 validation commit `86e2dbae408395a42b6cbc41876b8009f76d64bd`.  
**Scope:** read-only diagnosis of the native kext's OpenCore entry, current EFI bundle, signature/ownership diagnostics, boot logs, loaded-kext state and IORegistry attachment.

## Why this stage exists

Stage113 target-Mac regression tests and the native link/bundle passed. The resulting x86_64 executable hash is `409137db0772c6f5326af89f9f6dc699f8f18a13eb9025bc194b58e5bb92cd0a`, matching the Stage108 build. Its synchronized plist includes the executable-derived Apple dependencies and excludes `IO80211FamilyLegacy`.

Despite those build results, the user-reported post-reboot state still had no native `RTW88WCLController` or `RTW88WCLInfraInterface` in IORegistry and no native kext in `kmutil showloaded`. The RTL8821CE PCI device remained enumerated. Stage112's `kmutil print-diagnostics` output reported bad-code-signature authentication and paths with owner `99:99`; because the bundle was on the mounted EFI volume, the owner numbers must be correlated with the volume's filesystem/ownership mode and are not assumed to be the cause.

## What the runner inspects

- The already-mounted OpenCore config, exactly one native `Kernel -> Add` entry, Enabled/Arch/MinKernel/MaxKernel, resolved BundlePath, PlistPath, ExecutablePath, Info.plist identity/personality, and executable SHA-256 against Stage113.
- Other entries sharing the native bundle identifier, and enabled `Kernel -> Block` entries for IOSkywalkFamily/IO80211FamilyLegacy.
- Configured versus live boot arguments and configured CSR value; SIP status; SecureBootModel, Vault, and OpenCore debug settings.
- EFI volume filesystem/mount details, per-path UID/GID/mode, and ACL listings for the bundle, Info.plist and executable.
- Read-only `codesign -dv`, `codesign --verify`, `kmutil print-diagnostics`, and `kmutil libraries` results.
- `kmutil showloaded` for the native identifier and relevant loaded-kext rows.
- Exact IORegistry queries for RTW88WCLController and RTW88WCLInfraInterface, plus the RTL8821CE PCI node.
- Relevant unified log messages from the last six hours and up to three existing OpenCore log files under the already-mounted EFI's `EFI/OC/Logs` directory.

The runner records observed diagnostics; it does not assert that a code-signature or ownership message alone proves the precise boot-time cause. Absence of a logged rejection is not proof of successful injection.

## Safety boundaries

The runner does not mount an EFI volume, write to EFI, change config.plist, NVRAM, boot arguments or SIP, sign/build/install/load/unload a kext, start the radio, or transmit/receive packets. It only inspects an already-mounted `OPENCORE_CONFIG` (default `/Volumes/EFI/EFI/OC/config.plist`) and current running-system state. It writes a timestamped evidence log and a concise append to `Development/output.log`, then commits and pushes those two audit outputs.

The runner is pinned by Git blob SHA-1 in `Development/Allowlist/stage114-opencore-load-diagnostics.gitblob`. Verify the runner pin before execution. It requires a clean worktree on the Stage114 branch and confirms the Stage113 validation commit is an ancestor.

## Target-Mac execution

Use a separate worktree so local changes in the existing project folder, especially `Development/output.log`, are preserved. Run the single combined command supplied with this stage. The terminal prints a short result and saves the full report on the Desktop.

## Interpretation

- `NATIVE_NOT_LOADED_WITH_CODE_SIGNATURE_FAILURE_EVIDENCE`: the native bundle is absent from the loaded-kext query and signature failure is also observed. This is strong authentication evidence, not a permission to alter SIP or signing.
- `NATIVE_NOT_PRESENT_IN_LOADED_KEXT_QUERY; CAUSE_NOT_YET_PROVEN`: injection/load is absent but no explicit signature cause was captured.
- `EFI_NATIVE_EXECUTABLE_DIFFERS_FROM_STAGE113_VALIDATED_BINARY`: the EFI bundle does not match the tested artifact; do not proceed to activation.
- Controller/interface class matches indicate attachment/publication evidence only; they do not prove scan, association, TX/RX or stability.
- If the EFI volume reports ownership disabled, its synthetic UID/GID display (including possible `99:99`) must not be treated as a root-volume ownership failure without separate evidence.

**Activation remains blocked. PR #4 remains draft/open/unmerged.**
