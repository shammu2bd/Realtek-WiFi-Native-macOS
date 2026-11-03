#!/bin/bash
# Stage 50 — exact source call-site and callback reachability audit.
# VERSION_MARKER: STAGE50_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE50_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage50/$RUN"
REF="$OUT/stage48-reference"
mkdir -p "$OUT" "$REF"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE50_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -50 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
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

EXPECTED_CPP="2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b"
EXPECTED_ABI="63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb"
EXPECTED_HPP="9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4"

BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage48/run-20261102-115133-c4f9565a517a"
curl -fsSLo "$REF/abi-audit-aa.txt" "$BASE/abi-audit-aa.txt" || fail "cannot retrieve Stage48 ABI audit aa"
curl -fsSLo "$REF/abi-audit-ab.txt" "$BASE/abi-audit-ab.txt" || fail "cannot retrieve Stage48 ABI audit ab"
curl -fsSLo "$REF/abi-audit-ac.txt" "$BASE/abi-audit-ac.txt" || fail "cannot retrieve Stage48 ABI audit ac"
python3 - "$REF" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={
 "abi-audit-aa.txt":"fcd88bf6615846fe6f60fea83c3ce547911f33cc2c480548492392f837c0a886",
 "abi-audit-ab.txt":"ef0f8bd3f8e79775c0b442361c63e975713a2f8086d19ea4a366ac9be5ed24f4",
 "abi-audit-ac.txt":"77e997ce4216dadeabd129d1dfb4688171b17b5a75a4329e6dd1ee41dd1e227e"
}
for name,want in expected.items():
 got=hashlib.sha256((root/name).read_bytes()).hexdigest()
 print("STAGE48_REFERENCE=%s SHA256=%s RESULT=%s"%(name,got,"MATCH" if got==want else "MISMATCH"))
 if got!=want: raise SystemExit("Stage48 ABI reference SHA256 mismatch: "+name)
PY

python3 - "$SRC" "$OUT" "$EXPECTED_CPP" "$EXPECTED_ABI" "$EXPECTED_HPP" "$REF" <<'PY'
import hashlib,pathlib,re,sys

src,out=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
expected=dict(zip([
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp"
],sys.argv[3:6]))
ref=pathlib.Path(sys.argv[6])

# Preserve offsets and newlines while blanking comments and quoted literals.
def mask_cpp(text):
    chars=list(text)
    i=0
    state="code"
    while i<len(chars):
        c=chars[i]
        n=chars[i+1] if i+1<len(chars) else ""
        if state=="code":
            if c=="/" and n=="/":
                chars[i]=chars[i+1]=" "
                i+=2; state="line"; continue
            if c=="/" and n=="*":
                chars[i]=chars[i+1]=" "
                i+=2; state="block"; continue
            if c=='"':
                chars[i]=" "; i+=1; state="string"; continue
            if c=="'":
                chars[i]=" "; i+=1; state="char"; continue
            i+=1; continue
        if state=="line":
            if c=="\n": state="code"
            else: chars[i]=" "
            i+=1; continue
        if state=="block":
            if c=="*" and n=="/":
                chars[i]=chars[i+1]=" "; i+=2; state="code"; continue
            if c!="\n": chars[i]=" "
            i+=1; continue
        if state in ("string","char"):
            terminator='"' if state=="string" else "'"
            if c=="\\":
                chars[i]=" "
                if i+1<len(chars):
                    if chars[i+1]!="\n": chars[i+1]=" "
                    i+=2
                else: i+=1
                continue
            if c==terminator:
                chars[i]=" "; i+=1; state="code"; continue
            if c!="\n": chars[i]=" "
            i+=1
    return "".join(chars)

finger=[]
for rel,want in expected.items():
    p=src/rel
    got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
    finger += ["FILE="+rel,"EXPECTED_SHA256="+want,"ACTUAL_SHA256="+got,
               "RESULT="+("MATCH" if got==want else "MISMATCH")]
(out/"source-fingerprint.txt").write_text(
    "\n".join(finger)+"\nSTAGE43_SOURCE_CONTINUITY="+
    ("PASS" if all(x=="RESULT=MATCH" for x in finger if x.startswith("RESULT=")) else "REVIEW_REQUIRED")+"\n"
)
if any(x=="RESULT=MISMATCH" for x in finger):
    raise SystemExit("Stage43 source fingerprint changed; stopping without source analysis")

files=[]
for p in sorted((src/"src").rglob("*")):
    if p.is_file() and p.suffix.lower() in (".cpp",".hpp",".h",".c"):
        if any(part in ("build","DerivedData",".git") for part in p.parts):
            continue
        files.append(p)

original={}
masked={}
for p in files:
    try:
        value=p.read_text(errors="replace")
    except Exception:
        continue
    original[p]=value
    masked[p]=mask_cpp(value)

# Exact named C++ method bodies. A missing body is reported, never guessed.
specs=[
 ("infra_start","RTW88WCLInfraInterface::start"),
 ("infra_prepare_registration","RTW88WCLInfraInterface::prepareRegistrationInfo"),
 ("controller_start","RTW88WCLController::start"),
 ("controller_stop","RTW88WCLController::stop"),
 ("queue_allocate","RTW88WCLSkywalkQueues::allocateQueues"),
 ("queue_tx_submission","RTW88WCLSkywalkQueues::txSubmissionAction"),
 ("queue_tx_completion","RTW88WCLSkywalkQueues::txCompletionAction"),
 ("queue_rx_submission","RTW88WCLSkywalkQueues::rxSubmissionAction"),
 ("queue_rx_completion","RTW88WCLSkywalkQueues::rxCompletionAction"),
 ("tx_adapter_submit","RTW88WCLSkywalkTxAdapter::submitPacket"),
 ("tx_adapter_drain","RTW88WCLSkywalkTxAdapter::drainCompletions"),
 ("rx_adapter_enqueue","RTW88WCLSkywalkRxAdapter::enqueueFrame"),
 ("rx_adapter_work","RTW88WCLSkywalkRxAdapter::checkForWork"),
 ("controller_staged_rx_sink","RTW88WCLController::stagedRxFrame")
]

def extract_body(qname):
    pattern=re.compile(r"\b"+re.escape(qname)+r"\s*\(")
    for p in files:
        code=masked.get(p,"")
        m=pattern.search(code)
        if not m: continue
        op=code.find("(",m.start())
        depth=0
        close=None
        for i in range(op,len(code)):
            if code[i]=="(": depth+=1
            elif code[i]==")":
                depth-=1
                if depth==0:
                    close=i; break
        if close is None: continue
        # For these ordinary out-of-line methods, the next body brace is before
        # any terminating declaration semicolon.
        j=close+1
        brace=None
        while j<len(code):
            if code[j]=="{":
                brace=j; break
            if code[j]==";":
                break
            j+=1
        if brace is None: continue
        depth=0
        end=None
        for i in range(brace,len(code)):
            if code[i]=="{": depth+=1
            elif code[i]=="}":
                depth-=1
                if depth==0:
                    end=i+1; break
        if end is None: continue
        line=code.count("\n",0,m.start())+1
        body=code[brace:end]
        body_line=code.count("\n",0,brace)+1
        return p,line,body_line,body,original[p]
    return None

bodies={}
body_lines=["STAGE50_EXACT_METHOD_BODY_EXCERPTS","EXTRACTION_RULE=out-of-line qualified method definition; comments and literals masked for brace matching"]
for label,qname in specs:
    item=extract_body(qname)
    if not item:
        body_lines += ["\n===== "+label+" | "+qname+" | NOT_EXTRACTED ====="]
        bodies[label]=""
        continue
    p,signature_line,body_line,body,raw=item
    bodies[label]=body
    rawlines=raw.splitlines()
    body_end=body_line+body.count("\n")
    body_lines += ["\n===== %s | %s | %s:%d..%d ====="%(label,qname,p.relative_to(src),signature_line,body_end)]
    for n,line in enumerate(rawlines[body_line-1:body_end],body_line):
        body_lines.append("%5d %s"%(n,line))
(out/"function-bodies.txt").write_text("\n".join(body_lines)+"\n")

# Call-site inventory: comments and quoted strings are excluded. Each hit is a
# code occurrence; declaration/definition and callback-address distinctions
# are resolved from the exact method-body excerpts above.
names=[
 "initRegistrationInfo","registerInfraEthernetInterface","registerEthernetInterface",
 "registerNetworkInterface","deregisterEthernetInterface","deregisterNetworkInterface",
 "createWithQueues","createWithQueueSet","withPool","setDefaultLogicalLink",
 "setLogicalLink","setInterface","setQueueSet","txSubmissionAction","txCompletionAction",
 "rxSubmissionAction","rxCompletionAction","submitPacket","drainCompletions",
 "enqueuePacketsForNetworking","enqueuePackets","completePackets","outputPacketWithCompletion"
]
call_lines=["STAGE50_CODE_OCCURRENCE_INDEX","COMMENTS_AND_QUOTED_LITERALS=EXCLUDED"]
for name in names:
    rx=re.compile(r"\b"+re.escape(name)+r"\b")
    hits=[]
    for p in files:
        code=masked.get(p,"")
        raw=original.get(p,"")
        for m in rx.finditer(code):
            line=code.count("\n",0,m.start())+1
            rawline=raw.splitlines()[line-1].strip() if line<=len(raw.splitlines()) else ""
            hits.append((str(p.relative_to(src)),line,rawline[:420]))
    call_lines.append("\nSYMBOL=%s OCCURRENCES=%d"%(name,len(hits)))
    for path,line,rawline in hits[:100]:
        call_lines.append("%s:%d: %s"%(path,line,rawline))
    if len(hits)>100: call_lines.append("TRUNCATED_ADDITIONAL_OCCURRENCES=%d"%(len(hits)-100))
(out/"callsite-index.txt").write_text("\n".join(call_lines)+"\n")

def has(label,pattern):
    body=mask_cpp(bodies.get(label,""))
    return bool(body and re.search(pattern,body,re.I))

edges=[
 ("infra_start","registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface","InfraInterface::start -> Apple Skywalk registration entry point"),
 ("infra_prepare_registration","initRegistrationInfo","prepareRegistrationInfo -> initRegistrationInfo"),
 ("controller_start","registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|createWithQueues|createWithQueueSet","Controller::start -> registration / QueueSet / LogicalLink creation"),
 ("queue_allocate","withPool","allocateQueues -> four queue withPool constructors"),
 ("queue_allocate","&RTW88WCLSkywalkQueues::txSubmissionAction","allocateQueues -> TX submission callback address"),
 ("queue_allocate","&RTW88WCLSkywalkQueues::txCompletionAction","allocateQueues -> TX completion callback address"),
 ("queue_allocate","&RTW88WCLSkywalkQueues::rxSubmissionAction","allocateQueues -> RX submission callback address"),
 ("queue_allocate","&RTW88WCLSkywalkQueues::rxCompletionAction","allocateQueues -> RX completion callback address"),
 ("queue_allocate","createWithQueues|createWithQueueSet|registerEthernetInterface","allocateQueues -> QueueSet / LogicalLink / interface registration"),
 ("queue_tx_submission","submitPacket\\s*\\(","TX submission callback -> TX adapter submitPacket"),
 ("queue_tx_completion","drainCompletions\\s*\\(|enqueuePackets\\s*\\(|completePackets\\s*\\(","TX completion callback -> ticket drain / Skywalk completion"),
 ("queue_rx_submission","refill|replenish|enqueuePackets","RX submission callback -> RX buffer refill / queueing"),
 ("queue_rx_completion","enqueuePacketsForNetworking|enqueuePackets\\s*\\(","RX completion callback -> Skywalk network enqueue"),
 ("tx_adapter_submit","outputPacketWithCompletion","TX adapter -> RTW88 hardware completion-aware output"),
 ("tx_adapter_drain","CompletionSink|sink\\s*\\(","TX ticket drain -> deferred completion sink"),
 ("rx_adapter_work","_sink\\s*\\(","RX adapter workloop -> controller frame sink"),
 ("controller_staged_rx_sink","_stagedRxPackets\\.push","controller RX sink -> bounded staging ring")
]
matrix=[
 "STAGE50_DIRECT_BODY_CALL_GRAPH",
 "METHOD_BODIES=comment/string-masked; edge tests are direct-body token checks, not interprocedural proof",
 "PRESENT means the target token/reference is in that exact extracted body; ABSENT means no direct edge found there."
]
for label,pattern,description in edges:
    state="PRESENT" if has(label,pattern) else ("NOT_EXTRACTED" if not bodies.get(label) else "ABSENT")
    matrix.append("%s: %s | %s"%(description,state,label))

matrix += ["\nSTAGE50_CALLBACK_RETURN_CHECKS"]
for label in ("queue_tx_submission","queue_tx_completion","queue_rx_submission","queue_rx_completion"):
    body=mask_cpp(bodies.get(label,""))
    if not body:
        matrix.append("%s: NOT_EXTRACTED"%label)
    else:
        zeros=len(re.findall(r"return\s+(?:static_cast\s*<\s*IOReturn\s*>\s*\(\s*0\s*\)|0)\s*;",body))
        matrix.append("%s: zero-return statements=%d | %s"%(label,zeros,"FOUND" if zeros else "NOT_FOUND"))

matrix += ["\nSTAGE50_REGISTRATION_API_OCCURRENCES"]
for name in ("registerInfraEthernetInterface","registerEthernetInterface","registerNetworkInterface",
             "createWithQueues","createWithQueueSet","setDefaultLogicalLink","setLogicalLink","setInterface"):
    rx=re.compile(r"\b"+re.escape(name)+r"\b")
    count=sum(len(rx.findall(code)) for code in masked.values())
    matrix.append("%s_CODE_OCCURRENCES=%d"%(name,count))

infra=bodies.get("infra_start","")
controller=bodies.get("controller_start","")
if infra:
    matrix.append("INFRA_START_CONTAINS_RETURN_FALSE="+("YES" if re.search(r"\breturn\s+false\s*;",mask_cpp(infra)) else "NO"))
else:
    matrix.append("INFRA_START_CONTAINS_RETURN_FALSE=NOT_EXTRACTED")
if controller:
    matrix.append("CONTROLLER_START_CONTAINS_FAIL_CLOSED_GOTO="+("YES" if re.search(r"\bgoto\s+fail\s*;",mask_cpp(controller)) else "NO"))
else:
    matrix.append("CONTROLLER_START_CONTAINS_FAIL_CLOSED_GOTO=NOT_EXTRACTED")
(out/"call-graph-matrix.txt").write_text("\n".join(matrix)+"\n")

# Compact index of relevant exact 24H32 Apple method/callback evidence.
abi=[]
needles=re.compile(r"CLASS_METHOD|CALLBACK_SIGNATURE|registerInfraEthernetInterface|initRegistrationInfo|createWithQueues|initWithQueues|registerEthernetInterface|registerNetworkInterface|setDefaultLogicalLink|setLogicalLink|setInterface|enqueuePacketsForNetworking|METHODS_RESOLVED|METHODS_REVIEW_REQUIRED",re.I)
for p in sorted(ref.glob("abi-audit-*.txt")):
    for n,line in enumerate(p.read_text(errors="replace").splitlines(),1):
        if needles.search(line):
            abi.append("%s:%d: %s"%(p.name,n,line[:850]))
(out/"stage48-abi-key-index.txt").write_text("STAGE48_PINNED_ABI_KEY_INDEX\n"+"\n".join(abi)+"\n")

summary=[
 "STAGE50_SOURCE_CALL_GRAPH_AUDIT",
 "TARGET=macOS %s / %s / %s"%(sys.platform, "15.8.1/24H32","x86_64"),
 "SOURCE_FILES_SCANNED=%d"%len(files),
 "METHOD_BODIES_EXTRACTED=%d"%sum(bool(v) for v in bodies.values()),
 "METHOD_BODIES_REQUESTED=%d"%len(specs),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN",
 "KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
PY

{
  echo "========== STAGE 50 REGISTRATION CALL-GRAPH / CALLBACK REACHABILITY =========="
  echo "VERSION=$VERSION"
  echo "RUN=$RUN"
  echo "TARGET=$OSVER/$BUILD/$ARCH"
  echo "SOURCE_ROOT=$SOURCE_ROOT"
  echo "PREDECESSOR=Stage49 V2 run-20261102-122652-fc6a55d99118"
  echo "SCOPE=exact source method bodies; registration API call sites; QueueSet/LogicalLink creation; queue callback pointers; TX/RX datapath reachability; 24H32 ABI reference integrity"
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
  cat "$OUT/call-graph-matrix.txt"
  echo
  echo "STAGE48_REFERENCE_VERIFICATION:"
  for f in "$REF"/*; do echo "$(basename "$f") BYTES=$(wc -c < "$f" | tr -d ' ') SHA256=$(shasum -a 256 "$f" | awk '{print $1}')"; done
  echo
  echo "FUNCTION_BODIES=$OUT/function-bodies.txt"
  echo "CALLSITE_INDEX=$OUT/callsite-index.txt"
  echo "STAGE48_ABI_INDEX=$OUT/stage48-abi-key-index.txt"
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
  echo "========== END STAGE 50 =========="
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
  local file="$1" path="$2" allow_update="$3"
  local expected old payload response put got
  expected="$(blob_sha "$file")"
  old="$(github_sha "$path")"
  if [[ "$allow_update" == "1" ]]; then
    [[ "$old" =~ ^[0-9a-f]{40}$ ]] || { echo "UPDATE_TARGET_SHA_NOT_FOUND $path" >> "$UPLOAD_ERROR"; return 1; }
  elif [[ -n "$old" ]]; then
    if [[ "$old" == "$expected" ]]; then
      echo "IDENTICAL_EXISTING=$path SHA=$old" >> "$OUT/upload-verification.txt"
      return 0
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
obj={"message":"Add Stage50 read-only registration call-graph audit evidence","content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
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
    echo "READBACK_SHA_MISMATCH=$path put=$put got=$got expected=$expected" >> "$UPLOAD_ERROR"
    return 1
  }
  echo "VERIFIED=$path SHA=$got" >> "$OUT/upload-verification.txt"
}

MAN="$OUT/manifest.txt"
{
  echo "STAGE=50"
  echo "VERSION=$VERSION"
  echo "RUN=$RUN"
  echo "PURPOSE=read-only exact method-body call graph and callback reachability audit"
  echo "TARGET=$OSVER/$BUILD/$ARCH"
  echo "PREDECESSOR=Stage49 V2 run-20261102-122652-fc6a55d99118"
  echo "SOURCE_MODIFIED=NO"
  echo "BUILD=NOT_RUN"
  echo "ACTIVATION_GATE=BLOCKED"
  echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"

upload_artifact() {
  local file="$1" base group root
  base="$(basename "$file")"
  group="Development/Logs/stage50/$RUN/$base"
  root="Development/Logs/stage50-$RUN-$base"
  upload_one "$file" "$group" 0
  upload_one "$file" "$root" 0
  echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}

for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/call-graph-matrix.txt "$OUT"/callsite-index.txt "$OUT"/function-bodies.txt "$OUT"/stage48-abi-key-index.txt; do
  [[ -f "$f" ]] || fail "expected audit artifact missing: $f"
  bytes="$(wc -c < "$f" | tr -d ' ')"
  if (( bytes <= 225280 )); then
    upload_artifact "$f"
  else
    split -b 220k "$f" "$f.part-"
    for part in "$f".part-*; do upload_artifact "$part"; done
  fi
done

# The manifest is frozen after all grouped/root artifact pairs are recorded.
upload_one "$MAN" "Development/Logs/stage50/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage50-$RUN-manifest.txt" 0

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote))
old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 50 REGISTRATION CALL-GRAPH / CALLBACK REACHABILITY ==========\n"
 "STAGE50_RUN: %s\n"%run+
 "STAGE50_VERSION: %s\n"%version+
 "STAGE50_SCOPE: exact native method bodies, registration API call sites, QueueSet/LogicalLink construction, TX/RX callback reachability and pinned Stage48 ABI evidence\n"+
 "STAGE50_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — direct source call-graph audit only; queue registration and TX/RX datapath remain unapproved until missing edges and rollback are implemented and reviewed\n"+
 "STAGE50_LOGS: Development/Logs/stage50/%s/ and unique files directly under Development/Logs/\n"%run+
 "===============================================================\n"
).encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY
upload_one "$OUT/output.log" "Development/output.log" 1

echo
echo "STAGE50_VERSION=$VERSION"
echo "STAGE50_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE50_RUN=$RUN"
echo "STAGE50_LOCAL_OUTPUT=$OUT"
echo "STAGE50_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage50/$RUN"
echo "STAGE50_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE50_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE50_SOURCE_MODIFIED=NO"
echo "STAGE50_BUILD=NOT_RUN"
echo "STAGE50_INSTALL=NOT_RUN"
echo "STAGE50_LOAD=NOT_RUN"
echo "STAGE50_OPENCORE_CHANGE=NONE"
