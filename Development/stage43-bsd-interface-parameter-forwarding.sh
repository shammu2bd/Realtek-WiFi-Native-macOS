#!/bin/bash
# Stage 43 — implement the verified 24H32 BSD-parameter base forwarding path.
# VERSION_MARKER: STAGE43_V1_20261102
# Scope: one source change + native build. No install/load/sign/OpenCore actions.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PROJECT_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SOURCE_ROOT="$HOME/Downloads/$PROJECT_NAME"
if [[ ! -f "$SOURCE_ROOT/driver/RTL88WiFi/Makefile" ]]; then
  FOUND="$(find "$HOME/Downloads" -maxdepth 12 -type f -path '*/driver/RTL88WiFi/Makefile' -print -quit 2>/dev/null || true)"
  [[ -n "$FOUND" ]] || { echo "ERROR: Stage26 source tree not found under ~/Downloads"; exit 2; }
  SOURCE_ROOT="$(cd "$(dirname "$FOUND")/../.." && pwd -P)"
fi
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd -P)"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
FILE="$SRC/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$SOURCE_ROOT/run log/stage43/$RUN"
REPORT="$OUT/report.txt"
BUILDLOG="$OUT/native-build.log"
DRYRUN="$OUT/native-build-dryrun.txt"
BACKUP="$OUT/RTW88WCLInfraInterface.cpp.before"
PATCH="$OUT/stage43-bsd-parameters.patch"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE43_ERROR=exit:$rc line:$LINENO" >&2; if [[ -f "$UPLOAD_ERROR" ]]; then tail -60 "$UPLOAD_ERROR" >&2; fi; exit "$rc"' ERR

fail() { echo "ERROR: $*" >&2; exit 2; }
for tool in gh python3 make xcrun sw_vers uname shasum split diff file lipo plutil; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool missing: $tool"
done
[[ -f "$SRC/Makefile" && -f "$FILE" ]] || fail "expected Stage26 native source/Makefile not found"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run gh auth login"
BUILD="$(sw_vers -buildVersion)"
OSVER="$(sw_vers -productVersion)"
ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "target mismatch: expected macOS 15.8.1 / 24H32 / x86_64; got $OSVER / $BUILD / $ARCH"

# Stage42 captured this exact pre-change source fingerprint. Refuse to patch
# an unexpected source revision or a file already modified by another stage.
EXPECTED_BEFORE="20f8fcf3be99c797a28df29612a765a1b6d362dbc032e6045a7113d7f2ec82e1"
ACTUAL_BEFORE="$(shasum -a 256 "$FILE" | awk '{print $1}')"
[[ "$ACTUAL_BEFORE" == "$EXPECTED_BEFORE" ]] || fail "source fingerprint mismatch; expected Stage42 $EXPECTED_BEFORE but found $ACTUAL_BEFORE"
cp -p "$FILE" "$BACKUP"

# Replace exactly the fail-closed placeholder with a non-virtual, qualified
# call into the verified Apple 24H32 IO80211InfraInterface implementation.
python3 - "$FILE" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
data=p.read_text()
old="""SInt32 RTW88WCLInfraInterface::initBSDInterfaceParameters(
    ifnet_init_eparams *params, sockaddr_dl **address)
{
    (void)params;
    (void)address;
    return kIOReturnUnsupported;
}"""
new="""SInt32 RTW88WCLInfraInterface::initBSDInterfaceParameters(
    ifnet_init_eparams *params, sockaddr_dl **address)
{
    /*
     * Stage42 confirmed that the 24H32 IO80211InfraInterface implementation
     * forwards to IO80211SkywalkInterface::initBSDInterfaceParameters().
     * Use a qualified base call so this override does not recurse through
     * virtual dispatch. Apple retains ownership of the BSD parameter setup.
     */
    return IO80211InfraInterface::initBSDInterfaceParameters(params, address);
}"""
count=data.count(old)
if count != 1:
    raise SystemExit("Expected exactly one Stage42 BSD stub; found %d; source left unchanged"%count)
p.write_text(data.replace(old,new,1))
PY

diff -u "$BACKUP" "$FILE" > "$PATCH" || [[ "$?" -eq 1 ]]
PATCH_SHA="$(shasum -a 256 "$FILE" | awk '{print $1}')"
grep -Fq 'return IO80211InfraInterface::initBSDInterfaceParameters(params, address);' "$FILE" || fail "patched base-forwarding call not found"
if grep -A8 -F 'SInt32 RTW88WCLInfraInterface::initBSDInterfaceParameters' "$FILE" | grep -q 'return kIOReturnUnsupported'; then
  fail "old BSD stub remains"
fi

DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ -z "$DEVELOPER_DIR" || ! -d "$DEVELOPER_DIR" ]]; then
  DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
fi
[[ -d "$DEVELOPER_DIR" ]] || fail "Xcode Developer directory not found"
export DEVELOPER_DIR
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
[[ -d "$SDKROOT" ]] || fail "macOS SDK not found"
TARGET_BIN="$SRC/build/out/RTL88WiFiNative.kext/Contents/MacOS/RTL88WiFiNative"
KEXT="$SRC/build/out/RTL88WiFiNative.kext"

{
  echo "========== STAGE 43: BSD INTERFACE PARAMETER FORWARDING =========="
  echo "script_version=STAGE43_V1_20261102"
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "macOS=$OSVER"
  echo "build=$BUILD"
  echo "architecture=$ARCH"
  echo "source_root=$SOURCE_ROOT"
  echo "source_file=$FILE"
  echo "source_sha256_before=$ACTUAL_BEFORE"
  echo "source_sha256_after=$PATCH_SHA"
  echo "local_run_output=$OUT"
  echo "developer_dir=$DEVELOPER_DIR"
  echo "sdkroot=$SDKROOT"
  echo "predecessor=Stage42 run-20261102-035123"
  echo "evidence=Stage42 found IO80211InfraInterface::initBSDInterfaceParameters at 24H32 and disassembled its direct tail-call to IO80211SkywalkInterface::initBSDInterfaceParameters"
  echo "change=replace kIOReturnUnsupported stub with qualified IO80211InfraInterface base forwarding"
  echo "registration_info=unchanged"
  echo "interface_start_publication=still fail-closed; start() returning false is unchanged"
  echo
  echo "--- Source diff ---"
  cat "$PATCH"
  echo
  echo "--- Build target dry-run ---"
} > "$REPORT"

# Show the build target's commands first. Do not run any install/load/security
# or bootloader command from the dry-run.
(cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -n -f Makefile rtl88wifi-native) > "$DRYRUN" 2>&1
if grep -Eiq '(^|[[:space:]])(sudo|kextload|kmutil[[:space:]]+load|bless|systemextensionsctl)([[:space:]]|$)|/Library/Extensions|EFI/OC|OpenCore|codesign' "$DRYRUN"; then
  fail "dry-run contains a forbidden install/load/sign/OpenCore command; build not started"
fi
cat "$DRYRUN" >> "$REPORT"
echo "DRYRUN_FORBIDDEN_ACTIONS=NONE" >> "$REPORT"

# Incremental native build only. No clean/-B, no signing, no install or load.
set +e
(cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -f Makefile rtl88wifi-native) > "$BUILDLOG" 2>&1
BUILD_RC=$?
set -e
{
  echo
  echo "--- Native build result ---"
  echo "NATIVE_BUILD_EXIT=$BUILD_RC"
  echo "NATIVE_BUILD_BYTES=$(wc -c < "$BUILDLOG" | tr -d ' ')"
  echo "NATIVE_BUILD_LINES=$(wc -l < "$BUILDLOG" | tr -d ' ')"
  echo "COMPILE_ERRORS=$(grep -Ec '(^|: )(fatal error:|error:)' "$BUILDLOG" || true)"
  echo "WARNINGS=$(grep -Ec 'warning:' "$BUILDLOG" || true)"
  echo "--- Build log tail ---"
  tail -120 "$BUILDLOG"
  echo "--- End build log tail ---"
} >> "$REPORT"

if [[ "$BUILD_RC" -eq 0 && -f "$TARGET_BIN" && -f "$KEXT/Contents/Info.plist" ]]; then
  BUILD_STATUS="PASS"
  {
    echo "NATIVE_KEXT_BUNDLE=present"
    echo "NATIVE_EXECUTABLE_FILE=$(file "$TARGET_BIN")"
    echo "NATIVE_EXECUTABLE_ARCH=$(lipo -info "$TARGET_BIN" 2>&1 || true)"
    echo "INFO_PLIST_VALIDATION=$(plutil -lint "$KEXT/Contents/Info.plist" 2>&1 || true)"
    echo "NATIVE_EXECUTABLE_SHA256=$(shasum -a 256 "$TARGET_BIN" | awk '{print $1}')"
  } >> "$REPORT"
else
  BUILD_STATUS="FAILED"
  echo "NATIVE_KEXT_BUNDLE=missing_or_build_failed" >> "$REPORT"
fi

{
  echo
  echo "--- Source and activation gate ---"
  echo "BSD_PARAMETER_FORWARDING=IMPLEMENTED"
  echo "BSD_PARAMETER_SOURCE_SHA256=$PATCH_SHA"
  echo "NATIVE_BUILD=$BUILD_STATUS"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "CODESIGN=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
  echo "HARDWARE_TEST=NOT_RUN"
  echo "INTERFACE_PUBLICATION=BLOCKED"
  echo "ACTIVATION_GATE=BLOCKED"
  echo "REASON=BSD parameter forwarding alone does not close Skywalk queue registration, TX/RX completion ownership, interface start, or teardown gates."
  echo "========== END STAGE 43 =========="
} >> "$REPORT"

# Split potentially large reports/logs into small GitHub Contents API uploads.
mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"
split -b 220k "$BUILDLOG" "$OUT/parts/build-"

upload_file() {
  local local_file="$1" remote_path="$2" message="$3" payload="$4" response="$5" old put got
  old="$(gh api "repos/$REPO/contents/$remote_path" --jq .sha 2>/dev/null || true)"
  python3 - "$local_file" "$old" "$message" "$payload" <<'PY'
import base64,json,pathlib,sys
src,sha,msg,dst=sys.argv[1:]
obj={"message":msg,"content":base64.b64encode(pathlib.Path(src).read_bytes()).decode("ascii")}
if sha: obj["sha"]=sha
pathlib.Path(dst).write_text(json.dumps(obj),encoding="utf-8")
PY
  if ! gh api --method PUT "repos/$REPO/contents/$remote_path" --input "$payload" > "$response" 2> "$UPLOAD_ERROR"; then
    echo "UPLOAD_FAILED_PATH=$remote_path" >> "$UPLOAD_ERROR"; return 1
  fi
  put="$(python3 - "$response" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])); s=(v.get("content") or {}).get("sha")
if not s: raise SystemExit("GitHub response missing content SHA")
print(s)
PY
)"
  got="$(gh api "repos/$REPO/contents/$remote_path" --jq .sha)"
  [[ -n "$put" && "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$remote_path put=$put got=$got" >> "$UPLOAD_ERROR"; return 1; }
  UPLOAD_SHA="$got"
}

MANIFEST="$OUT/manifest.txt"
{
  echo "STAGE: 43"
  echo "RUN: $RUN"
  echo "PURPOSE: qualified base forwarding for BSD interface parameters + incremental native build"
  echo "SOURCE_FILE: src/kext/wcl24h32/RTW88WCLInfraInterface.cpp"
  echo "SOURCE_SHA256_BEFORE: $ACTUAL_BEFORE"
  echo "SOURCE_SHA256_AFTER: $PATCH_SHA"
  echo "NATIVE_BUILD: $BUILD_STATUS"
  echo "ACTIVATION_GATE: BLOCKED"
  echo "LOCAL_OUTPUT: $OUT"
} > "$MANIFEST"

for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  upload_file "$part" "Development/Logs/stage43/$RUN/$name" "Add Stage43 report $RUN/$name" "$OUT/report-upload.json" "$OUT/report-upload-response.json"
  echo "UPLOADED_REPORT_PART=$name SHA=$UPLOAD_SHA BYTES=$(wc -c < "$part" | tr -d ' ')" >> "$MANIFEST"
done
for part in "$OUT"/parts/build-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  upload_file "$part" "Development/Logs/stage43/$RUN/$name" "Add Stage43 build log $RUN/$name" "$OUT/build-upload.json" "$OUT/build-upload-response.json"
  echo "UPLOADED_BUILD_PART=$name SHA=$UPLOAD_SHA BYTES=$(wc -c < "$part" | tr -d ' ')" >> "$MANIFEST"
done
upload_file "$PATCH" "Development/Logs/stage43/$RUN/stage43-bsd-parameters.patch" "Add Stage43 BSD parameter source patch $RUN" "$OUT/patch-upload.json" "$OUT/patch-upload-response.json"
echo "PATCH_GITHUB_BLOB=$UPLOAD_SHA" >> "$MANIFEST"
upload_file "$MANIFEST" "Development/Logs/stage43/$RUN/manifest.txt" "Add Stage43 manifest $RUN" "$OUT/manifest-upload.json" "$OUT/manifest-upload-response.json"
echo "MANIFEST_GITHUB_BLOB=$UPLOAD_SHA" >> "$MANIFEST"

# Append a concise checkpoint to the canonical Development/output.log while
# preserving its current contents. The updated blob is read back and verified.
REMOTE_LOG_JSON="$OUT/remote-output-log.json"
gh api "repos/$REPO/contents/Development/output.log" > "$REMOTE_LOG_JSON"
python3 - "$REMOTE_LOG_JSON" "$OUT/output.log" "$RUN" "$BUILD_STATUS" "$PATCH_SHA" <<'PY'
import base64,json,pathlib,sys
remote,out,run,status,source_sha=sys.argv[1:]
obj=json.load(open(remote))
old=base64.b64decode(obj["content"])
entry=(
"\n========== STAGE 43 BSD PARAMETER FORWARDING ==========\n"
f"STAGE43_RUN: {run}\n"
"STAGE43_CHANGE: RTW88WCLInfraInterface::initBSDInterfaceParameters now forwards to the verified IO80211InfraInterface 24H32 base implementation\n"
f"STAGE43_SOURCE_SHA256: {source_sha}\n"
f"STAGE43_NATIVE_BUILD: {status}\n"
"STAGE43_INSTALL: NOT_RUN | LOAD: NOT_RUN | CODESIGN: NOT_RUN | OPENCORE_CHANGE: NONE\n"
"ACTIVATION_GATE: BLOCKED — queue registration, TX/RX completion ownership, publication and teardown remain open\n"
f"STAGE43_REPORTS: Development/Logs/stage43/{run}/\n"
"=======================================================\n"
).encode()
pathlib.Path(out).write_bytes(old.rstrip()+entry)
PY
upload_file "$OUT/output.log" "Development/output.log" "Append Stage43 BSD parameter forwarding result $RUN" "$OUT/output-log-upload.json" "$OUT/output-log-upload-response.json"

echo
echo "STAGE43_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE43_RUN=$RUN"
echo "STAGE43_BUILD=$BUILD_STATUS"
echo "STAGE43_LOCAL_OUTPUT=$OUT"
echo "STAGE43_GITHUB_REPORTS=https://github.com/$REPO/tree/main/Development/Logs/stage43/$RUN"
echo "STAGE43_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE43_SOURCE_FILE_MODIFIED=YES"
echo "STAGE43_INSTALL=NOT_RUN"
echo "STAGE43_LOAD=NOT_RUN"
echo "STAGE43_OPENCORE_CHANGE=NONE"
