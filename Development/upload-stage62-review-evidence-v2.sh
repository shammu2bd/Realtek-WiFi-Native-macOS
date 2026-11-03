#!/bin/bash
# Stage62 review evidence uploader V2.
# Preserves existing remote files; chooses a fresh, verified-unused folder before uploading.
# Does not modify driver source, kexts, OpenCore, SIP, or NVRAM.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
BASE="$SOURCE_ROOT/run log/stage62"

for tool in gh python3 split wc tr; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing required tool: $tool"; exit 2; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 2; }
[[ -d "$BASE" ]] || { echo "ERROR: Stage62 run-log folder not found: $BASE"; exit 2; }

RUN_DIR="$(python3 - "$BASE" <<'PY'
import pathlib,sys
base=pathlib.Path(sys.argv[1])
runs=[p for p in base.glob("run-*") if (p/"audit-summary.txt").is_file() and (p/"method-disassembly.txt").is_file()]
if not runs: raise SystemExit("No Stage62 audit output folder found")
print(max(runs,key=lambda p:p.stat().st_mtime))
PY
)"
grep -q "STAGE62_QUEUESET_LOGICALLINK_REGISTRATION_METADATA_AUDIT" "$RUN_DIR/audit-summary.txt" || {
  echo "ERROR: selected folder is not a Stage62 audit"; exit 2;
}

blob_sha() {
  python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\\0"+b).hexdigest())
PY
}
remote_sha() {
  gh api "repos/$REPO/contents/$1" -q .sha 2>/dev/null || true
}

# Pick a fresh remote folder. Never reuse a previous partial upload folder.
UPLOAD_ID=""
for attempt in 1 2 3 4 5 6 7 8; do
  candidate="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
  test_path="Development/Logs/stage62-review/$candidate/audit-summary.txt"
  if [[ -z "$(remote_sha "$test_path")" ]]; then
    UPLOAD_ID="$candidate"
    break
  fi
done
[[ -n "$UPLOAD_ID" ]] || { echo "ERROR: could not find a verified-unused GitHub folder"; exit 3; }

DEST="Development/Logs/stage62-review/$UPLOAD_ID"
WORK="$RUN_DIR/review-upload-v2-$UPLOAD_ID"
mkdir -p "$WORK"
MANIFEST="$WORK/manifest.txt"

upload_one() {
  local file="$1" path="$2" expected existing payload response put readback
  expected="$(blob_sha "$file")"
  existing="$(remote_sha "$path")"
  if [[ -n "$existing" ]]; then
    if [[ "$existing" == "$expected" ]]; then
      echo "ALREADY_VERIFIED=$path SHA=$existing"
      return 0
    fi
    echo "ERROR: remote path exists with different content; preserving it: $path" >&2
    return 1
  fi
  payload="$WORK/payload-$RANDOM-$RANDOM.json"
  response="$WORK/response-$RANDOM-$RANDOM.json"
  python3 - "$file" "$payload" <<'PY'
import base64,json,pathlib,sys
src,dst=sys.argv[1:]
obj={"message":"Upload Stage62 review-required audit evidence (V2)","content":base64.b64encode(pathlib.Path(src).read_bytes()).decode()}
pathlib.Path(dst).write_text(json.dumps(obj),encoding="utf-8")
PY
  gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
  put="$(python3 - "$response" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
  readback="$(remote_sha "$path")"
  [[ "$put" == "$expected" && "$readback" == "$expected" ]] || {
    echo "ERROR: readback SHA mismatch for $path (PUT=$put READBACK=$readback EXPECTED=$expected)" >&2
    return 1
  }
  echo "UPLOADED_AND_VERIFIED=$path SHA=$readback"
}

FILES=(
  audit-summary.txt
  method-status.txt
  method-disassembly.txt
  queueset-info-word-crosswalk.txt
  logical-link-info-crosswalk.txt
  registration-lifecycle-matrix.txt
  private-metadata-source-inventory.txt
  source-fingerprint.txt
  report.txt
)
[[ ! -f "$RUN_DIR/upload-error.txt" ]] || FILES+=(upload-error.txt)

{
  echo "STAGE=62_REVIEW_EVIDENCE"
  echo "VERSION=STAGE62_REVIEW_EVIDENCE_V2_20261102"
  echo "UPLOAD_ID=$UPLOAD_ID"
  echo "LOCAL_RUN=$(basename "$RUN_DIR")"
  echo "RESULT=REVIEW_REQUIRED"
  echo "ACTIVATION_GATE=BLOCKED"
  echo "SOURCE_MODIFIED=NO"
  echo "BUILD=NOT_RUN"
  echo "CODESIGN=NOT_RUN"
  echo "INSTALL=NOT_RUN"
  echo "LOAD=NOT_RUN"
  echo "OPENCORE_CHANGE=NONE"
  echo "SIP_NVRAM_CHANGE=NONE"
} > "$MANIFEST"

for name in "${FILES[@]}"; do
  file="$RUN_DIR/$name"
  [[ -f "$file" ]] || { echo "WARNING: artifact missing: $name"; continue; }
  bytes="$(wc -c < "$file" | tr -d ' ')"
  if (( bytes <= 225280 )); then
    upload_one "$file" "$DEST/$name"
    printf 'FILE=%s BYTES=%s BLOB_SHA=%s\n' "$name" "$bytes" "$(blob_sha "$file")" >> "$MANIFEST"
  else
    prefix="$WORK/$name.part-"
    split -b 220k "$file" "$prefix"
    for part in "$prefix"*; do
      [[ -f "$part" ]] || continue
      partname="$(basename "$part")"
      upload_one "$part" "$DEST/$partname"
      printf 'PART=%s BYTES=%s BLOB_SHA=%s\n' "$partname" "$(wc -c < "$part" | tr -d ' ')" "$(blob_sha "$part")" >> "$MANIFEST"
    done
  fi
done

upload_one "$MANIFEST" "$DEST/manifest.txt"

echo
echo "STAGE62_REVIEW_UPLOAD=SUCCESS"
echo "STAGE62_UPLOAD_ID=$UPLOAD_ID"
echo "STAGE62_LOCAL_EVIDENCE=$RUN_DIR"
echo "STAGE62_GITHUB_EVIDENCE=https://github.com/$REPO/tree/main/$DEST"
echo "NOTE=Evidence upload only. Stage62 remains REVIEW_REQUIRED. No driver, build, signing, install, load, or OpenCore changes."
