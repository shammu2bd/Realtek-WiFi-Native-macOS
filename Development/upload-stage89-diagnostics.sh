#!/bin/bash
# Collects Stage89 supervisor diagnostics and uploads them to Development/Logs.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
AUTO="$HOME/Library/Application Support/RTL88WiFi-Automation"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
REPORT="$AUTO/logs/post-repair-diagnostic-$STAMP.txt"
REMOTE="Development/Logs/automation-diagnostic-$STAMP.txt"
PAYLOAD="$AUTO/logs/diagnostic-upload-$STAMP.json"
RESPONSE="$AUTO/logs/diagnostic-upload-response-$STAMP.json"
ERROR="$AUTO/logs/diagnostic-upload-error-$STAMP.txt"

fail() {
  echo "DIAGNOSTIC_UPLOAD=FAILED"
  echo "DETAIL=$1"
  echo "LOCAL_REPORT=$REPORT"
  exit 1
}

[[ -d "$AUTO" ]] || fail "Automation folder not found: $AUTO"
command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is not installed"
command -v python3 >/dev/null 2>&1 || fail "python3 is not installed"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run gh auth login first"

mkdir -p "$AUTO/logs"

{
  echo "RTL88WIFI STAGE89 POST-REPAIR DIAGNOSTICS"
  echo "UTC_TIME=$STAMP"
  echo "HOST_ARCH=$(uname -m 2>/dev/null || true)"
  echo "MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null || true)"
  echo "MACOS_BUILD=$(sw_vers -buildVersion 2>/dev/null || true)"
  echo
  echo "===== SUPERVISOR FILE ====="
  if [[ -f "$AUTO/stage89-auto-runner.sh" ]]; then
    shasum "$AUTO/stage89-auto-runner.sh" 2>&1 || true
    grep -n 'next_version_AUTOMATION\|NEXT_RUNNER=\|next_version=' "$AUTO/stage89-auto-runner.sh" 2>/dev/null || true
  else
    echo "SUPERVISOR_FILE=MISSING"
  fi
  echo
  echo "===== GITHUB CLI AUTH ====="
  if gh auth status >/dev/null 2>&1; then echo "GH_AUTH=PASS"; else echo "GH_AUTH=FAIL"; fi
  echo
  echo "===== LAUNCHAGENT STATUS ====="
  launchctl print "gui/$(id -u)/com.realtekwifi.stage89-auto-runner" 2>&1 || true
  echo
  echo "===== LATEST POLL LOGS ====="
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    echo "--- $f ---"
    tail -100 "$f" 2>&1 || true
  done < <(ls -t "$AUTO"/logs/poll-*.log 2>/dev/null | head -3 || true)
  echo
  echo "===== LAUNCHD STDOUT ====="
  tail -100 "$AUTO/logs/launchd.stdout.log" 2>&1 || true
  echo
  echo "===== LAUNCHD STDERR ====="
  tail -100 "$AUTO/logs/launchd.stderr.log" 2>&1 || true
  echo
  echo "===== PREVIOUS VARIABLE ERROR SEARCH ====="
  grep -n 'next_version_AUTOMATION\|unbound variable' "$AUTO"/logs/*.log 2>/dev/null | tail -40 || true
  echo
  echo "===== V16 STATE ====="
  cat "$AUTO/state/notified-no-runner-v16" 2>/dev/null || true
  echo
  echo "===== APPROVED RUNNER ALLOWLIST ====="
  cat "$AUTO/allowlist.txt" 2>/dev/null || true
  echo
  echo "===== CACHED CANONICAL OUTPUT LOG TAIL ====="
  tail -80 "$AUTO/output-log.txt" 2>/dev/null || true
} > "$REPORT"

python3 - "$REPORT" "$PAYLOAD" "$REMOTE" <<'PY'
import base64, json, pathlib, sys
report, payload, remote = sys.argv[1:]
body = {
    "message": "Upload Stage89 automation post-repair diagnostics",
    "content": base64.b64encode(pathlib.Path(report).read_bytes()).decode("ascii")
}
pathlib.Path(payload).write_text(json.dumps(body))
print("REPORT_BYTES=" + str(pathlib.Path(report).stat().st_size))
print("GITHUB_DESTINATION=" + remote)
PY

if ! gh api --method PUT "repos/$REPO/contents/$REMOTE" --input "$PAYLOAD" > "$RESPONSE" 2> "$ERROR"; then
  echo "DIAGNOSTIC_UPLOAD=FAILED"
  echo "GITHUB_ERROR_FILE=$ERROR"
  cat "$ERROR" 2>/dev/null || true
  echo "LOCAL_REPORT=$REPORT"
  exit 1
fi

SHA="$(gh api "repos/$REPO/contents/$REMOTE?ref=main" -q '.sha' 2> "$ERROR")" || fail "Upload returned but read-after-write SHA verification failed"
echo "DIAGNOSTIC_UPLOAD=SUCCESS"
echo "GITHUB_BLOB_SHA=$SHA"
echo "GITHUB_FILE=https://github.com/$REPO/blob/main/$REMOTE"
echo "LOCAL_REPORT=$REPORT"
