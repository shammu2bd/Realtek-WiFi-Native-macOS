#!/bin/bash
set -u
set -o pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
API_PATH="repos/$REPO/contents/Development/output.log"
PROJECT_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"

fail() { echo "ERROR: $*" >&2; exit 2; }

find_project() {
    local candidate="${PROJECT_DIR:-}"
    local found=""

    if [[ -n "$candidate" ]]; then
        if [[ -f "$candidate/driver/RTL88WiFi/Makefile" ]]; then
            (cd "$candidate" && pwd -P); return 0
        fi
        if [[ -f "$candidate/Makefile" && -d "$candidate/src/kext" ]]; then
            (cd "$candidate/../.." && pwd -P); return 0
        fi
        echo "WARNING: Ignoring stale/invalid PROJECT_DIR: $candidate" >&2
    fi

    if [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then
        (cd "$PWD" && pwd -P); return 0
    fi
    if [[ -f "$PWD/Makefile" && -d "$PWD/src/kext" ]]; then
        (cd "$PWD/../.." && pwd -P); return 0
    fi

    local expected="$HOME/Downloads/$PROJECT_NAME"
    if [[ -f "$expected/driver/RTL88WiFi/Makefile" ]]; then
        (cd "$expected" && pwd -P); return 0
    fi

    if [[ -d "$HOME/Downloads" ]]; then
        found="$(find "$HOME/Downloads" -maxdepth 12 -type f -path '*/driver/RTL88WiFi/Makefile' -print -quit 2>/dev/null || true)"
    fi
    if [[ -n "$found" ]]; then
        (cd "$(dirname "$found")/../.." && pwd -P); return 0
    fi

    echo "PROJECT_DISCOVERY_DIAGNOSTIC: Stage26 driver Makefile not found." >&2
    echo "HOME=$HOME" >&2
    echo "PWD=$PWD" >&2
    echo "PROJECT_DIR=${candidate:-<unset>}" >&2
    find "$HOME/Downloads" -maxdepth 6 -type d -name 'RTL88WiFi*' -print >&2 2>/dev/null || true
    fail "Cannot locate Stage26 source under ~/Downloads. Extract the Stage26 source package or set PROJECT_DIR."
}

PROJECT="$(find_project)" || exit 2
DRIVER="$PROJECT/driver/RTL88WiFi"
MAKEFILE="$DRIVER/Makefile"
NATIVE_TEMPLATE="$DRIVER/RTL88WiFiNative.kext"
NATIVE_OUT="$DRIVER/build/out/RTL88WiFiNative.kext"
NATIVE_BIN="$NATIVE_OUT/Contents/MacOS/RTL88WiFiNative"
LOG="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage29c-native-link-build-v5-$STAMP"
REMOTE_JSON="$STAGE_DIR/github-output-log-before.json"
BASE_LOG="$STAGE_DIR/output-log-before.txt"
PAYLOAD="$STAGE_DIR/github-output-log-payload.json"
RESPONSE="$STAGE_DIR/github-upload-response.json"

mkdir -p "$STAGE_DIR" || fail "Cannot create Stage29c-v5 work directory."
command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is required."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run gh auth login once."

# Fetch the canonical Development log. This runner can resume even if the
# project-root local log was deleted.
gh api "$API_PATH" > "$REMOTE_JSON" || fail "GitHub Development/output.log does not exist or cannot be read."
python3 - "$REMOTE_JSON" "$BASE_LOG" <<'PY'
import base64, json, pathlib, sys
source, destination = sys.argv[1:3]
doc = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
data = base64.b64decode(doc.get("content", ""), validate=False)
if len(data) < 500:
    raise SystemExit("Remote Development/output.log is unexpectedly short; refusing to overwrite it.")
pathlib.Path(destination).write_bytes(data)
PY
cp "$BASE_LOG" "$LOG" || fail "Could not initialize project output.log from GitHub."

OS_VERSION="$(sw_vers -productVersion)"
OS_BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
BUILD_RC=0
VERIFY_RC=0

# Disable errexit during build/report so failures are written and uploaded.
set +e
{
    echo
    echo "RTL88WiFi Stage29c-v5 — native target actual compile and link"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "PROJECT: $PROJECT"
    echo "DRIVER: $DRIVER"
    echo "STAGE_DIR: $STAGE_DIR"
    echo "HOST: macOS $OS_VERSION / $OS_BUILD / $ARCH"
    echo "SCOPE: actual force-build and link of rtl88wifi-native only."
    echo "LOG_MODE: append to canonical GitHub log; JSON payload uploaded by file path."
    echo "GITHUB_DESTINATION: Development/output.log"
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
        echo "ERROR: Makefile missing: $MAKEFILE"
        BUILD_RC=11
    fi
    if [[ "$BUILD_RC" -eq 0 && ! -f "$NATIVE_TEMPLATE/Contents/Info.plist" ]]; then
        echo "ERROR: Native Info.plist missing: $NATIVE_TEMPLATE/Contents/Info.plist"
        BUILD_RC=12
    fi
    if [[ "$BUILD_RC" -eq 0 ]] && ! grep -Eq '^[[:space:]]*rtl88wifi-native:' "$MAKEFILE"; then
        echo "ERROR: rtl88wifi-native target missing from Makefile."
        BUILD_RC=13
    fi

    if [[ "$BUILD_RC" -eq 0 ]]; then
        /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries:com.apple.iokit.IO80211Family' "$NATIVE_TEMPLATE/Contents/Info.plist" >/dev/null 2>&1 || BUILD_RC=14
        /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries:com.apple.iokit.IOSkywalkFamily' "$NATIVE_TEMPLATE/Contents/Info.plist" >/dev/null 2>&1 || BUILD_RC=15
        if /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries:com.apple.iokit.IO80211FamilyLegacy' "$NATIVE_TEMPLATE/Contents/Info.plist" >/dev/null 2>&1; then
            echo "ERROR: Native plist contains IO80211FamilyLegacy."
            BUILD_RC=16
        fi
    fi

    if [[ "$BUILD_RC" -eq 0 ]]; then
        echo
        echo "========== ACTUAL NATIVE BUILD =========="
        echo "COMMAND: make -B -j1 rtl88wifi-native"
        (cd "$DRIVER" && make -B -j1 rtl88wifi-native)
        BUILD_RC=$?
        echo "NATIVE_BUILD_EXIT: $BUILD_RC"
    else
        echo "NATIVE_BUILD_SKIPPED_PREFLIGHT_RC: $BUILD_RC"
    fi

    if [[ "$BUILD_RC" -eq 0 ]]; then
        echo
        echo "========== NATIVE BUNDLE VALIDATION =========="
        if [[ ! -f "$NATIVE_OUT/Contents/Info.plist" ]]; then
            echo "ERROR: Native output Info.plist missing."
            VERIFY_RC=21
        elif [[ ! -f "$NATIVE_BIN" ]]; then
            echo "ERROR: Native executable missing: $NATIVE_BIN"
            VERIFY_RC=22
        else
            plutil -lint "$NATIVE_OUT/Contents/Info.plist"
            [[ $? -eq 0 ]] || VERIFY_RC=23

            EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$NATIVE_OUT/Contents/Info.plist" 2>&1)"
            BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NATIVE_OUT/Contents/Info.plist" 2>&1)"
            echo "BUNDLE_EXECUTABLE: $EXEC_NAME"
            echo "BUNDLE_IDENTIFIER: $BUNDLE_ID"
            [[ "$EXEC_NAME" == "RTL88WiFiNative" ]] || VERIFY_RC=24
            [[ "$BUNDLE_ID" == "io.github.x1ren41l.RTL88WiFi" ]] || VERIFY_RC=25

            echo "NATIVE_BINARY_FILE:"
            file "$NATIVE_BIN"
            echo "NATIVE_ARCHITECTURES:"
            ARCHS="$(lipo -archs "$NATIVE_BIN" 2>&1)"
            echo "$ARCHS"
            [[ " $ARCHS " == *" x86_64 "* ]] || VERIFY_RC=26

            echo "NATIVE_MACH_HEADER:"
            otool -hv "$NATIVE_BIN"
            otool -hv "$NATIVE_BIN" | grep -q 'KEXTBUNDLE' || VERIFY_RC=27

            echo "NATIVE_BINARY_SHA256:"
            shasum -a 256 "$NATIVE_BIN"

            echo "NATIVE_DEPENDENCIES:"
            /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries' "$NATIVE_OUT/Contents/Info.plist"
            if /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries:com.apple.iokit.IO80211FamilyLegacy' "$NATIVE_OUT/Contents/Info.plist" >/dev/null 2>&1; then
                echo "ERROR: Built native bundle contains IO80211FamilyLegacy."
                VERIFY_RC=28
            fi

            echo "NATIVE_PERSONALITY:"
            /usr/libexec/PlistBuddy -c 'Print :IOKitPersonalities' "$NATIVE_OUT/Contents/Info.plist"
        fi
        echo "NATIVE_POSTBUILD_VERIFY_EXIT: $VERIFY_RC"
    else
        echo "NATIVE_POSTBUILD_VERIFY: SKIPPED_BUILD_FAILED"
    fi

    echo
    echo "========== STAGE29C-V5 RESULT =========="
    if [[ "$BUILD_RC" -eq 0 && "$VERIFY_RC" -eq 0 ]]; then
        echo "NATIVE_ACTUAL_BUILD: PASS"
        echo "NATIVE_BUNDLE_VALIDATION: PASS"
        echo "NEXT_GATE: inspect Mach-O symbols and native meta-class/registration metadata; do not install/load."
    else
        echo "NATIVE_ACTUAL_BUILD: FAIL"
        echo "NATIVE_BUILD_EXIT: $BUILD_RC"
        echo "NATIVE_BUNDLE_VERIFY_EXIT: $VERIFY_RC"
        echo "NEXT_GATE: resolve build or bundle validation errors before further integration."
    fi
    echo "LEGACY_TARGET: NOT BUILT OR MODIFIED"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "OPENCORE_CHANGE: NONE"
    echo "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED"
} >> "$LOG" 2>&1
REPORT_RC=$?
set -e

if [[ "$REPORT_RC" -ne 0 ]]; then
    echo "WARNING: report append returned $REPORT_RC; continuing to upload the report." >&2
fi

# Write the full Contents API request to disk. Only the small filename is
# passed on the command line; no oversized base64 argument is used.
REMOTE_SHA="$(gh api "$API_PATH" --jq '.sha')" || fail "Unable to read current GitHub output.log SHA."
python3 - "$LOG" "$REMOTE_SHA" "$PAYLOAD" <<'PY'
import base64, json, pathlib, sys
log_path, sha, payload_path = sys.argv[1:4]
data = pathlib.Path(log_path).read_bytes()
if len(data) < 500:
    raise SystemExit("Refusing to upload an empty or unexpectedly short output.log.")
payload = {
    "message": "Stage29c-v5 native target build and bundle verification",
    "content": base64.b64encode(data).decode("ascii"),
    "sha": sha,
}
pathlib.Path(payload_path).write_text(json.dumps(payload), encoding="utf-8")
print("LOG_BYTES_TO_UPLOAD: {}".format(len(data)))
print("JSON_PAYLOAD_BYTES: {}".format(pathlib.Path(payload_path).stat().st_size))
PY
PREP_RC=$?
[[ "$PREP_RC" -eq 0 ]] || fail "Could not prepare GitHub upload JSON."

gh api --method PUT "$API_PATH" --input "$PAYLOAD" > "$RESPONSE" || fail "GitHub output.log upload failed."
PUT_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["content"]["sha"])' "$RESPONSE")"
COMMIT_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"]["sha"])' "$RESPONSE")"
READ_SHA="$(gh api "$API_PATH" --jq '.sha')" || fail "GitHub read-back failed."
[[ -n "$PUT_SHA" && "$PUT_SHA" == "$READ_SHA" ]] || fail "GitHub blob SHA mismatch after upload."

echo "GITHUB_UPLOAD_STATUS: SUCCESS — verified Development/output.log"
echo "GITHUB_COMMIT: $COMMIT_SHA"
echo "GITHUB_BLOB_SHA: $READ_SHA"
echo "STAGE29C_BUILD_EXIT: $BUILD_RC"
echo "STAGE29C_VERIFY_EXIT: $VERIFY_RC"

if [[ "$BUILD_RC" -ne 0 ]]; then exit "$BUILD_RC"; fi
if [[ "$VERIFY_RC" -ne 0 ]]; then exit "$VERIFY_RC"; fi
