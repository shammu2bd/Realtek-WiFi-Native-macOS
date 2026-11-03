#!/bin/bash
set -u
REPO='shammu2bd/Realtek-WiFi-Native-macOS'
API="repos/$REPO/contents/Development/stage22-latest-report.txt"
NAME='RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source'
PROJECT=''
if [[ -n "${PROJECT_DIR:-}" && -d "$PROJECT_DIR/build" ]]; then
  PROJECT="$(cd "$PROJECT_DIR" && pwd -P)"
elif [[ -d "$PWD/build" && -d "$PWD/driver/RTL88WiFi" ]]; then
  PROJECT="$(pwd -P)"
elif [[ -d "$HOME/Downloads/$NAME/build" ]]; then
  PROJECT="$HOME/Downloads/$NAME"
fi
[[ -n "$PROJECT" ]] || { echo 'Cannot locate Stage26 project.'; exit 2; }
command -v gh >/dev/null 2>&1 || { echo 'GitHub CLI required.'; exit 2; }
gh auth status >/dev/null 2>&1 || { echo 'GitHub CLI authentication required.'; exit 2; }
REPORT="$(find "$PROJECT/build" -type f -path '*/stage22-deep-source-lifecycle-audit-*/stage22-deep-source-lifecycle-report.txt' -print 2>/dev/null | sort | tail -n 1)"
[[ -n "$REPORT" && -s "$REPORT" ]] || { echo 'Stage22 report file not found. Stage22 may not have completed.'; exit 3; }
SIZE=$(wc -c < "$REPORT" | tr -d ' ')
if (( SIZE > 900000 )); then
  echo "Report is $SIZE bytes; single-file export limit exceeded. Report must be split."
  exit 4
fi
TMPDIR_STAGE22="$(mktemp -d)"
SHA=$(gh api "$API" --jq '.sha' 2>/dev/null || true)
python3 - "$REPORT" "$TMPDIR_STAGE22/payload.json" "$SHA" <<'PY'
import base64,json,pathlib,sys
raw=pathlib.Path(sys.argv[1]).read_bytes()
payload={"message":"Publish Stage22 report for review","content":base64.b64encode(raw).decode()}
if sys.argv[3]: payload["sha"]=sys.argv[3]
pathlib.Path(sys.argv[2]).write_text(json.dumps(payload))
PY
gh api --method PUT "$API" --input "$TMPDIR_STAGE22/payload.json" > "$TMPDIR_STAGE22/response.json" || exit 5
REMOTE=$(gh api "$API" --jq '.sha') || exit 5
PUT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["content"]["sha"])' "$TMPDIR_STAGE22/response.json")
[[ "$REMOTE" == "$PUT" ]] || { echo 'Report read-back SHA mismatch.'; exit 6; }
echo "STAGE22_REPORT_EXPORT: SUCCESS"
echo "REPORT_BYTES: $SIZE"
echo "REPORT_SOURCE: $REPORT"
echo "GITHUB_PATH: Development/stage22-latest-report.txt"
echo "REMOTE_BLOB_SHA: $REMOTE"
