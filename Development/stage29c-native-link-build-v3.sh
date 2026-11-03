#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
API_URL="https://api.github.com/repos/$REPO/contents/Development/output.log"
API_PATH="repos/$REPO/contents/Development/output.log"
PROJECT_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"

fail() { echo "ERROR: $*" >&2; exit 2; }

find_project() {
    local candidate="${PROJECT_DIR:-}"
    local here="$PWD"
    local found=""

    # Accept either the project root, the driver directory, or a shell opened
    # directly inside the driver's working directory.
    if [[ -n "$candidate" ]]; then
        if [[ -f "$candidate/driver/RTL88WiFi/Makefile" ]]; then
            (cd "$candidate" && pwd -P); return 0
        fi
        if [[ -f "$candidate/Makefile" && -d "$candidate/src/kext" ]]; then
            (cd "$candidate/../.." && pwd -P); return 0
        fi
        echo "WARNING: PROJECT_DIR is stale or points elsewhere; searching for the Stage26 tree." >&2
    fi
    if [[ -f "$here/driver/RTL88WiFi/Makefile" ]]; then
        (cd "$here" && pwd -P); return 0
    fi
    if [[ -f "$here/Makefile" && -d "$here/src/kext" ]]; then
        (cd "$here/../.." && pwd -P); return 0
    fi

    local expected="$HOME/Downloads/$PROJECT_NAME"
    if [[ -f "$expected/driver/RTL88WiFi/Makefile" ]]; then
        (cd "$expected" && pwd -P); return 0
    fi

    # Search Downloads for the exact driver Makefile instead of assuming the
    # downloaded folder kept its expected name.
    if [[ -d "$HOME/Downloads" ]]; then
        found="$(find "$HOME/Downloads" -maxdepth 12 -type f -path '*/driver/RTL88WiFi/Makefile' -print -quit 2>/dev/null || true)"
    fi
    if [[ -n "$found" ]]; then
        (cd "$(dirname "$found")/../.." && pwd -P); return 0
    fi

    echo "PROJECT_DISCOVERY_DIAGNOSTIC: no driver/RTL88WiFi/Makefile found." >&2
    echo "PROJECT_DIR=${candidate:-<unset>}" >&2
    echo "HOME=$HOME" >&2
    echo "PWD=$PWD" >&2
    echo "Downloads directory: $HOME/Downloads" >&2
    if [[ -d "$HOME/Downloads" ]]; then
        find "$HOME/Downloads" -maxdepth 4 -type d -name 'RTL88WiFi*' -print >&2 2>/dev/null || true
    fi
    fail "Cannot find the Stage26 driver tree. Ensure the Stage26 source ZIP is extracted under ~/Downloads, or set PROJECT_DIR to its project root."
}

PROJECT="$(find_project)"
DRIVER="$PROJECT/driver/RTL88WiFi"
MAKEFILE="$DRIVER/Makefile"
NATIVE_TEMPLATE="$DRIVER/RTL88WiFiNative.kext"
NATIVE_OUT="$DRIVER/build/out/RTL88WiFiNative.kext"
NATIVE_BIN="$NATIVE_OUT/Contents/MacOS/RTL88WiFiNative"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage29c-native-link-build-v3-$STAMP"
REMOTE_JSON="$STAGE_DIR/github-output-log-before.json"
BASE_LOG="$STAGE_DIR/output-log-before.txt"
OUTPUT_LOG="$STAGE_DIR/output.log"
RUN_LOG="$STAGE_DIR/stage29c-run.log"
PAYLOAD="$STAGE_DIR/github-output-log.json"
UPLOAD_RESPONSE="$STAGE_DIR/github-upload-response.json"

mkdir -p "$STAGE_DIR"
command -v gh >/dev/null 2>&1 || fail "GitHub CLI is missing."
command -v curl >/dev/null 2>&1 || fail "curl is missing."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run gh auth login."

# Read the canonical Development log and preserve its entire history.
gh api "$API_PATH" > "$REMOTE_JSON" || fail "Cannot download the current GitHub Development/output.log."
python3 - "$REMOTE_JSON" "$BASE_LOG" <<'PY'
import base64, json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
data = base64.b64decode(doc.get("content", ""), validate=False)
if not data:
    raise SystemExit("Remote Development/output.log is empty; refusing to overwrite.")
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
cp "$BASE_LOG" "$OUTPUT_LOG"
: > "$RUN_LOG"

# The run itself goes into a completed file first. Only after it exits will
# that file be appended and sent. No process-substitution tee race is possible.
exec 3>&1 4>&2
exec >>"$RUN_LOG" 2>&1

finish() {
    local rc=$?
    trap - EXIT
    set +e
    exec 1>&3 2>&4

    cat "$RUN_LOG" >> "$OUTPUT_LOG"
    cat "$RUN_LOG"

    echo
    echo "STAGE29C_LOG_BYTES: $(wc -c < "$OUTPUT_LOG" | tr -d ' ')"
    echo "GITHUB_DESTINATION: Development/output.log"

    local token remote_sha
    token="$(gh auth token 2>/dev/null)"
    remote_sha="$(gh api "$API_PATH" --jq '.sha' 2>/dev/null)"
    if [[ -z "$token" || -z "$remote_sha" ]]; then
        echo "GITHUB_UPLOAD_STATUS: FAILED — token or current file SHA unavailable."
        [[ "$rc" -ne 0 ]] || rc=30
    else
        python3 - "$OUTPUT_LOG" "$remote_sha" "$PAYLOAD" <<'PY'
import base64, json, pathlib, sys
log_path, sha, out_path = sys.argv[1:4]
blob = pathlib.Path(log_path).read_bytes()
if len(blob) < 100000:
    raise SystemExit("Refusing to upload unexpectedly small output.log.")
payload = {
    "message": "Stage29c native target build result (v3 synchronous uploader)",
    "content": base64.b64encode(blob).decode("ascii"),
    "sha": sha,
}
pathlib.Path(out_path).write_text(json.dumps(payload), encoding="utf-8")
PY
        if [[ $? -ne 0 ]]; then
            echo "GITHUB_UPLOAD_STATUS: FAILED — payload generation failed."
            [[ "$rc" -ne 0 ]] || rc=31
        else
            curl -sS --fail-with-body \
                -X PUT "$API_URL" \
                -H "Accept: application/vnd.github+json" \
                -H "Authorization: Bearer $token" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                -H "Content-Type: application/json" \
                --data-binary "@$PAYLOAD" \
                -o "$UPLOAD_RESPONSE"
            local put_rc=$?
            if [[ "$put_rc" -ne 0 ]]; then
                echo "GITHUB_UPLOAD_STATUS: FAILED — GitHub Contents API PUT returned $put_rc."
                [[ "$rc" -ne 0 ]] || rc=32
            else
                local put_sha read_sha commit_sha
                put_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["content"]["sha"])' "$UPLOAD_RESPONSE" 2>/dev/null)"
                commit_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"]["sha"])' "$UPLOAD_RESPONSE" 2>/dev/null)"
                read_sha="$(gh api "$API_PATH" --jq '.sha' 2>/dev/null)"
                if [[ -n "$put_sha" && "$put_sha" == "$read_sha" ]]; then
                    echo "GITHUB_UPLOAD_STATUS: SUCCESS — blob SHA verified by GitHub read-back."
                    echo "GITHUB_COMMIT: $commit_sha"
                    echo "GITHUB_BLOB_SHA: $read_sha"
                else
                    echo "GITHUB_UPLOAD_STATUS: FAILED — GitHub read-back SHA mismatch."
                    echo "PUT_BLOB_SHA: $put_sha"
                    echo "READ_BACK_SHA: $read_sha"
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
BUILD_RC=0
VERIFY_RC=0

echo
echo "RTL88WiFi Stage29c-v3 — native target actual compile and link"
echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "PROJECT: $PROJECT"
echo "DRIVER: $DRIVER"
echo "STAGE_DIR: $STAGE_DIR"
echo "HOST: macOS $OS_VERSION / $OS_BUILD / $ARCH"
echo "SCOPE: force-build and link only rtl88wifi-native."
echo "LEGACY_TARGET: NOT INVOKED"
echo "INSTALL: NOT RUN"
echo "LOAD: NOT RUN"
echo "OPENCORE_CHANGE: NONE"
echo "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED"

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
        echo "ERROR: Native plist contains IO80211FamilyLegacy."; BUILD_RC=16
    fi
fi

if [[ "$BUILD_RC" -eq 0 ]]; then
    echo
    echo "========== REMOVE EXPERIMENTAL NATIVE OUTPUT ONLY =========="
    rm -rf "$NATIVE_OUT"
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
        echo "ERROR: Native output Info.plist was not staged."; VERIFY_RC=21
    elif [[ ! -f "$NATIVE_BIN" ]]; then
        echo "ERROR: Native executable missing."; VERIFY_RC=22
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
            echo "ERROR: Built bundle contains IO80211FamilyLegacy."; VERIFY_RC=28
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
    echo "NEXT_GATE: inspect native Mach-O symbols and meta-class registration; do not install/load."
else
    echo "NATIVE_ACTUAL_BUILD: FAIL"
    echo "NATIVE_BUILD_EXIT: $BUILD_RC"
    echo "NATIVE_BUNDLE_VERIFY_EXIT: $VERIFY_RC"
    echo "NEXT_GATE: fix build or bundle validation before proceeding."
fi
echo "LEGACY_TARGET: NOT BUILT OR MODIFIED"
echo "INSTALL: NOT RUN"
echo "LOAD: NOT RUN"
echo "OPENCORE_CHANGE: NONE"
echo "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED"
