# Stage98 target-Mac compile diagnostic and corrective source update

Date: 2026-11-06
Branch: `work/stage91-tx-submission-callback-v1`
Target: macOS Sequoia 15.8.1 (24H32), Intel x86_64, Xcode 16.4

## Verified target compile result

The target-Mac diagnostic log was successfully uploaded:
`Development/Logs/stage98-target-compile-diagnostic-20261106T033413Z.log`

The command returned status **2**. The first blocking compile error is in
`driver/rtw88-stable/drivers/net/wireless/realtek/rtw88/sec.c`:

- line 32: call to undeclared function `rtw_warn`
- line 98: call to undeclared function `rtw_warn`
- make stopped while building `build/driver/sec.o`

The error is not an Xcode SDK selection failure: the log confirms Xcode 16.4
and the macOS SDK path. Other objects continued compiling and emitted warnings,
but the CAM security source did not compile.

## Root cause and correction

Stage97 added defensive CAM bounds diagnostics that invoked `rtw_warn(rtwdev, ...)`.
That helper is not declared by the checked-out driver or the macOS compatibility
headers. The compatibility layer already defines `dev_warn(dev, fmt, ...)`,
and `struct rtw_dev` contains `struct device *dev`.

Both bounds guards now use:

`dev_warn(rtwdev->dev, ...)`

This preserves the defensive bounds behavior and sends the warning through the
existing device logger. No CAM indexing logic or key-retirement behavior was
changed by this correction.

A Stage97 regression assertion was added to verify both guard paths use the
declared device logger. The Stage97 workflow is triggered by the source/test
update; its result must be checked before treating the source audit as passed.

## Required re-validation

The target-Mac `native-compile-only` command must be rerun against the new
branch head. This is object compilation only. Do not link a kext, sign,
install, load, activate native queues, publish an interface, or start the radio.

## Gate

- Previous target compile: **FAILED**, status 2, due to undeclared `rtw_warn`.
- Source correction: **COMMITTED**.
- Regression workflow after correction: **PENDING** at report creation.
- New target-Mac compile: **PENDING**.
- TX callback lock internals / target runtime lock-order proof: **OPEN**.
- Native activation and PR #4 merge: **BLOCKED**.
