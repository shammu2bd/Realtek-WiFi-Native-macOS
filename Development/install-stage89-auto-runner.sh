#!/bin/bash
# One-time installer for the Stage89 local read-only LaunchAgent supervisor.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
BASE="$ROOT/run log/automation"
SCRIPT="$BASE/stage89-auto-runner.sh"
TMP="$BASE/stage89-auto-runner.sh.download"
PLIST="$HOME/Library/LaunchAgents/com.realtekwifi.stage89-auto-runner.plist"
LABEL="com.realtekwifi.stage89-auto-runner"
EXPECTED_BLOB_SHA="7795de88b4cfd98789c7a32069e0c420ee0c0d94"
fail(){ echo "INSTALL_ERROR=$*" >&2; exit 1; }
for t in curl gh python3 sw_vers uname launchctl; do command -v "$t" >/dev/null 2>&1 || fail "Missing command: $t"; done
[[ -d "$ROOT/driver/RTL88WiFi/src" ]] || fail "Project folder not found: $ROOT"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "This supervisor is pinned to macOS Sequoia 15.8.1 (24H32) x86_64"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI must already be authenticated in this macOS user account"
mkdir -p "$BASE/logs" "$BASE/state" "$BASE/cache" "$HOME/Library/LaunchAgents"
curl -fsSLo "$TMP" "https://raw.githubusercontent.com/$REPO/main/Development/stage89-auto-runner.sh" || fail "Could not download supervisor"
python3 - "$TMP" "$EXPECTED_BLOB_SHA" <<'PYSHA'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
sha=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
if sha!=sys.argv[2]: raise SystemExit("Supervisor SHA mismatch: "+sha)
print("SUPERVISOR_BLOB_SHA_VERIFIED="+sha)
PYSHA
mv "$TMP" "$SCRIPT"
chmod 700 "$SCRIPT"
GH_DIR="$(dirname "$(command -v gh)")"
PY_DIR="$(dirname "$(command -v python3)")"
PATH_VALUE="$GH_DIR:$PY_DIR:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
python3 - "$PLIST" "$SCRIPT" "$ROOT" "$BASE" "$HOME" "$PATH_VALUE" "$LABEL" <<'PYPLIST'
import os,plistlib,sys
plist,script,root,base,home,path,label=sys.argv[1:]
obj={
 "Label":label,
 "ProgramArguments":["/bin/bash",script],
 "RunAtLoad":True,
 "StartInterval":300,
 "WorkingDirectory":root,
 "StandardOutPath":os.path.join(base,"logs","launchd.stdout.log"),
 "StandardErrorPath":os.path.join(base,"logs","launchd.stderr.log"),
 "EnvironmentVariables":{"HOME":home,"PATH":path,"GH_PROMPT_DISABLED":"1","REPO":"shammu2bd/Realtek-WiFi-Native-macOS"}
}
with open(plist,"wb") as f: plistlib.dump(obj,f,fmt=plistlib.FMT_XML,sort_keys=True)
PYPLIST
UID_NOW="$(id -u)"
launchctl bootout "gui/$UID_NOW" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_NOW" "$PLIST" || fail "launchd could not load the agent"
launchctl kickstart -k "gui/$UID_NOW/$LABEL" || fail "launchd could not start the agent"
echo "STAGE89_AUTO_RUNNER_INSTALLED=YES"
echo "LAUNCH_AGENT=$PLIST"
echo "POLL_INTERVAL_SECONDS=300"
echo "NEXT_ACTION=Supervisor automatically checks Development/output.log and runs only the next marked Stage89 read-only runner."
echo "LOCAL_LOGS=$BASE/logs/"
echo "LOCAL_STAGE_RUNS=$ROOT/run log/"
echo "GITHUB_HISTORY=Development/output.log"
echo "STAGE90=LOCKED"
echo "SOURCE_PULL=DISABLED BUILD_SIGN_INSTALL_LOAD=DISABLED OPENCORE_SIP_NVRAM=UNCHANGED"
