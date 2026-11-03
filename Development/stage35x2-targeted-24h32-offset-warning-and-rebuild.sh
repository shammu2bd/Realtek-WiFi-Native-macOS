#!/bin/bash
# Stage 35X — narrowly scope the Clang invalid-override/offsetof warning
# around the 24H32 ABI offset assertion; preserve the assertion itself.
# Then rebuild, validate x86_64 Kext + Info.plist, and upload the artifact.
# No signing, installation, loading, OpenCore changes, or hardware test.
set -Eeuo pipefail

echo "STAGE35X2_SCRIPT_VERSION=1"
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW88="$SOURCE_ROOT/driver/rtw88-stable/drivers/net/wireless/realtek/rtw88"
ABI="$SRC/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp"
DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35X-$RUN"
REPORT="$OUT/report.txt"
DRYRUN="$OUT/native-dry-run.txt"
BUILDLOG="$OUT/native-build.log"
UPLOAD_ERROR="$OUT/upload-error.txt"
BACK="$OUT/backups"
mkdir -p "$OUT" "$BACK"
PATCH_ACTIVE=0
FW_BACKUP_ACTIVE=0
trap 'rc=$?; if [[ "$FW_BACKUP_ACTIVE" == 1 ]]; then restore_fw_generated || true; fi; if [[ "$PATCH_ACTIVE" == 1 ]]; then rollback_abi || true; fi; echo "STAGE35X2_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 make xcrun split shasum tar file lipo plutil grep awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" && -d "$SRC/RTL88WiFiNative.kext" && -f "$SRC/scripts/gen_fw_blobs.py" ]] || { echo "ERROR: Stage26 native build inputs missing"; exit 3; }
[[ -f "$ABI" && -f "$RTW88/tx.h" ]] || { echo "ERROR: ABI or RTW88 source missing"; exit 4; }
[[ -d "$DEVELOPER_DIR" ]] || { echo "ERROR: Xcode 16.4 Developer directory missing"; exit 5; }
export DEVELOPER_DIR
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
[[ -d "$SDKROOT" ]] || { echo "ERROR: SDKROOT invalid"; exit 6; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 7; }

# Verify this Xcode Clang accepts the exact diagnostic-group spelling before
# touching the project ABI header. The control must emit the warning; the
# pragma case must suppress it without an unknown-warning-option diagnostic.
cat > "$OUT/offsetof-control.cpp" <<'CPP'
class Stage35XBase { public: virtual ~Stage35XBase() = default; };
class Stage35XDerived : public Stage35XBase { public: int member; };
static_assert(__builtin_offsetof(Stage35XDerived, member) >= 0, "layout probe");
CPP
cat > "$OUT/offsetof-pragma.cpp" <<'CPP'
class Stage35XBase { public: virtual ~Stage35XBase() = default; };
class Stage35XDerived : public Stage35XBase { public: int member; };
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winvalid-offsetof"
static_assert(__builtin_offsetof(Stage35XDerived, member) >= 0, "layout probe");
#pragma clang diagnostic pop
CPP
set +e
xcrun clang++ -std=c++17 -fsyntax-only "$OUT/offsetof-control.cpp" > "$OUT/offsetof-control.log" 2>&1
CONTROL_RC=$?
xcrun clang++ -std=c++17 -Werror=unknown-warning-option -fsyntax-only "$OUT/offsetof-pragma.cpp" > "$OUT/offsetof-pragma.log" 2>&1
PRAGMA_RC=$?
set -e
if [[ "$CONTROL_RC" -ne 0 || "$PRAGMA_RC" -ne 0 ]] ||
   ! grep -q "offset of on non-standard-layout type" "$OUT/offsetof-control.log" ||
   grep -Eq "unknown warning group|offset of on non-standard-layout type" "$OUT/offsetof-pragma.log"; then
  echo "ERROR: Xcode Clang rejected or failed to prove the -Winvalid-offsetof pragma"
  cat "$OUT/offsetof-control.log" "$OUT/offsetof-pragma.log" >&2
  exit 8
fi
{
  echo "ABI_DIAGNOSTIC_PRAGMA_SMOKE_TEST=PASS"
  echo "ABI_DIAGNOSTIC_GROUP=-Winvalid-offsetof"
  echo "CONTROL_WARNING=OBSERVED"
  echo "PRAGMA_WARNING=SUPPRESSED"
  echo "UNKNOWN_WARNING_OPTION=NONE"
} > "$OUT/pragma-smoke-test.txt"

cp -p "$ABI" "$BACK/RTW88WCL24H32InterfaceABI.hpp"
ABI_BEFORE="$(shasum -a 256 "$ABI" | awk '{print $1}')"
python3 - "$ABI" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text()
required=[
 'class IOSkywalkEthernetInterface : public IOSkywalkNetworkInterface',
 'static_assert(sizeof(IOSkywalkNetworkInterface) == 0xd0',
 'uint8_t _layout0[0x38];',
 'static_assert(sizeof(IOSkywalkEthernetInterface) == 0x110',
 'static_assert(__offsetof(IOSkywalkEthernetInterface, mExpansionData2) == 0x108'
]
for x in required:
    if s.count(x)!=1:
        raise SystemExit("ABI_PATCH_PREFLIGHT=BLOCKED expected unique declaration: "+x)
if '#pragma clang diagnostic ignored "-Winvalid-offsetof"' in s:
    raise SystemExit("ABI_PATCH_PREFLIGHT=BLOCKED diagnostic pragma already present")
print("ABI_LAYOUT_PREFLIGHT=PASS")
print("BASE_CLASS_SIZE=0xd0")
print("DERIVED_CLASS_SIZE=0x110")
print("EXPANSION_POINTER_OFFSET_ASSERTION=0x108")
print("SINGLE_NON_STANDARD_LAYOUT_ASSERTION=YES")
PY

rollback_abi() {
  if [[ "$PATCH_ACTIVE" == 1 ]]; then
    cp -p "$BACK/RTW88WCL24H32InterfaceABI.hpp" "$ABI"
    PATCH_ACTIVE=0
    echo "ABI_PATCH_ROLLBACK=COMPLETED" >> "$REPORT"
  fi
}
restore_fw_generated() {
  if [[ "$FW_BACKUP_ACTIVE" == 1 ]]; then
    if [[ "$FW_ORIG_PRESENT" == 1 ]]; then cp -p "$FW_BACKUP" "$FW_GENERATED"; else rm -f "$FW_GENERATED"; fi
    FW_BACKUP_ACTIVE=0
  fi
}

{
  echo "========== STAGE 35X: TARGETED 24H32 ABI WARNING SCOPE + NATIVE REBUILD =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "source_root=$SOURCE_ROOT"
  echo "sdkroot=$SDKROOT"
  echo "target=rtl88wifi-native"
  echo "predecessor=Stage35W run-20261102-015632"
  echo "predecessor_finding=two -Winvalid-offsetof diagnostics at ABI header line 453"
  echo "patch_scope=diagnostic pragma around exactly one existing static_assert"
  echo "ABI_ASSERTION_VALUE=0x108 (preserved)"
  echo "ABI_SIZE_ASSERTION=0x110 (preserved)"
  echo "no-warning-suppression-outside-this-assertion=YES"
  cat "$OUT/pragma-smoke-test.txt"
  echo
  echo "--- ABI source before patch ---"
  echo "sha256=$ABI_BEFORE"
  nl -ba "$ABI" | sed -n '438,460p'
  echo
} > "$REPORT"

python3 - "$ABI" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old='static_assert(__offsetof(IOSkywalkEthernetInterface, mExpansionData2) == 0x108, "24H32 Ethernet expansion offset");'
new='''// This kernel ABI class is polymorphic and therefore not standard-layout.
// Clang implements offsetof here as an ABI extension; keep the hard 24H32
// offset assertion, but scope the expected diagnostic to this assertion only.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winvalid-offsetof"
static_assert(__offsetof(IOSkywalkEthernetInterface, mExpansionData2) == 0x108, "24H32 Ethernet expansion offset");
#pragma clang diagnostic pop'''
if s.count(old)!=1:
    raise SystemExit("ABI_PATCH_FAILED expected offset assertion did not match exactly once")
p.write_text(s.replace(old,new,1))
print("ABI_PATCH_APPLIED=YES")
print("OFFSET_ASSERTION_RETAINED=YES")
print("OFFSET_ASSERTION_VALUE=0x108")
print("DIAGNOSTIC_SCOPE=single assertion")
PY
PATCH_ACTIVE=1

{
  echo
  echo "--- Patched ABI assertion ---"
  nl -ba "$ABI" | sed -n '444,464p'
  echo
} >> "$REPORT"

# Validate exactly the approved native build recipe set before building.
(cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -n -B -f Makefile rtl88wifi-native) > "$DRYRUN" 2>&1
python3 - "$DRYRUN" "$SRC" <<'PY' >> "$REPORT"
import pathlib,re,shlex,sys
p,src=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
issues=[]; compiler=[]; generator=0; rsync=0
for n,line in enumerate(p.read_text(errors="replace").splitlines(),1):
    t=line.strip()
    if not t: continue
    if t.startswith("xcrun clang ") or t.startswith("xcrun clang++ "):
        if re.search(r"\b(sudo|kextload|kmutil|bless|systemextensionsctl)\b|/Library/Extensions|EFI/OC|OpenCore",t,re.I):
            issues.append("FORBIDDEN_DESTINATION_OR_TOOL line %d"%n)
        compiler.append(t); continue
    try: argv=shlex.split(t,posix=True)
    except ValueError:
        issues.append("UNPARSEABLE_RECIPE line %d"%n); continue
    if not argv: continue
    exe=pathlib.PurePath(argv[0]).name
    if exe=="mkdir" and len(argv)==3 and argv[1]=="-p" and argv[2].startswith(str(src)+"/build/"):
        continue
    if exe=="echo":
        continue
    if exe=="python3" and argv==["python3",str(src/"scripts/gen_fw_blobs.py"),str(src/"firmware"),str(src/"src/compat/fw_blobs.c")]:
        generator+=1; continue
    if exe=="rsync" and argv==["rsync","-a","--exclude=MacOS",str(src)+"/RTL88WiFiNative.kext/",str(src)+"/build/out/RTL88WiFiNative.kext/"]:
        rsync+=1; continue
    issues.append("UNEXPECTED_RECIPE line %d: %s"%(n,t[:280]))
compiles=sum(bool(re.search(r"\s-c\s",x)) for x in compiler)
links=sum(bool("-static" in x and "-nostdlib" in x and "-Xlinker -kext" in x) for x in compiler)
for x in issues: print("DRYRUN_BLOCKER="+x)
ok=not issues and compiles>=30 and links==1 and generator==1 and rsync==1
print("DRYRUN_COMPILER_COMMANDS=%d"%len(compiler))
print("DRYRUN_COMPILE_COMMANDS=%d"%compiles)
print("DRYRUN_KEXT_LINK_COMMANDS=%d"%links)
print("DRYRUN_FIRMWARE_GENERATOR_COMMANDS=%d"%generator)
print("DRYRUN_KEXT_TEMPLATE_RSYNC_COMMANDS=%d"%rsync)
print("DRYRUN_PREFLIGHT="+("PASS" if ok else "BLOCKED"))
if not ok: raise SystemExit(9)
PY

FW_GENERATED="$SRC/src/compat/fw_blobs.c"
FW_BACKUP="$BACK/fw_blobs.c"
FW_ORIG_PRESENT=0
if [[ -f "$FW_GENERATED" ]]; then cp -p "$FW_GENERATED" "$FW_BACKUP"; FW_ORIG_PRESENT=1; fi
FW_BACKUP_ACTIVE=1
trap 'rc=$?; if [[ "$FW_BACKUP_ACTIVE" == 1 ]]; then restore_fw_generated || true; fi; if [[ "$PATCH_ACTIVE" == 1 ]]; then rollback_abi || true; fi; echo "STAGE35X2_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

set +e
(cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -B -f Makefile rtl88wifi-native) > "$BUILDLOG" 2>&1
BUILD_RC=$?
set -e
restore_fw_generated

{
  echo
  echo "--- Native build and exact diagnostics ---"
  echo "NATIVE_BUILD_EXIT=$BUILD_RC"
  echo "NATIVE_BUILD_LOG_BYTES=$(wc -c < "$BUILDLOG" | tr -d ' ')"
  echo "NATIVE_BUILD_LOG_LINES=$(wc -l < "$BUILDLOG" | tr -d ' ')"
  echo "COMPILE_ERROR_LINES=$(grep -Ec '(^|: )(fatal error:|error:)' "$BUILDLOG" || true)"
  echo "WARNING_LINES=$(grep -Ec 'warning:' "$BUILDLOG" || true)"
  echo "ABI_NON_STANDARD_LAYOUT_OFFSET_WARNING_LINES=$(grep -Ec "warning: offset of on non-standard-layout type 'IOSkywalkEthernetInterface'" "$BUILDLOG" || true)"
  echo "PACKED_MEMBER_WARNING_LINES=$(grep -Ec 'address-of-packed-member' "$BUILDLOG" || true)"
  echo "CONDITIONAL_UNINITIALIZED_WARNING_LINES=$(grep -Ec 'conditional-uninitialized' "$BUILDLOG" || true)"
  echo "ABI_OFFSET_DIAGNOSTIC_EXCERPTS:"
  grep -n -E 'offset of on non-standard-layout type|invalid offsetof' "$BUILDLOG" | head -30 || true
  echo
  echo "--- Build tail ---"
  tail -100 "$BUILDLOG"
} >> "$REPORT"

KEXT="$SRC/build/out/RTL88WiFiNative.kext"
ARTIFACT=""
ARTIFACT_REMOTE=""
ARTIFACT_BLOB="NONE"
ARTIFACT_SHA=""
ARTIFACT_BYTES=0
if [[ "$BUILD_RC" -eq 0 && -f "$KEXT/Contents/MacOS/RTL88WiFiNative" && -f "$KEXT/Contents/Info.plist" ]]; then
  set +e
  FILE_INFO="$(file "$KEXT/Contents/MacOS/RTL88WiFiNative" 2>&1)"; FILE_RC=$?
  LIPO_INFO="$(lipo -info "$KEXT/Contents/MacOS/RTL88WiFiNative" 2>&1)"; LIPO_RC=$?
  PLIST_INFO="$(plutil -lint "$KEXT/Contents/Info.plist" 2>&1)"; PLIST_RC=$?
  set -e
  {
    echo "KEXT_EXECUTABLE_FILE_RC=$FILE_RC"
    echo "KEXT_EXECUTABLE_FILE=$FILE_INFO"
    echo "KEXT_LIPO_INFO_RC=$LIPO_RC"
    echo "KEXT_ARCHITECTURES=$LIPO_INFO"
    echo "KEXT_PLUTIL_LINT_RC=$PLIST_RC"
    echo "KEXT_INFO_PLIST_VALIDATION=$PLIST_INFO"
  } >> "$REPORT"
  if [[ "$FILE_RC" -ne 0 || "$LIPO_RC" -ne 0 || "$PLIST_RC" -ne 0 || "$FILE_INFO" != *"x86_64"* || "$LIPO_INFO" != *"x86_64"* || "$PLIST_INFO" != *"OK"* ]]; then
    echo "BUILD_VALIDATION=FAIL" >> "$REPORT"
    BUILD_RC=98
  else
    echo "BUILD_VALIDATION=PASS" >> "$REPORT"
  fi
fi
if [[ "$BUILD_RC" -eq 0 && ( ! -f "$KEXT/Contents/MacOS/RTL88WiFiNative" || ! -f "$KEXT/Contents/Info.plist" ) ]]; then
  echo "BUILD_VALIDATION=FAIL_MISSING_KEXT_FILES" >> "$REPORT"
  BUILD_RC=97
fi

if [[ "$BUILD_RC" -eq 0 ]]; then
  # The exact compiler warning was expected to be suppressed only at the
  # asserted ABI member. Treat its reappearance as a failed patch and rollback.
  ABI_WARNING_COUNT="$(grep -Ec "warning: offset of on non-standard-layout type 'IOSkywalkEthernetInterface'" "$BUILDLOG" || true)"
  ABI_UNKNOWN_GROUP_COUNT="$(grep -Ec "unknown warning group '-Winvalid-offsetof'" "$BUILDLOG" || true)"
  {
    echo "ABI_NON_STANDARD_LAYOUT_OFFSET_WARNING_LINES=$ABI_WARNING_COUNT"
    echo "ABI_UNKNOWN_WARNING_GROUP_LINES=$ABI_UNKNOWN_GROUP_COUNT"
  } >> "$REPORT"
  if [[ "$ABI_WARNING_COUNT" -ne 0 || "$ABI_UNKNOWN_GROUP_COUNT" -ne 0 ]]; then
    echo "ABI_WARNING_SUPPRESSION=FAIL offset_warnings=$ABI_WARNING_COUNT unknown_group_warnings=$ABI_UNKNOWN_GROUP_COUNT" >> "$REPORT"
    BUILD_RC=96
  else
    echo "ABI_WARNING_SUPPRESSION=PASS" >> "$REPORT"
  fi
fi

if [[ "$BUILD_RC" -eq 0 ]]; then
  ARTIFACT="$OUT/RTL88WiFiNative-$RUN.tar.gz"
  tar -czf "$ARTIFACT" -C "$SRC/build/out" RTL88WiFiNative.kext
  ARTIFACT_BYTES="$(wc -c < "$ARTIFACT" | tr -d ' ')"
  ARTIFACT_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
  echo "KEXT_ARCHIVE_BYTES=$ARTIFACT_BYTES" >> "$REPORT"
  echo "KEXT_ARCHIVE_SHA256=$ARTIFACT_SHA" >> "$REPORT"
  PATCH_ACTIVE=0
  echo "ABI_PATCH_PERSISTED=YES" >> "$REPORT"
else
  rollback_abi
  echo "ABI_PATCH_PERSISTED=NO" >> "$REPORT"
fi

ABI_AFTER="$(shasum -a 256 "$ABI" | awk '{print $1}')"
{
  echo
  echo "--- Final source and safety status ---"
  echo "ABI_SHA256_BEFORE=$ABI_BEFORE"
  echo "ABI_SHA256_AFTER=$ABI_AFTER"
  echo "GENERATED_FW_SOURCE_RESTORED=YES"
  echo "ABI_PATCH_ROLLED_BACK=$([[ "$BUILD_RC" -eq 0 ]] && echo NO || echo YES)"
  echo "OFFSET_ASSERTION_RETAINED=YES"
  echo "OFFSET_ASSERTION_VALUE=0x108"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "CODESIGN=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
  echo "HARDWARE_TEST=NOT_RUN"
  echo "========== END STAGE 35X2 =========="
} >> "$REPORT"

upload_file() {
  local f="$1" path="$2" msg="$3" payload="$4" response="$5" old put got
  old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
  python3 - "$f" "$old" "$msg" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,sha,msg,dest=sys.argv[1:]
v={"message":msg,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha: v["sha"]=sha
pathlib.Path(dest).write_text(json.dumps(v))
PY2
  if ! gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" >"$response" 2>"$UPLOAD_ERROR"; then
    echo "UPLOAD_FAILED_PATH=$path" >> "$UPLOAD_ERROR"; return 1
  fi
  put="$(python3 - "$response" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); s=(v.get("content") or {}).get("sha")
if not s: raise SystemExit("Missing returned blob SHA")
print(s)
PY2
)"
  got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
  [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >> "$UPLOAD_ERROR"; return 1; }
  UPLOAD_SHA="$got"
}

if [[ -n "$ARTIFACT" ]]; then
  ARTIFACT_REMOTE="Development/Artifacts/stage35x2/RTL88WiFiNative-$RUN.tar.gz"
  upload_file "$ARTIFACT" "$ARTIFACT_REMOTE" "Add Stage35X2 native Kext artifact $RUN" "$OUT/artifact-upload.json" "$OUT/artifact-upload-response.json"
  ARTIFACT_BLOB="$UPLOAD_SHA"
  echo "KEXT_ARCHIVE_GITHUB_PATH=$ARTIFACT_REMOTE" >> "$REPORT"
  echo "KEXT_ARCHIVE_GITHUB_BLOB=$ARTIFACT_BLOB" >> "$REPORT"
fi

mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"
MANIFEST="$OUT/manifest.txt"
ARTIFACT_PATH="$ARTIFACT_REMOTE"; [[ -n "$ARTIFACT_PATH" ]] || ARTIFACT_PATH="NONE"
ARTIFACT_SHA_VALUE="$ARTIFACT_SHA"; [[ -n "$ARTIFACT_SHA_VALUE" ]] || ARTIFACT_SHA_VALUE="NONE"
printf 'STAGE: 35X2\nRUN: %s\nTARGET: rtl88wifi-native\nBUILD_EXIT: %s\nPATCH_SCOPE: targeted clang diagnostic around preserved ABI offset assertion\nABI_ASSERTION: 0x108\nARTIFACT_PATH: %s\nARTIFACT_BLOB: %s\nARTIFACT_SHA256: %s\nARTIFACT_BYTES: %s\n' "$RUN" "$BUILD_RC" "$ARTIFACT_PATH" "$ARTIFACT_BLOB" "$ARTIFACT_SHA_VALUE" "$ARTIFACT_BYTES" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35x2/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35X2 build report $RUN/$name" "$OUT/log-upload.json" "$OUT/log-upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35x2/$RUN/manifest.txt" "Add Stage35X2 manifest $RUN" "$OUT/manifest-upload.json" "$OUT/manifest-upload-response.json"

echo "STAGE35X2_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35X2_RUN=$RUN"
echo "STAGE35X2_BUILD_EXIT=$BUILD_RC"
echo "STAGE35X2_ABI_PATCH_PERSISTED=$([[ "$BUILD_RC" -eq 0 ]] && echo YES || echo NO)"
echo "STAGE35X2_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35x2/$RUN"
trap - ERR
exit "$BUILD_RC"
