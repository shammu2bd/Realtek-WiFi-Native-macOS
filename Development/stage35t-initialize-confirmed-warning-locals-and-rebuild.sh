#!/bin/bash
# Stage 35T — guarded fix for three conditional-uninitialized warnings,
# followed by the same native x86_64 Kext build used in Stage35R.
# No signing, installation, loading, or OpenCore modification.
set -Eeuo pipefail

echo "STAGE35T_SCRIPT_VERSION=2"
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW88="$SOURCE_ROOT/driver/rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35T-$RUN"
REPORT="$OUT/report.txt"
DRYRUN="$OUT/native-dry-run.txt"
BUILDLOG="$OUT/native-build.log"
UPLOAD_ERROR="$OUT/upload-error.txt"
DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
mkdir -p "$OUT"
PATCHED=0
FW_BACKUP_ACTIVE=0
ROLLBACK_ACTIVE=0
trap 'rc=$?; if [[ "$FW_BACKUP_ACTIVE" == 1 ]]; then restore_fw_generated || true; fi; if [[ "$ROLLBACK_ACTIVE" == 1 ]]; then rollback_sources || true; fi; echo "STAGE35T_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 make xcrun split shasum tar file lipo plutil grep awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" && -f "$SRC/scripts/gen_fw_blobs.py" && -d "$SRC/firmware" ]] || { echo "ERROR: Stage26 native build inputs missing"; exit 3; }
[[ -f "$RTW88/mac.c" && -f "$RTW88/pci.c" && -f "$RTW88/pci.h" && -f "$RTW88/util.c" ]] || { echo "ERROR: Stage26 rtw88 source files missing"; exit 4; }
[[ -d "$SRC/MacKernelSDK/Headers/IOKit/skywalk" && -d "$SRC/RTL88WiFiNative.kext" ]] || { echo "ERROR: native Kext template or project SDK missing"; exit 5; }
[[ -d "$DEVELOPER_DIR" ]] || { echo "ERROR: Xcode 16.4 Developer directory missing"; exit 6; }
export DEVELOPER_DIR
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
[[ -d "$SDKROOT" ]] || { echo "ERROR: invalid SDKROOT: $SDKROOT"; exit 7; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 8; }

MAC="$RTW88/mac.c"
PCI="$RTW88/pci.c"
PCIH="$RTW88/pci.h"
UTIL="$RTW88/util.c"
BACK="$OUT/backups"
mkdir -p "$BACK"
cp -p "$MAC" "$BACK/mac.c"
cp -p "$PCI" "$BACK/pci.c"
BEFORE="$(shasum -a 256 "$MAC" "$PCI" "$PCIH" "$UTIL")"

# Verify the control-flow assumptions before changing anything:
# - LTE read writes *val before returning true; false means no value is consumed.
# - both PCI warning sites are in loops with a positive, fixed retry count (20).
python3 - "$MAC" "$PCI" "$PCIH" "$UTIL" <<'PY'
import pathlib,re,sys
mac,pci,pcih,util=map(lambda x:pathlib.Path(x).read_text(errors="replace"),sys.argv[1:])
if not re.search(r"(?m)^\s*#define\s+RTW_PCI_WR_RETRY_CNT\s+20\s*$",pcih):
    raise SystemExit("BLOCKED: RTW_PCI_WR_RETRY_CNT is not exactly 20")
m=re.search(r"\bbool\s+ltecoex_read_reg\s*\([^)]*\)\s*\{(.*?)\n\}",util,re.S)
if not m:
    raise SystemExit("BLOCKED: ltecoex_read_reg definition not found")
body=m.group(1)
write=body.find("*val")
success=body.rfind("return true")
failure=body.find("return false")
if write < 0 or success < 0 or write > success or failure < 0 or failure > success:
    raise SystemExit("BLOCKED: ltecoex_read_reg output/return contract differs from audited semantics")
if "u32 ltecoex_bckp;" not in mac:
    raise SystemExit("BLOCKED: mac.c ltecoex backup declaration differs from expected source")
if pci.count("static void rtw_dbi_write8(")!=1 or pci.count("static void rtw_mdio_write(")!=1:
    raise SystemExit("BLOCKED: expected PCI functions are missing or ambiguous")
dbi=pci.split("static void rtw_dbi_write8(",1)[1].split("static int rtw_dbi_read8(",1)[0]
mdio=pci.split("static void rtw_mdio_write(",1)[1].split("static void rtw_pci_clkreq_set(",1)[0]
if dbi.count("\tu8 flag;\n")!=1 or mdio.count("\tu8 wflag;\n")!=1:
    raise SystemExit("BLOCKED: PCI local declarations differ from audited source")
if "for (cnt = 0; cnt < RTW_PCI_WR_RETRY_CNT; cnt++)" not in dbi or "for (cnt = 0; cnt < RTW_PCI_WR_RETRY_CNT; cnt++)" not in mdio:
    raise SystemExit("BLOCKED: PCI retry loops differ from audited source")
print("CONTROL_FLOW_PREFLIGHT=PASS")
print("LTECOEX_READ_OUTPUT_WRITTEN_BEFORE_TRUE=YES")
print("LTECOEX_READ_RETURNS_FALSE_WITHOUT_OUTPUT=YES")
print("PCI_RETRY_COUNT=20")
print("DBI_WRITE_RETRY_LOOP_PRESENT=YES")
print("MDIO_WRITE_RETRY_LOOP_PRESENT=YES")
PY

rollback_sources() {
  if [[ "$ROLLBACK_ACTIVE" == 1 ]]; then
    cp -p "$BACK/mac.c" "$MAC"
    cp -p "$BACK/pci.c" "$PCI"
    ROLLBACK_ACTIVE=0
    echo "SOURCE_PATCH_ROLLBACK=COMPLETED" >> "$REPORT"
  fi
}

restore_fw_generated() {
  if [[ "$FW_BACKUP_ACTIVE" == 1 ]]; then
    if [[ "$FW_ORIG_PRESENT" == 1 ]]; then cp -p "$FW_BACKUP" "$FW_GENERATED"; else rm -f "$FW_GENERATED"; fi
    FW_BACKUP_ACTIVE=0
  fi
}

# Exact, one-occurrence replacements only. The backup copies are used to
# restore both files automatically if the build does not succeed.
python3 - "$MAC" "$PCI" <<'PY'
import pathlib,sys
macp,pcip=map(pathlib.Path,sys.argv[1:])
mac=macp.read_text()
old="\tu32 ltecoex_bckp;\n"
new="\tu32 ltecoex_bckp = 0;\n"
if mac.count(old)!=1:
    raise SystemExit("PATCH_BLOCKED: mac.c declaration is not unique")
mac=mac.replace(old,new,1)

pci=pcip.read_text()
a="static void rtw_dbi_write8("
b="static int rtw_dbi_read8("
c="static void rtw_mdio_write("
d="static void rtw_pci_clkreq_set("
if pci.count(a)!=1 or pci.count(b)!=1 or pci.count(c)!=1 or pci.count(d)!=1:
    raise SystemExit("PATCH_BLOCKED: expected PCI function boundaries are not unique")
left=pci.index(a); right=pci.index(b,left)
dbi=pci[left:right]
if dbi.count("\tu8 flag;\n")!=1:
    raise SystemExit("PATCH_BLOCKED: DBI flag declaration mismatch")
dbi=dbi.replace("\tu8 flag;\n","\tu8 flag = 0;\n",1)
pci=pci[:left]+dbi+pci[right:]
left=pci.index(c); right=pci.index(d,left)
mdio=pci[left:right]
if mdio.count("\tu8 wflag;\n")!=1:
    raise SystemExit("PATCH_BLOCKED: MDIO wflag declaration mismatch")
mdio=mdio.replace("\tu8 wflag;\n","\tu8 wflag = 0;\n",1)
pci=pci[:left]+mdio+pci[right:]
macp.write_text(mac); pcip.write_text(pci)
print("PATCHED mac.c: ltecoex_bckp initialized to 0")
print("PATCHED pci.c: DBI flag initialized to 0")
print("PATCHED pci.c: MDIO wflag initialized to 0")
PY
PATCHED=1
ROLLBACK_ACTIVE=1

{
  echo "========== STAGE 35T: GUARDED WARNING FIX + NATIVE REBUILD =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "source_root=$SOURCE_ROOT"
  echo "target=rtl88wifi-native"
  echo "sdkroot=$SDKROOT"
  echo "predecessor=Stage35S run-20261102-013527"
  echo "patch_scope=three local scalar initializers only"
  echo "mac.c: u32 ltecoex_bckp = 0"
  echo "pci.c: DBI write u8 flag = 0"
  echo "pci.c: MDIO write u8 wflag = 0"
  echo "other changes=NONE"
  echo
  echo "--- Source hashes before patch ---"
  echo "$BEFORE"
  echo
  echo "--- Patched source context ---"
  grep -n -A2 -B2 "ltecoex_bckp = 0" "$MAC"
  grep -n -A2 -B2 "u8 flag = 0" "$PCI"
  grep -n -A2 -B2 "u8 wflag = 0" "$PCI"
} > "$REPORT"

# Re-run a restrained dry-run allow-list. It permits compiler/linker calls,
# build/ directory creation, the one firmware generator and the one Kext copy.
(cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -n -B -f Makefile rtl88wifi-native) > "$DRYRUN" 2>&1
python3 - "$DRYRUN" "$SRC" <<'PY' >> "$REPORT"
import pathlib,re,shlex,sys
p,src=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
lines=p.read_text(errors="replace").splitlines()
commands=[]; issues=[]
for n,line in enumerate(lines,1):
    t=line.strip()
    if not t: continue
    if t.startswith("xcrun clang ") or t.startswith("xcrun clang++ "):
        if re.search(r"\b(sudo|kextload|kmutil|bless|systemextensionsctl)\b|/Library/Extensions|EFI/OC|OpenCore",t,re.I):
            issues.append("FORBIDDEN_DESTINATION_OR_TOOL line %d"%n)
        commands.append(("compiler",t)); continue
    try: argv=shlex.split(t,posix=True)
    except ValueError: issues.append("UNPARSEABLE line %d"%n); continue
    if not argv: continue
    exe=pathlib.PurePath(argv[0]).name
    if exe=="mkdir" and len(argv)==3 and argv[1]=="-p" and argv[2].startswith(str(src)+"/build/"):
        commands.append(("mkdir",t))
    elif exe=="echo": commands.append(("echo",t))
    elif exe=="python3" and argv==["python3",str(src/"scripts/gen_fw_blobs.py"),str(src/"firmware"),str(src/"src/compat/fw_blobs.c")]:
        commands.append(("firmware-generator",t))
    elif exe=="rsync" and len(argv)==5 and argv[1:3]==["-a","--exclude=MacOS"] and argv[3]==str(src)+"/RTL88WiFiNative.kext/" and argv[4]==str(src)+"/build/out/RTL88WiFiNative.kext/":
        commands.append(("kext-template-copy",t))
    else: issues.append("UNEXPECTED_RECIPE line %d: %s"%(n,t[:260]))
comp=[x[1] for x in commands if x[0]=="compiler"]
compiles=sum(bool(re.search(r"\s-c\s",x)) for x in comp)
links=sum(bool("-static" in x and "-nostdlib" in x and "-Xlinker -kext" in x) for x in comp)
gens=sum(x[0]=="firmware-generator" for x in commands)
copies=sum(x[0]=="kext-template-copy" for x in commands)
print("DRYRUN_COMPILER_COMMANDS=%d"%len(comp))
print("DRYRUN_COMPILE_COMMANDS=%d"%compiles)
print("DRYRUN_KEXT_LINK_COMMANDS=%d"%links)
print("DRYRUN_FIRMWARE_GENERATOR_COMMANDS=%d"%gens)
print("DRYRUN_KEXT_TEMPLATE_COPY_COMMANDS=%d"%copies)
for issue in issues: print("DRYRUN_BLOCKER="+issue)
ok=(not issues and compiles>=30 and links==1 and gens==1 and copies==1)
print("DRYRUN_PREFLIGHT="+("PASS" if ok else "BLOCKED"))
if not ok: raise SystemExit(9)
PY

# The Make target regenerates a single firmware source file. Preserve and
# restore it across build success, failure, or interruption.
FW_GENERATED="$SRC/src/compat/fw_blobs.c"
FW_BACKUP="$BACK/fw_blobs.c"
FW_ORIG_PRESENT=0
if [[ -f "$FW_GENERATED" ]]; then cp -p "$FW_GENERATED" "$FW_BACKUP"; FW_ORIG_PRESENT=1; fi
FW_BACKUP_ACTIVE=1
trap 'rc=$?; if [[ "$FW_BACKUP_ACTIVE" == 1 ]]; then restore_fw_generated || true; fi; if [[ "$ROLLBACK_ACTIVE" == 1 ]]; then rollback_sources || true; fi; echo "STAGE35T_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

set +e
(cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -B -f Makefile rtl88wifi-native) > "$BUILDLOG" 2>&1
BUILD_RC=$?
set -e
restore_fw_generated
{
  echo
  echo "--- Actual native build ---"
  echo "NATIVE_BUILD_EXIT=$BUILD_RC"
  echo "NATIVE_BUILD_LOG_BYTES=$(wc -c < "$BUILDLOG" | tr -d ' ')"
  echo "NATIVE_BUILD_LOG_LINES=$(wc -l < "$BUILDLOG" | tr -d ' ')"
  echo "COMPILE_ERROR_LINES=$(grep -Ec '(^|: )(fatal error:|error:)' "$BUILDLOG" || true)"
  echo "WARNING_LINES=$(grep -Ec 'warning:' "$BUILDLOG" || true)"
  echo "CONDITIONAL_UNINITIALIZED_WARNING_LINES=$(grep -Ec 'conditional-uninitialized' "$BUILDLOG" || true)"
  echo "PACKED_MEMBER_WARNING_LINES=$(grep -Ec 'address-of-packed-member' "$BUILDLOG" || true)"
  echo "INVALID_OFFSETOF_WARNING_LINES=$(grep -Ec 'invalid offsetof' "$BUILDLOG" || true)"
  echo
  echo "--- High-risk warning matches ---"
  grep -n -E 'conditional-uninitialized|address-of-packed-member|invalid offsetof' "$BUILDLOG" | head -100 || true
  echo
  echo "--- Build tail ---"
  tail -120 "$BUILDLOG"
} >> "$REPORT"

ARTIFACT=""
ARTIFACT_REMOTE=""
ARTIFACT_SHA=""
ARTIFACT_BLOB="NONE"
ARTIFACT_BYTES=0
KEXT="$SRC/build/out/RTL88WiFiNative.kext"
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
    echo "BUILD_VALIDATION_FAILED=plist or x86_64 architecture validation failed" >> "$REPORT"
    BUILD_RC=98
  else
    echo "BUILD_VALIDATION=PASS" >> "$REPORT"
  fi
fi
if [[ "$BUILD_RC" -eq 0 && ( ! -f "$KEXT/Contents/MacOS/RTL88WiFiNative" || ! -f "$KEXT/Contents/Info.plist" ) ]]; then
  echo "BUILD_VALIDATION_FAILED=expected Kext executable or Info.plist is missing" >> "$REPORT"
  BUILD_RC=97
fi
if [[ "$BUILD_RC" -eq 0 && -f "$KEXT/Contents/MacOS/RTL88WiFiNative" && -f "$KEXT/Contents/Info.plist" ]]; then
  {
    echo
    echo "KEXT_BUNDLE_CREATED=YES"
    echo "KEXT_EXECUTABLE_FILE=$(file "$KEXT/Contents/MacOS/RTL88WiFiNative")"
    echo "KEXT_ARCHITECTURES=$(lipo -info "$KEXT/Contents/MacOS/RTL88WiFiNative" 2>&1 || true)"
    echo "KEXT_INFO_PLIST_VALIDATION=$(plutil -lint "$KEXT/Contents/Info.plist" 2>&1 || true)"
  } >> "$REPORT"
  ARTIFACT="$OUT/RTL88WiFiNative-$RUN.tar.gz"
  tar -czf "$ARTIFACT" -C "$SRC/build/out" RTL88WiFiNative.kext
  ARTIFACT_BYTES="$(wc -c < "$ARTIFACT" | tr -d ' ')"
  ARTIFACT_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
  {
    echo "KEXT_ARCHIVE_BYTES=$ARTIFACT_BYTES"
    echo "KEXT_ARCHIVE_SHA256=$ARTIFACT_SHA"
  } >> "$REPORT"
else
  echo "KEXT_BUNDLE_CREATED=NO" >> "$REPORT"
  echo "REASON=Native compile/link failed or expected Kext files missing" >> "$REPORT"
fi

if [[ "$BUILD_RC" -eq 0 ]]; then
  ROLLBACK_ACTIVE=0
  echo "SOURCE_PATCH_PERSISTED=YES" >> "$REPORT"
else
  rollback_sources
  echo "SOURCE_PATCH_PERSISTED=NO" >> "$REPORT"
fi
AFTER="$(shasum -a 256 "$MAC" "$PCI" "$PCIH" "$UTIL")"
{
  echo
  echo "--- Source hash after build and generated-file restoration ---"
  echo "$AFTER"
  echo "GENERATED_FW_SOURCE_RESTORED=YES"
  echo "PATCHED_SOURCE_FILES=mac.c,pci.c"
  echo "SOURCE_PATCH_ROLLED_BACK=$([[ "$BUILD_RC" -eq 0 ]] && echo NO || echo YES)"
  echo
  echo "--- Safety boundary ---"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "CODESIGN=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
  echo "HARDWARE_TEST=NOT_RUN"
  echo "========== END STAGE 35T =========="
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
    echo "UPLOAD_FAILED_PATH=$path" >>"$UPLOAD_ERROR"; return 1
  fi
  put="$(python3 - "$response" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); s=(v.get("content") or {}).get("sha")
if not s: raise SystemExit("Missing returned blob SHA")
print(s)
PY2
)"
  got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
  [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >>"$UPLOAD_ERROR"; return 1; }
  UPLOAD_SHA="$got"
}

if [[ -n "$ARTIFACT" && "$ARTIFACT_BYTES" -le 25000000 ]]; then
  ARTIFACT_REMOTE="Development/Artifacts/stage35t/RTL88WiFiNative-$RUN.tar.gz"
  upload_file "$ARTIFACT" "$ARTIFACT_REMOTE" "Add Stage35T native Kext artifact $RUN" "$OUT/artifact-upload.json" "$OUT/artifact-upload-response.json"
  echo "KEXT_ARCHIVE_GITHUB_PATH=$ARTIFACT_REMOTE" >> "$REPORT"
  ARTIFACT_BLOB="$UPLOAD_SHA"
  echo "KEXT_ARCHIVE_GITHUB_BLOB=$UPLOAD_SHA" >> "$REPORT"
fi

mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"
MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 35T\nRUN: %s\nTARGET: rtl88wifi-native\nBUILD_EXIT: %s\nPATCH_SCOPE: mac.c ltecoex_bckp=0; pci.c DBI flag=0; pci.c MDIO wflag=0\nARTIFACT_PATH: %s\nARTIFACT_BLOB: %s\nARTIFACT_SHA256: %s\nARTIFACT_BYTES: %s\n' "$RUN" "$BUILD_RC" "${ARTIFACT_REMOTE:-NONE}" "$ARTIFACT_BLOB" "${ARTIFACT_SHA:-NONE}" "$ARTIFACT_BYTES" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35t/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35T build report $RUN/$name" "$OUT/log-upload.json" "$OUT/log-upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35t/$RUN/manifest.txt" "Add Stage35T manifest $RUN" "$OUT/manifest-upload.json" "$OUT/manifest-upload-response.json"

echo "STAGE35T_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35T_RUN=$RUN"
echo "STAGE35T_BUILD_EXIT=$BUILD_RC"
echo "STAGE35T_PATCH_PERSISTED=$([[ "$BUILD_RC" -eq 0 ]] && echo YES || echo NO)"
echo "STAGE35T_ARTIFACT_REMOTE=${ARTIFACT_REMOTE:-NONE}"
echo "STAGE35T_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35t/$RUN"
trap - ERR
exit "$BUILD_RC"
