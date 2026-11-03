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
        echo "WARNING: Ignoring invalid PROJECT_DIR: $candidate" >&2
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
    fail "Cannot find Stage26 project under ~/Downloads. Set PROJECT_DIR to its root."
}

PROJECT="$(find_project)" || exit 2
DRIVER="$PROJECT/driver/RTL88WiFi"
BUNDLE="$DRIVER/build/out/RTL88WiFiNative.kext"
INFO="$BUNDLE/Contents/Info.plist"
BIN="$BUNDLE/Contents/MacOS/RTL88WiFiNative"
LOG="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage29e-kmutil-symbol-resolution-audit-$STAMP"
REMOTE_JSON="$STAGE_DIR/github-output-log-before.json"
BASE_LOG="$STAGE_DIR/output-log-before.txt"
PAYLOAD="$STAGE_DIR/github-output-log-payload.json"
RESPONSE="$STAGE_DIR/github-upload-response.json"

mkdir -p "$STAGE_DIR" || fail "Cannot create Stage29e audit directory."
command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is required."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated."
KMUTIL="$(command -v kmutil 2>/dev/null || true)"
[[ -n "$KMUTIL" ]] || fail "kmutil is not available on this macOS installation."

# Restore canonical log; never overwrite remote history using a stale local log.
gh api "$API_PATH" > "$REMOTE_JSON" || fail "Cannot read GitHub Development/output.log."
python3 - "$REMOTE_JSON" "$BASE_LOG" <<'PY'
import base64, json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
data = base64.b64decode(doc.get("content", ""), validate=False)
text = data.decode("utf-8", errors="replace")
if "STAGE29D_STATIC_AUDIT: PASS" not in text or "NATIVE_ACTUAL_BUILD: PASS" not in text:
    raise SystemExit("Canonical log does not contain the required Stage29c/29d PASS gates.")
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
[[ $? -eq 0 ]] || fail "Could not validate current remote log."
cp "$BASE_LOG" "$LOG" || fail "Could not restore canonical project log."

[[ -f "$INFO" ]] || fail "Native bundle Info.plist missing: $INFO"
[[ -f "$BIN" ]] || fail "Native executable missing: $BIN"

EXPECTED_SHA="$(python3 - "$LOG" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
m = re.findall(r"(?m)^BINARY_SHA256: ([0-9a-f]{64})$", text)
print(m[-1] if m else "")
PY
)"
[[ -n "$EXPECTED_SHA" ]] || fail "Stage29d native binary SHA-256 is not present in output.log."
ACTUAL_SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || fail "Native executable SHA does not match Stage29d; refusing stale or changed binary."

OS_VERSION="$(sw_vers -productVersion)"
OS_BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"

# Modern, read-only KernelManagement symbol/dependency queries.
# No --do-staging, no load, no install, no build, no OpenCore edits.
"$KMUTIL" libraries -p "$BUNDLE" --xml > "$STAGE_DIR/kmutil-libraries.xml.txt" 2>&1
LIBRARIES_RC=$?
"$KMUTIL" libraries -p "$BUNDLE" --undef-symbols > "$STAGE_DIR/kmutil-undefined-symbols.txt" 2>&1
UNDEFINED_RC=$?
"$KMUTIL" libraries -p "$BUNDLE" --all-symbols > "$STAGE_DIR/kmutil-all-symbols.txt" 2>&1
ALL_SYMBOLS_RC=$?
"$KMUTIL" print-diagnostics -p "$BUNDLE" -D > "$STAGE_DIR/kmutil-print-diagnostics.txt" 2>&1
DIAGNOSTICS_RC=$?

python3 - "$STAGE_DIR" "$BUNDLE" "$ACTUAL_SHA" "$EXPECTED_SHA" "$OS_VERSION" "$OS_BUILD" "$ARCH" "$LIBRARIES_RC" "$UNDEFINED_RC" "$ALL_SYMBOLS_RC" "$DIAGNOSTICS_RC" <<'PY'
from pathlib import Path
import sys
(stage, bundle, actual_sha, expected_sha, os_version, os_build, arch,
 libraries_rc, undefined_rc, all_symbols_rc, diagnostics_rc) = sys.argv[1:]
stage = Path(stage)
def read(name):
    p = stage / name
    return p.read_text(encoding="utf-8", errors="replace") if p.exists() else ""
libraries = read("kmutil-libraries.xml.txt")
undefined = read("kmutil-undefined-symbols.txt")
all_symbols = read("kmutil-all-symbols.txt")
diagnostics = read("kmutil-print-diagnostics.txt")

libraries_rc = int(libraries_rc)
undefined_rc = int(undefined_rc)
all_symbols_rc = int(all_symbols_rc)
diagnostics_rc = int(diagnostics_rc)
hash_ok = actual_sha == expected_sha
# kmutil libraries documents exit status 0 as no undefined or multiply-defined symbols.
symbol_resolution_ok = libraries_rc == 0
diagnostic_findings = []
if "Filesystem error: Invalid ownership" in diagnostics:
    diagnostic_findings.append("BUNDLE_OR_FILE_OWNERSHIP_NOT_ROOT_WHEEL")
if "Authenticating extension failed" in diagnostics or "Bad code signature" in diagnostics:
    diagnostic_findings.append("CODE_SIGNATURE_AUTHENTICATION_FAILED")
diagnostics_ok = diagnostics_rc == 0 and len(diagnostic_findings) == 0
overall = hash_ok and symbol_resolution_ok and diagnostics_ok

out = []
out.append("RTL88WiFi Stage29e — modern kmutil symbol-provider and dependency audit")
out.append("SCOPE: READ-ONLY; exact Stage29d binary; KernelManagement queries only")
out.append("HOST: macOS {} / {} / {}".format(os_version, os_build, arch))
out.append("BUNDLE: {}".format(bundle))
out.append("BINARY_SHA256: {}".format(actual_sha))
out.append("STAGE29D_BINARY_SHA256: {}".format(expected_sha))
out.append("BINARY_IDENTITY_MATCH: {}".format("PASS" if hash_ok else "FAIL"))
out.append("")
out.append("=== KMUTIL LIBRARY RESOLUTION ===")
out.append("KMUTIL_LIBRARIES_EXIT: {}".format(libraries_rc))
out.append("KMUTIL_SYMBOL_RESOLUTION: {}".format("PASS" if symbol_resolution_ok else "REVIEW_REQUIRED"))
out.append("KMUTIL_UNDEFINED_SYMBOL_QUERY_EXIT: {}".format(undefined_rc))
out.append("KMUTIL_ALL_SYMBOLS_QUERY_EXIT: {}".format(all_symbols_rc))
out.append("KMUTIL_LIBRARY_XML:")
out.extend("  " + line for line in libraries.splitlines()[:500])
if not libraries:
    out.append("  NO OUTPUT")
out.append("")
out.append("=== KMUTIL UNDEFINED-SYMBOL QUERY ===")
out.extend("  " + line for line in undefined.splitlines()[:700])
if not undefined:
    out.append("  NO OUTPUT")
out.append("")
out.append("=== KMUTIL PRINT-DIAGNOSTICS ===")
out.append("KMUTIL_PRINT_DIAGNOSTICS_EXIT: {}".format(diagnostics_rc))
out.append("KMUTIL_DEPENDENCY_DIAGNOSTICS: {}".format("PASS" if diagnostics_ok else "REVIEW_REQUIRED"))
out.append("KMUTIL_DIAGNOSTIC_FINDINGS: {}".format(", ".join(diagnostic_findings) if diagnostic_findings else "NONE"))
out.extend("  " + line for line in diagnostics.splitlines()[:900])
if not diagnostics:
    out.append("  NO OUTPUT")
out.append("")
out.append("=== KMUTIL ALL-SYMBOLS SUMMARY ===")
out.append("KMUTIL_ALL_SYMBOLS_BYTES: {}".format(len(all_symbols.encode("utf-8"))))
out.extend("  " + line for line in all_symbols.splitlines()[:300])
if len(all_symbols.splitlines()) > 300:
    out.append("  ... full inventory saved in {}".format(stage / "kmutil-all-symbols.txt"))
out.append("")
out.append("=== STAGE29E RESULT ===")
out.append("BINARY_IDENTITY_MATCH: {}".format("PASS" if hash_ok else "FAIL"))
out.append("KMUTIL_SYMBOL_RESOLUTION: {}".format("PASS" if symbol_resolution_ok else "REVIEW_REQUIRED"))
out.append("KMUTIL_DEPENDENCY_DIAGNOSTICS: {}".format("PASS" if diagnostics_ok else "REVIEW_REQUIRED"))
out.append("STAGE29E_MODERN_DEPENDENCY_AUDIT: {}".format("PASS" if overall else "REVIEW_REQUIRED"))
out.append("NOTE: A PASS confirms kmutil can resolve symbol providers and its read-only bundle diagnostics succeed; it is not proof of runtime queue ABI or packet I/O.")
out.append("BUILD: NOT RUN")
out.append("SOURCE_FILES_MODIFIED: NONE")
out.append("INSTALL: NOT RUN")
out.append("LOAD: NOT RUN")
out.append("OPENCORE_CHANGE: NONE")
out.append("QUEUE_REGISTRATION: NOT ENABLED")
out.append("KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED")
(stage / "stage29e-report.txt").write_text("\n".join(out) + "\n", encoding="utf-8")
print("\n".join(out))
raise SystemExit(0 if overall else 1)
PY
ANALYSIS_RC=$?

{
    echo
    echo "========== STAGE29E KMUTIL SYMBOL / DEPENDENCY AUDIT =========="
    echo "STAGE_DIR: $STAGE_DIR"
    echo "KMUTIL_LIBRARIES_EXIT: $LIBRARIES_RC"
    echo "KMUTIL_UNDEFINED_SYMBOL_QUERY_EXIT: $UNDEFINED_RC"
    echo "KMUTIL_ALL_SYMBOLS_QUERY_EXIT: $ALL_SYMBOLS_RC"
    echo "KMUTIL_PRINT_DIAGNOSTICS_EXIT: $DIAGNOSTICS_RC"
    cat "$STAGE_DIR/stage29e-report.txt" 2>/dev/null || echo "ERROR: Stage29e report missing."
    echo
    echo "BUILD: NOT RUN"
    echo "SOURCE_FILES_MODIFIED: NONE"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "OPENCORE_CHANGE: NONE"
    echo "QUEUE_REGISTRATION: NOT ENABLED"
    echo "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED"
} >> "$LOG" 2>&1

# File-backed JSON upload avoids macOS ARG_MAX problems with large logs.
REMOTE_SHA="$(gh api "$API_PATH" --jq '.sha')" || fail "Cannot get current remote log SHA."
python3 - "$LOG" "$REMOTE_SHA" "$PAYLOAD" <<'PY'
import base64, json, pathlib, sys
log_path, sha, payload_path = sys.argv[1:4]
data = pathlib.Path(log_path).read_bytes()
if len(data) < 500:
    raise SystemExit("Refusing to upload empty output.log.")
payload = {
    "message": "Stage29e read-only kmutil symbol and dependency resolution audit",
    "content": base64.b64encode(data).decode("ascii"),
    "sha": sha,
}
pathlib.Path(payload_path).write_text(json.dumps(payload), encoding="utf-8")
print("LOG_BYTES_TO_UPLOAD: {}".format(len(data)))
PY
PREP_RC=$?
[[ "$PREP_RC" -eq 0 ]] || fail "Could not create GitHub upload payload."

gh api --method PUT "$API_PATH" --input "$PAYLOAD" > "$RESPONSE" || fail "GitHub output.log upload failed."
PUT_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["content"]["sha"])' "$RESPONSE")"
COMMIT_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"]["sha"])' "$RESPONSE")"
READ_SHA="$(gh api "$API_PATH" --jq '.sha')" || fail "GitHub read-back failed."
[[ -n "$PUT_SHA" && "$PUT_SHA" == "$READ_SHA" ]] || fail "GitHub output.log read-back SHA mismatch."

echo "GITHUB_UPLOAD_STATUS: SUCCESS — verified Development/output.log"
echo "GITHUB_COMMIT: $COMMIT_SHA"
echo "GITHUB_BLOB_SHA: $READ_SHA"
echo "STAGE29E_ANALYSIS_EXIT: $ANALYSIS_RC"
[[ "$ANALYSIS_RC" -eq 0 ]] || exit "$ANALYSIS_RC"
