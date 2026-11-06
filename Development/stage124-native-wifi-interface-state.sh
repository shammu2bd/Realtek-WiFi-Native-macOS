#!/bin/bash
# Stage124: native Wi-Fi connected-state / current-BSSID publication check.
# Performs source tests and a target-Mac unsigned build only. It never signs,
# installs, loads, unloads, activates hardware, or changes OpenCore/EFI/SIP/NVRAM.
set -euo pipefail

EXPECTED_BRANCH="work/stage124-native-wifi-interface-state"
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [[ "$(git branch --show-current)" != "$EXPECTED_BRANCH" ]]; then
  echo "ERROR: expected branch $EXPECTED_BRANCH"
  exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree must be clean before Stage124"
  git status --short
  exit 2
fi

if [[ -d "/Applications/Xcode_16.4.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
fi
CXX_BIN="$(xcrun --find clang++ 2>/dev/null || command -v clang++)"
SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [[ -z "$SDK_PATH" || ! -d "$SDK_PATH" ]]; then
  echo "ERROR: macOS SDK not found; Stage124 requires target-Mac Xcode"
  exit 2
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMPROOT="${TMPDIR:-/tmp}"
REPORT="$(mktemp "${TMPROOT%/}/stage124-native-wifi-interface-state-XXXXXX.log")"
BUNDLE="driver/RTL88WiFi/build/out/RTL88WiFiNative.kext"
BIN="$BUNDLE/Contents/MacOS/RTL88WiFiNative"
PLIST="$BUNDLE/Contents/Info.plist"
SOURCE_COMMIT="$(git rev-parse HEAD)"

set +e
(
  set -euo pipefail
  echo "========== STAGE124 NATIVE WIFI INTERFACE STATE =========="
  echo "STAGE124_SOURCE_COMMIT=$SOURCE_COMMIT"
  echo "STAGE124_TARGET=macOS_15.8.1_24H32_x86_64"
  echo "STAGE124_SCOPE=CONNECTED_BSSID_CACHE_AND_NATIVE_INTERFACE_CONTROL_PLANE"
  echo "STAGE124_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
  echo "STAGE124_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
  echo

  echo "----- Stage124 current-AP/link-state source contract -----"
  python3 tests/test-wcl-link-state-publication-stage124.py

  echo
  echo "----- Existing native interface/registration regressions -----"
  python3 tests/test-wcl-controller-primary-attachment-stage121.py
  python3 tests/test-wcl-registration-transaction-stage108.py
  python3 tests/test-wcl-registration-contract.py
  python3 tests/test-wcl-registration-info-stage11.py
  python3 tests/test-wcl-tx-queue-array-contract.py
  python3 tests/test-wcl-resource-transaction.py

  echo
  echo "----- Native 24H32 unsigned build (no activation) -----"
  export CXX="$CXX_BIN"
  export SDKROOT="$SDK_PATH"
  export CODE_SIGNING_ALLOWED=NO
  make -C driver/RTL88WiFi rtl88wifi-native

  test -s "$BIN"
  test -s "$PLIST"
  plutil -lint "$PLIST"
  file "$BIN"
  lipo "$BIN" -verify_arch x86_64
  BINARY_SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
  echo "STAGE124_NATIVE_BUNDLE_ID=$BUNDLE_ID"
  echo "STAGE124_NATIVE_BINARY_SHA256=$BINARY_SHA"
  echo "STAGE124_NATIVE_BUILD=PASS"
) >"$REPORT" 2>&1
RUN_STATUS=$?
set -e

if [[ $RUN_STATUS -eq 0 ]]; then RESULT="PASS"; else RESULT="FAIL"; fi
{
  echo
  echo "STAGE124_RESULT=$RESULT"
  echo "STAGE124_EXIT=$RUN_STATUS"
  echo "STAGE124_SOURCE_COMMIT=$SOURCE_COMMIT"
  echo "STAGE124_CONNECTED_BSSID_CACHE=IMPLEMENTED"
  echo "STAGE124_RUNTIME_INTERFACE_PUBLICATION=NOT_TESTED"
  echo "STAGE124_WIFI_MENU=NOT_VERIFIED_DRIVER_NOT_LOADED"
  echo "STAGE124_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN HARDWARE_TEST=NOT_RUN"
  echo "STAGE124_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
  echo "========== END STAGE124 =========="
} >>"$REPORT"

echo "===== STAGE124 SUMMARY ====="
grep -aE '^(STAGE124_|PASS:|ERROR:|warning:|[0-9]+ warning)' "$REPORT" | tail -100 || true
echo "STAGE124_LOCAL_REPORT=$REPORT"

python3 - "$REPORT" "$STAMP" "$RUN_STATUS" "$REPO" <<'PY'
import base64, hashlib, json, pathlib, subprocess, sys, tempfile

report = pathlib.Path(sys.argv[1])
stamp = sys.argv[2]
status = int(sys.argv[3])
repo = sys.argv[4]
data = report.read_bytes()
dest = f"Development/Logs/stage124-native-wifi-interface-state-{stamp}.log"
payload = {
    "message": "Stage124: publish native Wi-Fi interface state validation",
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
    print("STAGE124_UPLOAD=FAILED")
    print(result.stderr.strip())
    sys.exit(result.returncode)
response = json.loads(result.stdout)
expected = hashlib.sha1(f"blob {len(data)}\\0".encode("ascii") + data).hexdigest()
actual = response.get("content", {}).get("sha")
if actual != expected:
    print("STAGE124_UPLOAD=VERIFY_REQUIRED")
    print("STAGE124_UPLOAD_SHA_EXPECTED=" + expected)
    print("STAGE124_UPLOAD_SHA_ACTUAL=" + str(actual))
    sys.exit(4)
print("STAGE124_UPLOAD=PASS")
print("STAGE124_UPLOAD_SHA=" + actual)
print("STAGE124_GITHUB_PATH=" + dest)
print("STAGE124_GITHUB_URL=https://github.com/" + repo + "/blob/main/" + dest)
PY

if [[ $RUN_STATUS -ne 0 ]]; then
  echo "Stage124 tests/build failed; inspect the published report."
  exit "$RUN_STATUS"
fi
echo "Stage124 source tests and native unsigned build passed; runtime Wi-Fi menu still requires a separately authorized load test."
