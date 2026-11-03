#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
API_PATH="repos/$REPO/contents/Development/output.log"
PROJECT_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"

fail() { echo "ERROR: $*" >&2; exit 2; }

find_project() {
    if [[ -n "${PROJECT_DIR:-}" ]]; then
        if [[ -f "${PROJECT_DIR}/driver/RTL88WiFi/Makefile" ]]; then
            (cd "${PROJECT_DIR}" && pwd -P); return
        fi
        if [[ -f "${PROJECT_DIR}/Makefile" && -d "${PROJECT_DIR}/src/kext" ]]; then
            (cd "${PROJECT_DIR}/../.." && pwd -P); return
        fi
        fail "PROJECT_DIR does not identify the Stage26 project or driver directory."
    fi
    local guess="$HOME/Downloads/$PROJECT_NAME"
    [[ -f "$guess/driver/RTL88WiFi/Makefile" ]] || fail "Stage26 project not found at $guess. Set PROJECT_DIR."
    (cd "$guess" && pwd -P)
}

PROJECT="$(find_project)"
DRIVER="$PROJECT/driver/RTL88WiFi"
MAKEFILE="$DRIVER/Makefile"
NATIVE_TEMPLATE="$DRIVER/RTL88WiFiNative.kext"
NATIVE_OUT="$DRIVER/build/out/RTL88WiFiNative.kext"
NATIVE_BIN="$NATIVE_OUT/Contents/MacOS/RTL88WiFiNative"
LOG="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage29c-native-link-build-$STAMP"
REMOTE_LOG="$STAGE_DIR/output.log.github-before"
RUN_LOG="$STAGE_DIR/stage29c-run.log"
PAYLOAD="$STAGE_DIR/github-output-log.json"

mkdir -p "$STAGE_DIR"
command -v gh >/dev/null 2>&1 || fail "GitHub CLI is missing."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run gh auth login."

# Fetch the single canonical history before appending this run.
gh api "$API_PATH" --jq '.content' | \
    python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' > "$REMOTE_LOG"
[[ -s "$REMOTE_LOG" ]] || fail "GitHub Development/output.log is empty or failed to decode; refusing to overwrite."
cp "$REMOTE_LOG" "$LOG"
: > "$RUN_LOG"

# Use a real file as the output sink. No asynchronous tee process can race the
# final GitHub payload construction.
exec 3>&1 4>&2
exec >>"$RUN_LOG" 2>&1

finish() {
    local rc=$?
    trap - EXIT
    set +e
    exec 1>&3 2>&4

    cat "$RUN_LOG" >> "$LOG"
    cat "$RUN_LOG"

    echo
    echo "CANONICAL_LOG: project output.log"
    echo "GITHUB_DESTINATION: Development/output.log"

    local remote_sha=""
    remote_sha="$(gh api "$API_PATH" --jq '.sha' 2>/dev/null)"
    if [[ -z "$remote_sha" ]]; then
        echo "GITHUB_UPLOAD_STATUS: FAILED — remote SHA unavailable."
        [[ "$rc" -ne 0 ]] || rc=30
    else
        python3 - "$LOG" "$remote_sha" "$PAYLOAD" <<'PY'
import base64
import json
import pathlib
import sys
log_path, sha, payload_path = sys.argv[1:4]
content = pathlib.Path(log_path).read_bytes()
if not content:
    raise SystemExit("Refusing to upload an empty log.")
payload = {
    "message": "Stage29c native target compile and link result",
    "content": base64.b64encode(content).decode("ascii"),
    "sha": sha,
}
pathlib.Path(payload_path).write_text(json.dumps(payload), encoding="utf-8")
PY
        local prep_rc=$?
        if [[ "$prep_rc" -ne 0 ]]; then
            echo "GITHUB_UPLOAD_STATUS: FAILED — upload payload creation failed."
            [[ "$rc" -ne 0 ]] || rc=31
        else
            local response=""
            response="$(gh api --method PUT "$API_PATH" --input "$PAYLOAD" 2>&1)"
            local put_rc=$?
            if [[ "$put_rc" -ne 0 ]]; then
                echo "GITHUB_UPLOAD_STATUS: FAILED — $response"
                [[ "$rc" -ne 0 ]] || rc=32
            else
                local commit_sha uploaded_sha verify_sha
                commit_sha="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["commit"]["sha"])' 2>/dev/null)"
                uploaded_sha="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["content"]["sha"])' 2>/dev/null)"
                verify_sha="$(gh api "$API_PATH" --jq '.sha' 2>/dev/null)"
                if [[ -n "$uploaded_sha" && "$verify_sha" == "$uploaded_sha" ]]; then
                    echo "GITHUB_UPLOAD_STATUS: SUCCESS"
                    echo "GITHUB_COMMIT: $commit_sha"
                    echo "GITHUB_OUTPUT_LOG_BLOB: $verify_sha"
                else
                    echo "GITHUB_UPLOAD_STATUS: UNVERIFIED — blob SHA mismatch on read-back."
                    [[ "$rc" -ne 0 ]] || rc=33
                fi
            fi
        fi
    fi
    exec 3>&- 4>&-
    exit "$rc"
}
trap finish EXIT

OS_VERSION="$(sw_vers -productVersion)"
OS_BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"

echo
echo "RTL88WiFi Stage29c — native target actual compile and link"
echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "PROJECT: $PROJECT"
echo "DRIVER: $DRIVER"
echo "STAGE_DIR: $STAGE_DIR"
echo "HOST: macOS $OS_VERSION / $OS_BUILD / $ARCH"
echo "SCOPE: force-build and link only the separate rtl88wifi-native target."
echo "CANONICAL_LOG: GitHub Development/output.log"
echo "LEGACY_TARGET: NOT INVOKED"
echo "INSTALL: NOT RUN"
echo "LOAD: NOT RUN"
echo "OPENCORE_CHANGE: NONE"
echo "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED"

BUILD_RC=0
VERIFY_RC=0

if [[ "$OS_VERSION" != "15.8.1" || "$OS_BUILD" != "24H32" || "$ARCH" != "x86_64" ]]; then
    echo "ERROR: Expected macOS 15.8.1 / 24H32 / x86_64."
    BUILD_RC=10
fi
if [[ "$BUILD_RC" -eq 0 && ! -f "$MAKEFILE" ]]; then
    echo "ERROR: Makefile missing: $MAKEFILE"; BUILD_RC=11
fi
if [[ "$BUILD_RC" -eq 0 && ! -f "$NATIVE_TEMPLATE/Contents/Info.plist" ]]; then
    echo "ERROR: Native bundle Info.plist missing."; BUILD_RC=12
fi
if [[ "$BUILD_RC" -eq 0 ]] && ! grep -Eq '^[[:space:]]*rtl88wifi-native:' "$MAKEFILE"; then
    echo "ERROR: rtl88wifi-native target missing."; BUILD_RC=13
fi

if [[ "$BUILD_RC" -eq 0 ]]; then
    /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries:com.apple.iokit.IO80211Family' "$NATIVE_TEMPLATE/Contents/Info.plist" >/dev/null 2>&1 || BUILD_RC=14
    /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries:com.apple.iokit.IOSkywalkFamily' "$NATIVE_TEMPLATE/Contents/Info.plist" >/dev/null 2>&1 || BUILD_RC=15
    if /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries:com.apple.iokit.IO80211FamilyLegacy' "$NATIVE_TEMPLATE/Contents/Info.plist" >/dev/null 2>&1; then
        echo "ERROR: Native plist has IO80211FamilyLegacy."; BUILD_RC=16
    fi
fi

if [[ "$BUILD_RC" -eq 0 ]]; then
    echo
    echo "========== CLEAN NATIVE OUTPUT ONLY =========="
    echo "Removing only experimental output: $NATIVE_OUT"
    rm -rf "$NATIVE_OUT"
    echo
    echo "========== ACTUAL NATIVE BUILD =========="
    echo "COMMAND: make -B -j1 rtl88wifi-native"
    set +e
    (cd "$DRIVER" && make -B -j1 rtl88wifi-native) 2>&1
    BUILD_RC=$?
    set -e
    echo "NATIVE_BUILD_EXIT: $BUILD_RC"
else
    echo "NATIVE_BUILD_SKIPPED_PREFLIGHT_RC: $BUILD_RC"
fi

if [[ "$BUILD_RC" -eq 0 ]]; then
    echo
    echo "========== NATIVE BUNDLE VALIDATION =========="
    if [[ ! -f "$NATIVE_OUT/Contents/Info.plist" ]]; then
        echo "ERROR: Native Info.plist was not staged."; VERIFY_RC=21
    elif [[ ! -f "$NATIVE_BIN" ]]; then
        echo "ERROR: Native executable missing: $NATIVE_BIN"; VERIFY_RC=22
    else
        plutil -lint "$NATIVE_OUT/Contents/Info.plist" || VERIFY_RC=23
        EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$NATIVE_OUT/Contents/Info.plist")"
        BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NATIVE_OUT/Contents/Info.plist")"
        echo "BUNDLE_EXECUTABLE: $EXEC_NAME"
        echo "BUNDLE_IDENTIFIER: $BUNDLE_ID"
        [[ "$EXEC_NAME" == "RTL88WiFiNative" ]] || VERIFY_RC=24
        [[ "$BUNDLE_ID" == "io.github.x1ren41l.RTL88WiFi" ]] || VERIFY_RC=25
        echo "NATIVE_BINARY_FILE:"; file "$NATIVE_BIN"
        echo "NATIVE_ARCHITECTURES:"; lipo -archs "$NATIVE_BIN"
        ARCHS="$(lipo -archs "$NATIVE_BIN")"
        [[ " $ARCHS " == *" x86_64 "* ]] || VERIFY_RC=26
        echo "NATIVE_MACH_HEADER:"; otool -hv "$NATIVE_BIN"
        otool -hv "$NATIVE_BIN" | grep -q 'KEXTBUNDLE' || VERIFY_RC=27
        echo "NATIVE_BINARY_SHA256:"; shasum -a 256 "$NATIVE_BIN"
        echo "NATIVE_DEPENDENCIES:"
        /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries' "$NATIVE_OUT/Contents/Info.plist"
        if /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries:com.apple.iokit.IO80211FamilyLegacy' "$NATIVE_OUT/Contents/Info.plist" >/dev/null 2>&1; then
            echo "ERROR: Built bundle contains legacy IO80211 dependency."; VERIFY_RC=28
        fi
        echo "NATIVE_PERSONALITY:"
        /usr/libexec/PlistBuddy -c 'Print :IOKitPersonalities' "$NATIVE_OUT/Contents/Info.plist"
    fi
    echo "NATIVE_POSTBUILD_VERIFY_EXIT: $VERIFY_RC"
else
    echo "NATIVE_POSTBUILD_VERIFY: SKIPPED_BUILD_FAILED"
fi

echo
echo "========== STAGE29C RESULT =========="
if [[ "$BUILD_RC" -eq 0 && "$VERIFY_RC" -eq 0 ]]; then
    echo "NATIVE_ACTUAL_BUILD: PASS"
    echo "NATIVE_BUNDLE_VALIDATION: PASS"
    echo "NEXT_GATE: inspect unresolved symbols and native controller registration metadata; do not install/load yet."
else
    echo "NATIVE_ACTUAL_BUILD: FAIL"
    echo "NATIVE_BUILD_EXIT: $BUILD_RC"
    echo "NATIVE_BUNDLE_VERIFY_EXIT: $VERIFY_RC"
    echo "NEXT_GATE: resolve build or bundle validation errors before integration."
fi
echo "LEGACY_TARGET: NOT BUILT OR MODIFIED"
echo "INSTALL: NOT RUN"
echo "LOAD: NOT RUN"
echo "OPENCORE_CHANGE: NONE"
echo "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED"
echo "RUN_LOG: $RUN_LOG"
echo "LOCAL_CANONICAL_LOG_COPY: $LOG"
