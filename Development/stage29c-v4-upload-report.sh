#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
API_PATH="repos/$REPO/contents/Development/output.log"
PROJECT_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"

fail() { echo "ERROR: $*" >&2; exit 2; }

# The previous Stage29c-v4 runner reached its uploader only after appending
# the build result. This helper uploads that existing local log; it DOES NOT
# rebuild, clean, install or load the kext.
PROJECT="$HOME/Downloads/$PROJECT_NAME"
if [[ ! -f "$PROJECT/driver/RTL88WiFi/Makefile" ]]; then
    FOUND="$(find "$HOME/Downloads" -maxdepth 12 -type f -path '*/driver/RTL88WiFi/Makefile' -print -quit 2>/dev/null || true)"
    [[ -n "$FOUND" ]] || fail "Stage26 source tree not found under ~/Downloads."
    PROJECT="$(cd "$(dirname "$FOUND")/../.." && pwd -P)"
fi
PROJECT="$(cd "$PROJECT" && pwd -P)"
LOG="$PROJECT/output.log"
DRIVER="$PROJECT/driver/RTL88WiFi"
NATIVE_BIN="$DRIVER/build/out/RTL88WiFiNative.kext/Contents/MacOS/RTL88WiFiNative"

[[ -s "$LOG" ]] || fail "Project output.log is missing or empty: $LOG"
grep -q 'STAGE29C-V4 RESULT' "$LOG" || fail "Local output.log does not contain the Stage29c-v4 result; refusing to upload unrelated data."
command -v gh >/dev/null 2>&1 || fail "GitHub CLI is missing."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run gh auth login."

STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage29c-v4-log-recovery-$STAMP"
mkdir -p "$STAGE_DIR"
PAYLOAD="$STAGE_DIR/github-output-log.json"
RESPONSE="$STAGE_DIR/github-upload-response.json"

echo "PROJECT: $PROJECT"
echo "LOCAL_LOG: $LOG"
echo "LOCAL_LOG_BYTES: $(wc -c < "$LOG" | tr -d ' ')"
echo "NATIVE_EXECUTABLE_PRESENT: $([[ -f "$NATIVE_BIN" ]] && echo YES || echo NO)"
echo "ACTION: upload existing Stage29c-v4 log only; no build will run."

REMOTE_SHA="$(gh api "$API_PATH" --jq '.sha')"
[[ -n "$REMOTE_SHA" ]] || fail "Could not read current GitHub Development/output.log SHA."

# JSON is written to a file; only its short path is passed to gh. This avoids
# macOS ARG_MAX failures from a huge -f content=<base64> argument.
python3 - "$LOG" "$REMOTE_SHA" "$PAYLOAD" <<'PY'
import base64
import json
import pathlib
import sys
log_path, remote_sha, payload_path = sys.argv[1:4]
data = pathlib.Path(log_path).read_bytes()
if len(data) < 100000:
    raise SystemExit("Refusing upload: local development log is unexpectedly small.")
payload = {
    "message": "Recover Stage29c-v4 native build report upload",
    "content": base64.b64encode(data).decode("ascii"),
    "sha": remote_sha,
}
pathlib.Path(payload_path).write_text(json.dumps(payload), encoding="utf-8")
print("UPLOAD_PAYLOAD_BYTES: {}".format(pathlib.Path(payload_path).stat().st_size))
PY

gh api --method PUT "$API_PATH" --input "$PAYLOAD" > "$RESPONSE"

PUT_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["content"]["sha"])' "$RESPONSE")"
COMMIT_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"]["sha"])' "$RESPONSE")"
READ_SHA="$(gh api "$API_PATH" --jq '.sha')"
[[ -n "$PUT_SHA" && "$PUT_SHA" == "$READ_SHA" ]] || fail "GitHub read-back SHA did not match uploaded content."

echo "GITHUB_UPLOAD_STATUS: SUCCESS"
echo "GITHUB_DESTINATION: Development/output.log"
echo "GITHUB_COMMIT: $COMMIT_SHA"
echo "GITHUB_BLOB_SHA: $READ_SHA"
echo "GITHUB_LOG_BYTES: $(gh api "$API_PATH" --jq '.size')"
echo "BUILD_RERUN: NO"
echo "INSTALL: NOT RUN"
echo "LOAD: NOT RUN"
echo "OPENCORE_CHANGE: NONE"
