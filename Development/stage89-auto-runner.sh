#!/bin/bash
# Stage89 local launchd supervisor.
# Runs only the next Stage89 script marked AUTO_SAFE_READ_ONLY=YES and AUTO_SCOPE=STAGE89_AUDIT.
# Never enters Stage90; never updates/pulls source; never builds, signs, installs, loads or changes OpenCore.
set -Eeuo pipefail
trap 'notify "Automation error; inspect run log for details."' ERR
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
BASE="$ROOT/run log/automation"
STATE="$BASE/state"
CACHE="$BASE/cache"
LOCK="$BASE/lock"
[[ -d "$ROOT/driver/RTL88WiFi/src" ]] || { echo "AUTOMATION_ERROR=project folder not found; no local folders created"; exit 1; }
mkdir -p "$BASE/logs" "$STATE" "$CACHE"
LOG="$BASE/logs/poll-$(date -u '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "$LOG") 2>&1
notify(){
 /usr/bin/osascript -e "display notification \"$1\" with title \"RTL88WiFi Stage89 automation\"" >/dev/null 2>&1 || true
}
fail(){
 echo "AUTOMATION_ERROR=$*"
 notify "Stage89 automation stopped: $1"
 exit 1
}
if ! mkdir "$LOCK" 2>/dev/null; then
 oldpid="$(cat "$LOCK/pid" 2>/dev/null || true)"
 if [[ "$oldpid" =~ ^[0-9]+$ ]] && kill -0 "$oldpid" 2>/dev/null; then
  echo "AUTOMATION_ALREADY_RUNNING=YES PID=$oldpid"
  exit 0
 fi
 rm -rf "$LOCK"
 mkdir "$LOCK" || exit 0
fi
echo "$$" > "$LOCK/pid"
cleanup(){ rm -rf "$LOCK"; }
trap cleanup EXIT
for t in curl gh python3 sw_vers uname date tee; do command -v "$t" >/dev/null 2>&1 || fail "missing $t"; done
if [[ -f "$BASE/STOP" ]]; then echo "AUTOMATION_PAUSED_BY_LOCAL_STOP_FILE=YES"; exit 0; fi
[[ -d "$ROOT/driver/RTL88WiFi/src" ]] || fail "project folder not found at expected path"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "wrong target OS/build/architecture; refusing to run"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI authentication unavailable"
echo "AUTOMATION_POLL=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "PROJECT_ROOT=$ROOT"
echo "POLICY=STAGE89_READ_ONLY_ONLY"
echo "SOURCE_PULL=DISABLED"
echo "BUILD_SIGN_INSTALL_LOAD=DISABLED"
echo "OPENCORE_SIP_NVRAM_CHANGES=DISABLED"
gh api "repos/$REPO/contents/Development/output.log" > "$BASE/output-log.json" || fail "cannot fetch canonical Development/output.log"
python3 - "$BASE/output-log.json" "$BASE/output-log.txt" <<'PYLOG'
import base64,json,pathlib,sys
o=json.load(open(sys.argv[1]))
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(o["content"]))
PYLOG
read_info="$(python3 - "$BASE/output-log.txt" <<'PYINFO'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text(errors="replace")
matches=list(re.finditer(r"STAGE89_V(\d+)_RUN:\s*(run-[A-Za-z0-9-]+)",s))
if not matches:
    raise SystemExit("NO_STAGE89_RUN")
m=matches[-1]
print(m.group(1)+"|"+m.group(2))
PYINFO
)" || fail "canonical log has no recognized Stage89 run"
latest_version="$(printf '%s' "$read_info" | cut -d '|' -f 1)"
latest_run="$(printf '%s' "$read_info" | cut -d '|' -f 2)"
echo "LATEST_CANONICAL_STAGE89_VERSION=$latest_version"
echo "LATEST_CANONICAL_STAGE89_RUN=$latest_run"
if (( latest_version >= 15 )) && [[ ! -f "$STATE/verified-v$latest_version" ]]; then fail "latest Stage89 V$latest_version lacks a verified local artifact receipt"; fi
[[ "$latest_version" =~ ^[0-9]+$ ]] || fail "bad latest Stage89 version"
next_version=$((latest_version+1))
if (( next_version >= 90 )); then
 echo "STAGE90_AUTOMATION=LOCKED; Stage89 must be explicitly closed and later stages separately authorized"
 exit 0
fi
if grep -q "STAGE89_EXIT=PASS" "$BASE/output-log.txt"; then
 echo "STAGE89_EXIT_GATE=PASS_REQUIRES_SEPARATE_REVIEW; supervisor will not start Stage90"
 exit 0
fi
gh api "repos/$REPO/contents/Development?ref=main" > "$BASE/development-list.json" || fail "cannot list Development runners"
runner="$(python3 - "$BASE/development-list.json" "$next_version" <<'PYRUNNER'
import json,sys
items=json.load(open(sys.argv[1]))
prefix="stage89-v"+sys.argv[2]+"-"
found=[x["name"] for x in items if x.get("type")=="file" and x.get("name","").startswith(prefix) and x["name"].endswith(".sh")]
if len(found)==0:
    print("NONE")
elif len(found)==1:
    print(found[0])
else:
    print("AMBIGUOUS")
PYRUNNER
)"
if [[ "$runner" == "NONE" ]]; then
 echo "NEXT_RUNNER=NOT_PUBLISHED stage89-v$next_version"
 stamp="$STATE/notified-no-runner-v$next_version"
 if [[ ! -f "$stamp" ]]; then
  touch "$stamp"
  notify "Waiting for the next approved Stage89 audit runner (V$next_version)."
 fi
 exit 0
fi
if [[ "$runner" == "AMBIGUOUS" ]]; then fail "multiple Stage89 V$next_version runners found; refusing to guess"; fi
echo "NEXT_RUNNER=$runner"
attempt_file="$STATE/attempts-v$next_version"
last_file="$STATE/last-attempt-v$next_version"
attempts="$(cat "$attempt_file" 2>/dev/null || echo 0)"
last="$(cat "$last_file" 2>/dev/null || echo 0)"
now="$(date +%s)"
[[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
[[ "$last" =~ ^[0-9]+$ ]] || last=0
if (( now-last < 900 )); then
 echo "RETRY_COOLDOWN=ACTIVE"
 exit 0
fi
if (( attempts >= 3 )); then
 echo "RUNNER_RETRY_LIMIT=3_REACHED version=$next_version"
 notify "Stage89 V$next_version reached its retry limit; review the run log."
 exit 0
fi
response="$CACHE/$runner.json"
script="$CACHE/$runner"
gh api "repos/$REPO/contents/Development/stage89-auto-allowlist.txt?ref=main" > "$BASE/allowlist.json" || fail "cannot fetch runner allowlist"
python3 - "$BASE/allowlist.json" "$BASE/allowlist.txt" <<'PYALLOW'
import base64,json,pathlib,sys
o=json.load(open(sys.argv[1]))
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(o["content"]))
PYALLOW
gh api "repos/$REPO/contents/Development/$runner?ref=main" > "$response" || fail "cannot download approved runner metadata"
python3 - "$response" "$script" "$BASE/allowlist.txt" <<'PYSCRIPT'
import base64,hashlib,json,pathlib,sys
o=json.load(open(sys.argv[1]))
raw=base64.b64decode(o["content"])
sha=hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()
if sha!=o.get("sha"): raise SystemExit("GitHub runner blob SHA mismatch")
s=raw.decode("utf-8")
entries={}
for line in pathlib.Path(sys.argv[3]).read_text(errors="replace").splitlines():
    if line.startswith("RUNNER|"):
        _,name,pin=line.split("|",2)
        entries[name]=pin
if entries.get(pathlib.Path(sys.argv[2]).name)!=o.get("sha"):
    raise SystemExit("Runner is not explicitly pinned in stage89-auto-allowlist.txt")
head="\n".join(s.splitlines()[:12])
if "# AUTO_SAFE_READ_ONLY=YES" not in head: raise SystemExit("runner lacks read-only automation marker")
if "# AUTO_SCOPE=STAGE89_AUDIT" not in head: raise SystemExit("runner lacks Stage89-only scope marker")
if not s.startswith("#!/bin/bash"): raise SystemExit("runner is not a bash script")
for bad in ["kmutil install","kextload","kextunload","csrutil","nvram ","bless ","spctl ","diskutil "]:
    if bad in s: raise SystemExit("runner contains a prohibited runtime/security command: "+bad)
pathlib.Path(sys.argv[2]).write_bytes(raw)
print("RUNNER_CONTENT_SHA="+sha)
PYSCRIPT
attempts=$((attempts+1))
printf '%s\n' "$attempts" > "$attempt_file"
printf '%s\n' "$now" > "$last_file"
echo "EXECUTING_APPROVED_RUNNER=$runner ATTEMPT=$attempts"
run_status=0
/bin/bash "$script" > >(tee -a "$BASE/logs/stage89-v$next_version-console.log") 2>&1 || run_status=$?
echo "RUNNER_EXIT_CODE=$run_status"
gh api "repos/$REPO/contents/Development/output.log" > "$BASE/output-log-after.json" || fail "cannot re-fetch canonical log after runner"
python3 - "$BASE/output-log-after.json" "$next_version" "$BASE/run-id-v$next_version.txt" <<'PYRUNID'
import base64,json,pathlib,re,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
m=list(re.finditer(r"STAGE89_V"+re.escape(sys.argv[2])+r"_RUN:\s*(run-[A-Za-z0-9-]+)",s))
if not m: raise SystemExit("No new canonical checkpoint for this version")
pathlib.Path(sys.argv[3]).write_text(m[-1].group(1))
print("CANONICAL_STAGE_CHECKPOINT=PASS")
PYRUNID
run_id="$(cat "$BASE/run-id-v$next_version.txt")"
stage_tag="stage89-v$next_version"
manifest_path="Development/Logs/$stage_tag/$run_id/manifest.txt"
gh api "repos/$REPO/contents/$manifest_path?ref=main" > "$BASE/manifest.json" || fail "runner checkpoint exists but its manifest cannot be fetched"
python3 - "$BASE/manifest.json" "$BASE/manifest.txt" <<'PYMAN'
import base64,json,pathlib,sys
o=json.load(open(sys.argv[1]))
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(o["content"]))
PYMAN
python3 - "$BASE/manifest.txt" "$run_id" "$stage_tag" <<'PYVERIFY'
import pathlib,sys,subprocess
lines=pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
run=sys.argv[2]; stage=sys.argv[3]
if "RUN="+run not in lines: raise SystemExit("Manifest run ID mismatch")
arts=[]
for line in lines:
    if line.startswith("ARTIFACT|"):
        bits=line.split("|",3)
        if len(bits)!=4: raise SystemExit("Malformed artifact manifest line")
        arts.append((bits[1],bits[2]))
if not arts: raise SystemExit("Manifest has no artifacts")
print("MANIFEST_ARTIFACT_COUNT="+str(len(arts)))
for name,want in arts:
    path="Development/Logs/"+stage+"/"+run+"/"+name
    got=subprocess.check_output(["gh","api","repos/shammu2bd/Realtek-WiFi-Native-macOS/contents/"+path+"?ref=main","-q",".sha"],text=True).strip()
    if got!=want: raise SystemExit("Artifact SHA mismatch "+name+" expected="+want+" actual="+got)
    print("ARTIFACT_SHA_VERIFIED="+name+" "+got)
PYVERIFY
if (( run_status != 0 )); then fail "runner returned nonzero after checkpoint/artifact verification"; fi
touch "$STATE/verified-v$next_version"
rm -f "$attempt_file" "$last_file" "$STATE/notified-no-runner-v$next_version"
echo "STAGE89_V$next_version_AUTOMATION=COMPLETED_AND_ARTIFACTS_VERIFIED"
echo "RUN_ID=$run_id"
notify "Stage89 V$next_version complete; uploaded artifacts verified. Review status remains in GitHub."
