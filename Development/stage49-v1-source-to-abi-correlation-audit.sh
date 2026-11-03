#!/bin/bash
# Stage 49 — source-to-24H32-ABI correlation and activation-gap matrix.
# VERSION_MARKER: STAGE49_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE49_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage49/$RUN"
REF="$OUT/stage48-reference"
mkdir -p "$OUT" "$REF"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE49_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -50 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }
for t in curl gh python3 shasum split grep awk sw_vers uname; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "expected macOS 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"

EXPECTED_CPP="2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b"
EXPECTED_ABI="63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb"
EXPECTED_HPP="9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4"
BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage48/run-20261102-115133-c4f9565a517a"
for f in report-aa.txt report-ab.txt report-ac.txt abi-audit-aa.txt abi-audit-ab.txt abi-audit-ac.txt source-context-aa.txt; do
  curl -fsSLo "$REF/$f" "$BASE/$f" || fail "cannot retrieve Stage48 reference artifact $f"
done
python3 - "$SRC" "$OUT" "$EXPECTED_CPP" "$EXPECTED_ABI" "$EXPECTED_HPP" "$REF" <<'PY'
import hashlib,pathlib,re,sys
src,out=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
expected=dict(zip(["src/kext/wcl24h32/RTW88WCLInfraInterface.cpp","src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp","src/kext/wcl24h32/RTW88WCLInfraInterface.hpp"],sys.argv[3:6]))
ref=pathlib.Path(sys.argv[6])
fp=[]
for rel,want in expected.items():
 p=src/rel; got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
 fp += [f"FILE={rel}",f"EXPECTED_SHA256={want}",f"ACTUAL_SHA256={got}",f"RESULT={'MATCH' if got==want else 'MISMATCH'}"]
(out/"source-fingerprint.txt").write_text("\n".join(fp)+"\nSTAGE43_SOURCE_CONTINUITY="+("PASS" if all(x.endswith("MATCH") for x in fp if x.startswith("RESULT=")) else "REVIEW_REQUIRED")+"\n")
terms=re.compile(r"registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|deregisterEthernetInterface|deregisterNetworkInterface|initRegistrationInfo|RegistrationInfo|IOSkywalk(PacketQueue|QueueSet|LogicalLink|PacketBufferPool|TxSubmissionQueue|RxSubmissionQueue|TxCompletionQueue|RxCompletionQueue)|initWithPool|createWithQueues|initWithQueues|packetSubmission|packetCompletion|bufferCompletion|enqueuePackets|completePackets|submitPacket|completionTicket|outstanding|refill|receive|transmit|rx|tx|setLogicalLink|setInterface|setDefaultLogicalLink",re.I)
files=[]
for p in sorted((src/"src").rglob("*")):
 if p.is_file() and p.suffix.lower() in (".cpp",".hpp",".h",".c") and re.search(r"(wcl|queue|packet|tx|rx|radio|controller|interface)",p.name,re.I):
  files.append(p)
out_lines=["STAGE49_SOURCE_CONTEXT","SOURCE_FILE_COUNT="+str(len(files))]
for p in files:
 lines=p.read_text(errors="replace").splitlines()
 hits=[i for i,s in enumerate(lines) if terms.search(s)]
 if not hits: continue
 out_lines += ["\n===== "+str(p.relative_to(src))+" =====","TOTAL_LINES="+str(len(lines)),"MATCH_LINES="+str(len(hits))]
 emitted=set()
 for i in hits:
  a=max(0,i-3); b=min(len(lines),i+5)
  for n in range(a,b):
   if n not in emitted:
    out_lines.append(f"{n+1:5d} {lines[n]}"); emitted.add(n)
   if len(emitted)>260: break
  if len(emitted)>260:
   out_lines.append("TRUNCATED_PER_FILE_AT_260_CONTEXT_LINES"); break
(out/"source-context.txt").write_text("\n".join(out_lines)+"\n")
# Capture Stage48 ABI statements as a pinned reference index (original reports retained separately).
abi_files=sorted(ref.glob("abi-audit-*.txt"))
needles=re.compile(r"registerInfraEthernetInterface|initRegistrationInfo|registerEthernetInterface|registerNetworkInterface|createWithQueues|initWithQueues|initWithPool|packetSubmission|packetCompletion|enqueuePackets|deregisterNetworkInterface|setLogicalLink|setInterface|0x130|CALLBACK_SIGNATURE|METHODS_RESOLVED|METHODS_REVIEW_REQUIRED",re.I)
abi=[]
for p in abi_files:
 for n,line in enumerate(p.read_text(errors="replace").splitlines(),1):
  if needles.search(line): abi.append(f"{p.name}:{n}: {line[:1000]}")
(out/"stage48-abi-index.txt").write_text("STAGE48_ABI_REFERENCE_INDEX\n"+"\n".join(abi)+"\n")
# Gap matrix is explicitly a source-presence screen, not a semantic proof.
alltext="\n".join(p.read_text(errors="replace") for p in files)
checks=[
("registration-info lifecycle",r"initRegistrationInfo|RegistrationInfo",r"registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface"),
("queue constructors and callback wiring",r"initWithPool|withPool",r"packetSubmission|packetCompletion|bufferCompletion"),
("queue-set grouping and registration order",r"QueueSet|createWithQueues|initWithQueues",r"registerInfraEthernetInterface|registerEthernetInterface"),
("TX/RX pool ownership",r"PacketBufferPool|txPool|rxPool",r"retain|release|withPool|setPacketBufferPool"),
("TX completion and ticket drain",r"txCompletionAction|TxCompletion|completionTicket|outstanding",r"complete|completion|drain|ticket"),
("RX refill and network enqueue",r"rxSubmissionAction|rxCompletionAction|RxSubmission|RxCompletion",r"refill|enqueuePackets|complete|receive"),
("rollback and teardown",r"deregister|stop\\(|free\\(",r"setLogicalLink|setInterface|release|detach|deregister")]
matrix=["STAGE49_GAP_MATRIX (pattern-presence only; manual review required)"]
for label,a,b in checks:
 ma=bool(re.search(a,alltext,re.I)); mb=bool(re.search(b,alltext,re.I))
 matrix.append(f"{label}: {'FOUND' if ma else 'NOT_FOUND'} primary-pattern; {'FOUND' if mb else 'NOT_FOUND'} corroborating-pattern; STATUS=REVIEW_REQUIRED")
matrix.append("SOURCE_START_FENCE="+("FOUND" if re.search(r"bool\s+RTW88WCLInfraInterface::start[\s\S]{0,1200}?return\s+false",alltext) else "NOT_CONFIRMED"))
matrix.append("CALLBACK_ZERO_RETURN="+("FOUND" if re.search(r"(txSubmissionAction|txCompletionAction|rxSubmissionAction|rxCompletionAction)[\s\S]{0,1600}?return\s+0",alltext) else "NOT_CONFIRMED"))
(out/"gap-matrix.txt").write_text("\n".join(matrix)+"\n")
PY
{
 echo "========== STAGE 49 SOURCE-TO-ABI CORRELATION =========="
 echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "SOURCE_ROOT=$SOURCE_ROOT"
 echo "PREDECESSOR=Stage48 run-20261102-115133-c4f9565a517a"
 echo "SCOPE=registration-info lifecycle; queue constructors/order/grouping; pool ownership; callback signatures/returns; TX completion/tickets; RX refill/enqueue; rollback/teardown"
 echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; echo "OPENCORE_CHANGE=NONE"
 echo; cat "$OUT/source-fingerprint.txt"; echo; cat "$OUT/gap-matrix.txt"
 echo; echo "STAGE48_REFERENCE_ARTIFACTS:"
 for f in "$REF"/*; do echo "$(basename "$f") BYTES=$(wc -c < "$f" | tr -d ' ') SHA256=$(shasum -a 256 "$f" | awk '{print $1}')"; done
 echo; cat "$OUT/stage48-abi-index.txt"
 echo; echo "SOURCE_CONTEXT=$OUT/source-context.txt"
 echo "SOURCE_CONTEXT_BYTES=$(wc -c < "$OUT/source-context.txt" | tr -d ' ')"
 echo "SOURCE_TREE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "CODESIGN=NOT_RUN"; echo "KEXT_INSTALL=NOT_RUN"; echo "KEXT_LOAD=NOT_RUN"
 echo "OPENCORE_MODIFIED=NO"; echo "SIP_NVRAM_MODIFIED=NO"; echo "HARDWARE_TEST=NOT_RUN"; echo "SYSTEM_FILES_MODIFIED=NO"
 echo "========== END STAGE 49 =========="
} > "$OUT/report.txt"
for f in "$OUT"/report.txt "$OUT"/source-context.txt "$OUT"/stage48-abi-index.txt "$OUT"/gap-matrix.txt "$OUT"/source-fingerprint.txt; do split -b 220k "$f" "$f.part-"; done

github_sha(){ gh api "repos/$REPO/contents/$1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha",""))' 2>/dev/null || true; }
upload(){
 local f="$1" path="$2" allow="$3" old localsha payload resp put got
 localsha="$(python3 - "$f" <<'PY2'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY2
)"
 old="$(github_sha "$path")"
 if [[ "$allow" == 1 ]]; then [[ "$old" =~ ^[0-9a-f]{40}$ ]] || { echo "MISSING_UPDATE_SHA $path" >> "$UPLOAD_ERROR"; return 1; }
 elif [[ -n "$old" ]]; then [[ "$old" == "$localsha" ]] || { echo "REFUSE_OVERWRITE $path remote=$old local=$localsha" >> "$UPLOAD_ERROR"; return 1; }; echo "$path IDENTICAL $old" >> "$OUT/upload-verification.txt"; return 0; fi
 payload="$OUT/payload-$RANDOM.json"; resp="$OUT/response-$RANDOM.json"
 python3 - "$f" "$old" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,sha,p=sys.argv[1:]; d={"message":"Add Stage49 read-only source/ABI audit evidence","content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha:d["sha"]=sha
pathlib.Path(p).write_text(json.dumps(d))
PY2
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$resp"
 put="$(python3 - "$resp" <<'PY2'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY2
)"
 got="$(github_sha "$path")"; [[ "$put" == "$got" && "$got" == "$localsha" ]] || { echo "READBACK_MISMATCH $path put=$put got=$got local=$localsha" >> "$UPLOAD_ERROR"; return 1; }
 echo "$path SHA=$got" >> "$OUT/upload-verification.txt"
}
MAN="$OUT/manifest.txt"
{
 echo "STAGE=49"; echo "RUN=$RUN"; echo "PURPOSE=read-only source-to-Stage48 ABI correlation and activation-gap matrix"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage48 run-20261102-115133-c4f9565a517a"
 echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"; echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"
upload_artifact(){
 local f="$1" suffix="$2" base group root
 base="$(basename "$f")"; group="Development/Logs/stage49/$RUN/$base"; root="Development/Logs/stage49-$RUN-$suffix"
 upload "$f" "$group" 0; upload "$f" "$root" 0
 echo "$group | $root" >> "$MAN"
}
for f in "$OUT"/*.part-*; do [[ -f "$f" ]] && upload_artifact "$f" "$(basename "$f")"; done
for f in "$OUT"/gap-matrix.txt "$OUT"/source-fingerprint.txt "$OUT"/manifest.txt; do [[ -f "$f" ]] && upload_artifact "$f" "$(basename "$f")"; done
upload "$MAN" "Development/Logs/stage49/$RUN/manifest.txt" 0
upload "$MAN" "Development/Logs/stage49-$RUN-manifest.txt" 0
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" <<'PY'
import base64,json,pathlib,sys
obj=json.load(open(sys.argv[1])); old=base64.b64decode(obj["content"])
entry=("\n========== STAGE 49 SOURCE-TO-ABI CORRELATION ==========\n"
f"STAGE49_RUN: {sys.argv[3]}\n"
"STAGE49_SCOPE: read-only correlation of native registration-info, queue construction/order, pool ownership, callback wiring, TX/RX datapath and rollback against Stage48 24H32 ABI evidence\n"
"STAGE49_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"
"ACTIVATION_GATE: BLOCKED — source-pattern correlation is not proof of safe queue activation; manual ABI/ownership review and implementation remain required\n"
f"STAGE49_LOGS: Development/Logs/stage49/{sys.argv[3]}/ and unique files directly under Development/Logs/\n"
"========================================================\n").encode()
pathlib.Path(sys.argv[2]).write_bytes(old.rstrip()+entry)
PY
upload "$OUT/output.log" "Development/output.log" 1
echo "STAGE49_VERSION=$VERSION"
echo "STAGE49_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE49_RUN=$RUN"
echo "STAGE49_LOCAL_OUTPUT=$OUT"
echo "STAGE49_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage49/$RUN"
echo "STAGE49_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE49_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE49_SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
