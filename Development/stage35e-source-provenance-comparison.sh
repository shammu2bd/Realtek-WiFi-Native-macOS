#!/bin/bash
# Stage 35E — compare local clean-source tree with public RTL88WiFi reference.
# Read-only with respect to the user's source tree, existing kexts, and OpenCore.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
REFERENCE="https://github.com/X1REN41L/RTL88WiFi.git"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35E-$RUN"
REPORT="$OUT/report.txt"
PARTS="$OUT/parts"
mkdir -p "$PARTS"
for tool in git gh python3 split shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -d "$SOURCE_ROOT/driver/RTL88WiFi" ]] || { echo "ERROR: expected source tree missing: $SOURCE_ROOT/driver/RTL88WiFi"; exit 3; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI not authenticated. Run gh auth login."; exit 4; }
CLONE="$OUT/reference"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; echo "STAGE35E_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -50 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

{
  echo "========== STAGE 35E: SOURCE PROVENANCE COMPARISON =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "local_source_root=$SOURCE_ROOT"
  echo "reference_repository=$REFERENCE"
  echo
  echo "--- Local source snapshot ---"
  ls -ld "$SOURCE_ROOT" "$SOURCE_ROOT/driver/RTL88WiFi"
  echo "local_makefile_sha256=$(shasum -a 256 "$SOURCE_ROOT/driver/RTL88WiFi/Makefile" | awk '{print $1}')"
  echo
  echo "--- Clone public reference into isolated diagnostic folder ---"
} > "$REPORT"

git clone --depth 1 --no-tags "$REFERENCE" "$CLONE" >>"$REPORT" 2>&1
{
  echo "reference_head=$(git -C "$CLONE" rev-parse HEAD)"
  echo "reference_branch=$(git -C "$CLONE" branch --show-current)"
  echo "reference_remote=$(git -C "$CLONE" remote get-url origin)"
  echo "reference_makefile_sha256=$(shasum -a 256 "$CLONE/driver/RTL88WiFi/Makefile" | awk '{print $1}')"
  echo
  echo "--- Compare driver/RTL88WiFi file content (exclude build products and Git metadata) ---"
} >> "$REPORT"

python3 - "$SOURCE_ROOT/driver/RTL88WiFi" "$CLONE/driver/RTL88WiFi" >>"$REPORT" <<'PY'
import hashlib, os, pathlib, sys
left, right = map(pathlib.Path, sys.argv[1:])
skip_dirs={".git","build","DerivedData"}
def inventory(root):
    out={}
    for base, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in skip_dirs and not d.endswith(".dSYM"))
        for name in sorted(files):
            p=pathlib.Path(base)/name
            rel=p.relative_to(root).as_posix()
            if name.endswith((".o",".a",".dylib")): continue
            if ".kext/Contents/MacOS/" in "/"+rel: continue
            try:
                h=hashlib.sha256(p.read_bytes()).hexdigest()
                out[rel]=h
            except (OSError, PermissionError) as e:
                out[rel]="READ_ERROR:"+str(e)
    return out
a,b=inventory(left),inventory(right)
common=sorted(a.keys() & b.keys())
same=[p for p in common if a[p]==b[p]]
diff=[p for p in common if a[p]!=b[p]]
only_local=sorted(a.keys()-b.keys())
only_ref=sorted(b.keys()-a.keys())
print("LOCAL_FILE_COUNT="+str(len(a)))
print("REFERENCE_FILE_COUNT="+str(len(b)))
print("IDENTICAL_FILES="+str(len(same)))
print("DIFFERENT_FILES="+str(len(diff)))
print("LOCAL_ONLY_FILES="+str(len(only_local)))
print("REFERENCE_ONLY_FILES="+str(len(only_ref)))
print("\n[DIFFERENT FILES]")
for p in diff: print(p)
print("\n[LOCAL ONLY]")
for p in only_local: print(p)
print("\n[REFERENCE ONLY]")
for p in only_ref: print(p)
print("\n[KEY FILE HASH COMPARISON]")
for p in ["Makefile","src/kext/RTW88HwOps.cpp","src/kext/RTW88PCIDevice.cpp"]:
    print(p+" | local="+a.get(p,"MISSING")+" | reference="+b.get(p,"MISSING"))
print("\nCOMPARISON_SCOPE=driver/RTL88WiFi; excludes .git, build, DerivedData, dSYM, object/archive/dylib files and kext executable payloads")
PY

{
  echo
  echo "--- Safety boundary ---"
  echo "SOURCE_TREE_MODIFIED=NO"
  echo "EXISTING_KEXT_MODIFIED=NO"
  echo "OPENCORE_MODIFIED=NO"
  echo "BUILD=NOT_RUN"
  echo "INSTALL=NOT_RUN"
  echo "LOAD=NOT_RUN"
  echo "REFERENCE_CLONE_LOCATION=$CLONE"
  echo "========== END STAGE 35E =========="
} >> "$REPORT"

split -b 220k "$REPORT" "$PARTS/report-"
upload_file() {
  local file="$1" path="$2" msg="$3" payload="$4" response="$5"
  local old put got
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
if not s: raise SystemExit("No content SHA in GitHub response: "+repr(d)[:800])
print(s)
PY2
)"
  got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
  [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >>"$UPLOAD_ERROR"; return 1; }
  UPLOAD_SHA="$got"
}
MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 35E\nRUN: %s\nREFERENCE: %s\n' "$RUN" "$REFERENCE" > "$MANIFEST"
COUNT=0
for part in "$PARTS"/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35e/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35E source comparison $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >>"$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35e/$RUN/manifest.txt" "Add Stage35E manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35E_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35E_RUN=$RUN"
echo "STAGE35E_REPORT_PARTS=$COUNT"
echo "STAGE35E_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35e/$RUN"
echo "STAGE35E_LOCAL_REPORT=$REPORT"
