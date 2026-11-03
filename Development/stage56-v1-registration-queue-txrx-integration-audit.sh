#!/bin/bash
# Stage 56 — registration-info, queue callback and TX/RX adapter integration audit.
# VERSION_MARKER: STAGE56_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE56_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
PREV_RUN="run-20261102-133625-3722213f0755"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage56/$RUN"
TOOLS="$OUT/tools"
PREV="$OUT/stage55-evidence"
mkdir -p "$TOOLS" "$PREV"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE56_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }

for t in curl gh python3 shasum split grep awk sw_vers uname wc; do
  command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"
done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"
BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "expected macOS 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"

curl -fsSLo "$TOOLS/kcfile.py" "$UPSTREAM_RAW/kcfile.py"
curl -fsSLo "$TOOLS/disasm.py" "$UPSTREAM_RAW/disasm.py"
python3 - "$TOOLS" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={"kcfile.py":"5d31e8a73e5cb175851e7407529456f223683589",
          "disasm.py":"d7777456f4700bc9815e765aed2313093ac133e9"}
for name,want in expected.items():
 data=(root/name).read_bytes()
 got=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
 print("UPSTREAM_GIT_BLOB_%s=%s"%(name,"MATCH" if got==want else "MISMATCH"))
 print("UPSTREAM_GIT_BLOB_SHA_%s=%s"%(name,got))
 if got!=want: raise SystemExit("Pinned upstream parser mismatch: "+name)
PY

EXPECTED_CPP="2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b"
EXPECTED_ABI="63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb"
EXPECTED_HPP="9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4"

python3 - "$SRC" "$OUT" "$EXPECTED_CPP" "$EXPECTED_ABI" "$EXPECTED_HPP" <<'PY'
import hashlib,pathlib,sys
src,out=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
items={
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":sys.argv[3],
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":sys.argv[4],
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":sys.argv[5],
}
rows=[]
for rel,want in items.items():
 p=src/rel
 got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
 rows += ["FILE="+rel,"EXPECTED_SHA256="+want,"ACTUAL_SHA256="+got,
          "RESULT="+("MATCH" if got==want else "MISMATCH")]
ok=all(x=="RESULT=MATCH" for x in rows if x.startswith("RESULT="))
(out/"source-fingerprint.txt").write_text("\n".join(rows)+"\nSTAGE43_SOURCE_CONTINUITY="+("PASS" if ok else "REVIEW_REQUIRED")+"\n")
if not ok: raise SystemExit("Stage43 source baseline changed; stop")
PY

PREV_RAW="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage55/$PREV_RUN"
for name in manifest.txt report.txt audit-summary.txt source-fingerprint.txt source-factory-crosswalk.txt method-body-audit.txt reachability-matrix.txt source-reference-inventory.txt; do
  curl -fsSLo "$PREV/$name" "$PREV_RAW/$name"
done
python3 - "$PREV" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={
 "manifest.txt":"9457ae94af90709957b818e0f5af717830e76583",
 "report.txt":"b5463860cab55d236b93a61a2367c4d59841a5b6",
 "audit-summary.txt":"26927a605ac856375f1067830ceb0595df57179d",
 "source-fingerprint.txt":"67bfe72603cd4316bd9a9107de5c97e1c37f625c",
 "source-factory-crosswalk.txt":"0c9a2b92b9d9b1d78837f59a0362f44043d71c4a",
 "method-body-audit.txt":"be59d2604304c8223d046a516b2b78ec2ec9797a",
 "reachability-matrix.txt":"e452dd27d1b27d746797d2507e4558f78d0fe1a6",
 "source-reference-inventory.txt":"3a1b51637e672d867ae3a1192049fc4df66bafeb"
}
for name,want in expected.items():
 data=(root/name).read_bytes()
 got=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
 print("STAGE55_GIT_BLOB_%s=%s"%(name,"MATCH" if got==want else "MISMATCH"))
 print("STAGE55_GIT_BLOB_SHA_%s=%s"%(name,got))
 if got!=want: raise SystemExit("Stage55 predecessor evidence mismatch: "+name)
manifest=(root/"manifest.txt").read_text()
summary=(root/"audit-summary.txt").read_text()
if "RUN=run-20261102-133625-3722213f0755" not in manifest:
 raise SystemExit("Unexpected Stage55 predecessor run id")
if "STAGE54_REQUIRED_METHODS_PASS=17/17" not in summary:
 raise SystemExit("Stage55 did not validate Stage54 ABI evidence")
PY

python3 - "$SRC" "$OUT" "$PREV" <<'PY'
import pathlib,re,sys
src,out,prev=map(pathlib.Path,sys.argv[1:])
# Walk all source/header text files while excluding hidden/generated build paths.
files=sorted(p for p in src.rglob("*") if p.is_file() and
             p.suffix.lower() in (".cpp",".cc",".cxx",".hpp",".h",".hh") and
             not any(part.startswith(".") or part in ("build","out","DerivedData") for part in p.relative_to(src).parts))
texts={str(p.relative_to(src)):p.read_text(errors="replace") for p in files}

classes=[
 "RTW88WCLInfraInterface","RTW88WCLController","RTW88WCLSkywalkQueues",
 "RTW88WCLSkywalkTxAdapter","RTW88WCLSkywalkRxAdapter"
]
# Brace-aware extraction of qualified C++ member definitions.
def extract_body(text, brace):
 depth=0; state="code"; quote=""; i=brace
 while i<len(text):
  c=text[i]; n=text[i+1] if i+1<len(text) else ""
  if state=="line":
   if c=="\n": state="code"
  elif state=="block":
   if c=="*" and n=="/": state="code"; i+=1
  elif state=="string":
   if c=="\\": i+=1
   elif c==quote: state="code"
  else:
   if c=="/" and n=="/": state="line"; i+=1
   elif c=="/" and n=="*": state="block"; i+=1
   elif c in ("'","\""): state="string"; quote=c
   elif c=="{": depth+=1
   elif c=="}":
    depth-=1
    if depth==0: return text[brace:i+1]
  i+=1
 return text[brace:]

records=[]
for path,text in texts.items():
 for cls in classes:
  rx=re.compile(r"\b"+re.escape(cls)+r"\s*::\s*([A-Za-z_~]\w*)\s*\(")
  for m in rx.finditer(text):
   brace=text.find("{",m.end()); semi=text.find(";",m.end())
   if brace<0 or (semi>=0 and semi<brace): continue
   body=extract_body(text,brace)
   line=text.count("\n",0,m.start())+1
   signature=text[m.start():brace].strip()
   records.append({"class":cls,"method":m.group(1),"path":path,"line":line,
                   "signature":signature,"body":body})

# Output every method definition found for the five ownership classes, rather
# than guessing one method spelling for the complete callback implementation.
body_lines=["STAGE56_QUEUE_REGISTRATION_AND_ADAPTER_METHOD_BODIES",
            "SOURCE_FILES_SCANNED=%d"%len(files),
            "QUALIFIED_METHOD_DEFINITIONS_FOUND=%d"%len(records)]
for r in records:
 body_lines += ["\n===== %s::%s %s:%d ====="%(r["class"],r["method"],r["path"],r["line"]),
                r["signature"],r["body"][:24000]]
(out/"ownership-method-bodies.txt").write_text("\n".join(body_lines)+"\n")

# Extract contexts around queue construction, callback arguments, registrations,
# completion sinks, packet pool operations, and interface construction/publication.
terms=re.compile(
 r"createQueues|destroyQueues|RTW88WCLSkywalkQueues|RTW88WCLSkywalkTxAdapter|"
 r"RTW88WCLSkywalkRxAdapter|createWithQueues|initWithQueues|createWithQueueSet|"
 r"registerInfraEthernetInterface|initRegistrationInfo|registerEthernetInterface|"
 r"registerNetworkInterface|callback|CompletionSink|stagedRxFrame|"
 r"submitPacket|drainCompletions|enqueuePacketsForNetworking|"
 r"rxPacketPool|txPacketPool|IO80211SkywalkInterface|RTW88WCLInfraInterface|"
 r"getPrimarySkywalkInterface|setPrimarySkywalkInterface",re.I)
context=["STAGE56_QUEUE_CONSTRUCTOR_AND_CALLBACK_ARGUMENT_CONTEXT"]
for path,text in texts.items():
 hits=[i for i,line in enumerate(text.splitlines()) if terms.search(line)]
 if not hits: continue
 ls=text.splitlines(); shown=set()
 context.append("\n===== "+path+" MATCHES="+str(len(hits))+" =====")
 for i in hits:
  for n in range(max(0,i-5),min(len(ls),i+8)):
   if n not in shown:
    context.append("%5d %s"%(n+1,ls[n])); shown.add(n)
   if len(shown)>=300: break
  if len(shown)>=300:
   context.append("TRUNCATED_AT_300_CONTEXT_LINES"); break
(out/"queue-callback-constructor-context.txt").write_text("\n".join(context)+"\n")

# Organize member bodies by class for explicit linkage checks.
by={}
for r in records:
 by.setdefault(r["class"]+"::"+r["method"],[]).append((r["path"]+"::"+r["class"]+"::"+r["method"],r["body"]))

def find(pattern,items,limit=100):
 rx=re.compile(pattern,re.I); hits=[]
 for path,body in items:
  for m in rx.finditer(body):
   line=body.count("\n",0,m.start())+1
   a=body.rfind("\n",0,m.start())+1; z=body.find("\n",m.end())
   if z<0:z=len(body)
   hits.append((path,line,body[a:z].strip()[:500]))
   if len(hits)>=limit:return hits
 return hits

audit=["STAGE56_REGISTRATION_INFO_OWNERSHIP_AND_LIFECYCLE"]
for key,patterns in [
 ("prepareRegistrationInfo",r"initRegistrationInfo|registerEthernetInterface|registerNetworkInterface|RegistrationInfo|return"),
 ("clearRegistrationInfo",r"memset|bzero|clear|release|RegistrationInfo"),
 ("createQueues",r"new\s+IOSkywalkPacketQueue|new\s+IOSkywalkPacketBufferPool|callback|create|init|return|tx|rx"),
 ("destroyQueues",r"release|destroy|queue|pool|nullptr"),
 ("RTW88WCLSkywalkTxAdapter::submitPacket",r"output|submit|ticket|completion|return"),
 ("RTW88WCLSkywalkTxAdapter::drainCompletions",r"completion|sink|ticket|drain|return"),
 ("RTW88WCLSkywalkRxAdapter methods",r"checkForWork|sink|stagedRxFrame|packet|pool|recycle|return")
]:
 audit.append("\nSECTION="+key)
 if key.startswith("RTW88WCLSkywalkTxAdapter::"):
  cls="RTW88WCLSkywalkTxAdapter::"+key.split("::",1)[1]
  scope=by.get(cls,[])
 elif key=="RTW88WCLSkywalkRxAdapter methods":
  scope=[x for k,v in by.items() if k.startswith("RTW88WCLSkywalkRxAdapter::") for x in v]
 else:
  cls="RTW88WCLInfraInterface::"+key if key in ("prepareRegistrationInfo","clearRegistrationInfo") else "RTW88WCLSkywalkQueues::"+key
  scope=by.get(cls,[])
 h=find(patterns,scope,120)
 audit.append("MATCHES=%d"%len(h))
 for p,l,snip in h[:60]: audit.append("%s:%d: %s"%(p,l,snip))
 if not h:audit.append("NO_MATCHES_IN_THIS_METHOD_SCOPE")
(out/"registration-and-queue-ownership-audit.txt").write_text("\n".join(audit)+"\n")

# Explicit checks distinguish implemented helpers from active call paths.
matrix=["STAGE56_QUEUE_TX_RX_OWNERSHIP_AND_CALLBACK_LINK_MATRIX",
        "SOURCE_FILES_SCANNED=%d"%len(files),
        "QUALIFIED_METHOD_DEFINITIONS_FOUND=%d"%len(records)]
checks=[
 ("interface prepares RegistrationInfo helper","RTW88WCLInfraInterface::prepareRegistrationInfo",r"initRegistrationInfo"),
 ("interface start calls RegistrationInfo helper","RTW88WCLInfraInterface::start",r"prepareRegistrationInfo"),
 ("interface start calls infra registration","RTW88WCLInfraInterface::start",r"registerInfraEthernetInterface"),
 ("queue owner creates TX/RX queues","RTW88WCLSkywalkQueues::createQueues",r"new\s+IOSkywalkPacketQueue"),
 ("queue owner creates TX/RX pools","RTW88WCLSkywalkQueues::createQueues",r"new\s+IOSkywalkPacketBufferPool"),
 ("queue creation passes callback function pointers","RTW88WCLSkywalkQueues::createQueues",r"callback|Callback|submitPacket|drainCompletions|stagedRxFrame|enqueue"),
 ("controller allocates TX adapter","RTW88WCLController::start",r"new\s+RTW88WCLSkywalkTxAdapter"),
 ("controller allocates RX adapter","RTW88WCLController::start",r"new\s+RTW88WCLSkywalkRxAdapter"),
 ("controller binds RX consumer sink","RTW88WCLController::start",r"stagedRxFrame"),
 ("TX adapter submit method calls RTW88 output","RTW88WCLSkywalkTxAdapter::submitPacket",r"(?:output|transmit|tx)"),
 ("TX adapter completion path exposes sink","RTW88WCLSkywalkTxAdapter::drainCompletions",r"CompletionSink|sink"),
 ("TX queue callback reaches TX adapter","RTW88WCLSkywalkQueues::createQueues",r"RTW88WCLSkywalkTxAdapter|submitPacket|drainCompletions"),
 ("RX queue callback reaches RX adapter","RTW88WCLSkywalkQueues::createQueues",r"RTW88WCLSkywalkRxAdapter|checkForWork|enqueuePacketsForNetworking"),
 ("RX adapter sends completed packet to networking sink","RTW88WCLSkywalkRxAdapter::checkForWork",r"sink|stagedRxFrame|enqueuePacketsForNetworking"),
 ("controller publishes primary interface","RTW88WCLController::start",r"setPrimarySkywalkInterface"),
 ("controller constructs native interface","RTW88WCLController::start",r"new\s+RTW88WCLInfraInterface")
]
for label,key,pattern in checks:
 scope=by.get(key,[])
 h=find(pattern,scope,40)
 matrix += ["\nCHECK="+label,"METHOD_SCOPE="+key,"RESULT="+("PRESENT" if h else "NOT_FOUND_IN_METHOD_BODY")]
 for p,l,snip in h[:12]: matrix.append("EVIDENCE=%s:%d: %s"%(p,l,snip))
# Also explicitly state method existence status, since a missing definition and a
# present-but-unwired method are different engineering cases.
for key in ["RTW88WCLInfraInterface::prepareRegistrationInfo",
            "RTW88WCLSkywalkQueues::createQueues","RTW88WCLSkywalkQueues::destroyQueues",
            "RTW88WCLSkywalkTxAdapter::submitPacket","RTW88WCLSkywalkTxAdapter::drainCompletions"]:
 matrix.append("\nMETHOD_DEFINITION="+key)
 matrix.append("FOUND="+("YES" if by.get(key) else "NO"))
rx_methods=[k for k in by if k.startswith("RTW88WCLSkywalkRxAdapter::")]
matrix.append("\nRX_ADAPTER_METHOD_DEFINITIONS="+",".join(sorted(rx_methods)))
(out/"queue-datapath-matrix.txt").write_text("\n".join(matrix)+"\n")

# Raw reference list for these APIs throughout all source and headers.
ref_patterns={
 "registration_info":r"prepareRegistrationInfo|initRegistrationInfo|registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface",
 "queue_and_link":r"createQueues|createWithQueues|initWithQueues|createWithQueueSet|IOSkywalkQueueSet|IOSkywalkLogicalLink",
 "tx_callbacks":r"submitPacket|drainCompletions|txComplete|transmitCallback|outputCallback|CompletionSink",
 "rx_callbacks":r"stagedRxFrame|enqueuePacketsForNetworking|checkForWork|rxComplete|receiveCallback|inputCallback",
 "native_interface_factory":r"RTW88WCLInfraInterface|IO80211SkywalkInterface::init|getPrimarySkywalkInterface|setPrimarySkywalkInterface"
}
inventory=["STAGE56_GLOBAL_REGISTRATION_QUEUE_AND_DATAPATH_REFERENCE_INVENTORY"]
for key,pattern in ref_patterns.items():
 rx=re.compile(pattern,re.I); matches=[]
 for path,text in texts.items():
  ls=text.splitlines()
  for i,line in enumerate(ls):
   if rx.search(line):
    matches.append((path,i+1,line.strip()[:500]))
    if len(matches)>=160: break
  if len(matches)>=160: break
 inventory += ["\nREFERENCE="+key,"MATCHES_AT_LEAST=%d"%len(matches)]
 for path,line,snip in matches:
  inventory.append("%s:%d: %s"%(path,line,snip))
(out/"global-reference-inventory.txt").write_text("\n".join(inventory)+"\n")

summary=[
 "STAGE56_REGISTRATION_INFO_QUEUE_CALLBACK_AND_TX_RX_AUDIT",
 "TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "SOURCE_FILES_SCANNED=%d"%len(files),
 "QUALIFIED_METHOD_DEFINITIONS_FOUND=%d"%len(records),
 "STAGE55_PREDECESSOR=VERIFIED",
 "STAGE43_SOURCE_CONTINUITY=PASS",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN",
 "KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
PY

{
 echo "========== STAGE 56 REGISTRATION / QUEUE / TX-RX DATAPATH AUDIT =========="
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "SOURCE_ROOT=$SOURCE_ROOT"
 echo "PREDECESSOR=Stage55 V1 $PREV_RUN"
 echo "SCOPE=inspect RegistrationInfo helper, QueueSet queue constructors/callback arguments, TX completion sink, RX consumer sink and native controller wiring"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "INSTALL=NOT_RUN"
 echo "LOAD=NOT_RUN"
 echo "OPENCORE_CHANGE=NONE"
 echo
 cat "$OUT/source-fingerprint.txt"
 echo
 cat "$OUT/audit-summary.txt"
 echo
 echo "STAGE55_EVIDENCE=$PREV"
 echo "OWNERSHIP_METHOD_BODIES=$OUT/ownership-method-bodies.txt"
 echo "QUEUE_CALLBACK_CONTEXT=$OUT/queue-callback-constructor-context.txt"
 echo "REGISTRATION_QUEUE_AUDIT=$OUT/registration-and-queue-ownership-audit.txt"
 echo "QUEUE_DATAPATH_MATRIX=$OUT/queue-datapath-matrix.txt"
 echo "GLOBAL_REFERENCE_INVENTORY=$OUT/global-reference-inventory.txt"
 echo
 echo "SOURCE_TREE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "CODESIGN=NOT_RUN"
 echo "KEXT_INSTALL=NOT_RUN"
 echo "KEXT_LOAD=NOT_RUN"
 echo "OPENCORE_MODIFIED=NO"
 echo "SIP_NVRAM_MODIFIED=NO"
 echo "HARDWARE_TEST=NOT_RUN"
 echo "SYSTEM_FILES_MODIFIED=NO"
 echo "========== END STAGE 56 =========="
} > "$OUT/report.txt"

github_sha() {
 gh api "repos/$REPO/contents/$1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha",""))' 2>/dev/null || true
}
blob_sha() {
 python3 - "$1" <<'PY2'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY2
}
PAYLOAD_INDEX=0
upload_one() {
 local file="$1" path="$2" allow="$3"
 local expected old payload response put got
 expected="$(blob_sha "$file")"
 old="$(github_sha "$path")"
 if [[ "$allow" == 1 ]]; then
   [[ "$old" =~ ^[0-9a-f]{40}$ ]] || { echo "UPDATE_TARGET_SHA_NOT_FOUND=$path" >> "$UPLOAD_ERROR"; return 1; }
 elif [[ -n "$old" ]]; then
   if [[ "$old" == "$expected" ]]; then
     echo "IDENTICAL_EXISTING=$path SHA=$old" >> "$OUT/upload-verification.txt"; return 0
   fi
   echo "REFUSE_OVERWRITE_DIFFERENT_FILE=$path REMOTE=$old LOCAL=$expected" >> "$UPLOAD_ERROR"
   return 1
 fi
 PAYLOAD_INDEX=$((PAYLOAD_INDEX+1))
 payload="$OUT/payload-$PAYLOAD_INDEX.json"
 response="$OUT/response-$PAYLOAD_INDEX.json"
 python3 - "$file" "$old" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,sha,dst=sys.argv[1:]
obj={"message":"Add Stage56 read-only queue and TX/RX integration audit evidence",
     "content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha: obj["sha"]=sha
pathlib.Path(dst).write_text(json.dumps(obj),encoding="utf-8")
PY2
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
 put="$(python3 - "$response" <<'PY2'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY2
)"
 got="$(github_sha "$path")"
 [[ "$put" == "$got" && "$got" == "$expected" ]] || {
   echo "READBACK_SHA_MISMATCH=$path PUT=$put GOT=$got EXPECTED=$expected" >> "$UPLOAD_ERROR"; return 1;
 }
 echo "VERIFIED=$path SHA=$got" >> "$OUT/upload-verification.txt"
}

MAN="$OUT/manifest.txt"
{
 echo "STAGE=56"
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "PURPOSE=read-only RegistrationInfo, queue callback and TX/RX adapter integration audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "PREDECESSOR=Stage55 V1 $PREV_RUN"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "ACTIVATION_GATE=BLOCKED"
 echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"

upload_artifact() {
 local file="$1" base group root
 base="$(basename "$file")"
 group="Development/Logs/stage56/$RUN/$base"
 root="Development/Logs/stage56-$RUN-$base"
 upload_one "$file" "$group" 0
 upload_one "$file" "$root" 0
 echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/registration-and-queue-ownership-audit.txt "$OUT"/queue-callback-constructor-context.txt "$OUT"/ownership-method-bodies.txt "$OUT"/queue-datapath-matrix.txt "$OUT"/global-reference-inventory.txt; do
 [[ -f "$f" ]] || fail "missing audit artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then
   upload_artifact "$f"
 else
   split -b 220k "$f" "$f.part-"
   for part in "$f".part-*; do upload_artifact "$part"; done
 fi
done
upload_one "$MAN" "Development/Logs/stage56/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage56-$RUN-manifest.txt" 0

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
old=base64.b64decode(json.load(open(remote))["content"])
entry=(
 "\n========== STAGE 56 REGISTRATION / QUEUE / TX-RX DATAPATH AUDIT ==========\n"
 "STAGE56_RUN: %s\n"%run+
 "STAGE56_VERSION: %s\n"%version+
 "STAGE56_SCOPE: detailed RegistrationInfo helper, queue constructor callback arguments, TX completion sink, RX consumer sink and native controller wiring\n"+
 "STAGE56_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — source audit only; no datapath enablement or hardware-test authorization\n"+
 "STAGE56_LOGS: Development/Logs/stage56/%s/ and unique files directly under Development/Logs/\n"%run+
 "==================================================================\n"
).encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY
upload_one "$OUT/output.log" "Development/output.log" 1

echo
echo "STAGE56_VERSION=$VERSION"
echo "STAGE56_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE56_RUN=$RUN"
echo "STAGE56_LOCAL_OUTPUT=$OUT"
echo "STAGE56_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage56/$RUN"
echo "STAGE56_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE56_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE56_SOURCE_MODIFIED=NO"
echo "STAGE56_BUILD=NOT_RUN"
echo "STAGE56_INSTALL=NOT_RUN"
echo "STAGE56_LOAD=NOT_RUN"
echo "STAGE56_OPENCORE_CHANGE=NONE"
