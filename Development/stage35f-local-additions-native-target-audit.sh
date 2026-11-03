#!/bin/bash
# Stage 35F — inspect local-only 24H32 additions and explicitly dry-run native Make targets.
# Does not modify the source tree, installed kexts, or OpenCore.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
REFERENCE="https://github.com/X1REN41L/RTL88WiFi.git"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35F-$RUN"
REPORT="$OUT/report.txt"
mkdir -p "$OUT"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; echo "STAGE35F_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
for tool in git gh python3 shasum split make; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -d "$SOURCE_ROOT/driver/RTL88WiFi" ]] || { echo "ERROR: expected Stage 26 source missing: $SOURCE_ROOT/driver/RTL88WiFi"; exit 3; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated. Run gh auth login."; exit 4; }
CLONE="$OUT/reference"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
{
  echo "========== STAGE 35F: LOCAL ADDITIONS + NATIVE TARGET DRY-RUN =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "source_root=$SOURCE_ROOT"
  echo "reference=$REFERENCE"
  echo "make_path=$(command -v make)"
  echo
  echo "--- Clone reference in isolated diagnostic directory ---"
} > "$REPORT"
git clone --depth 1 --no-tags "$REFERENCE" "$CLONE" >>"$REPORT" 2>&1
REF="$CLONE/driver/RTL88WiFi"
[[ -d "$REF" ]] || { echo "ERROR: reference driver tree missing" >>"$REPORT"; exit 5; }
echo "reference_head=$(git -C "$CLONE" rev-parse HEAD)" >>"$REPORT"
echo "reference_source_tree=$REF" >>"$REPORT"

python3 - "$SRC" "$REF" "$OUT" >>"$REPORT" <<'PY'
import difflib, hashlib, os, pathlib, re, sys
local, upstream, out = map(pathlib.Path, sys.argv[1:])
skip_dirs={".git","build","DerivedData"}
skip_suffix={".o",".a",".dylib"}
def inventory(root):
    result={}
    for base, dirs, names in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in skip_dirs and not d.endswith(".dSYM"))
        for name in sorted(names):
            p=pathlib.Path(base)/name
            rel=p.relative_to(root).as_posix()
            if name.endswith(tuple(skip_suffix)): continue
            if ".kext/Contents/MacOS/" in "/"+rel: continue
            try:
                raw=p.read_bytes()
                result[rel]=(hashlib.sha256(raw).hexdigest(),len(raw),raw)
            except OSError as e:
                result[rel]=("READ_ERROR:"+str(e),0,b"")
    return result
a,b=inventory(local),inventory(upstream)
common=sorted(a.keys() & b.keys())
changed=[p for p in common if a[p][0]!=b[p][0]]
same=[p for p in common if a[p][0]==b[p][0]]
local_only=sorted(a.keys()-b.keys())
ref_only=sorted(b.keys()-a.keys())
print("\n--- Detailed inventory ---")
print("LOCAL_FILES=%d REFERENCE_FILES=%d IDENTICAL=%d CHANGED=%d LOCAL_ONLY=%d REFERENCE_ONLY=%d"%(len(a),len(b),len(same),len(changed),len(local_only),len(ref_only)))
print("\n[LOCAL-ONLY FILES: category | bytes | sha256 | path]")
for p in local_only:
    low=p.lower()
    if p==".DS_Store": category="macOS metadata"
    elif ".kext/" in p: category="Kext bundle metadata"
    elif "wcl24h32/" in low: category="24H32 WCL implementation"
    elif "completion" in low or "skbuff_tx" in low: category="TX completion/lifetime"
    elif low.endswith((".cpp",".hpp",".h",".c")): category="additional C/C++ source"
    else: category="other"
    print("%s | %d | %s | %s"%(category,a[p][1],a[p][0],p))
print("\n[CHANGED FILES: local bytes/hash vs reference bytes/hash]")
for p in changed:
    print("%s | local=%d:%s | reference=%d:%s"%(p,a[p][1],a[p][0],b[p][1],b[p][0]))
print("\n[CHANGED FILE UNIFIED DIFFS; max 220 lines per file]")
for p in changed:
    try:
        x=a[p][2].decode("utf-8","replace").splitlines()
        y=b[p][2].decode("utf-8","replace").splitlines()
        d=list(difflib.unified_diff(y,x,fromfile="REFERENCE/"+p,tofile="LOCAL/"+p,lineterm=""))
        print("\n### "+p)
        if len(d)>220:
            print("\n".join(d[:220]))
            print("... DIFF TRUNCATED: total_diff_lines=%d"%len(d))
        else: print("\n".join(d))
    except Exception as e: print("DIFF_ERROR",p,repr(e))
print("\n--- Native Makefile target discovery ---")
mk=local/"Makefile"
lines=mk.read_text(errors="replace").splitlines()
targets=[]
for i,line in enumerate(lines,1):
    m=re.match(r"^([A-Za-z0-9_./%+\-]+)\s*:(?!=)",line)
    if m:
        name=m.group(1)
        if "native" in name.lower() or "rtl88wifinative" in name.lower():
            targets.append((name,i,line.strip()))
print("MAKEFILE_TARGET_DECLARATIONS_WITH_NATIVE=%d"%len(targets))
for name,n,line in targets:
    print("TARGET line=%d name=%s declaration=%s"%(n,name,line))
eligible=[]
for name,n,line in targets:
    if "%" not in name and re.fullmatch(r"[A-Za-z0-9_./+\-]+",name):
        eligible.append(name)
# prioritize exact, then the native bundle / native-labeled target names
eligible=sorted(set(eligible),key=lambda x:(0 if x.lower()=="rtl88wifi-native" else 1 if "rtl88wifinative" in x.lower() else 2 if "native" in x.lower() else 3,x))
(out/"native-targets.txt").write_text("\n".join(eligible)+"\n")
print("SAFE_EXPLICIT_NATIVE_TARGET_CANDIDATES=%d"%len(eligible))
print("Makefile lines referring to native source lists / expected components:")
for i,line in enumerate(lines,1):
    if re.search(r"native|NATIVE_CORE_SRCS|RTW88HwOps|RTW88PCIDevice|WCLPCIBackend|SkywalkQueues|TxCompletion",line,re.I):
        print("%d:%s"%(i,line[:500]))
# Detect parse-time shell commands and recipe behavior which can escape make -n.
shell=[]
for i,line in enumerate(lines,1):
    if "$(shell" in line or "${shell" in line:
        shell.append((i,line.strip()))
print("MAKEFILE_PARSE_TIME_SHELL_EXPRESSIONS=%d"%len(shell))
for i,line in shell: print("PARSE_SHELL line=%d %s"%(i,line[:500]))
danger=re.compile(r"\b(rm|mkdir|rmdir|touch|cp|mv|install|ditto|codesign|xcodebuild|kmutil|kextload|kextunload|open|curl|wget|osascript|launchctl|defaults|security|csrutil|diskutil|spctl|sudo|chmod|chown|ln|dd|truncate|python[0-9.]*|perl|bash|sh)\b",re.I)
dangerous=[(i,s) for i,s in shell if danger.search(s)]
recursive=[(i,l) for i,l in enumerate(lines,1) if "$(MAKE)" in l or re.match(r"^\s*\+\s",l)]
if dangerous:
    (out/"dryrun-guard.txt").write_text("SKIP: potentially mutating parse-time shell expressions\n"+"\n".join("%d:%s"%x for x in dangerous))
    print("DRYRUN_GUARD=SKIP_DANGEROUS_PARSE_TIME_SHELL")
elif recursive:
    (out/"dryrun-guard.txt").write_text("SKIP: recursive make or force-executed recipe marker found\n"+"\n".join("%d:%s"%x for x in recursive))
    print("DRYRUN_GUARD=SKIP_RECURSIVE_OR_FORCE_EXECUTION")
else:
    (out/"dryrun-guard.txt").write_text("SAFE_FOR_MAKE_MINUS_N: no mutating parse-time shell pattern, recursive make, or + recipe marker detected by static guard\n")
    print("DRYRUN_GUARD=PASS_STATIC_GUARD")
PY

TARGETS_FILE="$OUT/native-targets.txt"
GUARD_FILE="$OUT/dryrun-guard.txt"
{
  echo
  echo "--- Explicit native-target dry-run ---"
  cat "$GUARD_FILE"
} >>"$REPORT"
if grep -q '^SAFE_FOR_MAKE_MINUS_N:' "$GUARD_FILE" && [[ -s "$TARGETS_FILE" ]]; then
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    safe_name="$(printf '%s' "$target" | tr '/ ' '__')"
    out_file="$OUT/make-n-$safe_name.txt"
    set +e
    (cd "$SRC" && make -n -f Makefile "$target") >"$out_file" 2>&1
    rc=$?
    set -e
    {
      echo
      echo "### TARGET=$target"
      echo "MAKE_DRY_RUN_EXIT=$rc"
      echo "DRY_RUN_OUTPUT_BYTES=$(wc -c <"$out_file" | tr -d ' ')"
      echo "DRY_RUN_COMMAND_LINES=$(wc -l <"$out_file" | tr -d ' ')"
      echo "RTW88HwOps.cpp_mentions=$(grep -c 'RTW88HwOps.cpp' "$out_file" || true)"
      echo "RTW88PCIDevice.cpp_mentions=$(grep -c 'RTW88PCIDevice.cpp' "$out_file" || true)"
      echo "RTW88WCLPCIBackend.cpp_mentions=$(grep -c 'RTW88WCLPCIBackend.cpp' "$out_file" || true)"
      echo "RTW88WCLSkywalkQueues.cpp_mentions=$(grep -c 'RTW88WCLSkywalkQueues.cpp' "$out_file" || true)"
      echo "RTW88WCLTxCompletionSlots_mentions=$(grep -c 'RTW88WCLTxCompletionSlots' "$out_file" || true)"
      echo "NATIVE_KEXT_OUTPUT_mentions=$(grep -Eic 'RTL88WiFiNative\.kext|RTL88WiFiNative' "$out_file" || true)"
      echo "--- dry-run command output (first 500 lines) ---"
      sed -n '1,500p' "$out_file"
      echo "--- end target $target ---"
    } >>"$REPORT"
  done < "$TARGETS_FILE"
else
  echo "NATIVE_TARGET_DRY_RUN=SKIPPED (guard failed or no explicit native target discovered)" >>"$REPORT"
fi

{
  echo
  echo "--- Safety boundary ---"
  echo "SOURCE_TREE_MODIFIED=NO"
  echo "REFERENCE_CLONE_ONLY=$CLONE"
  echo "EXISTING_KEXT_MODIFIED=NO"
  echo "OPENCORE_MODIFIED=NO"
  echo "BUILD=NOT_RUN (make -n only, if guarded target was found)"
  echo "INSTALL=NOT_RUN"
  echo "LOAD=NOT_RUN"
  echo "========== END STAGE 35F =========="
} >>"$REPORT"

# Publish immutable report chunks (220 KB each) and verify every GitHub blob readback.
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
  [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >>"$UPLOAD_ERROR"; return 1; }
  UPLOAD_SHA="$got"
}
MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 35F\nRUN: %s\nREFERENCE: %s\n' "$RUN" "$REFERENCE" >"$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35f/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35F audit $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >>"$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35f/$RUN/manifest.txt" "Add Stage35F manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35F_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35F_RUN=$RUN"
echo "STAGE35F_REPORT_PARTS=$COUNT"
echo "STAGE35F_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35f/$RUN"
