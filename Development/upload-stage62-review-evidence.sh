#!/bin/bash
# Stage 62 review evidence uploader. Does not modify driver source, kexts, or OpenCore.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
BASE="$SOURCE_ROOT/run log/stage62"

for tool in gh python3 shasum split wc tr; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing $tool"; exit 2; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 2; }
[[ -d "$BASE" ]] || { echo "ERROR: Stage62 run-log folder not found: $BASE"; exit 2; }

RUN_DIR="$(python3 - "$BASE" <<'PY'
import pathlib,sys
base=pathlib.Path(sys.argv[1])
runs=[p for p in base.glob("run-*") if (p/"audit-summary.txt").is_file() and (p/"method-disassembly.txt").is_file()]
if not runs: raise SystemExit("No failed Stage62 evidence folder found")
print(max(runs,key=lambda p:p.stat().st_mtime))
PY
)"
grep -q "STAGE62_QUEUESET_LOGICALLINK_REGISTRATION_METADATA_AUDIT" "$RUN_DIR/audit-summary.txt" || {
  echo "ERROR: latest folder is not a Stage62 audit"; exit 2;
}

UPLOAD_ID="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(5))')"
DEST="Development/Logs/stage62-review/$UPLOAD_ID"
WORK="$RUN_DIR/review-upload-$UPLOAD_ID"
mkdir -p "$WORK"

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
upload_one() {
  local file="$1" path="$2" expected existing payload response put readback
  expected="$(blob_sha "$file")"
  existing="$(remote_sha "$path")"
  if [[ -n "$existing" ]]; then
    if [[ "$existing" == "$expected" ]]; then
      echo "ALREADY_VERIFIED=$path SHA=$existing"
      return 0
    fi
    echo "ERROR: refusing to overwrite a different existing file: $path" >&2
    return 1
  fi
  payload="$WORK/payload-$RANDOM.json"
  response="$WORK/response-$RANDOM.json"
  python3 - "$file" "$payload" <<'PY'
import base64,json,pathlib,sys
src,dst=sys.argv[1:]
obj={"message":"Upload Stage62 review-required audit evidence","content":base64.b64encode(pathlib.Path(src).read_bytes()).decode()}
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
    echo "ERROR: SHA verification failed for $path" >&2
    return 1
  }
  echo "UPLOADED_AND_VERIFIED=$path SHA=$readback"
}

MANIFEST="$WORK/manifest.txt"
{
  echo "STAGE=62_REVIEW_EVIDENCE"
  echo "UPLOAD_ID=$UPLOAD_ID"
  echo "LOCAL_RUN=$(basename "$RUN_DIR")"
  echo "RESULT=REVIEW_REQUIRED"
  echo "ACTIVATION_GATE=BLOCKED"
  echo "SOURCE_MODIFIED=NO"
  echo "BUILD=NOT_RUN"
  echo "INSTALL=NOT_RUN"
  echo "LOAD=NOT_RUN"
  echo "OPENCORE_CHANGE=NONE"
} > "$MANIFEST"

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

for name in "${FILES[@]}"; do
  file="$RUN_DIR/$name"
  [[ -f "$file" ]] || { echo "WARNING: missing $name"; continue; }
  bytes="$(wc -c < "$file" | tr -d ' ')"
  if (( bytes <= 225280 )); then
    upload_one "$file" "$DEST/$name"
    printf 'FILE=%s BYTES=%s GIT_BLOB_SHA=%s\n' "$name" "$bytes" "$(blob_sha "$file")" >> "$MANIFEST"
  else
    part_prefix="$WORK/$(basename "$name").part-"
    split -b 220k "$file" "$part_prefix"
    for part in "$part_prefix"*; do
      [[ -f "$part" ]] || continue
      partname="$(basename "$part")"
      upload_one "$part" "$DEST/$partname"
      printf 'PART=%s BYTES=%s GIT_BLOB_SHA=%s\n' "$partname" "$(wc -c < "$part" | tr -d ' ')" "$(blob_sha "$part")" >> "$MANIFEST"
    done
  fi
done

upload_one "$MANIFEST" "$DEST/manifest.txt"
echo
echo "STAGE62_REVIEW_UPLOAD=SUCCESS"
echo "LOCAL_EVIDENCE=$RUN_DIR"
echo "GITHUB_EVIDENCE=https://github.com/$REPO/tree/main/$DEST"
echo "NOTE=Review evidence only. Stage62 remains REVIEW_REQUIRED; no driver, build, install, load, or OpenCore changes."
