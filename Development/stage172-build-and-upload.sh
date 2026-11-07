#!/bin/bash
# Stage172 target-Mac build runner with automatic, verified GitHub log upload.
# Builds only rtl88wifi-native. Never signs, installs, loads, or edits OpenCore.
set -uo pipefail
umask 077

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BRANCH="work/stage172-controller-native-workqueue"
PROJECT="${PROJECT_DIR:-$HOME/Developer/Stage121-native-controller-attachment-20261106-202552}"
DEVELOPER_DIR_FIXED="/Applications/Xcode_16.4.app/Contents/Developer"
KEYCHAIN_SERVICE="realtek-wifi-native-macos-upload"
CHUNK_BYTES=$((600 * 1024))

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

need python3
need make
need curl
need sw_vers
need shasum
need plutil
need file
need lipo

DRIVER="$PROJECT/driver/RTL88WiFi"
MAKEFILE="$DRIVER/Makefile"
TEMPLATE="$DRIVER/RTL88WiFiNative.kext"
TEST="$PROJECT/tests/test-wcl-controller-native-workqueue-stage172.py"

[ -d "$PROJECT" ] || die "Project not found: $PROJECT (set PROJECT_DIR if it moved)."
[ -f "$MAKEFILE" ] || die "Native Makefile missing: $MAKEFILE"
[ -f "$TEMPLATE/Contents/Info.plist" ] || die "Native KEXT template is missing."
grep -Eq '^[[:space:]]*rtl88wifi-native:' "$MAKEFILE" || die "rtl88wifi-native target is missing."

if [ -d "$DEVELOPER_DIR_FIXED" ]; then
  export DEVELOPER_DIR="$DEVELOPER_DIR_FIXED"
fi
xcode-select -p >/dev/null 2>&1 || die "Xcode command line developer directory is unavailable."
xcrun --show-sdk-path >/dev/null 2>&1 || die "Xcode macOS SDK is unavailable."

OS_VERSION="$(sw_vers -productVersion)"
OS_BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
UUID_PART="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -c1-12)"
[ -n "$UUID_PART" ] || UUID_PART="$$"
RUN_ID="stage172-$STAMP-$UUID_PART"
RUN_DIR="$PROJECT/Development/Logs/stage172/$RUN_ID"
BUILD_LOG="$RUN_DIR/output.log"
SUMMARY="$RUN_DIR/summary.txt"
mkdir -p "$RUN_DIR" || die "Cannot create run log directory."

# Find an already configured token without displaying it. Prompt once and save
# it only in macOS Keychain if neither gh nor the environment has credentials.
GH_UPLOAD_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$GH_UPLOAD_TOKEN" ] && command -v gh >/dev/null 2>&1; then
  GH_UPLOAD_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ -z "$GH_UPLOAD_TOKEN" ] && command -v security >/dev/null 2>&1; then
  GH_UPLOAD_TOKEN="$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
fi
if [ -z "$GH_UPLOAD_TOKEN" ]; then
  printf '%s\n' "GitHub needs a token with Contents: Read and write for $REPO."
  printf '%s' "Paste token (hidden; it will be saved in macOS Keychain): "
  IFS= read -r -s GH_UPLOAD_TOKEN < /dev/tty || true
  printf '\n'
  [ -n "$GH_UPLOAD_TOKEN" ] || die "No GitHub token supplied."
  command -v security >/dev/null 2>&1 || die "macOS Keychain is unavailable; token was not saved."
  security add-generic-password -U -a "$USER" -s "$KEYCHAIN_SERVICE" -w "$GH_UPLOAD_TOKEN" >/dev/null 2>&1 || die "Could not save GitHub token in Keychain."
fi

# Everything from source tests through validation is captured, including stderr.
set +e
(
  echo "========== STAGE172 TARGET-MAC BUILD =========="
  echo "RUN_ID: $RUN_ID"
  echo "DATE_UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "PROJECT: $PROJECT"
  echo "BRANCH_FOR_UPLOAD: $BRANCH"
  echo "HOST: macOS $OS_VERSION / $OS_BUILD / $ARCH"
  echo "XCODE: $DEVELOPER_DIR"
  echo "SDK: $(xcrun --show-sdk-path)"
  echo "BUILD_TARGET: rtl88wifi-native"
  echo "INSTALL: NOT_RUN"
  echo "LOAD: NOT_RUN"
  echo "SIGNING: NOT_RUN"
  echo "OPENCORE_EFI_SIP_NVRAM: UNCHANGED"
  echo

  TEST_RC=0
  if [ -f "$TEST" ]; then
    echo "========== STAGE172 SOURCE CONTRACT =========="
    python3 "$TEST"
    TEST_RC=$?
    echo "STAGE172_SOURCE_CONTRACT_EXIT: $TEST_RC"
  else
    echo "STAGE172_SOURCE_CONTRACT: NOT_RERUN (test file not present in local checkout)"
  fi

  BUILD_RC=90
  VERIFY_RC=90
  if [ "$OS_VERSION" != "15.8.1" ] || [ "$OS_BUILD" != "24H32" ] || [ "$ARCH" != "x86_64" ]; then
    echo "BUILD_SKIPPED: expected macOS 15.8.1 / 24H32 / x86_64 target."
    BUILD_RC=91
  elif [ "$TEST_RC" -ne 0 ]; then
    echo "BUILD_SKIPPED: Stage172 source contract test did not pass."
    BUILD_RC=92
  else
    echo
    echo "========== FULL NATIVE KEXT BUILD =========="
    echo "COMMAND: make -B -j1 -C '$DRIVER' rtl88wifi-native"
    make -B -j1 -C "$DRIVER" rtl88wifi-native
    BUILD_RC=$?
    echo "STAGE172_NATIVE_BUILD_EXIT: $BUILD_RC"
  fi

  OUT="$DRIVER/build/out/RTL88WiFiNative.kext"
  BIN="$OUT/Contents/MacOS/RTL88WiFiNative"
  if [ "$BUILD_RC" -eq 0 ]; then
    echo
    echo "========== NATIVE BUNDLE VALIDATION =========="
    if [ ! -f "$OUT/Contents/Info.plist" ] || [ ! -f "$BIN" ]; then
      echo "ERROR: Expected native bundle or executable is missing."
      VERIFY_RC=21
    else
      plutil -lint "$OUT/Contents/Info.plist"
      PLIST_RC=$?
      file "$BIN"
      lipo "$BIN" -verify_arch x86_64
      ARCH_RC=$?
      echo "NATIVE_BINARY_SHA256:"
      shasum -a 256 "$BIN"
      echo "NATIVE_BUNDLE_DEPENDENCIES:"
      /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries' "$OUT/Contents/Info.plist"
      echo "NATIVE_BUNDLE_ID:"
      /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OUT/Contents/Info.plist"
      if /usr/libexec/PlistBuddy -c 'Print :OSBundleLibraries:com.apple.iokit.IO80211FamilyLegacy' "$OUT/Contents/Info.plist" >/dev/null 2>&1; then
        echo "ERROR: IO80211FamilyLegacy is unexpectedly present."
        VERIFY_RC=22
      elif [ "$PLIST_RC" -eq 0 ] && [ "$ARCH_RC" -eq 0 ]; then
        VERIFY_RC=0
      else
        VERIFY_RC=23
      fi
    fi
  else
    echo "NATIVE_BUNDLE_VALIDATION: SKIPPED_BUILD_FAILED"
  fi

  echo
  echo "========== STAGE172 RESULT =========="
  echo "STAGE172_SOURCE_CONTRACT_EXIT: $TEST_RC"
  echo "STAGE172_NATIVE_BUILD_EXIT: $BUILD_RC"
  echo "STAGE172_BUNDLE_VALIDATION_EXIT: $VERIFY_RC"
  if [ "$BUILD_RC" -eq 0 ] && [ "$VERIFY_RC" -eq 0 ]; then
    echo "STAGE172_RESULT: NATIVE_BUILD_AND_BUNDLE_VALIDATION_PASS"
  else
    echo "STAGE172_RESULT: BLOCKED_OR_FAILED"
  fi
  echo "INSTALL: NOT_RUN"
  echo "LOAD: NOT_RUN"
  echo "SIGNING: NOT_RUN"
  echo "OPENCORE_EFI_SIP_NVRAM: UNCHANGED"
  echo "END_UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  FINAL_RC="$BUILD_RC"
  if [ "$BUILD_RC" -eq 0 ] && [ "$VERIFY_RC" -ne 0 ]; then FINAL_RC="$VERIFY_RC"; fi
  echo "STAGE172_FINAL_EXIT: $FINAL_RC"
  exit "$FINAL_RC"
) 2>&1 | tee "$BUILD_LOG"
PIPE_RC=${PIPESTATUS[0]}
set -e

LOG_BYTES="$(wc -c < "$BUILD_LOG" | tr -d ' ')"
LOG_SHA="$(shasum -a 256 "$BUILD_LOG" | awk '{print $1}')"
{
  echo "RUN_ID: $RUN_ID"
  echo "DATE_UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "HOST: macOS $OS_VERSION / $OS_BUILD / $ARCH"
  echo "BUILD_TARGET: rtl88wifi-native"
  echo "PIPELINE_EXIT: $PIPE_RC"
  echo "BUILD_LOG_BYTES: $LOG_BYTES"
  echo "BUILD_LOG_SHA256: $LOG_SHA"
  echo "LOCAL_LOG: $BUILD_LOG"
  echo "INSTALL: NOT_RUN"
  echo "LOAD: NOT_RUN"
  echo "SIGNING: NOT_RUN"
  echo "OPENCORE_EFI_SIP_NVRAM: UNCHANGED"
} > "$SUMMARY"

# Upload the detailed output in safe-size chunks, verify each GitHub write, and
# append a short searchable record to Development/Logs/output.log.
export GH_UPLOAD_TOKEN REPO BRANCH RUN_ID RUN_DIR SUMMARY BUILD_LOG CHUNK_BYTES LOG_BYTES LOG_SHA PIPE_RC
set +e
python3 <<'PY'
import base64
import hashlib
import json
import os
import pathlib
import urllib.error
import urllib.parse
import urllib.request

repo = os.environ["REPO"]
branch = os.environ["BRANCH"]
token = os.environ["GH_UPLOAD_TOKEN"]
run_id = os.environ["RUN_ID"]
run_dir = pathlib.Path(os.environ["RUN_DIR"])
summary_path = pathlib.Path(os.environ["SUMMARY"])
log_path = pathlib.Path(os.environ["BUILD_LOG"])
chunk_limit = int(os.environ["CHUNK_BYTES"])
api = "https://api.github.com/repos/" + repo
headers = {
    "Accept": "application/vnd.github+json",
    "Authorization": "Bearer " + token,
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "RTL88WiFi-Stage172-Log-Uploader",
}

def api_json(method, url, payload=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=90) as response:
            raw = response.read()
            return None if not raw else json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise RuntimeError("GitHub API HTTP {}: {}".format(exc.code, detail[:1200]))

def contents_url(path):
    return api + "/contents/" + urllib.parse.quote(path, safe="/")

def get_content(path):
    url = contents_url(path) + "?ref=" + urllib.parse.quote(branch, safe="")
    try:
        return api_json("GET", url)
    except RuntimeError as exc:
        if "HTTP 404:" in str(exc):
            return None
        raise

def put_content(path, data, message):
    old = get_content(path)
    payload = {
        "message": message,
        "content": base64.b64encode(data).decode("ascii"),
        "branch": branch,
    }
    if old is not None:
        payload["sha"] = old["sha"]
    result = api_json("PUT", contents_url(path), payload)
    expected_sha = result["content"]["sha"]
    check = get_content(path)
    if check is None or check.get("sha") != expected_sha:
        raise RuntimeError("Read-back SHA verification failed for " + path)
    return expected_sha

raw = log_path.read_bytes()
log_sha256 = hashlib.sha256(raw).hexdigest()
remote_dir = "Development/Logs/stage172/" + run_id
uploaded = []

if len(raw) <= chunk_limit:
    path = remote_dir + "/output.log"
    put_content(path, raw, "Upload Stage172 target-Mac build output " + run_id)
    uploaded.append(path)
else:
    total = (len(raw) + chunk_limit - 1) // chunk_limit
    for i in range(total):
        path = remote_dir + "/output.log.part-{:03d}-of-{:03d}.txt".format(i + 1, total)
        start = i * chunk_limit
        put_content(path, raw[start:start + chunk_limit], "Upload Stage172 output chunk {} for {}".format(i + 1, run_id))
        uploaded.append(path)

summary_lines = summary_path.read_text(encoding="utf-8").rstrip().splitlines()
summary_lines += [
    "BUILD_LOG_SHA256: " + log_sha256,
    "BUILD_LOG_BYTES: " + str(len(raw)),
    "REMOTE_OUTPUT_FILES:",
]
summary_lines += ["- " + p for p in uploaded]
summary_data = ("\n".join(summary_lines) + "\n").encode("utf-8")
summary_path_remote = remote_dir + "/summary.txt"
put_content(summary_path_remote, summary_data, "Upload Stage172 build summary " + run_id)

# Keep the convenience index small; complete compiler output remains in its
# unique run folder above. Rotate the pointer file when it approaches 800 KiB.
index_path = "Development/Logs/output.log"
existing = get_content(index_path)
if existing is None:
    index_data = b""
else:
    index_data = base64.b64decode(existing.get("content", ""), validate=False)
record = (
    "\n========== STAGE172 MAC BUILD ==========\n"
    "RUN_ID: " + run_id + "\n"
    "BUILD_EXIT: " + os.environ["PIPE_RC"] + "\n"
    "LOG_BYTES: " + str(len(raw)) + "\n"
    "LOG_SHA256: " + log_sha256 + "\n"
    "RUN_FOLDER: " + remote_dir + "/\n"
    "SUMMARY: " + summary_path_remote + "\n"
    "INSTALL: NOT_RUN | LOAD: NOT_RUN | SIGNING: NOT_RUN\n"
    "========================================\n"
).encode("utf-8")
if len(index_data) + len(record) > 800 * 1024:
    archive_path = "Development/Logs/output-index-archive-" + run_id + ".log"
    put_content(archive_path, index_data, "Archive Stage172 output index before rotation " + run_id)
    index_data = b""
put_content(index_path, index_data + record, "Update Stage172 output index " + run_id)

print("GITHUB_UPLOAD: PASS")
print("GITHUB_BRANCH: " + branch)
print("GITHUB_INDEX: https://github.com/" + repo + "/blob/" + branch + "/" + index_path)
print("GITHUB_RUN_FOLDER: https://github.com/" + repo + "/tree/" + branch + "/" + remote_dir)
for path in uploaded:
    print("GITHUB_OUTPUT_FILE: https://github.com/" + repo + "/blob/" + branch + "/" + path)
print("GITHUB_SUMMARY: https://github.com/" + repo + "/blob/" + branch + "/" + summary_path_remote)
PY
UPLOAD_RC=$?
set -e
unset GH_UPLOAD_TOKEN

if [ "$UPLOAD_RC" -ne 0 ]; then
  printf 'GITHUB_UPLOAD: FAILED (exit %s)\n' "$UPLOAD_RC" | tee -a "$SUMMARY"
  printf 'LOCAL_OUTPUT_RETAINED: %s\n' "$RUN_DIR"
  exit 90
fi

printf '\nLOCAL_OUTPUT: %s\n' "$BUILD_LOG"
printf 'LOCAL_SUMMARY: %s\n' "$SUMMARY"
printf 'STAGE172_BUILD_EXIT: %s\n' "$PIPE_RC"
printf 'GITHUB_UPLOAD: PASS (verified)\n'
exit "$PIPE_RC"
