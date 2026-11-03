#!/bin/bash
# Stage 35P — native WCL TX adapter ownership, completion wakeup, and teardown audit.
# VERSION_MARKER: STAGE35P_V1_20261102
# READ ONLY: no source edits, build, install, Kext load, or OpenCore changes.
set -Eeuo pipefail
echo "STAGE35P_SCRIPT_VERSION=1"

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW="$SRC/../rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35P-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35P_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 shasum split find grep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" ]] || { echo "ERROR: project Makefile missing: $SRC/Makefile"; exit 3; }
[[ -f "$SRC/src/kext/wcl24h32/RTW88WCLController.cpp" ]] || { echo "ERROR: WCL controller source missing"; exit 4; }
[[ -f "$SRC/src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp" ]] || { echo "ERROR: WCL TX adapter source missing"; exit 5; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 6; }

{
  echo "========== STAGE 35P: NATIVE TX ADAPTER / DRAIN INTEGRATION AUDIT =========="
  echo "script_version=STAGE35P_V1_20261102"
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "source_root=$SOURCE_ROOT"
  echo "mode=read-only controller ownership / event wakeup / completion teardown audit"
  echo
} > "$REPORT"

python3 - "$SRC" "$RTW" >> "$REPORT" <<'PY'
import hashlib, os, pathlib, re, sys

src, rtw = map(pathlib.Path, sys.argv[1:])
roots = [("KEXT", src / "src/kext"), ("COMPAT", src / "src/compat"),
         ("RTW88", rtw)]
exts = {".c", ".cc", ".cpp", ".h", ".hpp", ".mm", ".m", ".mk", ".pbxproj"}
files = []
for label, root in roots:
    if not root.is_dir():
        print("MISSING_ROOT=%s" % root)
        continue
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in {".git", "build", "DerivedData", "Products"} and not d.endswith(".dSYM")]
        for name in sorted(names):
            p = pathlib.Path(base) / name
            if p.suffix.lower() not in exts and name != "Makefile":
                continue
            try:
                raw = p.read_bytes()
                txt = raw.decode("utf-8", "replace")
            except OSError as e:
                print("READ_ERROR=%s:%s" % (p, e))
                continue
            files.append((label, p, txt, raw))

def rel(p):
    try:
        return str(p.relative_to(src))
    except ValueError:
        try:
            return "../rtw88-stable/" + str(p.relative_to(rtw))
        except ValueError:
            return str(p)

by_path = {rel(p):(lab,p,t,raw) for lab,p,t,raw in files}
def get(name):
    return next((x for x in files if x[1].name == name), None)

def lines_for(rx, exclude_comments=True):
    out=[]
    for lab,p,t,raw in files:
        for n,line in enumerate(t.splitlines(),1):
            s=line.strip()
            if exclude_comments and (s.startswith("//") or s.startswith("/*") or s.startswith("*")):
                continue
            if rx.search(line):
                out.append((rel(p),n,line.rstrip()))
    return out

def emit_refs(title, rx, cap=180, exclude_comments=True):
    hits=lines_for(re.compile(rx),exclude_comments)
    print("\n--- %s ---" % title)
    print("REFERENCE_COUNT=%d" % len(hits))
    for path,n,line in hits[:cap]:
        print("%s:%d | %s" % (path,n,line[:360]))
    if len(hits)>cap:
        print("TRUNCATED=%d" % (len(hits)-cap))
    return hits

def context(title, name, patterns, before=10, after=24, cap=45):
    rows=[x for x in files if x[1].name==name]
    if not rows:
        print("\nFILE_NOT_FOUND=%s" % name)
        return
    for lab,p,t,raw in rows:
        ls=t.splitlines()
        hits=[i for i,line in enumerate(ls) if any(re.search(pat,line) for pat in patterns)]
        wins=[]
        for i in hits:
            lo=max(0,i-before); hi=min(len(ls),i+after+1)
            if wins and lo<=wins[-1][1]+2:
                wins[-1]=(wins[-1][0],max(wins[-1][1],hi))
            else:
                wins.append((lo,hi))
        print("\n=== %s | %s ===" % (title,rel(p)))
        print("MATCH_LINES=%d CONTEXT_WINDOWS=%d" % (len(hits),len(wins)))
        for lo,hi in wins[:cap]:
            print("\n[lines %d-%d]"%(lo+1,hi))
            for n in range(lo,hi):
                print("%5d %s"%(n+1,ls[n]))
        if len(wins)>cap: print("WINDOWS_TRUNCATED=%d"%(len(wins)-cap))

print("SOURCE_FILES_SCANNED=%d" % len(files))
for lab,p,t,raw in files:
    if p.name in {"Makefile","RTW88WCLController.cpp","RTW88WCLController.hpp",
                  "RTW88WCLSkywalkTxAdapter.cpp","RTW88WCLSkywalkTxAdapter.hpp",
                  "RTW88WCLSkywalkQueues.cpp","RTW88WCLSkywalkQueues.hpp",
                  "RTW88WCLPCIBackend.cpp","RTW88WCLPCIBackend.hpp",
                  "RTW88WCLInfraInterface.cpp","RTW88WCLInfraInterface.hpp",
                  "RTW88WCLWorkQueue.cpp","RTW88WCLRadioBridge.cpp",
                  "RTW88IEEE80211.cpp","RTW88IEEE80211.hpp",
                  "skbuff_tx_completion.h","skbuff.h"}:
        print("SOURCE path=%s bytes=%d sha256=%s"%(rel(p),len(raw),hashlib.sha256(raw).hexdigest()))

mk=src/"Makefile"
mktext=mk.read_text(errors="replace")
print("\n--- Native target Makefile membership / wiring ---")
ml=mktext.splitlines()
for i,line in enumerate(ml):
    if re.search(r"rtl88wifi-native|NATIVE_CORE_SRCS|NATIVE_CORE_OBJS|WCL24H32|RTW88WCLSkywalkTxAdapter|RTW88WCLController|RTW88WCLSkywalkQueues|RTW88WCLSkywalkRxAdapter",line,re.I):
        lo=max(0,i-2); hi=min(len(ml),i+5)
        print("\n[Makefile lines %d-%d]"%(lo+1,hi))
        for j in range(lo,hi): print("%5d %s"%(j+1,ml[j]))

controller=next((t for lab,p,t,raw in files if p.name=="RTW88WCLController.cpp"),"")
controller_h=next((t for lab,p,t,raw in files if p.name=="RTW88WCLController.hpp"),"")
adapter=next((t for lab,p,t,raw in files if p.name=="RTW88WCLSkywalkTxAdapter.cpp"),"")
adapter_h=next((t for lab,p,t,raw in files if p.name=="RTW88WCLSkywalkTxAdapter.hpp"),"")
queue=next((t for lab,p,t,raw in files if p.name=="RTW88WCLSkywalkQueues.cpp"),"")
backend=next((t for lab,p,t,raw in files if p.name=="RTW88WCLPCIBackend.cpp"),"")
radio=next((t for lab,p,t,raw in files if p.name=="RTW88IEEE80211.cpp"),"")

print("\n--- Controller: TX adapter ownership and complete lifecycle ---")
context("Controller ownership/start/stop/free", "RTW88WCLController.cpp", [
    r"RTW88WCLSkywalkTxAdapter",r"submitPacket",r"drainCompletions",
    r"releaseNativeResources",r"quiescePacketPath",r"createQueues",
    r"refusing publication",r"goto fail",r"bindRadioBackend",
    r"unbindRadioBackend",r"_radioStarted",r"_tx"
], before=12,after=28,cap=55)
context("Controller class fields and methods","RTW88WCLController.hpp",[
    r"RTW88WCLSkywalkTxAdapter",r"submitPacket",r"drainCompletions",
    r"_radio",r"_skywalkQueues",r"_tx",r"releaseNativeResources"
],before=8,after=24,cap=25)

print("\n--- TX adapter: submission, callback, drain, retain and free behavior ---")
context("TX adapter lifecycle","RTW88WCLSkywalkTxAdapter.cpp",[
    r"::init",r"::bind",r"::unbind",r"::submitPacket",
    r"::backendCompletion",r"::drainCompletions",
    r"hasOutstanding",r"outstandingCompletionCount",r"::free",
    r"retain\(",r"release\(",r"TicketPool::complete",
    r"claimCompleted",r"CompletionSink"
],before=8,after=28,cap=35)
context("TX adapter public API","RTW88WCLSkywalkTxAdapter.hpp",[
    r"submitPacket",r"drainCompletions",r"CompletionSink",
    r"TicketPool",r"retain",r"release"
],before=5,after=18,cap=15)

print("\n--- Skywalk queues and interface: TX queue creation, scheduling and handoff ---")
for name in ["RTW88WCLSkywalkQueues.cpp","RTW88WCLSkywalkQueues.hpp",
             "RTW88WCLInfraInterface.cpp","RTW88WCLInfraInterface.hpp"]:
    context("Skywalk queue/interface "+name,name,[
        r"createQueues",r"destroyQueues",r"TX",r"tx",r"output",
        r"completion",r"enqueue",r"dequeue",r"register",r"schedule",
        r"start",r"stop",r"queue"
    ],before=7,after=20,cap=22)

print("\n--- PCI backend and workloop: available callback/wakeup hooks ---")
for name in ["RTW88WCLPCIBackend.cpp","RTW88WCLPCIBackend.hpp",
             "RTW88WCLWorkQueue.cpp","RTW88WCLRadioBridge.cpp"]:
    context("Event source/scheduler "+name,name,[
        r"handleInterrupt",r"rtw88_trigger_interrupt",r"IOInterruptEventSource",
        r"IOCommandGate",r"IOWorkLoop",r"runAction",r"addEventSource",
        r"enable\(",r"disable\(",r"schedule",r"signal",r"wakeup",
        r"queue_work",r"thread_call",r"callback",r"Completion"
    ],before=8,after=22,cap=28)

print("\n--- RTW88 output completion and token dispatch path ---")
context("RTW88IEEE80211 output/completion","RTW88IEEE80211.cpp",[
    r"outputPacketWithCompletion",r"compat_tx_status",r"txStatus\(",
    r"rtw88_set_hw_callbacks",r"completion",r"report_tx_status",
    r"rtw_tx\(",r"free\("
],before=8,after=24,cap=34)
for name in ["skbuff_tx_completion.h","skbuff.h","rtw88_compat.c"]:
    context("Compatibility TX completion "+name,name,[
        r"completion",r"claim",r"dispatch",r"kfree_skb",
        r"tx_status",r"callback",r"rtw88_set_hw_callbacks"
    ],before=7,after=18,cap=25)

print("\n--- Global references: adapter class and methods ---")
adapter_type=emit_refs("RTW88WCLSkywalkTxAdapter type references",
                       r"RTW88WCLSkywalkTxAdapter",cap=220)
submit_refs=emit_refs("submitPacket references",r"\bsubmitPacket\s*\(",cap=100)
drain_refs=emit_refs("drainCompletions references",r"\bdrainCompletions\s*\(",cap=100)
callback_refs=emit_refs("backendCompletion references",r"\bbackendCompletion\s*\(",cap=100)
sink_refs=emit_refs("CompletionSink references",r"\bCompletionSink\b",cap=100)

print("\n--- Completion callback scheduler token scan ---")
scheduler_rx=re.compile(r"(?:runAction|thread_call_enter|queue_work|schedule_work|signalWorkAvailable|wakeup|dispatch_async|enqueueWork|scheduleCompletionDrain)\s*\(",re.I)
callback_body=adapter[adapter.find("void RTW88WCLSkywalkTxAdapter::backendCompletion"):adapter.find("uint32_t RTW88WCLSkywalkTxAdapter::drainCompletions")]
callback_code=re.sub(r"/\*.*?\*/|//[^\n]*","",callback_body,flags=re.S|re.M)
for label,txt in [("BACKEND_COMPLETION_BODY_CODE_ONLY",callback_code),
                  ("WCL_TREE_CODE_ONLY", "\n".join(t for lab,p,t,raw in files if lab=="KEXT"))]:
    code_only=re.sub(r"/\*.*?\*/|//[^\n]*","",txt,flags=re.S|re.M)
    matches=[(i+1,s.strip()) for i,s in enumerate(code_only.splitlines()) if scheduler_rx.search(s)]
    print("%s_MATCHES=%d"%(label,len(matches)))
    for n,s in matches[:100]: print("%s:%d | %s"%(label,n,s[:320]))

print("\n--- Explicit integration flags (lexical evidence; review contexts above) ---")
flags={
 "MAKEFILE_LINKS_TX_ADAPTER": "RTW88WCLSkywalkTxAdapter.cpp" in mktext,
 "MAKEFILE_LINKS_WCL_CONTROLLER": "RTW88WCLController.cpp" in mktext,
 "CONTROLLER_NAMES_TX_ADAPTER": "RTW88WCLSkywalkTxAdapter" in controller or "RTW88WCLSkywalkTxAdapter" in controller_h,
 "CONTROLLER_CALLS_SUBMIT": bool(re.search(r"(?:->|\.)submitPacket\s*\(",controller)),
 "CONTROLLER_CALLS_DRAIN": bool(re.search(r"(?:->|\.)drainCompletions\s*\(",controller)),
 "TX_ADAPTER_CALLS_DRAIN_OUTSIDE_ITS_DEFINITION": any(
     "drainCompletions" in line and "::drainCompletions" not in line
     for lab,p,t,raw in files if p.name not in {"RTW88WCLSkywalkTxAdapter.hpp","RTW88WCLSkywalkTxAdapter.cpp"}
     for line in t.splitlines()),
 "CONTROLLER_HAS_TX_ADAPTER_FIELD": bool(re.search(r"RTW88WCLSkywalkTxAdapter\s*\*",controller_h)),
 "BACKEND_COMPLETION_BODY_HAS_SCHEDULER_CALL": bool(scheduler_rx.search(adapter[adapter.find("void RTW88WCLSkywalkTxAdapter::backendCompletion"):adapter.find("uint32_t RTW88WCLSkywalkTxAdapter::drainCompletions")])),
 "ADAPTER_RETAINS_ON_SUBMIT": bool(re.search(r"retain\s*\(\)",adapter[adapter.find("IOReturn RTW88WCLSkywalkTxAdapter::submitPacket"):adapter.find("void RTW88WCLSkywalkTxAdapter::backendCompletion")])),
 "ADAPTER_RELEASES_PER_TICKET_ONLY_IN_DRAIN": bool(re.search(r"release\s*\(\)",adapter[adapter.find("uint32_t RTW88WCLSkywalkTxAdapter::drainCompletions"):adapter.find("bool RTW88WCLSkywalkTxAdapter::hasOutstandingCompletions")])),
 "UNBIND_RETURNS_BUSY_WITH_TICKETS": bool(re.search(r"if\s*\(_tickets\.hasOutstanding\s*\(\)\)\s*return\s+kIOReturnBusy",adapter)),
 "FREE_CALLS_UNBIND_WITHOUT_CHECKING_RESULT": bool(re.search(r"\n\s*unbind\s*\(\)\s*;\s*\n\s*super::free",adapter)),
 "CONTROLLER_HAS_FAIL_CLOSED_PUBLICATION_FENCE": "refusing publication until Skywalk datapath is ready" in controller,
 "CONTROLLER_RELEASE_PATH_HAS_NO_TX_ADAPTER_DRAIN": not bool(re.search(r"drainCompletions|RTW88WCLSkywalkTxAdapter",controller))
}
for k,v in flags.items(): print(k+"="+("YES" if v else "NO"))

print("\n--- Audit conclusions and next integration blockers ---")
for i,q in enumerate([
 "Is the TX adapter merely linked, or is an instance owned and bound by the WCL controller?",
 "Which registered Skywalk TX queue callback invokes submitPacket, and what owns that callback lifecycle?",
 "Which deferred workloop/command-gate event is signalled when backendCompletion changes a ticket to completed?",
 "Who calls drainCompletions, and what CompletionSink actually hands the result back to the Skywalk TX completion queue?",
 "How does controller stop quiesce TX submissions, wait for backend callbacks, drain every completed ticket, and only then unbind/release the adapter?",
 "What happens when a hardware completion never arrives: is there a timeout, cancellation or reset path that claims/releases the ticket?",
 "Does the WCL path intentionally stay behind its publication fence until TX/RX queue registration and packet completion are implemented?"
],1): print("OPEN_QUESTION_%02d=%s"%(i,q))

print("\n--- Safety boundary ---")
print("SOURCE_TREE_MODIFIED=NO")
print("BUILD=NOT_RUN")
print("INSTALL=NOT_RUN")
print("LOAD=NOT_RUN")
print("OPENCORE_MODIFIED=NO")
print("HARDWARE_TEST=NOT_RUN")
PY

{
  echo
  echo "--- End Stage 35P ---"
  echo "ACTUAL_BUILD=NOT_RUN"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "HARDWARE_TEST=NOT_RUN"
} >> "$REPORT"

mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"

upload_file() {
  local file="$1" path="$2" msg="$3" payload="$4" response="$5" old put got
  old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
  python3 - "$file" "$old" "$msg" "$payload" <<'PY2'
import base64, json, pathlib, sys
f, sha, msg, dest = sys.argv[1:]
v={"message":msg,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha: v["sha"]=sha
pathlib.Path(dest).write_text(json.dumps(v))
PY2
  if ! gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" >"$response" 2>"$UPLOAD_ERROR"; then
    echo "UPLOAD_FAILED_PATH=$path" >>"$UPLOAD_ERROR"
    echo "AUTH_ACCOUNT=$(gh api user --jq .login 2>&1 || true)" >>"$UPLOAD_ERROR"
    echo "REPO_PERMISSION=$(gh api "repos/$REPO" --jq '.full_name + " push=" + (.permissions.push|tostring)' 2>&1 || true)" >>"$UPLOAD_ERROR"
    return 1
  fi
  put="$(python3 - "$response" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1]))
s=(v.get("content") or {}).get("sha")
if not s: raise SystemExit("Missing returned blob SHA")
print(s)
PY2
)"
  got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
  [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >>"$UPLOAD_ERROR"; return 1; }
  UPLOAD_SHA="$got"
}

MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 35P\nRUN: %s\nPURPOSE: native WCL TX adapter ownership, completion wakeup/sink integration, and teardown safety audit\n' "$RUN" >"$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35p/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35P native TX drain integration audit $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >>"$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35p/$RUN/manifest.txt" "Add Stage35P manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35P_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35P_RUN=$RUN"
echo "STAGE35P_REPORT_PARTS=$COUNT"
echo "STAGE35P_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35p/$RUN"
