#!/bin/bash
# Safe source reconciliation + native build + automatic GitHub log upload.
# No install, load, code-signing, SIP/NVRAM, or OpenCore changes are performed.
set -uo pipefail
umask 077

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BRANCH="main"
SOURCE_COMMIT="c2240b4d89f77314e023473b8c1ccfa042dbb565"
PROJECT="\${PROJECT_DIR:-$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source}"
KEYCHAIN_SERVICE="realtek-wifi-native-macos-upload"
RAW_BASE="https://raw.githubusercontent.com/\${REPO}/\${SOURCE_COMMIT}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

[ -d "$PROJECT" ] || die "Project folder not found: $PROJECT"
[ -d "$PROJECT/driver/RTL88WiFi" ] || die "Missing driver/RTL88WiFi under $PROJECT"
[ -f "$PROJECT/driver/RTL88WiFi/Makefile" ] || die "Missing driver/RTL88WiFi/Makefile"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v make >/dev/null 2>&1 || die "make is required"

# Resolve GitHub authentication without printing or writing the token to a file.
GH_UPLOAD_TOKEN="\${GH_TOKEN:-\${GITHUB_TOKEN:-}}"
if [ -z "$GH_UPLOAD_TOKEN" ] && command -v gh >/dev/null 2>&1; then
  GH_UPLOAD_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ -z "$GH_UPLOAD_TOKEN" ] && command -v security >/dev/null 2>&1; then
  GH_UPLOAD_TOKEN="$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
fi
if [ -z "$GH_UPLOAD_TOKEN" ] && command -v git >/dev/null 2>&1; then
  CREDENTIALS="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null || true)"
  GH_UPLOAD_TOKEN="$(printf '%s\n' "$CREDENTIALS" | sed -n 's/^password=//p' | head -n 1)"
  unset CREDENTIALS
fi
if [ -z "$GH_UPLOAD_TOKEN" ]; then
  printf '%s\n' "No saved GitHub write credential was found."
  printf '%s\n' "Enter a fine-grained GitHub token with Contents: Read and write access to \${REPO}."
  printf '%s' "Token (hidden; saved only in macOS Keychain): "
  IFS= read -r -s GH_UPLOAD_TOKEN < /dev/tty || true
  printf '\n'
  [ -n "$GH_UPLOAD_TOKEN" ] || die "No GitHub token supplied; stopped before changing source or building."
  command -v security >/dev/null 2>&1 || die "macOS security tool unavailable; cannot save the token safely."
  security add-generic-password -U -a "$USER" -s "$KEYCHAIN_SERVICE" -w "$GH_UPLOAD_TOKEN" >/dev/null 2>&1 || die "Could not save token in macOS Keychain."
fi
[ -n "$GH_UPLOAD_TOKEN" ] || die "GitHub authentication is unavailable."

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
UUID_PART="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -c1-12)"
[ -n "$UUID_PART" ] || UUID_PART="$$"
RUN_ID="run-\${STAMP}-\${UUID_PART}"
RUN_DIR="$PROJECT/run log/source-reconciliation/$RUN_ID"
DOWNLOAD_DIR="$RUN_DIR/downloaded"
BACKUP_DIR="$RUN_DIR/backup"
mkdir -p "$DOWNLOAD_DIR" "$BACKUP_DIR" || die "Cannot create project run-log directory."

FILES=(
  "driver/RTL88WiFi/Makefile"
  "tools/generate-sequoia-native-plist.py"
  "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp"
  "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp"
  "driver/rtw88-stable/drivers/net/wireless/realtek/rtw88/mac.c"
  "driver/rtw88-stable/drivers/net/wireless/realtek/rtw88/pci.c"
  "driver/rtw88-stable/drivers/net/wireless/realtek/rtw88/tx.h"
)

printf 'RUN_ID: %s\nPROJECT: %s\nSOURCE_COMMIT: %s\n' "$RUN_ID" "$PROJECT" "$SOURCE_COMMIT" | tee "$RUN_DIR/run-metadata.txt"

# Download every pinned source first. Do not partially replace the tree on a download failure.
for REL in "\${FILES[@]}"; do
  DEST="$DOWNLOAD_DIR/$REL"
  mkdir -p "$(dirname "$DEST")" || die "Cannot create download folder for $REL"
  printf 'Downloading %s\n' "$REL"
  curl --fail --location --silent --show-error --retry 3 "$RAW_BASE/$REL" -o "$DEST" || die "Download failed: $REL"
  [ -s "$DEST" ] || die "Downloaded file is empty: $REL"
done

# Back up the local originals, then apply the seven reconciled files.
for REL in "\${FILES[@]}"; do
  LOCAL="$PROJECT/$REL"
  DOWNLOADED="$DOWNLOAD_DIR/$REL"
  mkdir -p "$(dirname "$LOCAL")" "$(dirname "$BACKUP_DIR/$REL")" || die "Cannot prepare path for $REL"
  if [ -f "$LOCAL" ]; then
    cp -p "$LOCAL" "$BACKUP_DIR/$REL" || die "Backup failed: $REL"
  else
    printf 'Previously absent: %s\n' "$REL" >> "$RUN_DIR/previously-absent.txt"
  fi
  cp "$DOWNLOADED" "$LOCAL" || die "Source update failed: $REL"
done

{
  echo "SOURCE_RECONCILIATION: APPLIED"
  echo "SOURCE_COMMIT: $SOURCE_COMMIT"
  echo "BACKUP_DIR: $BACKUP_DIR"
  echo "BUILD_TARGET: rtl88wifi-native"
  echo "INSTALL: NOT_RUN"
  echo "LOAD: NOT_RUN"
  echo "SIGNING: NOT_RUN"
  echo "OPENCORE_CHANGE: NONE"
  echo
  echo "SHA256 OF SYNCHRONIZED FILES:"
  for REL in "\${FILES[@]}"; do
    shasum -a 256 "$PROJECT/$REL"
  done
} > "$RUN_DIR/source-reconciliation.txt"

BUILD_LOG="$RUN_DIR/native-build.log"
printf 'Starting native build. Full output is captured at:\n%s\n' "$BUILD_LOG"
set +e
(
  cd "$PROJECT/driver/RTL88WiFi" || exit 90
  echo "COMMAND: env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -B -f Makefile rtl88wifi-native"
  echo "START_UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -B -f Makefile rtl88wifi-native
  RESULT=$?
  echo "BUILD_EXIT_CODE: $RESULT"
  echo "END_UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  exit "$RESULT"
) 2>&1 | tee "$BUILD_LOG"
BUILD_STATUS=\${PIPESTATUS[0]}
set -e

if [ "$BUILD_STATUS" -eq 0 ]; then
  BUILD_RESULT="PASS"
else
  BUILD_RESULT="FAIL"
fi

LOG_SHA="$(shasum -a 256 "$BUILD_LOG" | awk '{print $1}')"
LOG_BYTES="$(wc -c < "$BUILD_LOG" | tr -d ' ')"
{
  echo "RTL88WiFi native source reconciliation build"
  echo "RUN_ID: $RUN_ID"
  echo "DATE_UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "PROJECT: $PROJECT"
  echo "SOURCE_COMMIT: $SOURCE_COMMIT"
  echo "BUILD_TARGET: rtl88wifi-native"
  echo "BUILD_RESULT: $BUILD_RESULT"
  echo "BUILD_EXIT_CODE: $BUILD_STATUS"
  echo "BUILD_LOG_BYTES: $LOG_BYTES"
  echo "BUILD_LOG_SHA256: $LOG_SHA"
  echo "SOURCE_RECONCILIATION_RECORD: $RUN_DIR/source-reconciliation.txt"
  echo "INSTALL: NOT_RUN"
  echo "LOAD: NOT_RUN"
  echo "SIGNING: NOT_RUN"
  echo "OPENCORE_CHANGE: NONE"
  echo "RADIO_TEST: NOT_RUN"
  echo "LOCAL_BACKUPS: $BACKUP_DIR"
} > "$RUN_DIR/build-summary.txt"

# Upload logs directly to the repository. Large logs are split into readable text chunks
# below the GitHub Contents API per-file size ceiling; the local original remains intact.
REMOTE_DIR="Development/Logs/source-reconciliation/$RUN_ID"
export GITHUB_UPLOAD_TOKEN="$GH_UPLOAD_TOKEN"
export GITHUB_REPOSITORY="$REPO"
export GITHUB_BRANCH="$BRANCH"
export GITHUB_REMOTE_DIR="$REMOTE_DIR"
export GITHUB_RUN_ID="$RUN_ID"
export GITHUB_BUILD_RESULT="$BUILD_RESULT"
export GITHUB_BUILD_STATUS="$BUILD_STATUS"
export GITHUB_SOURCE_COMMIT="$SOURCE_COMMIT"
python3 - "$BUILD_LOG" "$RUN_DIR/build-summary.txt" "$RUN_DIR/source-reconciliation.txt" <<'PY'
import base64
import hashlib
import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

token = os.environ["GITHUB_UPLOAD_TOKEN"]
repo = os.environ["GITHUB_REPOSITORY"]
branch = os.environ["GITHUB_BRANCH"]
remote_dir = os.environ["GITHUB_REMOTE_DIR"]
run_id = os.environ["GITHUB_RUN_ID"]
api_root = "https://api.github.com/repos/" + repo
headers = {
    "Accept": "application/vnd.github+json",
    "Authorization": "Bearer " + token,
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "RTL88WiFi-RunLog-Uploader",
}

def request_json(method, url, payload=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            raw = response.read()
            return None if not raw else json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise RuntimeError("{} {}: HTTP {} {}".format(method, url, exc.code, detail[:1200]))

def get_file(path):
    quoted = urllib.parse.quote(path, safe="/")
    url = api_root + "/contents/" + quoted + "?ref=" + urllib.parse.quote(branch, safe="")
    try:
        return request_json("GET", url)
    except RuntimeError as exc:
        if "HTTP 404 " in str(exc):
            return None
        raise

def put_bytes(path, data, message):
    quoted = urllib.parse.quote(path, safe="/")
    url = api_root + "/contents/" + quoted
    current = get_file(path)
    payload = {
        "message": message,
        "content": base64.b64encode(data).decode("ascii"),
        "branch": branch,
    }
    if current is not None:
        payload["sha"] = current["sha"]
    request_json("PUT", url, payload)

log_path = pathlib.Path(sys.argv[1])
summary_path = pathlib.Path(sys.argv[2])
source_path = pathlib.Path(sys.argv[3])
log_data = log_path.read_bytes()
summary_data = summary_path.read_bytes()
source_data = source_path.read_bytes()
log_sha = hashlib.sha256(log_data).hexdigest()
remote_log_paths = []

chunk_size = 700 * 1024
if len(log_data) <= chunk_size:
    remote_log_paths.append(remote_dir + "/native-build.log")
    put_bytes(remote_log_paths[-1], log_data, "Upload native build log " + run_id)
else:
    total = (len(log_data) + chunk_size - 1) // chunk_size
    for index in range(total):
        name = "native-build.log.part-{:03d}-of-{:03d}.txt".format(index + 1, total)
        path = remote_dir + "/" + name
        start = index * chunk_size
        put_bytes(path, log_data[start:start + chunk_size], "Upload native build log chunk {} {}".format(index + 1, run_id))
        remote_log_paths.append(path)

index_lines = [
    summary_data.decode("utf-8", "replace").rstrip(),
    "",
    "BUILD_LOG_SHA256: " + log_sha,
    "BUILD_LOG_BYTES: " + str(len(log_data)),
    "SOURCE_RECONCILIATION_FILE: " + remote_dir + "/source-reconciliation.txt",
    "REMOTE_BUILD_LOG_FILES:",
]
index_lines.extend("- " + path for path in remote_log_paths)
index_data = ("\n".join(index_lines) + "\n").encode("utf-8")
put_bytes(remote_dir + "/build-summary.txt", index_data, "Upload native build summary " + run_id)
put_bytes(remote_dir + "/source-reconciliation.txt", source_data, "Upload source reconciliation record " + run_id)

# Append a compact pointer to the conventional Development/output.log when it remains
# below the safe Contents API size threshold. The full build output is in the run folder.
output_path = "Development/output.log"
existing = get_file(output_path)
if existing is None:
    old_data = b""
    old_sha = None
else:
    old_data = base64.b64decode(existing.get("content", ""))
    old_sha = existing["sha"]

record = (
    "\n========== PRE-STAGE89 SOURCE RECONCILIATION BUILD ==========\n"
    "RUN_ID: " + run_id + "\n"
    "SOURCE_COMMIT: " + os.environ["GITHUB_SOURCE_COMMIT"] + "\n"
    "BUILD_RESULT: " + os.environ["GITHUB_BUILD_RESULT"] + "\n"
    "BUILD_EXIT_CODE: " + os.environ["GITHUB_BUILD_STATUS"] + "\n"
    "BUILD_LOG_SHA256: " + log_sha + "\n"
    "BUILD_LOG_BYTES: " + str(len(log_data)) + "\n"
    "GITHUB_RUN_LOG_DIR: " + remote_dir + "/\n"
    "BUILD_SUMMARY: " + remote_dir + "/build-summary.txt\n"
    "INSTALL: NOT_RUN | LOAD: NOT_RUN | SIGNING: NOT_RUN | OPENCORE_CHANGE: NONE\n"
    "=============================================================\n"
).encode("utf-8")

if len(old_data) + len(record) <= 850 * 1024:
    output_url = api_root + "/contents/" + urllib.parse.quote(output_path, safe="/")
    payload = {
        "message": "Record native build log pointer " + run_id,
        "content": base64.b64encode(old_data + record).decode("ascii"),
        "branch": branch,
    }
    if old_sha:
        payload["sha"] = old_sha
    request_json("PUT", output_url, payload)
    output_status = "UPDATED"
else:
    output_status = "SKIPPED_OUTPUT_LOG_NEAR_API_LIMIT"

print("GITHUB_UPLOAD: PASS")
print("REPOSITORY: https://github.com/" + repo)
print("RUN_LOG_DIR: https://github.com/" + repo + "/tree/" + branch + "/" + remote_dir)
for path in remote_log_paths:
    print("UPLOADED_LOG: https://github.com/" + repo + "/blob/" + branch + "/" + path)
print("UPLOADED_SUMMARY: https://github.com/" + repo + "/blob/" + branch + "/" + remote_dir + "/build-summary.txt")
print("OUTPUT_LOG_STATUS: " + output_status)
PY
UPLOAD_STATUS=$?
unset GH_UPLOAD_TOKEN GITHUB_UPLOAD_TOKEN

if [ "$UPLOAD_STATUS" -ne 0 ]; then
  printf 'GITHUB_UPLOAD: FAILED (exit %s)\n' "$UPLOAD_STATUS" | tee -a "$RUN_DIR/build-summary.txt"
  printf 'Local logs remain at: %s\n' "$RUN_DIR"
  exit 90
fi

printf '\nBUILD_RESULT: %s (exit %s)\n' "$BUILD_RESULT" "$BUILD_STATUS"
printf 'GITHUB_RUN_LOG_DIR: https://github.com/%s/tree/%s/%s\n' "$REPO" "$BRANCH" "$REMOTE_DIR"
printf 'LOCAL_RUN_DIR: %s\n' "$RUN_DIR"
printf 'No install/load/signing/OpenCore changes were made.\n'
exit "$BUILD_STATUS"
