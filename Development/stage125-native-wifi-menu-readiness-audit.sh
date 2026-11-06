#!/bin/bash
# Stage125: read-only source audit of native macOS Wi-Fi menu readiness.
# No build, signing, install/load/unload, hardware activation or OC/EFI changes.
set -euo pipefail

EXPECTED_BRANCH="work/stage125-native-wifi-menu-readiness-audit"
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BASE_STAGE124="92322c8d966929649fa4a648570a917ea25b3b31"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [[ "$(git branch --show-current)" != "$EXPECTED_BRANCH" ]]; then
  echo "ERROR: expected branch $EXPECTED_BRANCH"
  exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree must be clean before Stage125"
  git status --short
  exit 2
fi
if ! git merge-base --is-ancestor "$BASE_STAGE124" HEAD; then
  echo "ERROR: Stage125 branch is not descended from the reviewed Stage124 source commit"
  exit 2
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMPROOT="${TMPDIR:-/tmp}"
REPORT="$(mktemp "${TMPROOT%/}/stage125-native-wifi-menu-readiness-XXXXXX")"
SOURCE_COMMIT="$(git rev-parse HEAD)"

set +e
(
  set -euo pipefail
  echo "========== STAGE125 NATIVE WIFI MENU READINESS AUDIT =========="
  echo "STAGE125_SOURCE_COMMIT=$SOURCE_COMMIT"
  echo "STAGE125_STAGE124_BASE=$BASE_STAGE124"
  echo "STAGE125_TARGET=macOS_15.8.1_24H32_x86_64"
  echo "STAGE125_SCOPE=READ_ONLY_NATIVE_WIFI_MENU_CONTROL_PLANE_SOURCE_AUDIT"
  echo "STAGE125_DRIVER_SOURCE_MODIFIED=NO"
  echo "STAGE125_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
  echo "STAGE125_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
  echo
  python3 tests/test-wcl-native-wifi-menu-readiness-stage125.py
) >"$REPORT" 2>&1
RUN_STATUS=$?
set -e

if [[ $RUN_STATUS -eq 0 ]]; then AUDIT_RESULT="COMPLETE"; else AUDIT_RESULT="INCOMPLETE"; fi
{
  echo
  echo "STAGE125_AUDIT_EXIT=$RUN_STATUS"
  echo "STAGE125_AUDIT_RESULT=$AUDIT_RESULT"
  echo "STAGE125_SOURCE_COMMIT=$SOURCE_COMMIT"
  echo "STAGE125_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
  echo "STAGE125_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
  echo "========== END STAGE125 =========="
} >>"$REPORT"

echo "===== STAGE125 SUMMARY ====="
grep -aE '^(STAGE125_|ERROR:|Traceback|AssertionError)' "$REPORT" | tail -120 || true
echo "STAGE125_LOCAL_REPORT=$REPORT"

python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64, hashlib, json, pathlib, subprocess, sys, tempfile

report = pathlib.Path(sys.argv[1])
stamp = sys.argv[2]
repo = sys.argv[3]
data = report.read_bytes()
dest = f"Development/Logs/stage125-native-wifi-menu-readiness-{stamp}.log"
payload = {
    "message": "Stage125: publish read-only native Wi-Fi menu readiness audit",
    "branch": "main",
    "content": base64.b64encode(data).decode("ascii"),
}
with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as f:
    json.dump(payload, f)
    f.flush()
    result = subprocess.run(
        ["gh", "api", "--method", "PUT",
         f"repos/{repo}/contents/{dest}", "--input", f.name],
        capture_output=True, text=True
    )
if result.returncode:
    print("STAGE125_UPLOAD=FAILED")
    print(result.stderr.strip())
    sys.exit(result.returncode)
response = json.loads(result.stdout)
expected = hashlib.sha1(f"blob {len(data)}\0".encode("ascii") + data).hexdigest()
actual = response.get("content", {}).get("sha")
if actual != expected:
    print("STAGE125_UPLOAD=VERIFY_REQUIRED")
    print("STAGE125_UPLOAD_SHA_EXPECTED=" + expected)
    print("STAGE125_UPLOAD_SHA_ACTUAL=" + str(actual))
    sys.exit(4)
print("STAGE125_UPLOAD=PASS")
print("STAGE125_UPLOAD_SHA=" + actual)
print("STAGE125_GITHUB_PATH=" + dest)
print("STAGE125_GITHUB_URL=https://github.com/" + repo + "/blob/main/" + dest)
PY

if [[ $RUN_STATUS -ne 0 ]]; then
  echo "Stage125 static audit incomplete; inspect the uploaded report."
  exit "$RUN_STATUS"
fi
echo "Stage125 static source audit completed. Readiness remains blocked by the findings listed in the report."
