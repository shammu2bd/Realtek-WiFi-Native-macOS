#!/bin/bash
# Stage 35U — read-only audit of packed TX descriptor access and alignment.
# No source edits, build, signing, install, load, or OpenCore changes.
set -Eeuo pipefail

echo "STAGE35U_SCRIPT_VERSION=1"
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW88="$SOURCE_ROOT/driver/rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35U-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
BUILDLOG=""
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35U_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 split shasum find sort file; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -d "$SOURCE_ROOT" && -d "$SRC" && -d "$RTW88" ]] || {
  echo "ERROR: Stage26 source tree missing: $SOURCE_ROOT"
  exit 3
}
for f in "$RTW88/tx.h" "$RTW88/tx.c" "$RTW88/pci.h" "$SRC/src/compat/linux/skbuff.h"; do
  [[ -f "$f" ]] || { echo "ERROR: required descriptor source missing: $f"; exit 4; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 5; }

BUILDLOG="$(find "$HOME/Downloads" -maxdepth 2 -type f -path '*/Stage35T-run-*/native-build.log' -print 2>/dev/null | sort | tail -1 || true)"

fingerprint() {
  python3 - "$@" <<'PY'
import hashlib,pathlib,sys
paths=[pathlib.Path(x) for x in sys.argv[1:]]
h=hashlib.sha256()
for p in sorted(paths,key=lambda x:str(x)):
    data=p.read_bytes()
    rel=str(p).encode()
    h.update(len(rel).to_bytes(8,"big")); h.update(rel)
    h.update(len(data).to_bytes(8,"big")); h.update(data)
print("files=%d sha256=%s"%(len(paths),h.hexdigest()))
PY
}

TXH="$RTW88/tx.h"
TXC="$RTW88/tx.c"
PCIH="$RTW88/pci.h"
SKBH="$SRC/src/compat/linux/skbuff.h"
BEFORE="$(fingerprint "$TXH" "$TXC" "$PCIH" "$SKBH")"

{
  echo "========== STAGE 35U: PACKED TX DESCRIPTOR ALIGNMENT AUDIT =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "source_root=$SOURCE_ROOT"
  echo "target=rtl88wifi-native"
  echo "predecessor=Stage35T run-20261102-014641, BUILD_EXIT=0"
  echo "predecessor_artifact=Development/Artifacts/stage35t/RTL88WiFiNative-run-20261102-014641.tar.gz"
  echo "predecessor_artifact_sha256=8e20b2f63fb6f5ce278f7aec8f4558c6bb624c812e52c982b71cf09308c5ef81"
  echo "audit_mode=read-only"
  echo "retained_stage35t_build_log=\${BUILDLOG:-NOT_FOUND}"
  echo
  echo "--- Source fingerprint before audit ---"
  echo "$BEFORE"
  echo
  echo "--- 1. TX descriptor definition and checksum implementation ---"
  nl -ba "$TXH" | sed -n '1,145p'
  echo
  echo "--- 2. TX data construction and descriptor ownership ---"
  nl -ba "$TXC" | sed -n '1,260p'
  echo
  echo "--- 3. PCI descriptor/ring layout and consumers ---"
  nl -ba "$PCIH" | sed -n '1,250p'
  echo
  echo "--- 4. skb layout and data/headroom helpers ---"
  nl -ba "$SKBH" | sed -n '1,310p'
  echo
} > "$REPORT"

python3 - "$RTW88" "$SRC/src/compat" "$SRC/src/kext" "$REPORT" <<'PY'
import pathlib,re,sys
roots=[pathlib.Path(x) for x in sys.argv[1:4]]
out=pathlib.Path(sys.argv[4])
patterns=[
    re.compile(r"\ble32p_replace_bits\b"),
    re.compile(r"\bfill_txdesc_checksum_common\b|\bfill_txdesc_checksum\b"),
    re.compile(r"\bRTW_TX_DESC_W7_TXDESC_CHECKSUM\b|\btx_desc\s*->\s*w7\b"),
    re.compile(r"\b(struct\s+rtw_tx_desc|rtw_tx_desc\s*\*)"),
    re.compile(r"\b(__skb_put|skb_put|skb_push|skb_reserve|skb_headroom|skb_tailroom)\s*\("),
    re.compile(r"\b(txdesc|tx_desc)\b.{0,80}\b(data|head|skb|dma|desc)\b|\b(data|head|skb|dma|desc)\b.{0,80}\b(txdesc|tx_desc)\b",re.I),
]
files=[]
for root in roots:
    for p in root.rglob("*"):
        if p.is_file() and p.suffix in {".c",".h",".cpp",".hpp"}:
            files.append(p)
files=sorted(set(files))
hits=[]
limits=[100,100,100,120,100,100]
counts=[0]*len(patterns)
for p in files:
    try: lines=p.read_text(errors="replace").splitlines()
    except OSError: continue
    for i,line in enumerate(lines):
        for k,pat in enumerate(patterns):
            if pat.search(line):
                if counts[k] < limits[k]:
                    hits.append((k,p,i,lines))
                    counts[k]+=1
                break
with out.open("a") as f:
    labels=[
      "le32p_replace_bits references",
      "TX checksum function references",
      "TX descriptor word-7 checksum field references",
      "TX descriptor type and pointer references",
      "skb data/headroom/tailroom helper references",
      "TX descriptor and skb/DMA pointer relationship references"
    ]
    print("--- 5. Cross-tree source references (bounded context) ---",file=f)
    print("SOURCE_FILES_SCANNED=%d"%len(files),file=f)
    for k,label in enumerate(labels):
        subset=[h for h in hits if h[0]==k]
        print("\n### %s (hits=%d)"%(label,len(subset)),file=f)
        for _,p,i,lines in subset:
            lo=max(0,i-3); hi=min(len(lines),i+4)
            print("\n--- %s:%d ---"%(p,i+1),file=f)
            for j in range(lo,hi):
                print("%6d %s"%(j+1,lines[j]),file=f)
PY

if [[ -n "$BUILDLOG" && -f "$BUILDLOG" ]]; then
  python3 - "$BUILDLOG" "$REPORT" <<'PY'
import pathlib,sys
log=pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
out=pathlib.Path(sys.argv[2])
needles=("address-of-packed-member","tx.h:125","tx.h:130")
hits=[i for i,line in enumerate(log) if any(n in line for n in needles)]
with out.open("a") as f:
    print("\n--- 6. Exact Stage35T compiler diagnostics for packed descriptor access ---",file=f)
    print("BUILD_LOG_LINES=%d PACKED_DIAGNOSTIC_HITS=%d"%(len(log),len(hits)),file=f)
    seen=set()
    for i in hits:
        lo=max(0,i-2); hi=min(len(log),i+5)
        if any(j in seen for j in range(lo,hi)): continue
        seen.update(range(lo,hi))
        print("\n--- build log lines %d-%d ---"%(lo+1,hi),file=f)
        for j in range(lo,hi):
            print("%7d %s"%(j+1,log[j]),file=f)
PY
else
  {
    echo
    echo "--- 6. Stage35T compiler diagnostics ---"
    echo "BUILD_LOG_CONTEXT=NOT_AVAILABLE"
  } >> "$REPORT"
fi

AFTER="$(fingerprint "$TXH" "$TXC" "$PCIH" "$SKBH")"
if [[ "$BEFORE" == "$AFTER" ]]; then SOURCE_FILES_MODIFIED=NO; else SOURCE_FILES_MODIFIED=YES; fi
{
  echo
  echo "--- Source immutability check ---"
  echo "before=$BEFORE"
  echo "after=$AFTER"
  echo "SOURCE_FILES_MODIFIED=$SOURCE_FILES_MODIFIED"
  echo
  echo "--- Findings policy ---"
  echo "PACKED_DESCRIPTOR_REMEDIATION=NOT_APPLIED"
  echo "ALIGNMENT_ASSUMPTIONS=NOT_PROVEN_BY_BUILD_ONLY"
  echo "REBUILD=NOT_RUN"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "CODESIGN=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
  echo "HARDWARE_TEST=NOT_RUN"
  echo "NEXT_GATE=prove descriptor base alignment and all call-site contracts before choosing unaligned-safe access"
  echo "========== END STAGE 35U =========="
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
printf 'STAGE: 35U\nRUN: %s\nPURPOSE: packed TX descriptor alignment audit\nSOURCE_FILES_MODIFIED: %s\n' "$RUN" "$SOURCE_FILES_MODIFIED" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35u/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35U TX descriptor audit $RUN/$name" "$OUT/log-upload.json" "$OUT/log-upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35u/$RUN/manifest.txt" "Add Stage35U manifest $RUN" "$OUT/manifest-upload.json" "$OUT/manifest-upload-response.json"

echo "STAGE35U_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35U_RUN=$RUN"
echo "STAGE35U_SOURCE_FILES_MODIFIED=$SOURCE_FILES_MODIFIED"
echo "STAGE35U_REPORT_PARTS=$COUNT"
echo "STAGE35U_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35u/$RUN"
