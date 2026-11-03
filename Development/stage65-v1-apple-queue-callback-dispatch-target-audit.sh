#!/bin/bash
# Stage 65 V1 — Apple queue callback dispatch targets and native packet-path edge audit.
# VERSION_MARKER: STAGE65_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE65_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
STAGE64_RUN="run-20261102-163320-6a2d28788a13"
STAGE61_RUN="run-20261102-152354-434ec3c3ae26"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage65/$RUN"
PREV="$OUT/predecessor-evidence"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
mkdir -p "$OUT" "$PREV" "$TOOLS" "$CACHE"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE65_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }

for t in curl gh python3 shasum grep awk sw_vers uname xcrun wc tr split; do
 command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"
done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
[[ -f "$BOOTKC" ]] || fail "BootKernelExtensions.kc not found"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"
BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "expected macOS 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump not found through selected Xcode"
export LLVM_OBJDUMP="$OBJDUMP"

blob_sha(){
python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
RAW64="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage64/$STAGE64_RUN"
for name in audit-summary.txt report.txt source-fingerprint.txt source-callback-bodies.txt sdk-action-typedefs.txt callback-behavior-matrix.txt callback-ownership-findings.txt apple-method-status.txt apple-checkforwork-disassembly.txt manifest.txt; do
 curl -fsSLo "$PREV/$name" "$RAW64/$name"
done
verify_pin(){
 local file="$1" expected="$2" got
 got="$(blob_sha "$PREV/$file")"
 [[ "$got" == "$expected" ]] || fail "Stage64 predecessor pin mismatch: $file expected=$expected got=$got"
 echo "STAGE64_PIN_PASS=$file SHA=$got"
}
verify_pin audit-summary.txt a87be021ffef6de76199a4939c2d90d388fe1955
verify_pin report.txt 59805ffe310dd6414049f2956d0fa2a041e9acb8
verify_pin source-fingerprint.txt 67bfe72603cd4316bd9a9107de5c97e1c37f625c
verify_pin source-callback-bodies.txt da005f489a8a7548b08d44ccaf33780305f43b91
verify_pin sdk-action-typedefs.txt 777fdb451e766d271ce0a0c3b50227e2d0d521b2
verify_pin callback-behavior-matrix.txt 9c4b083399aed46dbc027fb4457f13c61c890b6b
verify_pin callback-ownership-findings.txt 6b652dde67939a19749bef211284698eb7237be8
verify_pin apple-method-status.txt 65938dceacb07d3e5b29732f74b5b959f3da53d2
verify_pin apple-checkforwork-disassembly.txt a77289862df55f89c68b0841e6aa76ebfbbbfc15
verify_pin manifest.txt c5524db2e059b44a60a523518fd3c296e09553d2
grep -q '^RESULT=PASS$' "$PREV/audit-summary.txt" || fail "Stage64 predecessor did not PASS"
grep -q '^STAGE43_SOURCE_CONTINUITY=PASS$' "$PREV/source-fingerprint.txt" || fail "Stage64 source continuity is not PASS"

RAW61="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage61/$STAGE61_RUN"
curl -fsSLo "$PREV/queue-descriptor-record-matrix.txt" "$RAW61/queue-descriptor-record-matrix.txt"
[[ "$(blob_sha "$PREV/queue-descriptor-record-matrix.txt")" == "04c68bd635f16bc7a51615031f8950d620ba0818" ]] || fail "Stage61 queue descriptor pin mismatch"

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
 if got!=want: raise SystemExit("Pinned upstream parser mismatch: "+name)
PY

python3 - "$SRC" "$BOOTKC" "$CACHE" "$OBJDUMP" "$OUT" <<'PY'
import hashlib,os,pathlib,re,subprocess,sys
src=pathlib.Path(sys.argv[1]); bootkc=sys.argv[2]; cache=pathlib.Path(sys.argv[3])
objdump=sys.argv[4]; out=pathlib.Path(sys.argv[5])
tools=out/"tools"; sys.path.insert(0,str(tools))
from kcfile import KC
import disasm
os.environ["LLVM_OBJDUMP"]=objdump

# Verify the unchanged Stage43 ABI baseline before interpreting current native call sites.
fingerprint_items={
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":"2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":"63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":"9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4",
}
fp=[]; source_ok=True
for rel,want in fingerprint_items.items():
 p=src/rel; got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
 match=got==want; source_ok &= match
 fp += ["FILE="+rel,"EXPECTED_SHA256="+want,"ACTUAL_SHA256="+got,"RESULT="+("MATCH" if match else "MISMATCH")]
fp.append("STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"))
(out/"source-fingerprint.txt").write_text("\n".join(fp)+"\n")
if not source_ok: raise SystemExit("Stage43 source baseline changed")

kc=KC(bootkc)
disasm_lines=["STAGE65_APPLE_QUEUE_CALLBACK_DISPATCH_TARGET_DISASSEMBLY"]
status=[]; issues=[]; discovered=[]; all_methods={}
# Stage64 showed checkForWork uses these internal Apple helpers / vtable slots.
requested=[
 ("IOSkywalkTxSubmissionQueue",r"packetSubmissionForKPipe"),
 ("IOSkywalkTxCompletionQueue",r"enqueueAndCompletePackets"),
 ("IOSkywalkRxSubmissionQueue",r"gatedDequeue"),
 ("IOSkywalkRxCompletionQueue",r"gatedEnqueue"),
]
for cls,pat in requested:
 hits=[(va,nm) for va,nm in kc.methods(cls) if re.search(pat,nm,re.I)]
 discovered.append("DISCOVERY class=%s pattern=%s count=%d"%(cls,pat,len(hits)))
 if len(hits)==0:
  issues.append("APPLE_HELPER_NOT_FOUND_"+cls+"_"+pat)
 for va,nm in hits:
  all_methods[va]=(cls,nm,"named-helper")
# Capture initWithPool and performCommand methods to show where callback actions are installed/configured.
for cls in ("IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue",
            "IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue"):
 methods=kc.methods(cls)
 for va,nm in methods:
  if re.search(r"(initWithPool|performCommand)",nm,re.I):
   all_methods[va]=(cls,nm,"queue-action-setup")
   discovered.append("SETUP_METHOD class=%s address=0x%x symbol=%s"%(cls,va,nm))

# Resolve the two TxSubmission virtual targets used directly by its checkForWork body.
vtable_lines=["STAGE65_TX_SUBMISSION_CHECKFORWORK_VTABLE_TARGETS",
 "SOURCE=Stage64 checkForWork disassembly",
 "CALL_SITE_SLOT_OFFSETS=0x1d8,0x1e0",
 "NOTE=these are virtual dispatch targets; method meaning is not inferred from slot position"]
vt=None
try: vt=kc.vtable("IOSkywalkTxSubmissionQueue")
except Exception as e:
 issues.append("TX_SUBMISSION_VTABLE_ERROR")
 vtable_lines.append("VTABLE_ERROR="+str(e))
for off in (0x1d8,0x1e0):
 idx=off//8
 if vt is None or len(vt)<=idx:
  vtable_lines.append("SLOT offset=0x%x index=%d result=NOT_AVAILABLE"%(off,idx))
  issues.append("TX_SUBMISSION_SLOT_MISSING_0x%x"%off)
  continue
 word,raw,tgt,nm=vt[idx]
 owner=kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"
 vtable_lines.append("SLOT offset=0x%x index=%d target=0x%x owner=%s symbol=%s"%(off,idx,tgt,owner,nm))
 if not tgt or owner=="UNKNOWN":
  issues.append("TX_SUBMISSION_SLOT_TARGET_UNRESOLVED_0x%x"%off)
 else:
  all_methods[tgt]=("IOSkywalkTxSubmissionQueue","vtable@0x%x:%s"%(off,nm),"vtable-target")
(out/"tx-submission-vtable-targets.txt").write_text("\n".join(vtable_lines)+"\n")

# Resolve executable code ownership and disassemble each unique target.
resolved=[]
for va,(cls,nm,kind) in sorted(all_methods.items()):
 owner=kc.owner(va) or kc.sym_owner.get(va)
 if not owner or owner!=kc.sym_owner.get(va):
  status.append("METHOD class=%s kind=%s symbol=%s address=0x%x owner_validation=FAIL"%(cls,kind,nm,va))
  issues.append("OWNER_VALIDATION_"+nm); continue
 end=kc.next_sym(va) or va+0x1000
 if end<=va or end>va+0x20000: end=va+0x1000
 resolved.append((cls,nm,kind,va,owner,end))
carved={}
for owner in sorted({x[4] for x in resolved}):
 safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
 p=cache/(safe+".macho")
 kc.carve(owner,str(p))
 carved[owner]=p
for cls,nm,kind,va,owner,end in resolved:
 p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn",
  "--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved[owner])],
  text=True,capture_output=True)
 ins=sum(1 for line in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",line))
 ok=p.returncode==0 and ins>0
 status.append("METHOD class=%s kind=%s symbol=%s address=0x%x owner=%s instructions=%d result=%s"%(
  cls,kind,nm,va,owner,ins,"PASS" if ok else "REVIEW_REQUIRED"))
 if not ok: issues.append("DISASSEMBLY_"+nm)
 disasm_lines += ["\n===== METHOD class=%s kind=%s symbol=%s address=0x%x owner=%s ====="%(
  cls,kind,nm,va,owner),"OBJDUMP_EXIT=%d INSTRUCTIONS=%d"%(p.returncode,ins),
  "DISASSEMBLY_BEGIN",p.stdout[:60000].rstrip(),"DISASSEMBLY_END"]

(out/"method-status.txt").write_text("\n".join(status)+"\n")
(out/"apple-queue-helper-disassembly.txt").write_text("\n".join(disasm_lines)+"\n")
(out/"symbol-discovery.txt").write_text("\n".join(discovered)+"\n")

# Extract call edges from resolved Apple methods. Keep indirect virtual calls distinct from direct symbols.
edge_lines=["STAGE65_APPLE_QUEUE_DISPATCH_EDGE_INVENTORY"]
for block in re.split(r"(?=^===== METHOD )","\n".join(disasm_lines),flags=re.M):
 header=next((x for x in block.splitlines() if x.startswith("===== METHOD ")),None)
 if not header: continue
 edges=[x.strip() for x in block.splitlines() if re.search(r"\bcall\b|\bjmp\s+qword ptr\b",x)]
 edge_lines.append("\n"+header)
 edge_lines += edges or ["NO_CALL_EDGES_CAPTURED"]
(out/"dispatch-edge-inventory.txt").write_text("\n".join(edge_lines)+"\n")

# Report observed callback dispatch internals, without guessing callback ownership rules from return status.
helper_counts={}
for cls,pat in requested:
 helper_counts[cls]=sum(1 for va,(c,n,k) in all_methods.items() if c==cls and re.search(pat,n,re.I))
resolved_by_kind={}
for _,_,kind,_,_,_ in resolved: resolved_by_kind[kind]=resolved_by_kind.get(kind,0)+1
required_helpers=all(helper_counts.get(x,0)>=1 for x in (
 "IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue",
 "IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue"))
slots_ok=all(re.search(r"SLOT offset=0x%x index=%d target=0x[0-9a-f]+ owner=(?!UNKNOWN)\S+ symbol="%(
 off,off//8),"\n".join(vtable_lines)) for off in (0x1d8,0x1e0))
all_disassembled=len(resolved)>0 and all("result=PASS" in x for x in status)
summary=[
 "STAGE65_APPLE_QUEUE_CALLBACK_DISPATCH_TARGET_AUDIT",
 "TARGET=15.8.1/24H32/x86_64",
 "STAGE64_PREDECESSOR=10/10_PINS_PASS",
 "STAGE61_QUEUE_DESCRIPTOR_EVIDENCE=PIN_PASS",
 "STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"),
 "APPLE_HELPERS_FOUND="+("4/4" if required_helpers else "REVIEW_REQUIRED"),
 "TX_SUBMISSION_VTABLE_TARGETS="+("%d/2"%sum(1 for off in (0x1d8,0x1e0) if re.search(r"SLOT offset=0x%x index=%d target=0x[0-9a-f]+"%(off,off//8),"\n".join(vtable_lines)))),
 "APPLE_METHODS_RESOLVED=%d"%len(resolved),
 "APPLE_METHODS_DISASSEMBLED_PASS=%d"%sum("result=PASS" in x for x in status),
 "QUEUE_ACTION_SETUP_METHODS=%d"%resolved_by_kind.get("queue-action-setup",0),
 "VIRTUAL_TARGET_METHODS=%d"%resolved_by_kind.get("vtable-target",0),
 "CALLBACK_RETURN_ABI=IOReturn; packetCount is a separate callback input",
 "OWNERSHIP_CONCLUSION=NOT_INFERRED_FROM_IOReturn; helper bodies and packet state transitions are evidence only",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN",
 "KEXT_LOAD=NOT_RUN","OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "ISSUES="+(",".join(issues) if issues else "NONE"),
 "RESULT="+("PASS" if source_ok and required_helpers and slots_ok and all_disassembled and not issues else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 65 APPLE QUEUE CALLBACK DISPATCH TARGET AUDIT ==========",
 "VERSION=STAGE65_V1_20261102",
 "RUN="+out.name,
 "TARGET=15.8.1/24H32/x86_64",
 "PREDECESSOR=Stage64 V1 "+ "run-20261102-163320-6a2d28788a13",
 "PURPOSE=resolve the Apple queue callback helpers and the two TxSubmission virtual dispatch targets exposed by Stage64 checkForWork disassembly",
 "SCOPE=read-only kernel collection symbol/vtable resolution and method disassembly",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE",
 "",
 *summary,
 "",
 "CAUTION=the audit records dispatch targets and call edges; packet acceptance and ownership still require method-by-method state-transition analysis",
 "ACTIVATION_GATE=BLOCKED",
 "========== END STAGE 65 =========="
]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
if not source_ok or not required_helpers or not slots_ok or not all_disassembled or issues:
 raise SystemExit("Stage65 dispatch-target audit requires review")
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=65"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=read-only Apple queue callback dispatch and packet lifecycle helper audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage64 V1 $STAGE64_RUN"
 echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"
 echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"
PAYLOAD_INDEX=0
upload_one(){
 local file="$1" path="$2" expected payload response put got
 expected="$(blob_sha "$file")"
 PAYLOAD_INDEX=$((PAYLOAD_INDEX+1)); payload="$OUT/payload-$PAYLOAD_INDEX.json"; response="$OUT/response-$PAYLOAD_INDEX.json"
 python3 - "$file" "$payload" <<'PY'
import base64,json,pathlib,sys
f,d=sys.argv[1:]
pathlib.Path(d).write_text(json.dumps({"message":"Add Stage65 read-only Apple queue callback dispatch audit",
 "content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
 put="$(python3 - "$response" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 got="$(gh api "repos/$REPO/contents/$path" -q .sha)"
 [[ "$put" == "$expected" && "$got" == "$expected" ]] || {
  echo "READBACK_SHA_MISMATCH=$path PUT=$put GOT=$got EXPECTED=$expected" >> "$UPLOAD_ERROR"; return 1;
 }
 echo "VERIFIED=$path SHA=$got" >> "$OUT/upload-verification.txt"
}
upload_artifact(){
 local file="$1" base bytes
 base="$(basename "$file")"; bytes="$(wc -c < "$file" | tr -d ' ')"
 if (( bytes <= 225280 )); then upload_one "$file" "Development/Logs/stage65/$RUN/$base"
 else
  split -b 220k "$file" "$file.part-"
  for part in "$file".part-*; do [[ -f "$part" ]] || continue; upload_one "$part" "Development/Logs/stage65/$RUN/$(basename "$part")"; done
 fi
 echo "$base SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/symbol-discovery.txt "$OUT"/tx-submission-vtable-targets.txt "$OUT"/method-status.txt "$OUT"/apple-queue-helper-disassembly.txt "$OUT"/dispatch-edge-inventory.txt; do
 [[ -f "$f" ]] || fail "missing Stage65 artifact: $f"
 upload_artifact "$f"
done
upload_one "$MAN" "Development/Logs/stage65/$RUN/manifest.txt"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote)); old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 65 APPLE QUEUE CALLBACK DISPATCH TARGET AUDIT ==========\n"
 "STAGE65_RUN: %s\n"%run+
 "STAGE65_VERSION: %s\n"%version+
 "STAGE65_SCOPE: Apple TX/RX queue callback dispatch helpers and TxSubmission virtual targets\n"+
 "STAGE65_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — Apple internal callback helpers are being traced; RTL88WiFi packet ownership handoff remains unimplemented\n"+
 "STAGE65_LOGS: Development/Logs/stage65/%s/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry); pathlib.Path(dst+".sha").write_text(obj["sha"])
PY
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$(cat "$OUT/output.log.sha")" <<'PY'
import base64,json,pathlib,sys
f,d,sha=sys.argv[1:]
pathlib.Path(d).write_text(json.dumps({"message":"Append Stage65 Apple queue callback dispatch audit",
 "sha":sha,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
PUT_SHA="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
REMOTE_SHA="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$PUT_SHA" == "$REMOTE_SHA" ]] || fail "output.log readback SHA mismatch"

echo
echo "STAGE65_VERSION=$VERSION"
echo "STAGE65_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE65_RUN=$RUN"
echo "STAGE65_LOCAL_OUTPUT=$OUT"
echo "STAGE65_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage65/$RUN"
echo "STAGE65_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE65_SOURCE_MODIFIED=NO"
echo "STAGE65_BUILD=NOT_RUN"
echo "STAGE65_INSTALL=NOT_RUN"
echo "STAGE65_LOAD=NOT_RUN"
