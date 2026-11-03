#!/bin/bash
# Stage 35D — locate project root and automatically upload diagnostic results.
# Read-only project scan. Uses the user's existing GitHub CLI login (gh auth).
# Does not initialize Git, edit source, build/install/load a kext, or alter OpenCore.
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE35D_ERROR=exit:$rc line:$LINENO" >&2; if [[ -f "${OUT:-}/upload-error.txt" ]]; then echo "UPLOAD_ERROR_LOG=$OUT/upload-error.txt" >&2; tail -40 "$OUT/upload-error.txt" >&2; fi; exit "$rc"' ERR

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
DOWNLOADS="$HOME/Downloads"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35D-$RUN"
REPORT="$OUT/report.txt"
PARTS_DIR="$OUT/parts"
MANIFEST="$OUT/manifest.txt"
mkdir -p "$PARTS_DIR"
for tool in find sort head git gh python3 split shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated. Run: gh auth login"; exit 3; }
[[ -d "$DOWNLOADS" ]] || { echo "ERROR: Downloads directory missing: $DOWNLOADS"; exit 2; }

# Capture the complete diagnostic locally while keeping terminal output concise.
{
  echo "========== STAGE 35D: PROJECT ROOT DISCOVERY =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "pwd=$PWD"
  echo "home=$HOME"
  echo

  echo "--- Candidate project directories ---"
  find "$DOWNLOADS" -maxdepth 6 -type d \( -iname '*RTL88WiFi*' -o -iname '*RTW88*' -o -iname 'BDIX-TV' \) -print 2>/dev/null | sort

  echo
  echo "--- Git metadata (.git directories or files) ---"
  find "$DOWNLOADS" -maxdepth 8 \( -type d -name .git -o -type f -name .git \) -print 2>/dev/null | sort

  echo
  echo "--- Expected native driver Makefile ---"
  find "$DOWNLOADS" -maxdepth 9 -type f -path '*/driver/RTL88WiFi/Makefile' -print 2>/dev/null | sort

  echo
  echo "--- Any RTL88WiFi Makefiles (layout discovery) ---"
  find "$DOWNLOADS" -maxdepth 9 -type f -iname 'Makefile' -path '*RTL88WiFi*' -print 2>/dev/null | sort | head -200

  echo
  echo "--- Nearby Development/src/build directories ---"
  find "$DOWNLOADS" -maxdepth 6 -type d \( -name Development -o -name src -o -name build \) -print 2>/dev/null | sort | head -200

  echo
  echo "--- Git status for every discovered checkout ---"
  while IFS= read -r gitdir; do
    [[ -n "$gitdir" ]] || continue
    candidate="${gitdir%/.git}"
    [[ -f "$gitdir" ]] && candidate="$(dirname "$gitdir")"
    echo "GIT_CANDIDATE=$candidate"
    git -C "$candidate" rev-parse --show-toplevel 2>&1 || true
    git -C "$candidate" rev-parse --short HEAD 2>&1 || true
    git -C "$candidate" remote -v 2>&1 | head -4 || true
    echo
  done < <(find "$DOWNLOADS" -maxdepth 8 \( -type d -name .git -o -type f -name .git \) -print 2>/dev/null)

  echo "READ_ONLY=YES"
  echo "SOURCE_OR_OPENCORE_MODIFIED=NO"
  echo "========== END STAGE 35D =========="
} >"$REPORT" 2>&1

# Split the report into conservative GitHub Contents API-sized chunks.
split -b 240k "$REPORT" "$PARTS_DIR/report-"
: > "$MANIFEST"
printf 'STAGE: 35D\nRUN: %s\nREPORT_BYTES: %s\n' "$RUN" "$(wc -c <"$REPORT" | tr -d ' ')" >> "$MANIFEST"

upload_file() {
  local file="$1" path="$2" message="$3" payload="$4" response="$5"
  local old put got
  old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
  python3 - "$file" "$old" "$message" "$payload" <<'PY'
import base64,json,pathlib,sys
file_path,sha,message,dest=sys.argv[1:]
obj={"message":message,"content":base64.b64encode(pathlib.Path(file_path).read_bytes()).decode("ascii")}
if sha: obj["sha"]=sha
pathlib.Path(dest).write_text(json.dumps(obj))
PY
  if ! gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" >"$response" 2>"$OUT/upload-error.txt"; then
    {
      echo "UPLOAD_FAILED_PATH=$path"
      echo "UPLOAD_HTTP_OR_GH_ERROR:"
      cat "$OUT/upload-error.txt"
      echo "PAYLOAD_BYTES=$(wc -c <"$payload" | tr -d ' ')"
      echo "AUTH_ACCOUNT=$(gh api user --jq .login 2>&1 || true)"
      echo "REPO_PERMISSION_CHECK:"
      gh api "repos/$REPO" --jq '.full_name + " push=" + (.permissions.push|tostring)' 2>&1 || true
    } >>"$OUT/upload-error.txt"
    echo "ERROR: upload failed for $path; details: $OUT/upload-error.txt" >&2
    return 1
  fi
  put="$(python3 - "$response" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
sha=(data.get("content") or {}).get("sha")
if not sha:
    raise SystemExit("GitHub PUT response did not contain content.sha: "+repr(data)[:1000])
print(sha)
PY
)"
  if ! got="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>"$OUT/readback-error.txt")"; then
    echo "READBACK_FAILED_PATH=$path" >>"$OUT/upload-error.txt"
    cat "$OUT/readback-error.txt" >>"$OUT/upload-error.txt"
    return 1
  fi
  [[ "$put" == "$got" ]] || { echo "ERROR: GitHub SHA readback mismatch: $path"; return 1; }
  UPLOAD_SHA="$got"
}

COUNT=0
for part in "$PARTS_DIR"/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35d/$RUN/$name"
  upload_file "$part" "$remote" "Add immutable Stage35D diagnostic chunk $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
  bytes="$(wc -c <"$part" | tr -d ' ')"
  local_sha="$(shasum -a 256 "$part" | awk '{print $1}')"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$bytes" "$local_sha" >> "$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]] || { echo "ERROR: report split produced no chunks"; exit 4; }

upload_file "$MANIFEST" "Development/Logs/stage35d/$RUN/manifest.txt" "Add Stage35D diagnostic manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
MANIFEST_BLOB="$UPLOAD_SHA"

echo "STAGE35D_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35D_RUN=$RUN"
echo "STAGE35D_REPORT_BYTES=$(wc -c <"$REPORT" | tr -d ' ')"
echo "STAGE35D_REPORT_PARTS=$COUNT"
echo "STAGE35D_MANIFEST_BLOB=$MANIFEST_BLOB"
echo "STAGE35D_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35d/$RUN"
echo "STAGE35D_LOCAL_REPORT=$REPORT"
echo "SOURCE_CHANGES=NONE | BUILD=NOT RUN | INSTALL=NOT RUN | LOAD=NOT RUN | OPENCORE_CHANGE=NONE"
