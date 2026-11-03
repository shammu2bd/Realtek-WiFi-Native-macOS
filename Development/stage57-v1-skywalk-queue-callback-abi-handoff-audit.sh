#!/bin/bash
# Stage 57 V2 — 24H32 Skywalk queue callback ABI and adapter handoff audit.
# VERSION_MARKER: STAGE57_V2_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE57_V2_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
STAGE48_RUN="run-20261102-115133-c4f9565a517a"
STAGE56_RUN="run-20261102-134535-d4dcecdcf6bf"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage57/$RUN"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
PREV48="$OUT/stage48-evidence"
PREV56="$OUT/stage56-evidence"
mkdir -p "$TOOLS" "$CACHE" "$PREV48" "$PREV56"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE57_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }

for t in curl gh python3 shasum split grep awk sw_vers uname xcrun file wc tr; do
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

# Fetch and validate Stage56 predecessor outputs.
RAW56="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage56/$STAGE56_RUN"
for name in manifest.txt report.txt audit-summary.txt source-fingerprint.txt registration-and-queue-ownership-audit.txt queue-datapath-matrix.txt ownership-method-bodies.txt global-reference-inventory.txt; do
 curl -fsSLo "$PREV56/$name" "$RAW56/$name"
done
# Stage56 split context file is retained as two immutable parts.
for name in queue-callback-constructor-context.txt.part-aa queue-callback-constructor-context.txt.part-ab; do
 curl -fsSLo "$PREV56/$name" "$RAW56/$name"
done
python3 - "$PREV56" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={
 "manifest.txt":"11afa3505c665a812508f318c0f7847afe192c00",
 "report.txt":"282d3ee2bdde7badbf536a5aa79ec58d6f4ccd9e",
 "audit-summary.txt":"2b927aff5e9d9c64ce883edc89f17d47948afab2",
 "source-fingerprint.txt":"67bfe72603cd4316bd9a9107de5c97e1c37f625c",
 "registration-and-queue-ownership-audit.txt":"d9e6417e031dc25785660ff5fd74e3c8473ba85d",
 "queue-datapath-matrix.txt":"28a9a684b45d201d963ed604283b3075177a92e5",
 "ownership-method-bodies.txt":"e10ebe15ef8863e80c7ea0f2ffcd6b0057fc80d7",
 "global-reference-inventory.txt":"cefe92d4afdd7a07ade6231649da87cd836d5509",
 "queue-callback-constructor-context.txt.part-aa":"f0abfce26501737a440125c4714c3dfd507a23d4",
 "queue-callback-constructor-context.txt.part-ab":"7be3757783032bca68473185ba50ce7ed541e03b"
}
for name,want in expected.items():
 data=(root/name).read_bytes()
 got=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
 print("STAGE56_GIT_BLOB_%s=%s"%(name,"MATCH" if got==want else "MISMATCH"))
 if got!=want: raise SystemExit("Stage56 evidence mismatch: "+name)
if "STAGE43_SOURCE_CONTINUITY=PASS" not in (root/"source-fingerprint.txt").read_text():
 raise SystemExit("Stage56 source fingerprint is not PASS")
PY

# Fetch immutable Stage48 queue ABI reference evidence.
RAW48="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage48/$STAGE48_RUN"
for name in report-aa.txt report-ab.txt report-ac.txt abi-audit-aa.txt abi-audit-ab.txt abi-audit-ac.txt manifest.txt; do
 curl -fsSLo "$PREV48/$name" "$RAW48/$name"
done
python3 - "$PREV48" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={
 "report-aa.txt":"3455e7fd96aa728ddea165661f559ceb9e9bc71e",
 "report-ab.txt":"cb6b61748ef57a1a8fbc3a838b4e079d8cd14e49",
 "report-ac.txt":"0dd716f00a812a7dad0b72e22a51e7af2b51ea98",
 "abi-audit-aa.txt":"ba1b50fa57d2743a85d2657f85069ca38e8a175b",
 "abi-audit-ab.txt":"2deedc5bbe160d27ef711ec3a3045bfa1a3eed70",
 "abi-audit-ac.txt":"74de39e4c68fbbca44e24fab19087eda60d81433",
 "manifest.txt":"44b1bfd5e22849ea10427a7146cb079d3d2e4a7f"
}
for name,want in expected.items():
 data=(root/name).read_bytes()
 got=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
 print("STAGE48_GIT_BLOB_%s=%s"%(name,"MATCH" if got==want else "MISMATCH"))
 if got!=want: raise SystemExit("Stage48 ABI evidence mismatch: "+name)
PY

python3 - "$SRC" "$BOOTKC" "$CACHE" "$OBJDUMP" "$OUT" "$PREV48" "$PREV56" <<'PY'
import os,pathlib,re,subprocess,sys
src=pathlib.Path(sys.argv[1])
kc_path=sys.argv[2]
cache=pathlib.Path(sys.argv[3])
objdump=sys.argv[4]
out=pathlib.Path(sys.argv[5])
prev48=pathlib.Path(sys.argv[6])
prev56=pathlib.Path(sys.argv[7])
tools=out/"tools"
sys.path.insert(0,str(tools))
from kcfile import KC
import disasm
os.environ["LLVM_OBJDUMP"]=objdump
kc=KC(sys.argv[2])
parser=disasm.Disassembler(kc,str(cache))

classes={
 "IOSkywalkPacketQueue":r"(initWithPool|initialize|free|packetCompletion)",
 "IOSkywalkTxSubmissionQueue":r"(initWithPool|initialize|free|packetSubmission|packetCompletion)",
 "IOSkywalkTxCompletionQueue":r"(initWithPool|initialize|free|completePackets|enqueuePackets)",
 "IOSkywalkRxSubmissionQueue":r"(initWithPool|initialize|free|packetCompletion)",
 "IOSkywalkRxCompletionQueue":r"(initWithPool|initialize|free|enqueuePackets|enqueuePacketsForNetworking|enqueuePacketsForKPipe)",
 "IOSkywalkQueueSet":r"(createWithQueues|initWithQueues|free)",
 "IOSkywalkLogicalLink":r"(createWithQueueSet|initWithQueueSet|free)"
}
discovery=["STAGE57_24H32_SKYWALK_QUEUE_CALLBACK_ABI_AUDIT",
           "BOOTKC_SHA256="+kc.sha256(),"FILESET_ENTRY_COUNT=%d"%len(kc.entries),
           "OBJDUMP="+objdump]
hits_by_class={}
for cls,pat in classes.items():
 try: methods=kc.methods(cls)
 except Exception as e:
  discovery.append("CLASS_SCAN_%s=ERROR:%s"%(cls,str(e))); hits_by_class[cls]=[]; continue
 hits=[(va,nm) for va,nm in methods if re.search(pat,nm,re.I)]
 hits_by_class[cls]=hits
 discovery.append("\nCLASS=%s METHODS_TOTAL=%d SELECTED=%d"%(cls,len(methods),len(hits)))
 for va,nm in hits:
  discovery.append("METHOD class=%s address=0x%x owner=%s symbol=%s"%(
   cls,va,kc.owner(va) or kc.sym_owner.get(va) or "UNKNOWN",nm))

# Queue vtable slots relevant to packet dispatch and lifecycle.
vtable_lines=["STAGE57_SKYWALK_QUEUE_VTABLE_INDEX"]
vt_pat=re.compile(r"initWithPool|initialize|free|packetSubmission|packetCompletion|completePackets|enqueuePackets",re.I)
for cls in classes:
 try: vt=kc.vtable(cls)
 except Exception as e:
  vtable_lines.append("VTABLE_%s=ERROR:%s"%(cls,str(e))); continue
 if vt is None:
  vtable_lines.append("VTABLE_%s=NOT_FOUND"%cls); continue
 vtable_lines.append("\nVTABLE_CLASS=%s ENTRIES=%d"%(cls,len(vt)))
 count=0
 for idx,(word,raw,tgt,nm) in enumerate(vt):
  if vt_pat.search(nm or ""):
   owner=kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"
   vtable_lines.append("VTABLE_SLOT class=%s offset=0x%x index=%d target=0x%x owner=%s symbol=%s"%(
    cls,idx*8,idx,tgt,owner,nm))
   count+=1
 vtable_lines.append("VTABLE_MATCH_COUNT=%d"%count)
(out/"vtable-index.txt").write_text("\n".join(vtable_lines)+"\n")

# Resolve selected methods with a real executable owner/range, then disassemble.
resolved=[]; issues=[]; seen=set()
for cls,hits in hits_by_class.items():
 for va,nm in hits:
  if va in seen: continue
  seen.add(va)
  owner=kc.owner(va) or kc.sym_owner.get(va)
  if not owner or owner!=kc.sym_owner.get(va):
   issues.append("OWNER_VALIDATION_FAIL class=%s symbol=%s owner=%s symbol_owner=%s"%(cls,nm,owner,kc.sym_owner.get(va))); continue
  segs=[x for x in kc.entry_segs.get(owner,[]) if x[1]<=va<x[1]+x[2] and (x[5]&4)]
  if not segs:
   issues.append("EXECUTABLE_SEGMENT_MISSING class=%s symbol=%s"%(cls,nm)); continue
  end=kc.next_sym(va) or va+0x1000
  if end<=va or end>va+0x20000: end=va+0x1000
  resolved.append((cls,nm,va,owner,end))
discovery += issues
discovery.append("\nMETHODS_RESOLVED=%d"%len(resolved))
all_disasm=[]; status=[]
for owner in sorted({x[3] for x in resolved}):
 safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
 carved=cache/(safe+".macho")
 kc.carve(owner,str(carved))
 discovery.append("CARVED_OWNER=%s BYTES=%d"%(owner,carved.stat().st_size))
 for cls,nm,va,o,end in [x for x in resolved if x[3]==owner]:
  all_disasm.append("\n===== METHOD class=%s symbol=%s address=0x%x owner=%s range=0x%x..0x%x ====="%(
   cls,nm,va,o,va,end))
  args=["-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%va,
        "--stop-address=0x%x"%end,str(carved)]
  p=subprocess.run([objdump]+args,text=True,capture_output=True)
  addrs,ins=parser._parse(p.stdout); ok=p.returncode==0 and bool(addrs)
  all_disasm.append("OBJDUMP_EXIT=%d INSTRUCTIONS=%d"%(p.returncode,len(addrs)))
  if p.stderr.strip(): all_disasm.append("STDERR="+p.stderr[:1000])
  if p.stdout.strip():
   all_disasm.append("DISASSEMBLY_BEGIN"); all_disasm.append(p.stdout[:50000].rstrip()); all_disasm.append("DISASSEMBLY_END")
  all_disasm.append("METHOD_DISASSEMBLY="+("PASS" if ok else "REVIEW_REQUIRED"))
  status.append("METHOD_STATUS class=%s symbol=%s address=0x%x instructions=%d result=%s"%(
   cls,nm,va,len(addrs),"PASS" if ok else "REVIEW_REQUIRED"))
(out/"queue-dispatch-disassembly.txt").write_text("\n".join(all_disasm)+"\n")
(out/"class-method-discovery.txt").write_text("\n".join(discovery)+"\n")
(out/"method-status.txt").write_text("\n".join(status+issues)+"\n")

# Source inventories and exact queue/action/adapter bodies.
source_files=sorted(p for p in src.rglob("*") if p.is_file() and
 p.suffix.lower() in (".cpp",".cc",".cxx",".hpp",".h",".hh") and
 not any(z.startswith(".") or z in ("build","out","DerivedData") for z in p.relative_to(src).parts))
source_text={str(p.relative_to(src)):p.read_text(errors="replace") for p in source_files}

def extract_body(text,brace):
 depth=0; state="code"; quote=""; i=brace
 while i<len(text):
  c=text[i]; n=text[i+1] if i+1<len(text) else ""
  if state=="line":
   if c=="\n":state="code"
  elif state=="block":
   if c=="*" and n=="/":state="code";i+=1
  elif state=="str":
   if c=="\\":i+=1
   elif c==quote:state="code"
  else:
   if c=="/" and n=="/":state="line";i+=1
   elif c=="/" and n=="*":state="block";i+=1
   elif c in ("'","\""):state="str";quote=c
   elif c=="{":depth+=1
   elif c=="}":
    depth-=1
    if depth==0:return text[brace:i+1]
  i+=1
 return text[brace:]

targets={
 "RTW88WCLSkywalkQueues":["createQueues","txSubmissionAction","txCompletionAction","rxSubmissionAction","rxCompletionAction","destroyQueues"],
 "RTW88WCLSkywalkTxAdapter":["submitPacket","backendCompletion","drainCompletions","bind","unbind"],
 "RTW88WCLSkywalkRxAdapter":["checkForWork","enqueueFrame","copyMbufToSkywalkPacket","init","stop"],
 "RTW88WCLController":["start","stagedRxFrame","releaseNativeResources"],
 "RTW88WCLInfraInterface":["prepareRegistrationInfo","start"]
}
records=[]
for path,text in source_text.items():
 for cls,names in targets.items():
  for name in names:
   rx=re.compile(r"\b"+re.escape(cls)+r"\s*::\s*"+re.escape(name)+r"\s*\(")
   for m in rx.finditer(text):
    brace=text.find("{",m.end()); semi=text.find(";",m.end())
    if brace<0 or (semi>=0 and semi<brace):continue
    body=extract_body(text,brace)
    records.append((cls,name,path,text.count("\n",0,m.start())+1,text[m.start():brace].strip(),body))
body_lines=["STAGE57_NATIVE_QUEUE_AND_ADAPTER_METHOD_BODIES",
            "SOURCE_FILES_SCANNED=%d"%len(source_files),
            "SELECTED_METHOD_DEFINITIONS_FOUND=%d"%len(records)]
for cls,name,path,line,sig,body in records:
 body_lines += ["\n===== %s::%s %s:%d ====="%(cls,name,path,line),sig,body[:18000]]
(out/"native-method-bodies.txt").write_text("\n".join(body_lines)+"\n")

# Capture callback typedefs and queue construction declarations from SDK headers.
header_hits=[]
for path,text in source_text.items():
 if not (path.endswith(".h") or path.endswith(".hpp")): continue
 if not any(x in path for x in ("IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue",
                                "IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue")):
  continue
 ls=text.splitlines()
 rx=re.compile(r"withPool|initWithPool|Action|Callback|PFj|packet",re.I)
 for i,line in enumerate(ls):
  if rx.search(line):
   lo=max(0,i-4); hi=min(len(ls),i+9)
   header_hits.append("\n===== HEADER %s:%d ====="%(path,i+1))
   header_hits.extend("%5d %s"%(n+1,ls[n]) for n in range(lo,hi))
(out/"queue-sdk-callback-signatures.txt").write_text("\n".join(header_hits)+"\n")

def search(pattern,items,limit=100):
 rx=re.compile(pattern,re.I); found=[]
 for path,text in items:
  for m in rx.finditer(text):
   line=text.count("\n",0,m.start())+1
   lo=text.rfind("\n",0,m.start())+1; hi=text.find("\n",m.end())
   if hi<0:hi=len(text)
   found.append((path,line,text[lo:hi].strip()[:450]))
   if len(found)>=limit:return found
 return found
method_scope=[("%s::%s %s:%d"%(c,n,p,l),b) for c,n,p,l,sig,b in records]
matrix=["STAGE57_APPLE_QUEUE_ACTION_ABI_TO_NATIVE_CALLBACK_CROSSWALK",
        "APPLE_QUEUE_METHODS_RESOLVED=%d"%len(resolved),
        "APPLE_QUEUE_METHODS_DISASSEMBLED_PASS=%d"%sum(x.endswith("result=PASS") for x in status),
        "NATIVE_SOURCE_FILES_SCANNED=%d"%len(source_files)]
checks=[
 ("queue owner binds TX submission action","RTW88WCLSkywalkQueues::createQueues",r"txSubmissionAction"),
 ("queue owner binds TX completion action","RTW88WCLSkywalkQueues::createQueues",r"txCompletionAction"),
 ("queue owner binds RX submission action","RTW88WCLSkywalkQueues::createQueues",r"rxSubmissionAction"),
 ("queue owner binds RX completion action","RTW88WCLSkywalkQueues::createQueues",r"rxCompletionAction"),
 ("TX submission action calls TX adapter","RTW88WCLSkywalkQueues::txSubmissionAction",r"RTW88WCLSkywalkTxAdapter|submitPacket"),
 ("TX completion action drains adapter tickets","RTW88WCLSkywalkQueues::txCompletionAction",r"RTW88WCLSkywalkTxAdapter|drainCompletions|completePackets"),
 ("RX submission action calls RX adapter/refill","RTW88WCLSkywalkQueues::rxSubmissionAction",r"RTW88WCLSkywalkRxAdapter|refill|enqueueFrame"),
 ("RX completion action hands packets to networking","RTW88WCLSkywalkQueues::rxCompletionAction",r"enqueuePacketsForNetworking|RTW88WCLSkywalkRxAdapter"),
 ("TX completion drain is called by active controller path","RTW88WCLController::start",r"drainCompletions"),
 ("RX consumer sink accepts staged frames","RTW88WCLController::stagedRxFrame",r"return\s+true"),
 ("TX action return includes accepted packet count","RTW88WCLSkywalkQueues::txSubmissionAction",r"return\s+(?:packetCount|accepted|submitted|count)"),
 ("TX completion action returns completed count","RTW88WCLSkywalkQueues::txCompletionAction",r"return\s+(?:packetCount|completed|count)"),
 ("RX completion action returns delivered count","RTW88WCLSkywalkQueues::rxCompletionAction",r"return\s+(?:packetCount|delivered|count)")
]
for label,key,pattern in checks:
 scope=[(p,b) for p,b in method_scope if p.startswith(key)]
 h=search(pattern,scope,60)
 matrix += ["\nCHECK="+label,"METHOD_SCOPE="+key,"RESULT="+("PRESENT" if h else "NOT_FOUND_IN_METHOD_BODY")]
 for p,l,snip in h[:15]:matrix.append("EVIDENCE=%s:%d: %s"%(p,l,snip))
# Report direct action code and key ABI function targets independently.
for cls in classes:
 matrix.append("\nAPPLE_QUEUE_CLASS="+cls)
 h=hits_by_class.get(cls,[])
 matrix.append("METHODS_FOUND=%d"%len(h))
 for va,nm in h:
  matrix.append("SYMBOL=0x%x %s"%(va,nm))
(out/"callback-link-matrix.txt").write_text("\n".join(matrix)+"\n")

global_refs=["STAGE57_GLOBAL_QUEUE_AND_ADAPTER_REFERENCE_INVENTORY"]
patterns={
 "queue_action_binding":r"txSubmissionAction|txCompletionAction|rxSubmissionAction|rxCompletionAction",
 "tx_adapter_handoff":r"submitPacket|backendCompletion|drainCompletions|CompletionSink",
 "rx_adapter_handoff":r"checkForWork|stagedRxFrame|enqueuePacketsForNetworking|rxCompletionAction",
 "apple_queue_methods":r"initWithPool|packetSubmission|packetCompletion|completePackets|enqueuePacketsForNetworking"
}
for key,pat in patterns.items():
 h=search(pat,list(source_text.items()),200)
 global_refs += ["\nREFERENCE="+key,"MATCHES_AT_LEAST=%d"%len(h)]
 for p,l,snip in h[:150]:global_refs.append("%s:%d: %s"%(p,l,snip))
(out/"global-reference-inventory.txt").write_text("\n".join(global_refs)+"\n")

summary=[
 "STAGE57_SKYWALK_QUEUE_CALLBACK_ABI_AND_ADAPTER_HANDOFF_AUDIT",
 "TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "APPLE_QUEUE_METHODS_RESOLVED=%d"%len(resolved),
 "APPLE_QUEUE_METHODS_DISASSEMBLED_PASS=%d"%sum(x.endswith("result=PASS") for x in status),
 "APPLE_QUEUE_CLASS_COUNT=%d"%len(classes),
 "NATIVE_SOURCE_FILES_SCANNED=%d"%len(source_files),
 "NATIVE_METHOD_DEFINITIONS_FOUND=%d"%len(records),
 "STAGE56_PREDECESSOR=VERIFIED",
 "STAGE48_QUEUE_ABI_EVIDENCE=VERIFIED",
 "STAGE43_SOURCE_CONTINUITY=PASS",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN",
 "KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
PY

{
 echo "========== STAGE 57 SKYWALK QUEUE CALLBACK ABI / ADAPTER HANDOFF AUDIT =========="
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "SOURCE_ROOT=$SOURCE_ROOT"
 echo "PREDECESSOR=Stage56 V1 $STAGE56_RUN"
 echo "ABI_REFERENCE=Stage48 run-$STAGE48_RUN"
 echo "SCOPE=24H32 queue constructor/dispatch callback ABI, queue vtables, native action signatures, TX completion and RX networking handoff"
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
 echo "CLASS_METHOD_DISCOVERY=$OUT/class-method-discovery.txt"
 echo "QUEUE_DISPATCH_DISASSEMBLY=$OUT/queue-dispatch-disassembly.txt"
 echo "QUEUE_VTABLE_INDEX=$OUT/vtable-index.txt"
 echo "METHOD_STATUS=$OUT/method-status.txt"
 echo "NATIVE_METHOD_BODIES=$OUT/native-method-bodies.txt"
 echo "QUEUE_SDK_CALLBACK_SIGNATURES=$OUT/queue-sdk-callback-signatures.txt"
 echo "CALLBACK_LINK_MATRIX=$OUT/callback-link-matrix.txt"
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
 echo "========== END STAGE 57 =========="
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
obj={"message":"Add Stage57 read-only Skywalk queue callback ABI and adapter audit evidence",
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
 echo "STAGE=57"
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "PURPOSE=read-only 24H32 Skywalk queue callback ABI and TX/RX adapter handoff audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "PREDECESSOR=Stage56 V1 $STAGE56_RUN"
 echo "ABI_REFERENCE=Stage48 run-$STAGE48_RUN"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "ACTIVATION_GATE=BLOCKED"
 echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"

upload_artifact() {
 local file="$1" base group root
 base="$(basename "$file")"
 group="Development/Logs/stage57/$RUN/$base"
 root="Development/Logs/stage57-$RUN-$base"
 upload_one "$file" "$group" 0
 upload_one "$file" "$root" 0
 echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/class-method-discovery.txt "$OUT"/queue-dispatch-disassembly.txt "$OUT"/vtable-index.txt "$OUT"/method-status.txt "$OUT"/native-method-bodies.txt "$OUT"/queue-sdk-callback-signatures.txt "$OUT"/callback-link-matrix.txt "$OUT"/global-reference-inventory.txt; do
 [[ -f "$f" ]] || fail "missing audit artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then
   upload_artifact "$f"
 else
   split -b 220k "$f" "$f.part-"
   for part in "$f".part-*; do upload_artifact "$part"; done
 fi
done
upload_one "$MAN" "Development/Logs/stage57/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage57-$RUN-manifest.txt" 0

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
old=base64.b64decode(json.load(open(remote))["content"])
entry=(
 "\n========== STAGE 57 SKYWALK QUEUE CALLBACK ABI / ADAPTER HANDOFF AUDIT ==========\n"
 "STAGE57_RUN: %s\n"%run+
 "STAGE57_VERSION: %s\n"%version+
 "STAGE57_SCOPE: 24H32 queue constructor and dispatch ABI, action signatures, TX completion ticket handoff and RX networking sink wiring\n"+
 "STAGE57_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — ABI/callback crosswalk only; no queue registration implementation or hardware-test authorization\n"+
 "STAGE57_LOGS: Development/Logs/stage57/%s/ and unique files directly under Development/Logs/\n"%run+
 "==================================================================\n"
).encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY
upload_one "$OUT/output.log" "Development/output.log" 1

echo
echo "STAGE57_VERSION=$VERSION"
echo "STAGE57_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE57_RUN=$RUN"
echo "STAGE57_LOCAL_OUTPUT=$OUT"
echo "STAGE57_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage57/$RUN"
echo "STAGE57_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE57_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE57_SOURCE_MODIFIED=NO"
echo "STAGE57_BUILD=NOT_RUN"
echo "STAGE57_INSTALL=NOT_RUN"
echo "STAGE57_LOAD=NOT_RUN"
echo "STAGE57_OPENCORE_CHANGE=NONE"
