#!/bin/bash
# Stage 76 V1 — 24H32 startup/publication gate audit.
# VERSION_MARKER: STAGE76_V1_20261103
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE76_V1_20261103"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAGE73_RUN="run-20261102-180530-d711b3944b06"
STAGE75_RUN="run-20261102-182045-29fbc9d32933"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage76/$RUN"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/console-output.log") 2>&1
LAST_ERROR_LINE="unknown"; LAST_ERROR_COMMAND="unknown"
fail(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="fail: $*"; echo "ERROR: $*" >&2; exit 2; }
capture_error(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="$BASH_COMMAND"; return 0; }
on_exit(){
 local rc="$1" rp="Development/Logs/stage76/$RUN/failure-report.txt"
 [[ "$rc" -ne 0 ]] || return 0
 trap - EXIT ERR; set +e
 { echo "STAGE=76"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "EXIT_CODE=$rc"; echo "FAILED_LINE=$LAST_ERROR_LINE"; echo "FAILED_COMMAND=$LAST_ERROR_COMMAND"; echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; echo "OPENCORE_MODIFIED=NO"; echo "TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; echo "===== CONSOLE TAIL ====="; tail -n 220 "$OUT/console-output.log"; } > "$OUT/failure-report.txt"
 if gh auth status >/dev/null 2>&1; then
  gh_contents_upload "$OUT/failure-report.txt" "$rp" "Upload Stage76 failure report" || true
  append_failure_log "$rc" "$rp" || true
 fi
 exit "$rc"
}
trap 'capture_error' ERR
trap 'on_exit $?' EXIT
for t in curl gh python3 shasum grep awk sw_vers uname wc tr tee date tail cut basename; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
[[ -d "$SRC/src" ]] || fail "source directory missing: $SRC/src"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "wrong host target; expected macOS 15.8.1/24H32/x86_64"
git_blob_sha(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
pin(){
 local file="$1" want="$2" got
 curl -fsSLo "$OUT/$file" "$3"
 got="$(git_blob_sha "$OUT/$file")"
 [[ "$got" == "$want" ]] || fail "predecessor pin mismatch $file expected=$want got=$got"
 echo "PIN_PASS=$file SHA=$got"
}
gh_contents_upload(){
 local file="$1" path="$2" message="$3" payload="$OUT/upload-$(basename "$file").json" result put got want
 want="$(git_blob_sha "$file")"
 python3 - "$file" "$payload" "$message" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":sys.argv[3],"content":base64.b64encode(p.read_bytes()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$OUT/upload-response.json"
 put="$(python3 - "$OUT/upload-response.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 got="$(gh api "repos/$REPO/contents/$path" -q .sha)"
 [[ "$put" == "$want" && "$got" == "$want" ]] || fail "upload readback mismatch $path expected=$want put=$put got=$got"
 echo "$path|$got" >> "$OUT/uploaded-artifacts.txt"
}
append_output_log(){
 local entry="$1"
 gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output.json"
 python3 - "$OUT/remote-output.json" "$OUT/output-payload.json" "$entry" <<'PY'
import base64,json,pathlib,sys
o=json.load(open(sys.argv[1])); old=base64.b64decode(o["content"])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage76 startup gate audit to output.log","sha":o["sha"],"content":base64.b64encode(old.rstrip()+sys.argv[3].encode()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
 local a b
 a="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 b="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
 [[ "$a" == "$b" ]] || fail "output.log readback SHA mismatch"
}
append_failure_log(){
 local rc="$1" rp="$2"
 append_output_log "\n========== STAGE 76 FAILURE ==========\nSTAGE76_FAILURE_RUN: $RUN\nSTAGE76_EXIT_CODE: $rc\nSTAGE76_FAILURE_REPORT: $rp\nSTAGE76_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n======================================\n"
}
RAW73="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage73/$STAGE73_RUN"
RAW75="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage75/$STAGE75_RUN"
pin "stage73-source-tree-fingerprint.txt" 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$RAW73/source-tree-fingerprint.txt"
pin "stage75-audit-summary.txt" 8bf032d3916517c990eb37ae015711e057011e50 "$RAW75/audit-summary.txt"
pin "stage75-registration-lifecycle.txt" 8eb7a938332c25c47b81701e229b997389211939 "$RAW75/registration-lifecycle-and-rollback.txt"
pin "stage75-native-registration-contract.txt" 96bf95d77d0033a8cc87901648a042b66e4d9b77 "$RAW75/native-registration-argument-contract.txt"
grep -q '^RESULT=PASS$' "$OUT/stage75-audit-summary.txt" || fail "Stage75 predecessor not PASS"

python3 - "$SRC" "$OUT/stage73-source-tree-fingerprint.txt" "$OUT/source-tree-revalidation.txt" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]); fp=pathlib.Path(sys.argv[2]); out=pathlib.Path(sys.argv[3])
expected={}
for line in fp.read_text().splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts}
ok=len(expected)==91 and set(expected)==set(actual)
rows=["STAGE76_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for rel in sorted(set(expected)|set(actual)):
 a=expected.get(rel,"MISSING"); b=actual.get(rel,"MISSING")
 if a!=b: ok=False
 rows.append("FILE="+rel+" EXPECTED="+a+" ACTUAL="+b+" RESULT="+("MATCH" if a==b else "MISMATCH"))
out.write_text("\n".join(rows)+"\n")
if not ok: raise SystemExit("source tree changed from pinned Stage73 inventory")
PY

python3 - "$SRC" "$OUT" <<'PY'
import pathlib,re,sys
src=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
files={}
for rel in ["src/kext/wcl24h32/RTW88WCLController.cpp",
            "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
            "src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp",
            "src/kext/wcl24h32/RTW88WCLController.hpp",
            "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp"]:
 p=src/rel
 if not p.is_file(): raise SystemExit("missing required source "+rel)
 files[rel]=p.read_text(errors="replace")
def strip_comments(s):
 out=[]; i=0; state="code"
 while i<len(s):
  c=s[i]; n=s[i+1] if i+1<len(s) else ""
  if state=="code":
   if c=='"': state="str"; out.append(c); i+=1; continue
   if c=="'": state="char"; out.append(c); i+=1; continue
   if c=="/" and n=="/": out.extend("  "); i+=2; state="line"; continue
   if c=="/" and n=="*": out.extend("  "); i+=2; state="block"; continue
   out.append(c); i+=1; continue
  if state in ("str","char"):
   out.append(c); i+=1
   if c=="\\" and i<len(s): out.append(s[i]); i+=1; continue
   if (state=="str" and c=='"') or (state=="char" and c=="'"): state="code"
   continue
  if state=="line":
   if c=="\n": out.append("\n"); state="code"
   else: out.append(" ")
   i+=1; continue
  if state=="block":
   if c=="*" and n=="/": out.extend("  "); i+=2; state="code"
   else: out.append("\n" if c=="\n" else " "); i+=1
 return "".join(out)
clean={k:strip_comments(v) for k,v in files.items()}
def body(rel,name):
 s=clean[rel]; m=re.search(r"(?<![A-Za-z0-9_])"+re.escape(name)+r"\s*\(",s)
 if not m:return None
 b=s.find("{",m.end()); semi=s.find(";",m.end())
 if b<0 or (semi>=0 and semi<b):return None
 depth=0; state="code"; i=b
 while i<len(s):
  c=s[i]
  if state=="code":
   if c=='"':state="str"
   elif c=="'":state="char"
   elif c=="{":depth+=1
   elif c=="}":
    depth-=1
    if depth==0:return s[b:i+1],s.count("\n",0,b)+1
  elif state in ("str","char"):
   if c=="\\":i+=1
   elif (state=="str" and c=='"') or (state=="char" and c=="'"):state="code"
  i+=1
 return None
rows=["STAGE76_STARTUP_AND_PUBLICATION_GATE_EVIDENCE"]
specs=[
 ("src/kext/wcl24h32/RTW88WCLController.cpp","RTW88WCLController::start"),
 ("src/kext/wcl24h32/RTW88WCLController.cpp","RTW88WCLController::releaseNativeResources"),
 ("src/kext/wcl24h32/RTW88WCLController.cpp","RTW88WCLController::stop"),
 ("src/kext/wcl24h32/RTW88WCLInfraInterface.cpp","RTW88WCLInfraInterface::start"),
 ("src/kext/wcl24h32/RTW88WCLInfraInterface.cpp","RTW88WCLInfraInterface::prepareRegistrationInfo"),
 ("src/kext/wcl24h32/RTW88WCLInfraInterface.cpp","RTW88WCLInfraInterface::stop")]
bodies={}
for rel,name in specs:
 got=body(rel,name); rows.append("\n===== "+name+" SOURCE="+rel+" =====")
 if not got: rows.append("BODY=NOT_FOUND"); continue
 text,start=got; bodies[name]=text
 rows.extend("%d: %s"%(start+i,line) for i,line in enumerate(text.splitlines()))
# Exact implementation references, no declaration/comment matches.
refrows=["STAGE76_REGISTRATION_AND_PACKETPATH_IMPLEMENTATION_REFERENCES"]
names=["prepareRegistrationInfo","registerInfraEthernetInterface","registerEthernetInterface","registerNetworkInterface","registerNetworkInterfaceWithLogicalLink","deregisterEthernetInterface","deregisterNetworkInterface","deregisterLogicalLink","bindPacketPath","activatePacketPath","_packetPathInterface","kPacketPathActive"]
for rel,s in clean.items():
 if not rel.endswith((".cpp",".cc",".mm")):continue
 for n,line in enumerate(s.splitlines(),1):
  hits=[x for x in names if re.search(r"(?<![A-Za-z0-9_])"+re.escape(x)+r"(?![A-Za-z0-9_])",line)]
  if hits:refrows.append("SOURCE="+rel+":"+str(n)+" TOKENS="+",".join(hits)+" TEXT="+files[rel].splitlines()[n-1].strip()[:300])
(out/"startup-control-flow-evidence.txt").write_text("\n".join(rows)+"\n")
(out/"registration-and-packetpath-callsite-map.txt").write_text("\n".join(refrows)+"\n")
c=bodies.get("RTW88WCLController::start","")
i=bodies.get("RTW88WCLInfraInterface::start","")
summary=[
 "STAGE76_24H32_STARTUP_AND_PUBLICATION_GATE_AUDIT",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "STAGE75_PREDECESSOR=PASS","SOURCE_TREE_REVALIDATION=PASS",
 "CONTROLLER_START_BODY="+("FOUND" if c else "MISSING"),
 "CONTROLLER_START_FAIL_LABEL="+("PRESENT" if re.search(r"\bfail\s*:",c) else "MISSING"),
 "CONTROLLER_START_TERMINAL_GOTO_FAIL="+("PRESENT" if re.search(r"goto\s+fail\s*;\s*fail\s*:",c) else "NOT_CONFIRMED"),
 "CONTROLLER_START_RETURN_TRUE_COUNT="+str(len(re.findall(r"\breturn\s+true\s*;",c))),
 "CONTROLLER_START_RETURN_FALSE_COUNT="+str(len(re.findall(r"\breturn\s+false\s*;",c))),
 "INFRA_START_BODY="+("FOUND" if i else "MISSING"),
 "INFRA_START_RETURN_TRUE_COUNT="+str(len(re.findall(r"\breturn\s+true\s*;",i))),
 "INFRA_START_RETURN_FALSE_COUNT="+str(len(re.findall(r"\breturn\s+false\s*;",i))),
 "PREPARE_REGISTRATION_CALLS_IN_INFRA_START="+str(len(re.findall(r"\bprepareRegistrationInfo\s*\(",i))),
 "NATIVE_REGISTRATION_IMPLEMENTATION_CALLS="+str(sum(len(re.findall(r"(?<![A-Za-z0-9_:])"+x+r"\s*\(",s)) for rel,s in clean.items() if rel.endswith((".cpp",".cc",".mm")) for x in ["registerInfraEthernetInterface","registerEthernetInterface","registerNetworkInterface","registerNetworkInterfaceWithLogicalLink"])),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_MODIFIED=NO",
 "ISSUES=NONE","RESULT=PASS","ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=["========== STAGE 76 STARTUP / PUBLICATION GATE ==========","VERSION=STAGE76_V1_20261103","RUN="+out.name,"PREDECESSOR=Stage75 V1","PURPOSE=verify start return paths, registration callsites and packet-path activation gates from unchanged 24H32 source","",*summary,"","RESULT=PASS means read-only audit completed; it does not mean the driver can start or publish an interface.","========== END STAGE 76 =========="]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=76"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "TARGET=15.8.1/24H32/x86_64"
 echo "PREDECESSOR=Stage75 run $STAGE75_RUN"; echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"
} > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/startup-control-flow-evidence.txt" "$OUT/registration-and-packetpath-callsite-map.txt" "$OUT/report.txt"; do
 sha="$(git_blob_sha "$f")"; echo "ARTIFACT|$(basename "$f")|$sha" >> "$MAN"
 gh_contents_upload "$f" "Development/Logs/stage76/$RUN/$(basename "$f")" "Add Stage76 startup gate evidence"
done
gh_contents_upload "$MAN" "Development/Logs/stage76/$RUN/manifest.txt" "Add Stage76 manifest"
append_output_log "\n========== STAGE 76 STARTUP / PUBLICATION GATE ==========\nSTAGE76_RUN: $RUN\nSTAGE76_VERSION: $VERSION\nSTAGE76_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nACTIVATION_GATE: BLOCKED — read-only startup gate audit\nSTAGE76_LOGS: Development/Logs/stage76/$RUN/\n=========================================================\n"
echo "STAGE76_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE76_RUN=$RUN"
echo "STAGE76_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage76/$RUN"
