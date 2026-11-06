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


## Second target-Mac compile and follow-up fixes

The corrected compile was rerun on 24H32 with Xcode 16.4. Its result is recorded in:
`Development/Logs/stage98-target-compile-fixed-20261106T033742Z.log`

The rerun passed the prior `sec.c` compilation point and exposed 17 errors in
`RTW88IEEE80211.cpp`. The reported root causes were:

1. Eight uses of `_txBAState` did not match the declared member `_txBaState`.
2. The connected-scan deauthentication predicate and RX-data connected predicate
   were each missing their closing `);`. The `infraHdr` undeclared errors
   followed from the parser losing the intended function structure.
3. M3 GTK length/index variables were declared inside the nested key-mutation
   block, while the later WPA2-connected diagnostic used them after that block.

Corrections committed:
- Replaced all eight member-name mismatches with the declared `_txBaState`.
- Closed both state predicates.
- Moved M3 `gtk_len` and `gtk_idx` declarations to the enclosing M3 branch,
  retaining their parsed values for the later diagnostic.
- Added four Stage98 source-regression checks for those invariants.

Source fix commit: `5797f5a8144c0b01819b763a5c94878922f99672`  
Regression test commit: `a4df1110819349535da2cb7d3a472ab1ffccf1b1`

Post-fix static workflow result has not yet been verified. The target-Mac
compile must be rerun against the latest branch head; no successful native
compile is claimed.

## Updated gate

- CAM logging helper: source correction committed.
- Native C++ identifier / syntax / GTK scope corrections: source correction committed.
- Static regression suite: pending Actions verification.
- Target 24H32 compile: failed on the previous revision; post-fix rerun pending.
- TX completion reporter internals and runtime lock-order proof: open.
- Native activation, install/load and PR #4 merge: blocked.

## Verified Stage98 target compile and regression results

Target-Mac compile-only log:
Development/Logs/stage98-final-compile-20261106T034120Z.log

- macOS Sequoia 15.8.1 (24H32), Intel x86_64; Xcode 16.4.
- Shell command exit status: 0.
- Build marker: NATIVE_COMPILE_ONLY=PASS (objects only; no link/sign/install/load).
- The final make invocation rebuilt RTW88IEEE80211.cpp and emitted 22 warnings, 0 errors. Other object prerequisites were already current from earlier Stage98 compile attempts. This is a successful incremental object-only target, not yet a clean-from-empty build-directory compile.

GitHub Actions:
- Stage98 static audit run 42158234359: success, 13 checks passed, 0 failed. Lock review remains open for completion-reporter internals and target runtime.
- Stage94 compatibility/integration run 42158279149: success, 39 checks passed, 0 blockers. The Stage94 test had stale case-sensitive _txBAState expectations after the source was corrected to the declared _txBaState; the test-only expectations were corrected.

## Remaining gate

A clean target-Mac object-only build is still recommended: make clean removes only this Makefile's build/ directory, followed by make native-compile-only. No link, bundle, signing, installation, loading or hardware activation is required for that check.

Still open:
- Trace the internal locking and possible callback re-entry in rtw88_skb_tx_completion_report().
- Verify actual target macOS lock ordering/runtime behavior; source checks are not a deadlock proof.
- No full kext link, signing, install/load, RTL8821CE hardware TX/RX or throughput test has been performed.
- Native activation and PR #4 merge remain blocked.