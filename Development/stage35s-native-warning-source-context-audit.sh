#!/bin/bash
# Stage 35S — source-context audit for high-risk warnings from the successful
# Stage 35R native build. Read-only: no source edits, rebuild, signing, install,
# load, or OpenCore changes.
set -Eeuo pipefail

echo "STAGE35S_SCRIPT_VERSION=1"
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW88="$SOURCE_ROOT/driver/rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35S-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
BUILDLOG=""
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35S_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 split shasum sed nl grep find sort awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -d "$SOURCE_ROOT" && -d "$SRC" && -d "$RTW88" ]] || {
  echo "ERROR: Stage26 source root not found: $SOURCE_ROOT"
  exit 3
}
for f in "$RTW88/mac.c" "$RTW88/pci.c" "$RTW88/tx.h" "$SRC/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp"; do
  [[ -f "$f" ]] || { echo "ERROR: required audit source missing: $f"; exit 4; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 5; }

# Locate the retained Stage35R compiler log, when the user's temporary folder
# still contains it. The uploaded Stage35R report remains the fallback source.
BUILDLOG="$(find "$HOME/Downloads" -maxdepth 2 -type f -path '*/Stage35R-run-*/native-build.log' -print 2>/dev/null | sort | tail -1 || true)"

fingerprint() {
  python3 - "$@" <<'PY'
import hashlib,pathlib,sys
paths=[pathlib.Path(x) for x in sys.argv[1:]]
h=hashlib.sha256()
for p in sorted(paths,key=lambda x:str(x)):
    rel=str(p).encode()
    data=p.read_bytes()
    h.update(len(rel).to_bytes(8,"big")); h.update(rel)
    h.update(len(data).to_bytes(8,"big")); h.update(data)
print("files=%d sha256=%s"%(len(paths),h.hexdigest()))
PY
}

MAC="$RTW88/mac.c"
PCI="$RTW88/pci.c"
TXH="$RTW88/tx.h"
ABI="$SRC/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp"
BEFORE="$(fingerprint "$MAC" "$PCI" "$TXH" "$ABI")"

{
  echo "========== STAGE 35S: NATIVE BUILD WARNING SOURCE-CONTEXT AUDIT =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "source_root=$SOURCE_ROOT"
  echo "target=rtl88wifi-native"
  echo "predecessor=Stage35R run-20261102-012552, BUILD_EXIT=0"
  echo "predecessor_artifact=Development/Artifacts/stage35r/RTL88WiFiNative-run-20261102-012552.tar.gz"
  echo "predecessor_artifact_sha256=7c2af9719f60446f78d8bf4e96816ed1bfe3c5d2f67200605c6b5b00c526bc18"
  echo "audit_mode=read-only source and warning-context inspection"
  echo "retained_stage35r_build_log=${BUILDLOG:-NOT_FOUND}"
  echo
  echo "--- Source fingerprint before audit ---"
  echo "$BEFORE"
  echo
  echo "--- 1. mac.c: LTE coexistence backup/read/write path (lines 770-830) ---"
  nl -ba "$MAC" | sed -n '770,830p'
  echo
  echo "--- 2. pci.c: DBI register flag path (lines 1280-1350) ---"
  nl -ba "$PCI" | sed -n '1280,1350p'
  echo
  echo "--- 3. pci.c: MDIO WFLAG path (lines 1350-1405) ---"
  nl -ba "$PCI" | sed -n '1350,1405p'
  echo
  echo "--- 4. tx.h: packed TX descriptor and checksum writes (lines 1-150) ---"
  nl -ba "$TXH" | sed -n '1,150p'
  echo
  echo "--- 5. ABI assertion and surrounding declarations (lines 425-465) ---"
  nl -ba "$ABI" | sed -n '425,465p'
  echo
  echo "--- 6. All le32p_replace_bits definitions and uses in relevant source roots ---"
  grep -R -n -E '(^|[^[:alnum:]_])le32p_replace_bits' \
    "$SOURCE_ROOT/driver/rtw88-stable" "$SRC/src/compat" "$SRC/src/kext" 2>/dev/null | head -100 || true
  echo
} > "$REPORT"

if [[ -n "$BUILDLOG" && -f "$BUILDLOG" ]]; then
  {
    echo "--- 7. Exact compiler diagnostic excerpts from retained Stage35R build log ---"
    python3 - "$BUILDLOG" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
lines=p.read_text(errors="replace").splitlines()
needles=("conditional-uninitialized","address-of-packed-member","invalid offsetof",
         "ltecoex_bckp","variable 'flag' may be uninitialized",
         "variable 'wflag' may be uninitialized","IOSkywalkEthernetInterface")
hits=[i for i,line in enumerate(lines) if any(n in line for n in needles)]
print("BUILD_LOG_LINES=%d TARGETED_DIAGNOSTIC_HITS=%d"%(len(lines),len(hits)))
seen=set()
for i in hits:
    lo=max(0,i-3); hi=min(len(lines),i+5)
    if any(j in seen for j in range(lo,hi)):
        continue
    seen.update(range(lo,hi))
    print("\n--- build log lines %d-%d ---"%(lo+1,hi))
    for j in range(lo,hi):
        print("%7d %s"%(j+1,lines[j]))
PY
    echo
  } >> "$REPORT"
else
  {
    echo "--- 7. Retained Stage35R build log ---"
    echo "BUILD_LOG_CONTEXT=NOT_AVAILABLE"
    echo "Reason: the Stage35R temporary native-build.log was not found."
    echo "The source contexts above are still captured directly from Stage26 files."
    echo
  } >> "$REPORT"
fi

AFTER="$(fingerprint "$MAC" "$PCI" "$TXH" "$ABI")"
if [[ "$BEFORE" == "$AFTER" ]]; then SOURCE_FILES_MODIFIED=NO; else SOURCE_FILES_MODIFIED=YES; fi
{
  echo "--- Source immutability check ---"
  echo "before=$BEFORE"
  echo "after=$AFTER"
  echo "SOURCE_FILES_MODIFIED=$SOURCE_FILES_MODIFIED"
  echo
  echo "--- Findings policy ---"
  echo "WARNING_REMEDIATION=NOT_APPLIED"
  echo "REBUILD=NOT_RUN"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "CODESIGN=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
  echo "HARDWARE_TEST=NOT_RUN"
  echo "NEXT_GATE=review exact control flow, then prepare minimal guarded patch only for confirmed defects"
  echo "========== END STAGE 35S =========="
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

mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"
MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 35S\nRUN: %s\nPURPOSE: native build warning source-context audit\nSOURCE_FILES_MODIFIED: %s\n' "$RUN" "$SOURCE_FILES_MODIFIED" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35s/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35S source-context audit $RUN/$name" "$OUT/log-upload.json" "$OUT/log-upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35s/$RUN/manifest.txt" "Add Stage35S manifest $RUN" "$OUT/manifest-upload.json" "$OUT/manifest-upload-response.json"

echo "STAGE35S_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35S_RUN=$RUN"
echo "STAGE35S_SOURCE_FILES_MODIFIED=$SOURCE_FILES_MODIFIED"
echo "STAGE35S_REPORT_PARTS=$COUNT"
echo "STAGE35S_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35s/$RUN"
echo "STAGE35S_NEXT=review report and implement only confirmed warning fixes"
