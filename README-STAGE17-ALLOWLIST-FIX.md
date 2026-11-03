# Stage 17 target-class inventory filter fix

## Cause

The Stage 17 kcabi patch enumerated methods for every class in upstream WTLKcAbi's broad `CLASSES` allow-list. That list includes AppleBCMWLAN classes such as `AppleBCMWLANCore`, while the Stage 17 ownership auditor intentionally accepts exactly 13 IOSkywalk target classes. The audit therefore stopped with `Unexpected class in executable-method inventory: AppleBCMWLANCore` even though the class method disassembly itself had completed.

## Correction

This overlay updates `tools/patch-kcabi-class-list-stage17.py` and its regression tests. The temporary kcabi copy keeps upstream `CLASSES` unchanged for the general vtable/size collection, but introduces an exact `STAGE17_TARGET_CLASSES` tuple containing only the 13 Stage 17 IOSkywalk classes. Only those classes are added to the Stage 17 executable-method manifest and method-disassembly set. The patcher verifies the allow-list exactly and remains idempotent.

The regression fixture deliberately includes `AppleBCMWLANCore`, `AppleBCMWLANInfraProtocol`, and `AppleBCMWLANPCIeSkywalk` in the upstream class list and confirms none leak into the Stage 17 manifest.

## Apply and run

Download `RTL88WiFi-Stage17-target-class-filter-fix-overlay.zip` into `~/Downloads`, then run:

```zsh
PROJECT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
OVERLAY="$HOME/Downloads/RTL88WiFi-Stage17-target-class-filter-fix-overlay.zip"

set -e
[[ -d "$PROJECT" ]] || { echo "Project folder missing"; exit 2; }
[[ -f "$OVERLAY" ]] || { echo "Overlay ZIP missing"; exit 2; }
/bin/bash "$PROJECT/tools/apply-overlay-and-run.sh" \
  "$OVERLAY" tools/run-stage17.sh
```

This uses the project's existing automatic overlay applier and `runlog` helper. The runner will write `output.log` and upload the Stage 17 diagnostic/result archive to `shammu2bd/Realtek-WIFI-Native-macOS`.

## Acceptance criteria

Do not advance based only on the synthetic test. The real Stage 17 log must show:

- `Stage 17 status: PASS`;
- all 13 target classes represented in the manifest;
- executable method body count equal to executable method count, with no missing bodies;
- all 19 source ownership checks passing;
- archive SHA and Stage 14/15/16 input linkage verified;
- `DATAPATH_ACTIVATION: BLOCKED` (this is intentional; this stage is still read-only).

The broader WTLKcAbi vtable/size collection can continue to include upstream classes; only the Stage 17 method manifest is class-filtered. No TX/RX callbacks, packet submission, queue registration or interface publication are enabled by this overlay.
