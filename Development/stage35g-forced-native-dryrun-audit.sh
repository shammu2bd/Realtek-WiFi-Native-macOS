#!/bin/bash
# Stage 35G — force Make to print the complete native target command graph.
# make -n -B only prints commands; it does not build, install, or load a Kext.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35G-$RUN"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
REPORT="$OUT/report.txt"
DRYRUN="$OUT/native-dry-run.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35G_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 make split shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" ]] || { echo "ERROR: Stage26 Makefile not found: $SRC/Makefile"; exit 3; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated. Run gh auth login."; exit 4; }

{
  echo "========== STAGE 35G: FORCED NATIVE TARGET DRY-RUN =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "source_root=$SOURCE_ROOT"
  echo "make_path=$(command -v make)"
  echo "target=rtl88wifi-native"
  echo "mode=make -n -B (print only; no build)"
  echo "source_tree_modification=NO"
  echo
  echo "--- Preflight: Makefile dry-run safety scan ---"
} > "$REPORT"

# -n normally prints recipes rather than running them. These exceptions must
# be rejected; parse-time $(shell ...) is separately allow-listed below.
python3 - "$SRC/Makefile" "$SRC/build" "$OUT/preflight.txt" <<'PY'
import os,re,sys,pathlib
makefile,build,out=map(pathlib.Path,sys.argv[1:])
text=makefile.read_text(errors="replace")
lines=text.splitlines()
issues=[]
notes=[]
# The only parse-time shell commands currently expected in this Makefile are
# read-only host CPU, working-directory, and SDK-path queries.
for n,line in enumerate(lines,1):
    if "$(shell" in line or "${shell" in line:
        expr=line.split("$(shell",1)[-1].split(")",1)[0] if "$(shell" in line else line.split("${shell",1)[-1].split("}",1)[0]
        commands=re.findall(r"(?:^|[|;&()]\s*)([A-Za-z_][A-Za-z0-9_.-]*)",expr)
        allowed={"sysctl","pwd","xcrun","echo"}
        bad=[c for c in commands if c not in allowed]
        if bad: issues.append("UNSAFE_PARSE_SHELL line %d commands=%s text=%s"%(n,bad,line.strip()))
        else: notes.append("ALLOW_READ_ONLY_PARSE_SHELL line %d: %s"%(n,line.strip()))
    if "$(MAKE)" in line or "${MAKE}" in line:
        issues.append("RECURSIVE_MAKE_REFERENCE line %d: %s"%(n,line.strip()))
    if "$(file" in line or "${file" in line or "$(guile" in line or "$(eval" in line:
        issues.append("POTENTIALLY_SIDE_EFFECTING_MAKE_FUNCTION line %d: %s"%(n,line.strip()))
    if re.match(r"^\t[ \t]*[ @+-]*\+",line):
        issues.append("FORCE_EXECUTED_RECIPE line %d: %s"%(n,line.strip()))
# Dependency files included by Makefile are normally plain target prerequisites.
# Reject any existing dependency file containing force-run or recursive-make markers.
depfiles=list(build.rglob("*.d")) if build.exists() else []
for p in depfiles:
    try:
        d=p.read_text(errors="replace")
    except OSError as e:
        issues.append("DEPFILE_READ_ERROR %s %s"%(p,e)); continue
    if "$(MAKE)" in d or "$(shell" in d or "${shell" in d or "$(file" in d or "$(eval" in d or re.search(r"(?m)^\t[ \t]*[ @+-]*\+",d):
        issues.append("UNSAFE_INCLUDED_DEPFILE %s"%p)
print("MAKEFILE=%s"%makefile)
print("DEPFILES_SCANNED=%d"%len(depfiles))
for n in notes: print(n)
for issue in issues: print("BLOCKER: "+issue)
if issues:
    print("DRYRUN_PREFLIGHT=BLOCKED")
else:
    print("DRYRUN_PREFLIGHT=PASS")
pathlib.Path(out).write_text("\n".join(["DRYRUN_PREFLIGHT="+("BLOCKED" if issues else "PASS")]+notes+issues)+"\n")
PY
cat "$OUT/preflight.txt" >> "$REPORT"

if ! grep -q '^DRYRUN_PREFLIGHT=PASS$' "$OUT/preflight.txt"; then
  {
    echo
    echo "NATIVE_DRY_RUN=SKIPPED"
    echo "REASON=Preflight found a potentially force-executed or side-effecting Make construct."
    echo "BUILD=NOT_RUN"
    echo "INSTALL=NOT_RUN"
    echo "LOAD=NOT_RUN"
  } >> "$REPORT"
else
  {
    echo
    echo "--- Explicit forced dry-run: rtl88wifi-native ---"
    echo "command=env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -n -B -f Makefile rtl88wifi-native"
  } >> "$REPORT"
  set +e
  (cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -n -B -f Makefile rtl88wifi-native) > "$DRYRUN" 2>&1
  MAKE_RC=$?
  set -e
  {
    echo "MAKE_DRY_RUN_EXIT=$MAKE_RC"
    echo "DRY_RUN_OUTPUT_BYTES=$(wc -c < "$DRYRUN" | tr -d ' ')"
    echo "DRY_RUN_COMMAND_LINES=$(wc -l < "$DRYRUN" | tr -d ' ')"
    echo "CLANG_COMMAND_LINES=$(grep -Ec '(^|[[:space:]])(clang|clang\+\+)([[:space:]]|$)' "$DRYRUN" || true)"
    echo "LINK_COMMAND_LINES=$(grep -Ec '(^|[[:space:]])(ld|ld64)([[:space:]]|$)' "$DRYRUN" || true)"
    echo "RTW88HwOps.cpp_mentions=$(grep -c 'RTW88HwOps.cpp' "$DRYRUN" || true)"
    echo "RTW88PCIDevice.cpp_mentions=$(grep -c 'RTW88PCIDevice.cpp' "$DRYRUN" || true)"
    echo "RTW88WCLRadioBridge.cpp_mentions=$(grep -c 'RTW88WCLRadioBridge.cpp' "$DRYRUN" || true)"
    echo "RTW88WCLWorkQueue.cpp_mentions=$(grep -c 'RTW88WCLWorkQueue.cpp' "$DRYRUN" || true)"
    echo "RTW88WCLController.cpp_mentions=$(grep -c 'RTW88WCLController.cpp' "$DRYRUN" || true)"
    echo "RTW88WCLInfraInterface.cpp_mentions=$(grep -c 'RTW88WCLInfraInterface.cpp' "$DRYRUN" || true)"
    echo "RTW88WCLPCIBackend.cpp_mentions=$(grep -c 'RTW88WCLPCIBackend.cpp' "$DRYRUN" || true)"
    echo "RTW88WCLSkywalkQueues.cpp_mentions=$(grep -c 'RTW88WCLSkywalkQueues.cpp' "$DRYRUN" || true)"
    echo "RTW88WCLSkywalkTxAdapter.cpp_mentions=$(grep -c 'RTW88WCLSkywalkTxAdapter.cpp' "$DRYRUN" || true)"
    echo "RTW88WCLSkywalkRxAdapter.cpp_mentions=$(grep -c 'RTW88WCLSkywalkRxAdapter.cpp' "$DRYRUN" || true)"
    echo "NATIVE_KEXT_OUTPUT_mentions=$(grep -Eic 'RTL88WiFiNative\.kext|RTL88WiFiNative' "$DRYRUN" || true)"
    echo "DRY_RUN_NOOP=$(grep -Eic 'Nothing to be done|is up to date' "$DRYRUN" || true)"
    echo
    echo "--- Complete dry-run command output follows ---"
    cat "$DRYRUN"
    echo "--- End dry-run output ---"
    echo
    echo "BUILD=NOT_RUN"
    echo "INSTALL=NOT_RUN"
    echo "LOAD=NOT_RUN"
  } >> "$REPORT"
fi

{
  echo
  echo "--- Safety boundary ---"
  echo "SOURCE_TREE_MODIFIED=NO"
  echo "EXISTING_KEXT_MODIFIED=NO"
  echo "OPENCORE_MODIFIED=NO"
  echo "ACTUAL_BUILD=NOT_RUN"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "HARDWARE_TEST=NOT_RUN"
  echo "========== END STAGE 35G =========="
} >> "$REPORT"

# Immutable GitHub log upload, <=220 KB per part, with blob-SHA readback checks.
mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"
upload_file() {
  local file="$1" path="$2" msg="$3" payload="$4" response="$5" old put got
  old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
  python3 - "$file" "$old" "$msg" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,sha,msg,dest=sys.argv[1:]
o={"message":msg,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha:o["sha"]=sha
pathlib.Path(dest).write_text(json.dumps(o))
PY2
  if ! gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" >"$response" 2>"$UPLOAD_ERROR"; then
    echo "UPLOAD_FAILED_PATH=$path" >>"$UPLOAD_ERROR"
    echo "AUTH_ACCOUNT=$(gh api user --jq .login 2>&1 || true)" >>"$UPLOAD_ERROR"
    echo "REPO_PERMISSION=$(gh api "repos/$REPO" --jq '.full_name + " push=" + (.permissions.push|tostring)' 2>&1 || true)" >>"$UPLOAD_ERROR"
    return 1
  fi
  put="$(python3 - "$response" <<'PY2'
import json,sys
d=json.load(open(sys.argv[1])); s=(d.get("content") or {}).get("sha")
if not s: raise SystemExit("Missing GitHub content SHA: "+repr(d)[:800])
print(s)
PY2
)"
  got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
  [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >> "$UPLOAD_ERROR"; return 1; }
  UPLOAD_SHA="$got"
}
MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 35G\nRUN: %s\nTARGET: rtl88wifi-native\n' "$RUN" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35g/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35G native dry-run report $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35g/$RUN/manifest.txt" "Add Stage35G manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35G_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35G_RUN=$RUN"
echo "STAGE35G_REPORT_PARTS=$COUNT"
echo "STAGE35G_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35g/$RUN"
