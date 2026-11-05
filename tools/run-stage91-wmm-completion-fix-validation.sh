#!/bin/bash
# Validate the Stage91 WMM-routing and completion-retry fixes.
# Runs the existing eleven-test host/source suite, then compiles only seven
# objects (six WCL objects plus RTW88IEEE80211.o). No link/sign/install/load.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

EXPECTED_BRANCH="work/stage91-tx-submission-callback-v1"
BRANCH="$(git branch --show-current 2>/dev/null || true)"
if [ "$BRANCH" != "$EXPECTED_BRANCH" ]; then
    echo "ERROR: run only on $EXPECTED_BRANCH"
    echo "CURRENT_BRANCH=$BRANCH"
    exit 91
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "STOP: local changes detected; no reset or overwrite performed."
    exit 2
fi

git fetch origin || exit 1
git merge --ff-only "origin/$BRANCH" || exit 1

echo "===== STAGE91 HOST/SOURCE SUITE ====="
bash tools/run-stage91-tx-submission-tests.sh
TEST_RESULT=$?
if [ "$TEST_RESULT" -ne 0 ]; then
    echo "HOST_SOURCE_SUITE=FAIL"
    echo "NATIVE_COMPILE=NOT_RUN"
    exit "$TEST_RESULT"
fi

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
mkdir -p Development/Logs Development || exit 1
LOG="Development/Logs/stage91-wmm-completion-fix-compile-$STAMP.log"
export DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"

set +e
(
    set -eu
    echo "STAGE91 WMM + COMPLETION RETRY NATIVE COMPILE-ONLY"
    echo "BRANCH=$BRANCH"
    echo "COMMIT=$(git rev-parse HEAD)"
    echo "TARGET=macOS Sequoia 15.8.1 / 24H32 / x86_64"
    echo "DEVELOPER_DIR=$DEVELOPER_DIR"

    xcodebuild -version
    xcrun --sdk macosx --show-sdk-path

    cd "$ROOT/driver/RTL88WiFi"
    DRYRUN="$(mktemp)"
    trap 'rm -f "$DRYRUN"' EXIT

    env -u MAKEFLAGS -u MFLAGS -u MAKEFILES \
      make -n -B -f Makefile rtl88wifi-wcl-controller-abi-check \
      "$PWD/build/native/RTW88IEEE80211.o" > "$DRYRUN" 2>&1

    echo "===== SEVEN-OBJECT DRY-RUN PREFLIGHT ====="
    cat "$DRYRUN"
    COUNT="$(grep -Ec '^xcrun clang[+][+] .* -c ' "$DRYRUN" || true)"
    echo "COMPILE_COMMAND_COUNT=$COUNT"
    [ "$COUNT" -eq 7 ] || {
        echo "FAIL: expected exactly seven compile-only commands."
        exit 10
    }

    if grep -Eq 'NATIVE LD|(^|[[:space:]])ld[[:space:]]|rsync |kextutil|kmutil|codesign|/Library/Extensions|EFI/OC' "$DRYRUN"; then
        echo "FAIL: dry-run contains a link, signing, install, load or OpenCore operation."
        exit 11
    fi
    echo "DRY_RUN_PREFLIGHT=PASS"

    echo "===== ACTUAL SEVEN-OBJECT COMPILE-ONLY BUILD ====="
    env -u MAKEFLAGS -u MFLAGS -u MAKEFILES \
      make -B -f Makefile rtl88wifi-wcl-controller-abi-check \
      "$PWD/build/native/RTW88IEEE80211.o"

    echo "===== OBJECT VERIFICATION ====="
    for obj in \
      build/wcl24h32/RTW88WCLController.o \
      build/wcl24h32/RTW88WCLInfraInterface.o \
      build/wcl24h32/RTW88WCLPCIBackend.o \
      build/wcl24h32/RTW88WCLSkywalkQueues.o \
      build/wcl24h32/RTW88WCLSkywalkTxAdapter.o \
      build/wcl24h32/RTW88WCLSkywalkRxAdapter.o \
      build/native/RTW88IEEE80211.o
    do
        test -s "$obj"
        file "$obj"
    done

    echo "STAGE91_WMM_COMPLETION_FIX_COMPILE=PASS"
    echo "OBJECT_COUNT=7"
    echo "FULL_KEXT_LINK=NOT_RUN"
    echo "SIGNING=NOT_RUN"
    echo "INSTALL=NOT_RUN"
    echo "LOAD=NOT_RUN"
    echo "HARDWARE_TEST=NOT_RUN"
) > "$ROOT/$LOG" 2>&1
COMPILE_RESULT=$?
set -e

echo "===== STAGE91 NATIVE COMPILE LOG ====="
cat "$ROOT/$LOG"
echo "COMPILE_EXIT_CODE=$COMPILE_RESULT"

{
    echo
    echo "## Stage91 WMM/completion-retry compile — $STAMP"
    echo "- Branch: $BRANCH"
    echo "- Commit: $(git rev-parse HEAD)"
    echo "- Result: $([ "$COMPILE_RESULT" -eq 0 ] && echo PASS || echo FAIL)"
    echo "- Log: $LOG"
    echo "- Scope: seven compile-only objects; no full link, signing, install, load or hardware test."
} >> Development/output.log

git add -f "$LOG" Development/output.log || exit 20
git commit -m "Stage91: record WMM and completion retry compile $STAMP" || exit 21
git push origin HEAD || exit 22

echo "GITHUB_COMPILE_LOG_UPLOAD=PASS"
exit "$COMPILE_RESULT"
