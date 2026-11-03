#!/bin/bash
# Stage 35B — read-only existing artifact, dry-run link, and symbol audit.
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE35B_ERROR: exit=$rc line=$LINENO" >&2; exit "$rc"' ERR
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PROJECT_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
if [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$PROJECT_NAME/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$HOME/Downloads/$PROJECT_NAME"
else echo "ERROR: project root not found; run from project root or restore it under ~/Downloads/$PROJECT_NAME"; exit 2; fi
for t in python3 gh curl shasum split nm; do command -v "$t" >/dev/null || { echo "ERROR: missing tool $t"; exit 2; }; done
gh auth status >/dev/null
STAMP="$(date +%Y%m%d-%H%M%S)"; RUN="run-$STAMP"
OUT="$PROJECT/build/stage35b-artifact-symbol-audit-$STAMP"
mkdir -p "$OUT/parts"
REPORT="$OUT/stage35b-existing-artifact-symbol-audit.txt"
MF_DIR="$PROJECT/driver/RTL88WiFi"
MAKEFILE="$MF_DIR/Makefile"
{
 echo "STAGE 35B — EXISTING BUILD ARTIFACT / SYMBOL AUDIT"
 echo "PROJECT_ROOT=$PROJECT"
 echo "TARGET=macOS Sequoia 15.8.1 build 24H32 x86_64"
 echo "MODE=READ-ONLY; no compile/install/load/OpenCore/source modifications"
 echo "RUN=$RUN"
 echo
 echo "=== GIT ROOT DISCOVERY ==="
 d="$PROJECT"; found=0
 while :; do
   if git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1; then
     found=1; echo "GIT_ROOT=$(git -C "$d" rev-parse --show-toplevel)"
     echo "GIT_HEAD=$(git -C "$d" rev-parse HEAD)"
     echo "GIT_BRANCH=$(git -C "$d" branch --show-current)"
     echo "GIT_STATUS_BEGIN"; git -C "$d" status --porcelain=v2 --branch --untracked-files=all; echo "GIT_STATUS_END"
     echo "GIT_TRACKED_COUNT=$(git -C "$d" ls-files | wc -l | tr -d ' ')"
     echo "GIT_DIFF_CHECK_BEGIN"; git -C "$d" diff --check; echo "GIT_DIFF_CHECK_END"
     break
   fi
   [[ "$d" == "/" ]] && break
   d="$(dirname "$d")"
 done
 [[ "$found" -eq 1 ]] || echo "GIT_ROOT=UNAVAILABLE (no parent directory is a Git worktree)"
 echo
 echo "=== MAKEFILE TARGETS / LINK RECIPE CANDIDATES ==="
 grep -nE '^[[:alnum:]_.%/-]+[[:space:]]*::?[[:space:]]*|NATIVE_[A-Z0-9_]*[[:space:]]*[:+?]?=|(^|[[:space:]])(clang\+\+|g\+\+|ld|libtool)([[:space:]]|$)|RTW88(HwOps|PCIDevice)\.cpp|NATIVE_ALL_OBJS|NATIVE_CORE_SRCS' "$MAKEFILE" || true
 echo
 echo "=== MAKE DRY-RUN (DEFAULT TARGET; RECIPES NOT EXECUTED) ==="
 (cd "$PROJECT" && make -n -C "$MF_DIR" -f Makefile) 2>&1 || echo "MAKE_DRY_RUN_EXIT=$?"
 echo
 echo "=== EXISTING OBJECTS / KEXT BINARIES ==="
 python3 - "$PROJECT" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); roots=[root/'build',root/'driver',root/'Products',root/'DerivedData']
seen=set(); files=[]
for base in roots:
 if not base.exists(): continue
 for p in base.rglob('*'):
  if not p.is_file() or '.git' in p.parts: continue
  if p.suffix=='.o' or p.name.endswith('.kext') or p.parent.name=='MacOS':
   try:
    rp=str(p.relative_to(root))
    if rp not in seen: seen.add(rp); files.append((p,rp,p.stat().st_size))
   except OSError: pass
print('ARTIFACT_COUNT='+str(len(files)))
for p,rp,size in sorted(files,key=lambda x:x[1]): print(f'ARTIFACT {rp} bytes={size}')
PY
 echo
 echo "=== nm SYMBOL TABLE: EXISTING RELEVANT OBJECTS / EXECUTABLES ==="
 python3 - "$PROJECT" <<'PY'
from pathlib import Path
import subprocess,sys
root=Path(sys.argv[1]); roots=[root/'build',root/'driver',root/'Products',root/'DerivedData']
seen=set()
for base in roots:
 if not base.exists(): continue
 for p in base.rglob('*'):
  if not p.is_file() or p in seen: continue
  if p.suffix=='.o' or p.name.endswith('.kext') or p.parent.name=='MacOS':
   seen.add(p); target=p
   if p.name.endswith('.kext'):
    exe=p/'Contents'/'MacOS'
    if exe.is_dir():
     candidates=[x for x in exe.iterdir() if x.is_file()]
     if candidates: target=candidates[0]
     else: continue
   if not target.is_file(): continue
   try:
    q=subprocess.run(['nm','-g',str(target)],capture_output=True,text=True,timeout=30)
    lines=[x for x in (q.stdout+'\n'+q.stderr).splitlines() if '_dma_ops' in x or 'rtw88_dma_ops' in x]
    print(f'NM {target.relative_to(root)} exit={q.returncode} matching_symbols={len(lines)}')
    for line in lines: print('  '+line)
   except Exception as e: print(f'NM_ERROR {target}: {e}')
PY
 echo
 echo "=== SOURCE AND BUILD DESCRIPTOR HASHES ==="
 find "$PROJECT" \( -path '*/.git' -o -path '*/build' -o -path '*/DerivedData' \) -prune -o -type f \( -name 'Makefile' -o -name '*.mk' -o -name 'RTW88HwOps.cpp' -o -name 'RTW88PCIDevice.cpp' -o -name 'RTW88WCLPCIBackend.cpp' \) -print0 | sort -z | xargs -0 shasum -a 256
 echo
 echo "=== CONCLUSION RULES ==="
 echo "A dry-run command is build-plan evidence only; it is not a successful link."
 echo "An nm definition in an existing object/binary is stronger evidence than source membership."
 echo "nm output containing U means undefined reference, not a definition."
 echo "If no relevant objects/binary exist, final linked _dma_ops count remains UNVERIFIED."
 echo "ACTIVATION_GATE=BLOCKED until native binary, DMA callback installation, and runtime safety are independently proven."
} > "$REPORT"
test -s "$REPORT"
if command -v shellcheck >/dev/null 2>&1; then shellcheck "$PROJECT/Development/stage35b-existing-artifact-symbol-audit.sh" >"$OUT/shellcheck.txt" 2>&1 || true
else echo "shellcheck not installed; skipped" >"$OUT/shellcheck.txt"; fi
split -b 260000 -d -a 3 "$REPORT" "$OUT/parts/report-"
MANIFEST="$OUT/manifest.txt"; : > "$MANIFEST"
upload() {
 local file="$1" path="$2" message="$3" payload="$4" response="$5" old="" put="" got=""
 old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
 python3 - "$file" "$old" "$message" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,sha,msg,dst=sys.argv[1:]
o={'message':msg,'content':base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha:o['sha']=sha
pathlib.Path(dst).write_text(json.dumps(o))
PY2
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" >"$response"
 put="$(python3 - "$response" <<'PY2'
import json,sys
print(json.load(open(sys.argv[1]))['content']['sha'])
PY2
)"
 got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
 [[ "$put" == "$got" ]] || { echo "ERROR: SHA readback mismatch $path"; return 1; }
 UPLOAD_SHA="$got"; echo "UPLOAD_VERIFIED $path $got"
}
PARTS=0
for part in "$OUT"/parts/report-*; do
 [[ -f "$part" ]] || continue
 name="$(basename "$part").txt"; remote="Development/Logs/stage35b/$RUN/$name"
 upload "$part" "$remote" "Add immutable Stage35B audit chunk $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
 printf '%s %s %s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" >> "$MANIFEST"
 PARTS=$((PARTS+1))
done
remote="Development/Logs/stage35b/$RUN/shellcheck.txt"
upload "$OUT/shellcheck.txt" "$remote" "Add Stage35B shellcheck result $RUN" "$OUT/aux.json" "$OUT/aux-response.json"
printf '%s %s %s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$OUT/shellcheck.txt" | tr -d ' ')" >> "$MANIFEST"
printf 'STAGE: 35B\nRUN: %s\nREPORT_BYTES: %s\nREPORT_PARTS: %s\nSOURCE_CHANGES: NONE\nBUILD_INSTALL_LOAD: NOT RUN\nACTIVATION_GATE: BLOCKED\n' "$RUN" "$(wc -c <"$REPORT" | tr -d ' ')" "$PARTS" >> "$MANIFEST"
upload "$MANIFEST" "Development/Logs/stage35b/$RUN/manifest.txt" "Add Stage35B immutable manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35B_MANIFEST_SHA=$UPLOAD_SHA"
echo "STAGE35B_REPORT_PARTS=$PARTS"
echo "STAGE35B_LOG_DIRECTORY=https://github.com/$REPO/tree/main/Development/Logs/stage35b/$RUN"
echo "STAGE35B_STATUS=REVIEW_REQUIRED"
echo "ACTIVATION_GATE=BLOCKED"
echo "SOURCE_CHANGES=NONE | BUILD=NOT RUN | INSTALL=NOT RUN | LOAD=NOT RUN | OPENCORE_CHANGE=NONE"
