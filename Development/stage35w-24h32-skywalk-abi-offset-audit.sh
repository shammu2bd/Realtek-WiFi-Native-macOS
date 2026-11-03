#!/bin/bash
# Stage 35W — exact 24H32 Skywalk ABI offset and compiler-warning audit.
# Read-only: no source edits, rebuild, signing, installation, loading or OpenCore changes.
set -Eeuo pipefail

echo "STAGE35W_SCRIPT_VERSION=1"
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
ABI="$SRC/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp"
SDK_HEADERS="$SRC/MacKernelSDK/Headers"
DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35W-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
BUILDLOG=""
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35W_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 split shasum find sort grep sed nl xcrun; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$ABI" && -d "$SDK_HEADERS" ]] || { echo "ERROR: ABI header or project SDK headers missing"; exit 3; }
[[ -d "$DEVELOPER_DIR" ]] || { echo "ERROR: Xcode 16.4 Developer directory missing"; exit 4; }
export DEVELOPER_DIR
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
[[ -d "$SDKROOT" ]] || { echo "ERROR: SDKROOT invalid"; exit 5; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 6; }

BUILDLOG="$(find "$HOME/Downloads" -maxdepth 2 -type f -path '*/Stage35V-run-*/native-build.log' -print 2>/dev/null | sort | tail -1 || true)"
fingerprint() {
  python3 - "$@" <<'PY'
import hashlib,pathlib,sys
h=hashlib.sha256()
paths=[pathlib.Path(x) for x in sys.argv[1:]]
for p in sorted(paths,key=lambda x:str(x)):
    b=p.read_bytes(); n=str(p).encode()
    h.update(len(n).to_bytes(8,"big")); h.update(n)
    h.update(len(b).to_bytes(8,"big")); h.update(b)
print("files=%d sha256=%s"%(len(paths),h.hexdigest()))
PY
}
BEFORE="$(fingerprint "$ABI")"

{
  echo "========== STAGE 35W: SEQUOIA 24H32 SKYWALK ABI OFFSET AUDIT =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "source_root=$SOURCE_ROOT"
  echo "sdkroot=$SDKROOT"
  echo "predecessor=Stage35V run-20261102-015408, BUILD_EXIT=0"
  echo "predecessor_artifact=Development/Artifacts/stage35v/RTL88WiFiNative-run-20261102-015408.tar.gz"
  echo "predecessor_artifact_sha256=cf7f6c235add64a578cc70b7991d73522d283f6b84c8e42a69d205da8bc3ea22"
  echo "audit_mode=read-only"
  echo "retained_stage35v_build_log=$BUILDLOG"
  echo
  echo "--- ABI header fingerprint ---"
  echo "$BEFORE"
  echo
  echo "--- 1. Project ABI declaration and assertions ---"
  nl -ba "$ABI" | sed -n '1,180p'
  nl -ba "$ABI" | sed -n '360,490p'
  echo
  echo "--- 2. Project SDK references to IOSkywalkEthernetInterface and expansion data ---"
  grep -R -n -E 'IOSkywalkEthernetInterface|mExpansionData2|ExpansionData' "$SDK_HEADERS" 2>/dev/null | head -240 || true
  echo
  echo "--- 3. Xcode SDK Kernel header references ---"
  grep -R -n -E 'IOSkywalkEthernetInterface|mExpansionData2|ExpansionData' \
    "$SDKROOT/System/Library/Frameworks/Kernel.framework/Headers" 2>/dev/null | head -240 || true
  echo
} > "$REPORT"

python3 - "$SDK_HEADERS" "$SDKROOT/System/Library/Frameworks/Kernel.framework/Headers" "$REPORT" <<'PY'
import pathlib,sys
roots=[pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])]
out=pathlib.Path(sys.argv[3])
needles=("IOSkywalkEthernetInterface","mExpansionData2","ExpansionData")
with out.open("a") as f:
    print("--- 4. Bounded source/header context around ABI type and expansion fields ---",file=f)
    seen=set()
    count=0
    for root in roots:
        if not root.exists(): continue
        for p in root.rglob("*"):
            if not p.is_file() or p.suffix not in {".h",".hpp",".cpp",".c"}: continue
            try: lines=p.read_text(errors="replace").splitlines()
            except OSError: continue
            matches=[i for i,x in enumerate(lines) if any(n in x for n in needles)]
            for i in matches:
                key=(str(p),i)
                if key in seen: continue
                seen.add(key); count+=1
                lo=max(0,i-5); hi=min(len(lines),i+7)
                print("\n--- %s:%d ---"%(p,i+1),file=f)
                for j in range(lo,hi):
                    print("%6d %s"%(j+1,lines[j]),file=f)
                if count>=260:
                    print("CONTEXT_LIMIT_REACHED=YES",file=f)
                    break
            if count>=260: break
        if count>=260: break
    print("ABI_HEADER_CONTEXT_HITS=%d"%count,file=f)
PY

if [[ -n "$BUILDLOG" && -f "$BUILDLOG" ]]; then
  python3 - "$BUILDLOG" "$REPORT" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); lines=p.read_text(errors="replace").splitlines()
out=pathlib.Path(sys.argv[2])
with out.open("a") as f:
    print("\n--- 5. Exact warning category counts from Stage35V native build log ---",file=f)
    print("BUILD_LOG_LINES=%d"%len(lines),file=f)
    print("EXACT_INVALID_OFFSETOF_DIAGNOSTIC_LINES=%d"%sum("-Winvalid offsetof" in x for x in lines),file=f)
    print("NON_STANDARD_LAYOUT_OFFSET_DIAGNOSTIC_LINES=%d"%sum("offset of on non-standard-layout type" in x for x in lines),file=f)
    print("MEXPANSIONDATA2_DIAGNOSTIC_LINES=%d"%sum("mExpansionData2" in x and "warning:" in x for x in lines),file=f)
    print("PACKED_MEMBER_DIAGNOSTIC_LINES=%d"%sum("address-of-packed-member" in x for x in lines),file=f)
    print("CONDITIONAL_UNINITIALIZED_DIAGNOSTIC_LINES=%d"%sum("conditional-uninitialized" in x for x in lines),file=f)
    print("OFFSETOF_WARNING_METRIC_WAS_UNDERCOUNTED=%s"%("YES" if any("offset of on non-standard-layout type" in x for x in lines) else "NO"),file=f)
    needles=("invalid offsetof","-Winvalid offsetof","offset of on non-standard-layout type","mExpansionData2")
    hits=[i for i,line in enumerate(lines) if any(q in line for q in needles)]
    seen=set()
    for i in hits:
        lo=max(0,i-3); hi=min(len(lines),i+6)
        if any(j in seen for j in range(lo,hi)): continue
        seen.update(range(lo,hi))
        print("\n--- build log lines %d-%d ---"%(lo+1,hi),file=f)
        for j in range(lo,hi):
            print("%7d %s"%(j+1,lines[j]),file=f)
PY
else
  {
    echo "--- 5. Stage35V exact compiler warning categories ---"
    echo "BUILD_LOG_CONTEXT=NOT_AVAILABLE"
    echo "WARNING_CATEGORY_COUNTS=NOT_MEASURED"
  } >> "$REPORT"
fi

AFTER="$(fingerprint "$ABI")"
if [[ "$BEFORE" == "$AFTER" ]]; then SOURCE_FILES_MODIFIED=NO; else SOURCE_FILES_MODIFIED=YES; fi
{
  echo
  echo "--- Source immutability check ---"
  echo "before=$BEFORE"
  echo "after=$AFTER"
  echo "SOURCE_FILES_MODIFIED=$SOURCE_FILES_MODIFIED"
  echo
  echo "--- Safety boundary ---"
  echo "ABI_PATCH=NOT_APPLIED"
  echo "REBUILD=NOT_RUN"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "CODESIGN=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
  echo "HARDWARE_TEST=NOT_RUN"
  echo "NEXT_GATE=confirm 24H32 field declaration and expansion offset before any ABI assertion change"
  echo "========== END STAGE 35W =========="
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

mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"
MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 35W\nRUN: %s\nPURPOSE: 24H32 Skywalk ABI offset and warning audit\nSOURCE_FILES_MODIFIED: %s\n' "$RUN" "$SOURCE_FILES_MODIFIED" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35w/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35W ABI audit $RUN/$name" "$OUT/log-upload.json" "$OUT/log-upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35w/$RUN/manifest.txt" "Add Stage35W manifest $RUN" "$OUT/manifest-upload.json" "$OUT/manifest-upload-response.json"

echo "STAGE35W_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35W_RUN=$RUN"
echo "STAGE35W_SOURCE_FILES_MODIFIED=$SOURCE_FILES_MODIFIED"
echo "STAGE35W_REPORT_PARTS=$COUNT"
echo "STAGE35W_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35w/$RUN"
