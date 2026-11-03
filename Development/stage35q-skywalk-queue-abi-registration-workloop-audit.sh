#!/bin/bash
# Stage 35Q — Sequoia Skywalk queue ABI, registration, and deferred-workloop audit.
# VERSION_MARKER: STAGE35Q_V1_20261102
# READ ONLY: no source edits, build, install, Kext load, or OpenCore changes.
set -Eeuo pipefail
echo "STAGE35Q_SCRIPT_VERSION=1"

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW="$SRC/../rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35Q-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35Q_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 shasum split find grep xcrun; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" ]] || { echo "ERROR: project Makefile missing: $SRC/Makefile"; exit 3; }
[[ -f "$SRC/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp" ]] || { echo "ERROR: WCL Skywalk queues source missing"; exit 4; }
[[ -f "$SRC/src/kext/RTW88WCLWorkQueue.cpp" ]] || { echo "ERROR: WCL workqueue source missing at $SRC/src/kext/RTW88WCLWorkQueue.cpp"; exit 5; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 6; }

DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
if [[ -z "$SDKROOT" && -d "/Applications/Xcode_16.4.app/Contents/Developer" ]]; then
  DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
  SDKROOT="$(DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi
DEV_REPORT="$DEVELOPER_DIR"
SDK_REPORT="$SDKROOT"
[[ -n "$DEV_REPORT" ]] || DEV_REPORT="NOT_FOUND"
[[ -n "$SDK_REPORT" ]] || SDK_REPORT="NOT_FOUND"
if [[ -n "$DEVELOPER_DIR" ]]; then export DEVELOPER_DIR; fi

{
  echo "========== STAGE 35Q: SKYWALK QUEUE ABI / REGISTRATION / WORKLOOP AUDIT =========="
  echo "script_version=STAGE35Q_V1_20261102"
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "source_root=$SOURCE_ROOT"
  echo "developer_dir=$DEV_REPORT"
  echo "sdkroot=$SDK_REPORT"
  echo "mode=read-only source + installed SDK header inspection"
  echo
} > "$REPORT"

python3 - "$SRC" "$RTW" "$SDKROOT" >> "$REPORT" <<'PY'
import hashlib, os, pathlib, re, sys

src, rtw = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sdk_arg = sys.argv[3]
sdk = pathlib.Path(sdk_arg) if sdk_arg else None

source_roots = [("KEXT", src / "src/kext"), ("COMPAT", src / "src/compat"),
                ("RTW88", rtw)]
source_exts = {".c", ".cc", ".cpp", ".h", ".hpp", ".mm", ".m", ".mk"}
source_files = []
for label, root in source_roots:
    if not root.is_dir():
        print("MISSING_SOURCE_ROOT=%s" % root)
        continue
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in {".git","build","DerivedData","Products"} and not d.endswith(".dSYM")]
        for name in sorted(names):
            p = pathlib.Path(base) / name
            if p.suffix.lower() not in source_exts:
                continue
            try:
                raw = p.read_bytes()
                txt = raw.decode("utf-8", "replace")
            except OSError as e:
                print("SOURCE_READ_ERROR=%s:%s" % (p,e))
                continue
            source_files.append((label,p,txt,raw))

def rel(p):
    try: return str(p.relative_to(src))
    except ValueError:
        try: return "../rtw88-stable/" + str(p.relative_to(rtw))
        except ValueError: return str(p)

def print_context(title, label, p, txt, patterns, before=8, after=20, cap=30):
    lines=txt.splitlines()
    hits=[i for i,line in enumerate(lines) if any(re.search(rx,line,re.I) for rx in patterns)]
    windows=[]
    for i in hits:
        lo=max(0,i-before); hi=min(len(lines),i+after+1)
        if windows and lo<=windows[-1][1]+2:
            windows[-1]=(windows[-1][0],max(windows[-1][1],hi))
        else:
            windows.append((lo,hi))
    print("\n=== %s | %s ==="%(title,rel(p)))
    print("MATCH_LINES=%d CONTEXT_WINDOWS=%d"%(len(hits),len(windows)))
    for lo,hi in windows[:cap]:
        print("\n[lines %d-%d]"%(lo+1,hi))
        for n in range(lo,hi): print("%5d %s"%(n+1,lines[n]))
    if len(windows)>cap: print("WINDOWS_TRUNCATED=%d"%(len(windows)-cap))

print("--- Project source inventory / fingerprints ---")
print("SOURCE_FILES_SCANNED=%d"%len(source_files))
for label,p,txt,raw in source_files:
    if p.name in {
        "RTW88WCLSkywalkQueues.cpp","RTW88WCLSkywalkQueues.hpp",
        "RTW88WCLSkywalkTxAdapter.cpp","RTW88WCLSkywalkTxAdapter.hpp",
        "RTW88WCLSkywalkRxAdapter.cpp","RTW88WCLSkywalkRxAdapter.hpp",
        "RTW88WCLController.cpp","RTW88WCLController.hpp",
        "RTW88WCLInfraInterface.cpp","RTW88WCLInfraInterface.hpp",
        "RTW88WCLWorkQueue.cpp","RTW88WCLWorkQueue.hpp",
        "RTW88WCLPCIBackend.cpp","RTW88WCLPCIBackend.hpp",
        "RTW88WCLRegistrationInfo.hpp","RTW88WCL24H32InterfaceABI.hpp",
        "RTW88IEEE80211.cpp","RTW88IEEE80211.hpp","Makefile"
    }:
        print("SOURCE path=%s bytes=%d sha256=%s"%(rel(p),len(raw),hashlib.sha256(raw).hexdigest()))

print("\n--- Installed SDK presence and version ---")
print("SDKROOT=%s"%(sdk if sdk else "NOT_FOUND"))
if sdk and sdk.exists():
    print("SDKROOT_EXISTS=YES")
    for p in [sdk/"System/Library/Frameworks/Kernel.framework/Headers",
              sdk/"System/Library/Frameworks/IOKit.framework/Headers",
              sdk/"System/Library/Frameworks/Kernel.framework/Versions/A/Headers"]:
        print("SDK_HEADER_ROOT path=%s exists=%s"%(p,p.is_dir()))
else:
    print("SDKROOT_EXISTS=NO")
print("SDK_HEADER_FILE_DISCOVERY begins")

header_names={
 "IOSkywalkTxSubmissionQueue.h","IOSkywalkTxCompletionQueue.h",
 "IOSkywalkRxSubmissionQueue.h","IOSkywalkRxCompletionQueue.h",
 "IOSkywalkPacketBufferPool.h","IOSkywalkPacket.h",
 "IOSkywalkEthernetInterface.h","IOSkywalkNetworkInterface.h",
 "IOSkywalkRegistrationInfo.h","IOEventSource.h","IOWorkLoop.h",
 "IOCommandGate.h","IOInterruptEventSource.h"
}
header_files=[]
search_roots=[]
if sdk and sdk.exists():
    search_roots.extend([sdk/"System/Library/Frameworks/Kernel.framework",
                         sdk/"System/Library/Frameworks/IOKit.framework",
                         sdk/"System/Library/Frameworks/Kernel.framework/Versions/A"])
developer=pathlib.Path(os.environ.get("DEVELOPER_DIR",""))
if developer.exists():
    search_roots.extend([developer/"Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Kernel.framework",
                         developer/"Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/IOKit.framework"])
seen=set()
for root in search_roots:
    if not root.exists(): continue
    for base,dirs,names in os.walk(root):
        dirs[:]=[d for d in dirs if d not in {".git","Modules","_CodeSignature"}]
        for name in names:
            if name in header_names:
                p=pathlib.Path(base)/name
                if str(p) not in seen:
                    seen.add(str(p)); header_files.append(p)
print("SDK_HEADERS_FOUND=%d"%len(header_files))
for p in header_files:
    try:
        raw=p.read_bytes()
        print("SDK_HEADER path=%s bytes=%d sha256=%s"%(p,len(raw),hashlib.sha256(raw).hexdigest()))
    except OSError as e:
        print("SDK_HEADER_READ_ERROR=%s:%s"%(p,e))

sdk_patterns=[
 r"typedef.*(?:Action|Dispatch|Handler)",r"using.*(?:Action|Dispatch|Handler)",
 r"withPool",r"registerEthernetInterface",r"register.*Interface",
 r"unregister",r"set.*Queue",r"set.*Ring",r"set.*Pool",
 r"completePackets",r"submitPackets",r"enqueue",r"dequeue",
 r"process",r"packetCount",r"refCon",r"refcon",
 r"dispatch",r"callback",r"completion",r"submission",
 r"class IOSkywalk",r"virtual .*checkForWork",r"signalWorkAvailable",
 r"checkForWork",r"addEventSource",r"removeEventSource",r"runAction"
]
for p in header_files:
    try: txt=p.read_text(errors="replace")
    except OSError: continue
    print_context("Installed SDK declarations","SDK",p,txt,sdk_patterns,8,20,35)

print("\n--- Source include paths and Skywalk ABI assumptions ---")
for label,p,txt,raw in source_files:
    if label=="KEXT" and (re.search(r"Skywalk|skywalk|IOSkywalk",str(p),re.I) or
                          re.search(r"registerEthernetInterface|IOSkywalk.*Queue|IOSkywalk.*Pool",txt,re.I)):
        print_context("Skywalk source ABI use",label,p,txt,[
            r"#include.*[Ss]kywalk",r"IOSkywalk",r"registerEthernetInterface",
            r"RegistrationInfo",r"withPool",r"set.*Queue",r"set.*Pool",
            r"txSubmissionAction",r"txCompletionAction",
            r"rxSubmissionAction",r"rxCompletionAction",
            r"return static_cast<IOReturn>\(0\)"
        ],7,19,28)

print("\n--- Queue construction, callback typedefs, and current fail-closed actions ---")
for name in ["RTW88WCLSkywalkQueues.cpp","RTW88WCLSkywalkQueues.hpp"]:
    for label,p,txt,raw in source_files:
        if p.name==name:
            print_context("Queue create/register/destroy/callback "+name,label,p,txt,[
                r"withPool",r"txSubmissionAction",r"txCompletionAction",
                r"rxSubmissionAction",r"rxCompletionAction",
                r"registerEthernetInterface",r"RegistrationInfo",
                r"destroyQueues",r"queuesAllocated",r"return static_cast<IOReturn>",
                r"setDispatch",r"set.*Action"
            ],9,24,45)

print("\n--- RegistrationInfo builder and controller/interface publication path ---")
for label,p,txt,raw in source_files:
    if p.name in {"RTW88WCLRegistrationInfo.hpp","RTW88WCL24H32InterfaceABI.hpp",
                  "RTW88WCLController.cpp","RTW88WCLController.hpp",
                  "RTW88WCLInfraInterface.cpp","RTW88WCLInfraInterface.hpp"}:
        print_context("Registration/publication "+p.name,label,p,txt,[
            r"RegistrationInfo",r"registerEthernetInterface",r"unregisterEthernetInterface",
            r"register",r"unregister",r"IO80211SkywalkInterface",
            r"createQueues",r"txSubmission",r"txCompletion",
            r"rxSubmission",r"rxCompletion",r"start\(",r"stop\(",
            r"publication",r"refusing",r"fail closed"
        ],9,22,38)

print("\n--- Existing workloop event-source API usage ---")
for label,p,txt,raw in source_files:
    if p.name in {"RTW88WCLWorkQueue.cpp","RTW88WCLWorkQueue.hpp",
                  "RTW88WCLPCIBackend.cpp","RTW88WCLPCIBackend.hpp",
                  "RTW88WCLSkywalkRxAdapter.cpp","RTW88WCLSkywalkRxAdapter.hpp",
                  "RTW88WCLSkywalkTxAdapter.cpp","RTW88WCLSkywalkTxAdapter.hpp"}:
        print_context("Workloop/wakeup "+p.name,label,p,txt,[
            r"IOEventSource",r"IOWorkLoop",r"IOCommandGate",
            r"signalWorkAvailable",r"checkForWork",r"runAction",
            r"addEventSource",r"removeEventSource",r"setEnabled",
            r"enable\(",r"disable\(",r"thread_call_enter",
            r"schedule",r"wakeup",r"handleInterrupt",
            r"backendCompletion",r"drainCompletions"
        ],8,22,40)

print("\n--- Exact source references for relevant Skywalk API symbols ---")
symbols=[
 "IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue",
 "IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue",
 "IOSkywalkPacketBufferPool","IOSkywalkPacket",
 "IOSkywalkEthernetInterface","registerEthernetInterface",
 "unregisterEthernetInterface","IOSkywalkRegistrationInfo",
 "txSubmissionAction","txCompletionAction","rxSubmissionAction","rxCompletionAction",
 "signalWorkAvailable","checkForWork","drainCompletions","submitPacket"
]
for sym in symbols:
    rx=re.compile(r"(?<![A-Za-z0-9_])"+re.escape(sym)+r"(?![A-Za-z0-9_])")
    hits=[]
    for label,p,txt,raw in source_files:
        for n,line in enumerate(txt.splitlines(),1):
            s=line.strip()
            if s.startswith(("//","*","/*")): continue
            if rx.search(line): hits.append((rel(p),n,s))
    print("\nSYMBOL=%s REFERENCES=%d"%(sym,len(hits)))
    for path,n,line in hits[:100]: print("%s:%d | %s"%(path,n,line[:320]))

print("\n--- Evidence flags (presence is not proof of runtime ABI validity) ---")
queues=next((txt for label,p,txt,raw in source_files if p.name=="RTW88WCLSkywalkQueues.cpp"),"")
controller=next((txt for label,p,txt,raw in source_files if p.name=="RTW88WCLController.cpp"),"")
controller_h=next((txt for label,p,txt,raw in source_files if p.name=="RTW88WCLController.hpp"),"")
workq=next((txt for label,p,txt,raw in source_files if p.name=="RTW88WCLWorkQueue.cpp"),"")
adapter=next((txt for label,p,txt,raw in source_files if p.name=="RTW88WCLSkywalkTxAdapter.cpp"),"")
reginfo=next((txt for label,p,txt,raw in source_files if p.name=="RTW88WCLRegistrationInfo.hpp"),"")
flags={
 "SDKROOT_DISCOVERED": bool(sdk and sdk.exists()),
 "SDK_TX_SUBMISSION_HEADER_FOUND": any(p.name=="IOSkywalkTxSubmissionQueue.h" for p in header_files),
 "SDK_TX_COMPLETION_HEADER_FOUND": any(p.name=="IOSkywalkTxCompletionQueue.h" for p in header_files),
 "SDK_PACKET_BUFFER_POOL_HEADER_FOUND": any(p.name=="IOSkywalkPacketBufferPool.h" for p in header_files),
 "TX_SUBMISSION_ACTION_CURRENTLY_FAILS_CLOSED": bool(re.search(r"txSubmissionAction[\s\S]{0,1800}return\s+static_cast<IOReturn>\(0\)",queues)),
 "TX_COMPLETION_ACTION_CURRENTLY_RETURNS_ZERO": bool(re.search(r"txCompletionAction[\s\S]{0,500}return\s+static_cast<IOReturn>\(0\)",queues)),
 "FOUR_QUEUE_OBJECTS_CREATED": all(s in queues for s in ["IOSkywalkTxSubmissionQueue::withPool","IOSkywalkTxCompletionQueue::withPool","IOSkywalkRxSubmissionQueue::withPool","IOSkywalkRxCompletionQueue::withPool"]),
 "QUEUE_CLASS_HAS_REGISTRATION_CALL": bool(re.search(r"registerEthernetInterface|setDispatch|setSubmissionQueue|setCompletionQueue",queues)),
 "CONTROLLER_CALLS_REGISTER_ETHERNET_INTERFACE": "registerEthernetInterface" in controller,
 "CONTROLLER_OWNS_TX_ADAPTER": "RTW88WCLSkywalkTxAdapter" in controller_h,
 "TX_ADAPTER_DRAIN_CALL_IN_CONTROLLER": bool(re.search(r"drainCompletions\s*\(",controller)),
 "WORKQUEUE_USES_SIGNAL_WORK_AVAILABLE": "signalWorkAvailable()" in workq,
 "TX_ADAPTER_CALLBACK_SIGNALS_WORK": bool(re.search(r"signalWorkAvailable|runAction|thread_call_enter|queue_work|schedule_work",adapter[adapter.find("void RTW88WCLSkywalkTxAdapter::backendCompletion"):adapter.find("uint32_t RTW88WCLSkywalkTxAdapter::drainCompletions")])),
 "WORKQUEUE_CHECKFORWORK_IMPLEMENTED": bool(re.search(r"bool\s+RTW88WCLWorkQueue::checkForWork",workq)),
 "REGISTRATION_INFO_HAS_QUEUE_WIRING": bool(re.search(r"txSubmission|txCompletion|rxSubmission|rxCompletion",reginfo))
}
for k,v in flags.items(): print(k+"="+("YES" if v else "NO"))

print("\n--- Build-readiness boundary ---")
print("THIS_STAGE_IS_READ_ONLY=YES")
print("COMPILE_OR_LINK_ATTEMPT=NOT_RUN")
print("SDK_ABI_CONFIRMED_ONLY_WHERE_EXACT_DECLARATIONS_WERE_FOUND=YES")
print("MISSING_OR_PRIVATE_SDK_HEADERS_MUST_NOT_BE_GUESSED=YES")
print("OPENCORE_MODIFIED=NO")
print("KEXT_INSTALL=NOT_RUN")
print("KEXT_LOAD=NOT_RUN")

print("\n--- Open questions for implementation planning ---")
questions=[
 "Does this installed Sequoia/Xcode SDK expose the exact queue callback typedefs and queue registration methods needed by the WCL class?",
 "If SDK headers are private or absent, which already-audited 24H32 ABI source establishes exact callback and registration contracts?",
 "What complete RegistrationInfo transaction connects all four queues and pools to the IO80211 Skywalk interface, including rollback/unregister?",
 "Should TX completion draining use a dedicated IOEventSource, an IOCommandGate action, or an existing serialized workqueue on the controller workloop?",
 "How can backendCompletion signal deferred work without calling Skywalk or releasing OSObjects in the hardware completion context?",
 "What callback return count and packet ownership semantics does the actual 24H32 queue dispatcher consume?",
 "Can a compile-only native target be attempted after ABI evidence is reviewed, without installing or loading the resulting Kext?"
]
for i,q in enumerate(questions,1): print("OPEN_QUESTION_%02d=%s"%(i,q))
PY

{
  echo
  echo "--- End Stage 35Q ---"
  echo "SOURCE_TREE_MODIFIED=NO"
  echo "ACTUAL_BUILD=NOT_RUN"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
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
printf 'STAGE: 35Q\nRUN: %s\nPURPOSE: Sequoia Skywalk queue ABI declarations, queue registration, and deferred workloop wakeup audit\nSDKROOT: %s\n' "$RUN" "$SDK_REPORT" >"$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35q/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35Q Skywalk ABI audit $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >>"$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35q/$RUN/manifest.txt" "Add Stage35Q manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35Q_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35Q_RUN=$RUN"
echo "STAGE35Q_REPORT_PARTS=$COUNT"
echo "STAGE35Q_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35q/$RUN"
