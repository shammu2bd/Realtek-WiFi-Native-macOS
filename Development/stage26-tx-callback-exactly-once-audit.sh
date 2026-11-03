#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE26_ERROR: exit=$rc line=$LINENO command=$BASH_COMMAND" >&2; exit "$rc"' ERR
REPO='shammu2bd/Realtek-WiFi-Native-macOS'
NAME='RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source'
PROJECT=''
if [[ -n "${PROJECT_DIR:-}" ]] && [[ -f "${PROJECT_DIR:-}/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$(cd "$PROJECT_DIR" && pwd -P)"
elif [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$HOME/Downloads/$NAME"
fi
[[ -n "$PROJECT" ]] || { echo 'Cannot locate Stage26 project.'; exit 2; }
DRIVER="$PROJECT/driver/RTL88WiFi"
command -v gh >/dev/null 2>&1 || { echo 'GitHub CLI required.'; exit 2; }
gh auth status >/dev/null 2>&1 || { echo 'GitHub CLI authentication required.'; exit 2; }
STAGE="$PROJECT/build/stage26-tx-callback-exactly-once-audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
REPORT="$STAGE/stage26-tx-callback-exactly-once-audit.txt"
python3 - "$PROJECT" "$DRIVER" "$REPORT" <<'PY'
from pathlib import Path
import hashlib,re,sys
project,driver,out=map(Path,sys.argv[1:])
exts={".c",".cc",".cpp",".cxx",".h",".hh",".hpp",".hxx"}
sdk=("MacKernelSDK/Headers/","MacKernelSDK/PrivateHeaders/")
files=sorted(p for p in driver.rglob("*") if p.is_file() and p.suffix.lower() in exts
             and not any(x in p.relative_to(driver).as_posix() for x in sdk))
targets=[
"outputPacketWithCompletion","txDataFrame","txStatus","compat_tx_status",
"rtw88_skb_tx_completion_report","rtw88_skb_tx_completion_dispatch",
"rtw88_skb_tx_completion_init","rtw88_skb_tx_completion_clear",
"kfree_skb","ieee80211_tx_status_irqsafe","ieee80211_free_txskb",
"submitPacket","backendCompletion","finishTicket","claimCompleted",
"reserveTicket","markSubmitted","markCompleted","releaseTicket",
"drainCompleted","completeTx","stop","reset","flush_workqueue",
"cancel_work_sync","synchronize_irq","freeDMAList","releaseDMAEntries",
"allocDMA","freeDMA","mapDMA","unmapDMA","prepareDMA","completeDMA"
]
def extract_functions(src, names):
    # Locate symbol occurrences followed by a parameter list and an opening brace;
    # then balance braces while ignoring comments and quoted literals.
    found=[]
    for name in names:
        for m in re.finditer(r'(?<![A-Za-z0-9_])'+re.escape(name)+r'\s*\(',src):
            pos=m.start()
            # Ignore callsites: only accept a nearby declaration-like prefix and body brace
            close=src.find(')',m.end())
            if close<0: continue
            brace=src.find('{',close,min(len(src),close+700))
            semi=src.find(';',close,min(len(src),close+700))
            if brace<0 or (semi>=0 and semi<brace): continue
            prefix=src[max(0,pos-500):pos]
            if not re.search(r'(~?\w+\s+|::|\*\s*)$',prefix): continue
            depth=0; i=brace; state='code'; quote=''
            while i<len(src):
                c=src[i]; n=src[i+1] if i+1<len(src) else ''
                if state=='line':
                    if c=='\n': state='code'
                elif state=='block':
                    if c=='*' and n=='/': state='code'; i+=1
                elif state=='string':
                    if c=='\\': i+=1
                    elif c==quote: state='code'
                else:
                    if c=='/' and n=='/': state='line'; i+=1
                    elif c=='/' and n=='*': state='block'; i+=1
                    elif c in ('"',"'"): state='string'; quote=c
                    elif c=='{': depth+=1
                    elif c=='}':
                        depth-=1
                        if depth==0:
                            found.append((name,pos,src[pos:i+1]))
                            break
                i+=1
    # Deduplicate same function start
    unique={}
    for x in found: unique[(x[0],x[1])]=x
    return sorted(unique.values(),key=lambda x:x[1])
report=[
"RTL88WiFi Stage26 — exact TX completion and ticket ownership audit",
"PURPOSE: capture complete implementations and enumerate all terminal completion paths.",
"SCOPE: all non-SDK C/C++ implementation and project-header files under driver/RTL88WiFi.",
"SOURCE_CHANGES: NONE","BUILD: NOT RUN","INSTALL: NOT RUN","LOAD: NOT RUN",
"OPENCORE_CHANGE: NONE","KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED",
"QUEUE_REGISTRATION/ENABLE: NOT CALLED","RADIO_START: NOT RUN","",
"=== INVENTORY AND HASHES ===",
"PROJECT_SOURCE_FILES_SCANNED: "+str(len(files))]
for p in files:
    report.append("FILE: {} SHA256={}".format(p.relative_to(project),hashlib.sha256(p.read_bytes()).hexdigest()))
for p in files:
    try: src=p.read_text(encoding="utf-8",errors="replace")
    except Exception: continue
    funcs=extract_functions(src,targets)
    if funcs:
        report += ["","=== COMPLETE_FUNCTIONS: "+str(p.relative_to(project))+" ==="]
        for name,pos,body in funcs:
            line=src.count("\n",0,pos)+1
            report += ["--- SYMBOL {} LINE {} BODY_BYTES {} ---".format(name,line,len(body)),body,"--- END SYMBOL ---"]
# Exact occurrence index with line numbers; captures calls and producers, not just definitions.
terms=re.compile(r'outputPacketWithCompletion|txDataFrame|txStatus|compat_tx_status|'
                 r'rtw88_skb_tx_completion_(?:report|dispatch|init|clear)|'
                 r'kfree_skb|ieee80211_(?:tx_status_irqsafe|free_txskb)|'
                 r'(?:reserve|markSubmitted|markCompleted|claimCompleted|finish|release).*Ticket|'
                 r'(?:tx|dma).*(?:reset|stop|complete|free|map|unmap)|'
                 r'(?:complete|free|map|unmap).*(?:tx|dma)|'
                 r'flush_workqueue|cancel_work_sync|synchronize_irq|freeDMAList|releaseDMAEntries',re.I)
report += ["","=== ALL_RELEVANT_OCCURRENCES ==="]
for p in files:
    lines=p.read_text(encoding="utf-8",errors="replace").splitlines()
    hits=[i for i,line in enumerate(lines) if terms.search(line) and not line.lstrip().startswith(("//","*","/*"))]
    if not hits: continue
    report.append("FILE: {} MATCHES: {}".format(p.relative_to(project),len(hits)))
    for i in hits:
        report.append("  {:05d}: {}".format(i+1,lines[i]))
report += ["","=== REQUIRED SEMANTIC DECISIONS ===",
"1. For every outputPacketWithCompletion return branch, state whether callback fires synchronously, asynchronously, or not at all; prove who owns mbuf/skb.",
"2. For txDataFrame, enumerate every allocation, conversion, early return, skb handoff and ownership transfer. Determine whether false return can coexist with a prior callback.",
"3. For txStatus and every skb free/purge/reset path, prove one shared atomic token claim and exactly one callback/release; inspect races and callback reentrancy.",
"4. For every ticket state transition, identify legal predecessor/successor states, producer/consumer concurrency, memory ordering, duplicate callback behavior, and ticket reuse safety.",
"5. Prove adapter and packet retains are released exactly once on success, synchronous rejection, asynchronous completion, reset, stop and failed initialization.",
"6. Enumerate every RTW88 caller of ieee80211_tx_status_irqsafe, ieee80211_tx_status and ieee80211_free_txskb; establish each skb's single terminal owner.",
"7. Trace stop/reset work cancellation, interrupt synchronization and DMA engine stop before any callback token, skb, ticket, descriptor or adapter is freed.",
"8. Pair each TX descriptor and payload DMA allocation/map/prepare with complete/unmap/free on all terminal paths; distinguish coherent rings from streaming mappings.",
"9. Stage26 is source evidence only. A source-text scan cannot certify runtime race freedom or hardware behavior.",
"","STAGE26_STATUS: REVIEW_REQUIRED",
"ACTIVATION_GATE: BLOCKED — do not enable Skywalk TX or RX, register queues, publish interface, start radio, build/install/load, or change OpenCore."]
out.write_text("\n".join(report)+"\n",encoding="utf-8")
print("STAGE26_REPORT_PATH: "+str(out))
print("PROJECT_SOURCE_FILES_SCANNED: "+str(len(files)))
print("REPORT_BYTES: "+str(out.stat().st_size))
PY
[[ -s "$REPORT" ]] || { echo 'Stage26 report missing.'; exit 2; }
BYTES=$(wc -c < "$REPORT" | tr -d ' ')
(( BYTES <= 900000 )) || { echo "Stage26 report exceeds 900KB upload cap: $BYTES"; exit 2; }
upload_file() {
 local path="$1" api="$2" message="$3" payload="$4" response="$5"
 local oldsha putsha readsha
 echo "GITHUB_UPLOAD_BEGIN: $api"
 oldsha="$(gh api "$api" --jq '.sha' 2>/dev/null || true)"
 python3 - "$path" "$oldsha" "$message" "$payload" <<'PY2'
import base64,json,pathlib,sys
path,sha,message,payload=sys.argv[1:]
d={"message":message,"content":base64.b64encode(pathlib.Path(path).read_bytes()).decode()}
if sha: d["sha"]=sha
pathlib.Path(payload).write_text(json.dumps(d))
print("UPLOAD_PAYLOAD_BYTES:",pathlib.Path(payload).stat().st_size)
PY2
 if ! gh api --method PUT "$api" --input "$payload" > "$response"; then
  echo "GITHUB_UPLOAD_FAILED: PUT $api" >&2; cat "$response" >&2 2>/dev/null || true; return 1
 fi
 putsha="$(python3 - "$response" <<'PY2'
import json,sys
d=json.load(open(sys.argv[1])); print(d.get("content",{}).get("sha",""))
PY2
)"
 [[ -n "$putsha" ]] || { echo "GITHUB_UPLOAD_FAILED: no content SHA" >&2; cat "$response" >&2; return 1; }
 readsha="$(gh api "$api" --jq '.sha')"
 [[ "$putsha" == "$readsha" ]] || { echo "GITHUB_UPLOAD_FAILED: SHA mismatch put=$putsha read=$readsha" >&2; return 1; }
 echo "GITHUB_UPLOAD_VERIFIED: $api $readsha"
 UPLOAD_RESULT_SHA="$readsha"
}
upload_file "$REPORT" "repos/$REPO/contents/Development/stage26-tx-callback-exactly-once-audit.txt" "Add Stage26 exact TX completion ownership audit" "$STAGE/report-payload.json" "$STAGE/report-response.json"
SHA="$UPLOAD_RESULT_SHA"
echo "STAGE26_REPORT_UPLOAD: SUCCESS"
echo "STAGE26_REPORT_BLOB_SHA: $SHA"
LOG="$PROJECT/output.log"
API="repos/$REPO/contents/Development/output.log"
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/Development/output.log" -o "$STAGE/remote-output.log"
python3 - "$STAGE/remote-output.log" "$LOG" "$SHA" "$BYTES" <<'PY2'
import pathlib,sys
old=pathlib.Path(sys.argv[1]).read_text(encoding="utf-8",errors="replace")
marker="========== STAGE26 TX CALLBACK EXACTLY-ONCE AUDIT =========="
if marker in old: old=old[:old.index(marker)].rstrip()+"\n"
entry=("\n"+marker+"\n"
"STAGE26_REPORT: Development/stage26-tx-callback-exactly-once-audit.txt\n"
"STAGE26_REPORT_BLOB_SHA: "+sys.argv[3]+"\n"
"STAGE26_REPORT_BYTES: "+sys.argv[4]+"\n"
"STAGE26_STATUS: REVIEW_REQUIRED\nACTIVATION_GATE: BLOCKED\n"
"SOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE\n"
"KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED\n")
pathlib.Path(sys.argv[2]).write_text(old+entry,encoding="utf-8")
PY2
upload_file "$LOG" "$API" "Record Stage26 TX callback ownership audit" "$STAGE/log-payload.json" "$STAGE/log-response.json"
echo "CANONICAL_OUTPUT_LOG_UPLOAD: SUCCESS"
echo "CANONICAL_OUTPUT_LOG_BLOB_SHA: $UPLOAD_RESULT_SHA"
echo "STAGE26_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
