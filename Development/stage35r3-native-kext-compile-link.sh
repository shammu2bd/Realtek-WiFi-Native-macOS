#!/bin/bash
# Stage 35R v3 — native RTL88WiFi Kext compile/link attempt.
# This writes only into the project's build/ directory and a temporary report folder.
# It never installs, loads, signs, or edits OpenCore.
set -Eeuo pipefail

echo "STAGE35R_SCRIPT_VERSION=3"
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35R-$RUN"
REPORT="$OUT/report.txt"
DRYRUN="$OUT/native-dry-run.txt"
BUILDLOG="$OUT/native-build.log"
UPLOAD_ERROR="$OUT/upload-error.txt"
DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35R_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 make xcrun split shasum tar file lipo plutil; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" ]] || { echo "ERROR: Stage26 Makefile missing: $SRC/Makefile"; exit 3; }
[[ -d "$SRC/MacKernelSDK/Headers/IOKit/skywalk" ]] || { echo "ERROR: project MacKernelSDK Skywalk headers missing"; exit 4; }
[[ -f "$SRC/scripts/gen_fw_blobs.py" ]] || { echo "ERROR: firmware generator missing: $SRC/scripts/gen_fw_blobs.py"; exit 4; }
[[ -d "$SRC/firmware" ]] || { echo "ERROR: firmware input directory missing: $SRC/firmware"; exit 4; }
[[ -d "$SRC/RTL88WiFiNative.kext" ]] || { echo "ERROR: native Kext template missing: $SRC/RTL88WiFiNative.kext"; exit 4; }
for h in IOSkywalkTxSubmissionQueue.h IOSkywalkTxCompletionQueue.h IOSkywalkPacketBufferPool.h IOSkywalkPacket.h; do
  [[ -f "$SRC/MacKernelSDK/Headers/IOKit/skywalk/$h" ]] || { echo "ERROR: required project SDK header missing: $h"; exit 5; }
done
[[ -d "$DEVELOPER_DIR" ]] || { echo "ERROR: Xcode 16.4 developer directory missing: $DEVELOPER_DIR"; exit 6; }
export DEVELOPER_DIR
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
[[ -d "$SDKROOT" ]] || { echo "ERROR: xcrun returned invalid SDKROOT: $SDKROOT"; exit 7; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 8; }

# Fingerprint the source tree so the build can be shown not to have edited sources.
python3 - "$SRC/src" "$OUT/source-before.sha256" <<'PY'
import hashlib, pathlib, sys
root=pathlib.Path(sys.argv[1]); h=hashlib.sha256(); count=0
for p in sorted(x for x in root.rglob("*") if x.is_file()):
    rel=str(p.relative_to(root)).encode()
    try: data=p.read_bytes()
    except OSError as e: raise SystemExit("SOURCE_READ_ERROR %s %s"%(p,e))
    h.update(len(rel).to_bytes(8,"big")); h.update(rel)
    h.update(len(data).to_bytes(8,"big")); h.update(data); count+=1
pathlib.Path(sys.argv[2]).write_text("files=%d\nsha256=%s\n"%(count,h.hexdigest()))
PY

{
  echo "========== STAGE 35R: NATIVE KEXT COMPILE/LINK =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "source_root=$SOURCE_ROOT"
  echo "target=rtl88wifi-native"
  echo "developer_dir=$DEVELOPER_DIR"
  echo "sdkroot=$SDKROOT"
  echo "build_mode=forced actual compile/link; -B forces all target objects"
  echo "build_output=$SRC/build/out/RTL88WiFiNative.kext"
  echo "side_effect_boundary=project build/ only; no install/load/OpenCore"
  echo
  echo "--- Source fingerprint before build ---"
  cat "$OUT/source-before.sha256"
  echo
  echo "--- Project private SDK header preflight ---"
  for h in IOSkywalkTxSubmissionQueue.h IOSkywalkTxCompletionQueue.h IOSkywalkPacketBufferPool.h IOSkywalkPacket.h; do
    echo "FOUND $SRC/MacKernelSDK/Headers/IOKit/skywalk/$h"
  done
} > "$REPORT"

# Confirm Make's parse-time shell and included dependency files are not hiding
# extra commands before allowing a forced build.
python3 - "$SRC/Makefile" "$SRC/build" "$OUT/makefile-preflight.txt" <<'PY'
import pathlib,re,shlex,sys
mk,build,out=map(pathlib.Path,sys.argv[1:])
lines=mk.read_text(errors="replace").splitlines()
issues=[]; notes=[]
for n,line in enumerate(lines,1):
    if "$(shell" in line or "${shell" in line:
        expr=line.split("$(shell",1)[-1].split(")",1)[0] if "$(shell" in line else line.split("${shell",1)[-1].split("}",1)[0]
        # Split shell control operators, then inspect only argv[0] for each
        # command. Arguments such as hw.logicalcpu must never be mistaken for
        # executable names.
        commands=[]
        for part in re.split(r"\s*(?:&&|\|\||[;&|])\s*",expr):
            part=part.strip()
            if not part:
                continue
            try:
                argv=shlex.split(part,posix=True)
            except ValueError as e:
                issues.append("UNPARSEABLE_PARSE_SHELL line %d: %s"%(n,e))
                continue
            while argv and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=",argv[0]):
                argv.pop(0)
            if argv:
                commands.append(pathlib.PurePath(argv[0]).name)
        bad=[c for c in commands if c not in {"sysctl","pwd","xcrun","echo"}]
        if bad: issues.append("UNSAFE_PARSE_SHELL line %d executables=%s"%(n,bad))
        else: notes.append("READ_ONLY_PARSE_SHELL line %d executables=%s: %s"%(n,commands,line.strip()))
    if "$(MAKE)" in line or "${MAKE}" in line or "$(file" in line or "${file" in line or "$(guile" in line or "$(eval" in line:
        issues.append("POTENTIALLY_SIDE_EFFECTING_MAKE_CONSTRUCT line %d: %s"%(n,line.strip()))
    if re.match(r"^\t[ \t]*[ @+-]*\+",line):
        issues.append("FORCE_EXECUTED_RECIPE line %d: %s"%(n,line.strip()))
deps=list(build.rglob("*.d")) if build.exists() else []
for p in deps:
    d=p.read_text(errors="replace")
    if any(x in d for x in ("$(MAKE)","$(shell","${shell","$(file","$(eval")) or re.search(r"(?m)^\t[ \t]*[ @+-]*\+",d):
        issues.append("UNSAFE_INCLUDED_DEPFILE %s"%p)
print("MAKEFILE=%s"%mk)
print("DEPENDENCY_FILES_SCANNED=%d"%len(deps))
for x in notes: print(x)
for x in issues: print("BLOCKER: "+x)
print("MAKEFILE_PREFLIGHT="+("BLOCKED" if issues else "PASS"))
pathlib.Path(out).write_text("MAKEFILE_PREFLIGHT="+("BLOCKED" if issues else "PASS")+"\n"+"\n".join(notes+issues)+"\n")
if issues: raise SystemExit(9)
PY
cat "$OUT/makefile-preflight.txt" >> "$REPORT"

# Dry-run command allow-list. In addition to compiler/linker and build/
# mkdir commands, this target has two understood recipes:
# 1) the firmware generator writes exactly src/compat/fw_blobs.c (backed up
#    and restored around the build below);
# 2) rsync copies the project Kext template into build/out only.
(cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -n -B -f Makefile rtl88wifi-native) > "$DRYRUN" 2>&1
python3 - "$DRYRUN" "$SRC" "$OUT/dryrun-preflight.txt" <<'PY'
import pathlib,re,shlex,sys
p,src,out=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),pathlib.Path(sys.argv[3])
text=p.read_text(errors="replace")
issues=[]; compiler=[]; generator_count=0; rsync_count=0; mkdir_count=0; echo_count=0
src_s=str(src)
expected_generator=[
    "python3", str(src/"scripts/gen_fw_blobs.py"),
    str(src/"firmware"), str(src/"src/compat/fw_blobs.c")
]
expected_rsync=[
    "rsync", "-a", "--exclude=MacOS",
    src_s+"/RTL88WiFiNative.kext/",
    src_s+"/build/out/RTL88WiFiNative.kext/"
]
for n,line in enumerate(text.splitlines(),1):
    t=line.strip()
    if not t: continue
    if t.startswith("xcrun clang ") or t.startswith("xcrun clang++ "):
        compiler.append(t)
        if re.search(r"\b(sudo|kextload|kmutil|bless|systemextensionsctl)\b|/Library/Extensions|EFI/OC|OpenCore",t,re.I):
            issues.append("FORBIDDEN_TOOL_OR_DESTINATION line %d"%n)
        continue
    try:
        argv=shlex.split(t,posix=True)
    except ValueError as e:
        issues.append("UNPARSEABLE_RECIPE line %d: %s"%(n,e)); continue
    if not argv: continue
    exe=pathlib.PurePath(argv[0]).name
    if exe=="mkdir":
        if len(argv)==3 and argv[1]=="-p" and argv[2].startswith(src_s+"/build/"):
            mkdir_count+=1
        else:
            issues.append("UNEXPECTED_MKDIR line %d: %s"%(n,t[:240]))
    elif exe=="echo":
        echo_count+=1
    elif exe=="python3":
        if argv==expected_generator:
            generator_count+=1
        else:
            issues.append("UNEXPECTED_PYTHON_RECIPE line %d: %s"%(n,t[:320]))
    elif exe=="rsync":
        if argv==expected_rsync:
            rsync_count+=1
        else:
            issues.append("UNEXPECTED_RSYNC_RECIPE line %d: %s"%(n,t[:320]))
    else:
        issues.append("UNEXPECTED_RECIPE line %d: %s"%(n,t[:320]))
compile_count=sum(1 for x in compiler if re.search(r"\s-c\s",x))
link_count=sum(1 for x in compiler if "-static" in x and "-nostdlib" in x and "-Xlinker" in x and "-kext" in x)
expected_output=src_s+"/build/out/RTL88WiFiNative.kext/Contents/MacOS/RTL88WiFiNative"
output_ok=any(expected_output in x for x in compiler)
headers_ok=any(src_s+"/MacKernelSDK/Headers" in x for x in compiler)
print("DRYRUN_COMPILER_COMMANDS=%d"%len(compiler))
print("COMPILE_COMMANDS=%d"%compile_count)
print("KEXT_LINK_COMMANDS=%d"%link_count)
print("BUILD_MKDIR_COMMANDS=%d"%mkdir_count)
print("ECHO_COMMANDS=%d"%echo_count)
print("FIRMWARE_GENERATOR_COMMANDS=%d"%generator_count)
print("KEXT_TEMPLATE_RSYNC_COMMANDS=%d"%rsync_count)
print("EXPECTED_OUTPUT_PATH_PRESENT=%s"%("YES" if output_ok else "NO"))
print("PROJECT_MAC_KERNEL_SDK_INCLUDE_PRESENT=%s"%("YES" if headers_ok else "NO"))
for x in issues: print("BLOCKER="+x)
ok=(not issues and compile_count>=30 and link_count==1 and output_ok and headers_ok
    and generator_count==1 and rsync_count==1)
print("DRYRUN_PREFLIGHT="+("PASS" if ok else "BLOCKED"))
out.write_text("DRYRUN_PREFLIGHT="+("PASS" if ok else "BLOCKED")+"\n")
if not ok: raise SystemExit(10)
PY
cat "$OUT/dryrun-preflight.txt" >> "$REPORT"
{
  echo
  echo "--- Dry-run summary ---"
  echo "DRYRUN_BYTES=$(wc -c < "$DRYRUN" | tr -d ' ')"
  echo "DRYRUN_LINES=$(wc -l < "$DRYRUN" | tr -d ' ')"
  echo "DRYRUN_CLANG_COMMANDS=$(grep -Ec '^xcrun clang(\+\+)? ' "$DRYRUN" || true)"
  echo "DRYRUN_KEXT_LINK_COMMANDS=$(grep -Ec ' -static -nostdlib .* -Xlinker -kext ' "$DRYRUN" || true)"
  echo "DRYRUN_INSTALL_OR_LOAD_COMMANDS=0"
  echo
  echo "--- Actual forced native build ---"
  echo "command=env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -B -f Makefile rtl88wifi-native"
} >> "$REPORT"

# The forced Make build regenerates one source-tree file. Preserve its
# original bytes (or absence) and restore it even on an interrupted build.
FW_GENERATED="$SRC/src/compat/fw_blobs.c"
FW_BACKUP="$OUT/fw_blobs.c.original"
FW_ORIG_PRESENT=0
if [[ -f "$FW_GENERATED" ]]; then
  cp -p "$FW_GENERATED" "$FW_BACKUP"
  FW_ORIG_PRESENT=1
fi
FW_BACKUP_ACTIVE=1
restore_fw_generated() {
  if [[ "${FW_BACKUP_ACTIVE:-0}" == "1" ]]; then
    if [[ "${FW_ORIG_PRESENT:-0}" == "1" ]]; then
      cp -p "$FW_BACKUP" "$FW_GENERATED"
    else
      rm -f "$FW_GENERATED"
    fi
    FW_BACKUP_ACTIVE=0
  fi
}
trap restore_fw_generated EXIT

{
  echo
  echo "FW_GENERATED_SOURCE=$FW_GENERATED"
  echo "FW_GENERATED_SOURCE_PREEXISTED=$([[ "$FW_ORIG_PRESENT" == 1 ]] && echo YES || echo NO)"
  echo "FW_GENERATOR_POLICY=temporary output; original source file restored after build"
  echo
} >> "$REPORT"

set +e
(cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -B -f Makefile rtl88wifi-native) > "$BUILDLOG" 2>&1
BUILD_RC=$?
set -e
restore_fw_generated
trap - EXIT

{
  echo "NATIVE_BUILD_EXIT=$BUILD_RC"
  echo "NATIVE_BUILD_LOG_BYTES=$(wc -c < "$BUILDLOG" | tr -d ' ')"
  echo "NATIVE_BUILD_LOG_LINES=$(wc -l < "$BUILDLOG" | tr -d ' ')"
  echo "COMPILE_ERROR_LINES=$(grep -Ec '(^|: )(fatal error:|error:)' "$BUILDLOG" || true)"
  echo "WARNING_LINES=$(grep -Ec 'warning:' "$BUILDLOG" || true)"
  echo
  echo "--- Build output tail ---"
  tail -160 "$BUILDLOG"
  echo
  echo "--- Complete build output ---"
  cat "$BUILDLOG"
  echo "--- End complete build output ---"
  echo
} >> "$REPORT"

KEXT="$SRC/build/out/RTL88WiFiNative.kext"
ARTIFACT=""
ARTIFACT_SHA=""
ARTIFACT_BYTES=0
if [[ $BUILD_RC -eq 0 && -d "$KEXT" && -f "$KEXT/Contents/MacOS/RTL88WiFiNative" && -f "$KEXT/Contents/Info.plist" ]]; then
  {
    echo "KEXT_BUNDLE_CREATED=YES"
    echo "KEXT_EXECUTABLE=$KEXT/Contents/MacOS/RTL88WiFiNative"
    echo "KEXT_EXECUTABLE_FILE=$(file "$KEXT/Contents/MacOS/RTL88WiFiNative")"
    echo "KEXT_ARCHITECTURES=$(lipo -info "$KEXT/Contents/MacOS/RTL88WiFiNative" 2>&1 || true)"
    echo "KEXT_INFO_PLIST_VALIDATION=$(plutil -lint "$KEXT/Contents/Info.plist" 2>&1 || true)"
  } >> "$REPORT"
  ARTIFACT="$OUT/RTL88WiFiNative-$RUN.tar.gz"
  tar -czf "$ARTIFACT" -C "$SRC/build/out" RTL88WiFiNative.kext
  ARTIFACT_BYTES="$(wc -c < "$ARTIFACT" | tr -d ' ')"
  ARTIFACT_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
  echo "KEXT_ARCHIVE_BYTES=$ARTIFACT_BYTES" >> "$REPORT"
  echo "KEXT_ARCHIVE_SHA256=$ARTIFACT_SHA" >> "$REPORT"
else
  echo "KEXT_BUNDLE_CREATED=NO" >> "$REPORT"
  echo "REASON=Build failed or expected executable/Info.plist is missing." >> "$REPORT"
fi

python3 - "$SRC/src" "$OUT/source-after.sha256" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); h=hashlib.sha256(); count=0
for p in sorted(x for x in root.rglob("*") if x.is_file()):
    rel=str(p.relative_to(root)).encode(); data=p.read_bytes()
    h.update(len(rel).to_bytes(8,"big")); h.update(rel)
    h.update(len(data).to_bytes(8,"big")); h.update(data); count+=1
pathlib.Path(sys.argv[2]).write_text("files=%d\nsha256=%s\n"%(count,h.hexdigest()))
PY
if cmp -s "$OUT/source-before.sha256" "$OUT/source-after.sha256"; then
  SOURCE_TREE_MODIFIED=NO
else
  SOURCE_TREE_MODIFIED=YES
fi
{
  echo
  echo "--- Source tree immutability check ---"
  cat "$OUT/source-after.sha256"
  echo "SOURCE_TREE_MODIFIED=$SOURCE_TREE_MODIFIED"
  echo
  echo "--- Safety boundary ---"
  echo "BUILD_OUTPUTS_WRITTEN=YES"
  echo "SOURCE_FILES_EDITED=$([[ "$SOURCE_TREE_MODIFIED" == NO ]] && echo NO || echo YES)"
  echo "GENERATED_FW_SOURCE_RESTORED=YES"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "CODESIGN=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
  echo "HARDWARE_TEST=NOT_RUN"
  echo "========== END STAGE 35R =========="
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
    echo "UPLOAD_FAILED_PATH=$path" >>"$UPLOAD_ERROR"
    return 1
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

# Upload the built Kext archive only when the native target really succeeded.
ARTIFACT_REMOTE=""
ARTIFACT_BLOB=""
if [[ -n "$ARTIFACT" && "$ARTIFACT_BYTES" -le 25000000 ]]; then
  ARTIFACT_REMOTE="Development/Artifacts/stage35r/RTL88WiFiNative-$RUN.tar.gz"
  if upload_file "$ARTIFACT" "$ARTIFACT_REMOTE" "Add Stage35R native Kext build artifact $RUN" "$OUT/artifact-upload.json" "$OUT/artifact-upload-response.json"; then
    ARTIFACT_BLOB="$UPLOAD_SHA"
    echo "KEXT_ARCHIVE_GITHUB_PATH=$ARTIFACT_REMOTE" >> "$REPORT"
    echo "KEXT_ARCHIVE_GITHUB_BLOB=$ARTIFACT_BLOB" >> "$REPORT"
  else
    echo "KEXT_ARCHIVE_GITHUB_UPLOAD=FAILED" >> "$REPORT"
  fi
elif [[ -n "$ARTIFACT" ]]; then
  echo "KEXT_ARCHIVE_GITHUB_UPLOAD=SKIPPED_OVER_25MB" >> "$REPORT"
fi

mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"
MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 35R\nRUN: %s\nTARGET: rtl88wifi-native\nBUILD_EXIT: %s\nARTIFACT_PATH: %s\nARTIFACT_BLOB: %s\nARTIFACT_SHA256: %s\nARTIFACT_BYTES: %s\n' "$RUN" "$BUILD_RC" "${ARTIFACT_REMOTE:-NONE}" "${ARTIFACT_BLOB:-NONE}" "${ARTIFACT_SHA:-NONE}" "$ARTIFACT_BYTES" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35r/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35R native build report $RUN/$name" "$OUT/log-upload.json" "$OUT/log-upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35r/$RUN/manifest.txt" "Add Stage35R manifest $RUN" "$OUT/manifest-upload.json" "$OUT/manifest-upload-response.json"

echo "STAGE35R_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35R_RUN=$RUN"
echo "STAGE35R_BUILD_EXIT=$BUILD_RC"
echo "STAGE35R_ARTIFACT_REMOTE=${ARTIFACT_REMOTE:-NONE}"
echo "STAGE35R_REPORT_PARTS=$COUNT"
echo "STAGE35R_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35r/$RUN"

# A failed compile/link should still upload diagnostics, then return the make exit.
trap - ERR
exit "$BUILD_RC"
