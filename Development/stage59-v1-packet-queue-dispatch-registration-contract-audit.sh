#!/bin/bash
# Stage 59 — 24H32 packet-queue virtual dispatch ABI and registration contract audit.
# VERSION_MARKER: STAGE59_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE59_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
STAGE58_RUN="run-20261102-143451-43ae9daec178"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage59/$RUN"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
PREV58="$OUT/stage58-evidence"
mkdir -p "$TOOLS" "$CACHE" "$PREV58"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE59_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
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

RAW58="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage58/$STAGE58_RUN"
for name in audit-summary.txt callback-return-abi-clarification.txt class-method-discovery.txt manifest.txt method-disassembly.txt method-status.txt native-registration-method-bodies.txt registration-reference-inventory.txt report.txt sdk-queue-link-registration-headers.txt source-fingerprint.txt transaction-matrix.txt vtable-dispatch-slot-context.txt; do
 curl -fsSLo "$PREV58/$name" "$RAW58/$name"
done
python3 - "$PREV58" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={
 "audit-summary.txt":"2b0409d8d374057568b1f96ea20a223a2e5e2a23",
 "callback-return-abi-clarification.txt":"74df6ecbcab7acdcf1a979629e8dc08085d572e4",
 "class-method-discovery.txt":"5af5989cffb4761b7d3205a83407b78bcc53cbd4",
 "manifest.txt":"122d3e6aae97455f433df37afce540cf4954f298",
 "method-disassembly.txt":"86524bfd3be0e46002849fe2e737b44cb4e6dc42",
 "method-status.txt":"15dcfd49f9eee4fa92e9d80cf1824b65820b00a7",
 "native-registration-method-bodies.txt":"7b4f3d87a0a732e4dd9b54ddc79f2058871cf1cc",
 "registration-reference-inventory.txt":"d6ec14068472114222a3a8116411a1e588021710",
 "report.txt":"0614c668990d76f39bd80e817c5b8c1ed52344a4",
 "sdk-queue-link-registration-headers.txt":"f6e15da4ffa26d9c82b9c3f587f1b1bc48e1818e",
 "source-fingerprint.txt":"67bfe72603cd4316bd9a9107de5c97e1c37f625c",
 "transaction-matrix.txt":"a276f542c8e355ec71d51ff9cc632b5929e3860d",
 "vtable-dispatch-slot-context.txt":"c915ac7f62be5aebcdcb3f2a67d3b6b57d5f9092"
}
for name,want in expected.items():
 data=(root/name).read_bytes()
 got=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
 print("STAGE58_GIT_BLOB_%s=%s"%(name,"MATCH" if got==want else "MISMATCH"))
 if got!=want: raise SystemExit("Stage58 V2 evidence mismatch: "+name)
if "STAGE43_SOURCE_CONTINUITY=PASS" not in (root/"source-fingerprint.txt").read_text():
 raise SystemExit("Stage58 source fingerprint is not PASS")
if "APPLE_METHODS_DISASSEMBLED_PASS=23" not in (root/"audit-summary.txt").read_text():
 raise SystemExit("Stage58 Apple method audit is incomplete")
if "ALL_FOUR_QUEUE_SUBCLASSES_RESOLVE_TO=IOSkywalkPacketQueue::getFreeSpace" not in (root/"vtable-dispatch-slot-context.txt").read_text():
 raise SystemExit("Stage58 dispatch-slot resolution is not complete")
PY

python3 - "$SRC" "$BOOTKC" "$CACHE" "$OBJDUMP" "$OUT" "$PREV58" <<'PY'
import os,pathlib,re,subprocess,sys
src=pathlib.Path(sys.argv[1])
cache=pathlib.Path(sys.argv[3])
objdump=sys.argv[4]
out=pathlib.Path(sys.argv[5])
prev58=pathlib.Path(sys.argv[6])
tools=out/"tools"
sys.path.insert(0,str(tools))
from kcfile import KC
import disasm
os.environ["LLVM_OBJDUMP"]=objdump
kc=KC(sys.argv[2])
parser=disasm.Disassembler(kc,str(cache))

classes={
 "IOSkywalkPacketQueue":r"(getFreeSpace|getPacketCount|getPacketBufferCount|getBufferSize|setPacketBufferPool|setQueueSet|initWithPool|free)",
 "IOSkywalkTxSubmissionQueue":r"(getFreeSpace|getPacketCount|initWithPool|packetSubmission|free)",
 "IOSkywalkTxCompletionQueue":r"(getFreeSpace|getPacketCount|initWithPool|completePackets|enqueuePackets|free)",
 "IOSkywalkRxSubmissionQueue":r"(getFreeSpace|getPacketCount|initWithPool|packetCompletion|free)",
 "IOSkywalkRxCompletionQueue":r"(getFreeSpace|getPacketCount|initWithPool|enqueuePacketsForNetworking|free)",
 "IOSkywalkQueueSet":r"(initWithQueues|isWMMSchedModelCapable|createWithQueues|free)",
 "IOSkywalkNetworkInterface":r"(registerNetworkInterface|deregisterNetworkInterface)"
}
discovery=["STAGE59_24H32_PACKET_QUEUE_VIRTUAL_DISPATCH_CONTRACT_AUDIT",
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

# Full relevant vtable windows, not just a single disputed slot.
vtable_lines=["STAGE59_PACKET_QUEUE_VTABLE_WINDOWS",
              "WINDOW=offset 0x1e0..0x270 (entries 60..78, 8-byte slots)"]
queue_classes=("IOSkywalkPacketQueue","IOSkywalkTxSubmissionQueue",
               "IOSkywalkTxCompletionQueue","IOSkywalkRxSubmissionQueue",
               "IOSkywalkRxCompletionQueue")
for cls in queue_classes:
 try: vt=kc.vtable(cls)
 except Exception as e:
  vtable_lines.append("VTABLE_%s=ERROR:%s"%(cls,str(e))); continue
 if vt is None:
  vtable_lines.append("VTABLE_%s=NOT_FOUND"%cls); continue
 vtable_lines.append("\nVTABLE_CLASS=%s ENTRIES=%d"%(cls,len(vt)))
 for idx in range(60,min(len(vt),79)):
  word,raw,tgt,nm=vt[idx]
  owner=kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"
  vtable_lines.append("VTABLE_SLOT class=%s index=%d offset=0x%x target=0x%x owner=%s symbol=%s"%(
   cls,idx,idx*8,tgt,owner,nm))
(out/"packet-queue-vtable-windows.txt").write_text("\n".join(vtable_lines)+"\n")

# Resolve and disassemble selected method bodies from validated executable owners.
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
(out/"method-disassembly.txt").write_text("\n".join(all_disasm)+"\n")
(out/"class-method-discovery.txt").write_text("\n".join(discovery)+"\n")
(out/"method-status.txt").write_text("\n".join(status+issues)+"\n")

# Preserve the exact QueueSet initWithQueues indirect-dispatch sequence and nearby instructions.
dispatch_lines=["STAGE59_QUEUESET_INITWITHQUEUES_INDIRECT_DISPATCH_CONTEXT"]
all_text="\n".join(all_disasm)
start=all_text.find("===== METHOD class=IOSkywalkQueueSet symbol=__ZN17IOSkywalkQueueSet14initWithQueues")
if start>=0:
 end=all_text.find("\n===== METHOD ",start+1)
 block=all_text[start:end if end>=0 else len(all_text)]
 ls=block.splitlines()
 indexes=[i for i,line in enumerate(ls) if re.search(r"call\s+qword ptr \[rax \+ 0x218\]",line)]
 dispatch_lines.append("QUEUESET_INITWITHQUEUES_METHOD=PRESENT")
 dispatch_lines.append("CALLSITE_COUNT=%d"%len(indexes))
 for ix in indexes:
  dispatch_lines += ["\nCALLSITE_CONTEXT_BEGIN"]+ls[max(0,ix-14):min(len(ls),ix+22)]+["CALLSITE_CONTEXT_END"]
else:
 dispatch_lines += ["QUEUESET_INITWITHQUEUES_METHOD=NOT_FOUND","CALLSITE_COUNT=0"]
(out/"queueset-indirect-callsite-context.txt").write_text("\n".join(dispatch_lines)+"\n")

# Extract local SDK declarations for queue methods and callback typedefs.
source_files=sorted(p for p in src.rglob("*") if p.is_file() and
 p.suffix.lower() in (".cpp",".cc",".cxx",".hpp",".h",".hh") and
 not any(z.startswith(".") or z in ("build","out","DerivedData") for z in p.relative_to(src).parts))
source_text={str(p.relative_to(src)):p.read_text(errors="replace") for p in source_files}
sdk_names={"IOSkywalkPacketQueue.h","IOSkywalkTxSubmissionQueue.h","IOSkywalkTxCompletionQueue.h",
 "IOSkywalkRxSubmissionQueue.h","IOSkywalkRxCompletionQueue.h","IOSkywalkEthernetInterface.h",
 "IOSkywalkNetworkInterface.h","IO80211InfraInterface.h","IOSkywalkPacketBufferPool.h"}
sdk_lines=["STAGE59_PACKET_QUEUE_AND_REGISTRATION_SDK_CONTRACTS"]
rx=re.compile(r"getFreeSpace|getPacketCount|getPacketBufferCount|getBufferSize|setPacketBufferPool|setQueueSet|QueueSetInfo_s|LogicalLinkInfo_s|registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|typedef .*Action|withPool\s*\(",re.I)
for path,text in source_text.items():
 if pathlib.PurePosixPath(path).name not in sdk_names: continue
 ls=text.splitlines(); picks=set()
 for i,line in enumerate(ls):
  if rx.search(line):
   for n in range(max(0,i-4),min(len(ls),i+7)):picks.add(n)
 if picks:
  sdk_lines.append("\n===== SDK_HEADER %s ====="%path)
  sdk_lines.extend("%5d %s"%(i+1,ls[i]) for i in sorted(picks))
(out/"sdk-packet-queue-contracts.txt").write_text("\n".join(sdk_lines)+"\n")

# Global source search for private structure declarations and native use.
patterns={
 "queueset_info_declarations":r"(struct|class|typedef)[^\n]{0,100}QueueSetInfo_s|QueueSetInfo_s",
 "logicallink_info_declarations":r"(struct|class|typedef)[^\n]{0,100}LogicalLinkInfo_s|LogicalLinkInfo_s",
 "packet_queue_virtual_api":r"getFreeSpace\s*\(|getPacketCount\s*\(|getPacketBufferCount\s*\(|setQueueSet\s*\(",
 "registration_api":r"registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|deregisterNetworkInterface",
 "queue_set_construction":r"createWithQueues|initWithQueues|QueueSetInfo_s|createWithQueueSet|LogicalLinkInfo_s",
 "queue_type_terms":r"queueType|queue_type|QueueType|queue_class|QueueClass",
}
global_lines=["STAGE59_GLOBAL_QUEUE_AND_REGISTRATION_SOURCE_INVENTORY",
              "SOURCE_FILES_SCANNED=%d"%len(source_files)]
for key,pat in patterns.items():
 rx=re.compile(pat,re.I); found=[]
 for path,text in source_text.items():
  for m in rx.finditer(text):
   line=text.count("\n",0,m.start())+1
   lo=text.rfind("\n",0,m.start())+1; hi=text.find("\n",m.end())
   if hi<0:hi=len(text)
   found.append("%s:%d: %s"%(path,line,text[lo:hi].strip()[:500]))
   if len(found)>=250:break
  if len(found)>=250:break
 global_lines += ["\nREFERENCE="+key,"MATCHES_AT_LEAST=%d"%len(found)]+found
(out/"source-contract-inventory.txt").write_text("\n".join(global_lines)+"\n")

# Native method bodies and comment-masked source-edge checks.
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
 "RTW88WCLController":["start","releaseNativeResources","stagedRxFrame"],
 "RTW88WCLInfraInterface":["prepareRegistrationInfo","clearRegistrationInfo","start","stop","free"],
 "RTW88WCLSkywalkQueues":["createQueues","destroyQueues","txSubmissionAction","txCompletionAction","rxSubmissionAction","rxCompletionAction"],
 "RTW88WCLSkywalkTxAdapter":["submitPacket","drainCompletions"],
 "RTW88WCLSkywalkRxAdapter":["checkForWork","stop"]
}
records=[]
for path,text in source_text.items():
 for cls,names in targets.items():
  for name in names:
   rxm=re.compile(r"\b"+re.escape(cls)+r"\s*::\s*"+re.escape(name)+r"\s*\(")
   for m in rxm.finditer(text):
    brace=text.find("{",m.end()); semi=text.find(";",m.end())
    if brace<0 or (semi>=0 and semi<brace):continue
    body=extract_body(text,brace)
    records.append((cls,name,path,text.count("\n",0,m.start())+1,text[m.start():brace].strip(),body))
body_lines=["STAGE59_NATIVE_QUEUE_AND_REGISTRATION_METHOD_BODIES",
            "SOURCE_FILES_SCANNED=%d"%len(source_files),
            "SELECTED_METHOD_DEFINITIONS_FOUND=%d"%len(records)]
for cls,name,path,line,sig,body in records:
 body_lines += ["\n===== %s::%s %s:%d ====="%(cls,name,path,line),sig,body[:20000]]
(out/"native-queue-registration-bodies.txt").write_text("\n".join(body_lines)+"\n")

def code_only(s):
 s=re.sub(r"/\*.*?\*/"," ",s,flags=re.S)
 s=re.sub(r"//[^\n]*"," ",s)
 return s
scopes={}
for cls,name,path,line,sig,body in records:
 scopes.setdefault(cls+"::"+name,[]).append(code_only(body))
def scope_text(key):return "\n".join(scopes.get(key,[]))
def global_code(pattern,cpp_only=False):
 rxg=re.compile(pattern,re.I|re.S)
 for path,text in source_text.items():
  if cpp_only and pathlib.PurePosixPath(path).suffix.lower() not in (".cpp",".cc",".cxx"): continue
  code=code_only(text)
  if rxg.search(code):return True,path
 return False,""
checks=[
 ("SDK declares getFreeSpace as a no-argument UInt32 virtual","GLOBAL",r"virtual\s+UInt32\s+getFreeSpace\s*\(\s*\)"),
 ("SDK declares getPacketCount as a no-argument UInt32 virtual","GLOBAL",r"virtual\s+UInt32\s+getPacketCount\s*\(\s*\)\s*=\s*0"),
 ("native WCL calls QueueSet construction API","CPP",r"createWithQueues\s*\("),
 ("native WCL calls LogicalLink construction API","CPP",r"createWithQueueSet\s*\("),
 ("controller allocates and creates native queues","RTW88WCLController::start",r"new\s+RTW88WCLSkywalkQueues[\s\S]*_skywalkQueues\s*->\s*createQueues\s*\("),
 ("controller reaches registration API","RTW88WCLController::start",r"registerInfraEthernetInterface|registerEthernetInterface"),
 ("infra start calls RegistrationInfo helper","RTW88WCLInfraInterface::start",r"prepareRegistrationInfo\s*\("),
 ("infra start calls Apple registration API","RTW88WCLInfraInterface::start",r"registerInfraEthernetInterface|registerEthernetInterface"),
 ("TX queue callback calls TX adapter","RTW88WCLSkywalkQueues::txSubmissionAction",r"submitPacket"),
 ("TX completion action drains completion tickets","RTW88WCLSkywalkQueues::txCompletionAction",r"drainCompletions"),
 ("RX completion action submits packets to networking","RTW88WCLSkywalkQueues::rxCompletionAction",r"enqueuePacketsForNetworking"),
 ("RX staging sink hands packet to completion queue","RTW88WCLController::stagedRxFrame",r"enqueuePacketsForNetworking|_rxCompletion"),
 ("interface creates QueueSet or LogicalLink","RTW88WCLInfraInterface::start",r"createWithQueues|createWithQueueSet")
]
matrix=["STAGE59_PACKET_QUEUE_DISPATCH_AND_REGISTRATION_GAP_MATRIX",
        "APPLE_METHODS_RESOLVED=%d"%len(resolved),
        "APPLE_METHODS_DISASSEMBLED_PASS=%d"%sum("result=PASS" in x for x in status),
        "NATIVE_SOURCE_FILES_SCANNED=%d"%len(source_files),
        "NATIVE_METHOD_DEFINITIONS_FOUND=%d"%len(records)]
for label,scope,pattern in checks:
 if scope in ("GLOBAL","CPP"):
  ok,path=global_code(pattern,cpp_only=(scope=="CPP"))
  matrix += ["\nCHECK="+label,"SCOPE=whole native source tree",
             "RESULT="+("PRESENT" if ok else "NOT_FOUND"),
             "SOURCE="+(path if path else "none")]
 else:
  body=scope_text(scope)
  source=next((x[2]+":"+str(x[3]) for x in records if x[0]+"::"+x[1]==scope),"none")
  found=re.search(pattern,body,re.I|re.S)
  matrix += ["\nCHECK="+label,"METHOD_SCOPE="+scope,
             "RESULT="+("PRESENT" if found else "NOT_FOUND_IN_METHOD_BODY"),
             "SOURCE="+source]
  if found:matrix.append("MATCH="+found.group(0)[:320].replace("\n"," "))
# Exact vtable/callsite consistency must be interpreted, not assumed.
getfree=next((x for x in resolved if x[1].endswith("getFreeSpaceEv")),None)
matrix += ["\nDISPATCH_SLOT_0x218_TARGET=IOSkywalkPacketQueue::getFreeSpace",
           "SDK_DECLARATION=virtual UInt32 getFreeSpace()",
           "QUEUESET_INIT_WITH_QUEUES_CALLSITE=captured in queueset-indirect-callsite-context.txt",
           "INTERPRETATION=This audit records the symbol, declared prototype, and actual callsite registers separately; it does not invent a queue-type enum or infer a private ABI from the slot name."]
if getfree:matrix.append("GETFREESPACE_SYMBOL_ADDRESS=0x%x"%getfree[2])
(out/"registration-dispatch-contract-matrix.txt").write_text("\n".join(matrix)+"\n")

summary=[
 "STAGE59_PACKET_QUEUE_VIRTUAL_DISPATCH_AND_REGISTRATION_CONTRACT_AUDIT",
 "TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "APPLE_METHODS_RESOLVED=%d"%len(resolved),
 "APPLE_METHODS_DISASSEMBLED_PASS=%d"%sum("result=PASS" in x for x in status),
 "APPLE_CLASS_COUNT=%d"%len(classes),
 "QUEUESET_DISPATCH_SLOT_0x218=IOSkywalkPacketQueue::getFreeSpace",
 "NATIVE_SOURCE_FILES_SCANNED=%d"%len(source_files),
 "NATIVE_METHOD_DEFINITIONS_FOUND=%d"%len(records),
 "STAGE58_PREDECESSOR=VERIFIED",
 "STAGE43_SOURCE_CONTINUITY=PASS",
 "CALLBACK_RETURN_TYPE=IOReturn_STATUS_NOT_PACKET_COUNT",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN",
 "KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
PY

{
 echo "========== STAGE 59 PACKET-QUEUE VIRTUAL DISPATCH / REGISTRATION CONTRACT AUDIT =========="
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "SOURCE_ROOT=$SOURCE_ROOT"
 echo "PREDECESSOR=Stage58 V2 $STAGE58_RUN"
 echo "SCOPE=24H32 packet-queue vtable windows, getFreeSpace virtual ABI, QueueSet indirect callsite registers, SDK prototypes and native registration gaps"
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
 echo "METHOD_DISASSEMBLY=$OUT/method-disassembly.txt"
 echo "METHOD_STATUS=$OUT/method-status.txt"
 echo "PACKET_QUEUE_VTABLE_WINDOWS=$OUT/packet-queue-vtable-windows.txt"
 echo "QUEUESET_INDIRECT_CALLSITE=$OUT/queueset-indirect-callsite-context.txt"
 echo "SDK_PACKET_QUEUE_CONTRACTS=$OUT/sdk-packet-queue-contracts.txt"
 echo "SOURCE_CONTRACT_INVENTORY=$OUT/source-contract-inventory.txt"
 echo "NATIVE_QUEUE_REGISTRATION_BODIES=$OUT/native-queue-registration-bodies.txt"
 echo "REGISTRATION_DISPATCH_MATRIX=$OUT/registration-dispatch-contract-matrix.txt"
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
 echo "========== END STAGE 59 =========="
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
obj={"message":"Add Stage59 read-only packet-queue virtual dispatch and registration contract audit evidence",
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
 echo "STAGE=59"
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "PURPOSE=read-only 24H32 packet-queue virtual dispatch ABI and native registration gap audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "PREDECESSOR=Stage58 V2 $STAGE58_RUN"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "ACTIVATION_GATE=BLOCKED"
 echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"

upload_artifact() {
 local file="$1" base group root
 base="$(basename "$file")"
 group="Development/Logs/stage59/$RUN/$base"
 root="Development/Logs/stage59-$RUN-$base"
 upload_one "$file" "$group" 0
 upload_one "$file" "$root" 0
 echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/class-method-discovery.txt "$OUT"/method-disassembly.txt "$OUT"/method-status.txt "$OUT"/packet-queue-vtable-windows.txt "$OUT"/queueset-indirect-callsite-context.txt "$OUT"/sdk-packet-queue-contracts.txt "$OUT"/source-contract-inventory.txt "$OUT"/native-queue-registration-bodies.txt "$OUT"/registration-dispatch-contract-matrix.txt; do
 [[ -f "$f" ]] || fail "missing audit artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then
   upload_artifact "$f"
 else
   split -b 220k "$f" "$f.part-"
   for part in "$f".part-*; do upload_artifact "$part"; done
 fi
done
upload_one "$MAN" "Development/Logs/stage59/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage59-$RUN-manifest.txt" 0

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
old=base64.b64decode(json.load(open(remote))["content"])
entry=(
 "\n========== STAGE 59 PACKET-QUEUE VIRTUAL DISPATCH / REGISTRATION CONTRACT AUDIT ==========\n"
 "STAGE59_RUN: %s\n"%run+
 "STAGE59_VERSION: %s\n"%version+
 "STAGE59_SCOPE: 24H32 packet-queue vtable/getFreeSpace contract, QueueSet indirect-dispatch callsite, SDK declarations and native registration reachability\n"+
 "STAGE59_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — dispatch/registration ABI audit only; no queue activation or hardware-test authorization\n"+
 "STAGE59_LOGS: Development/Logs/stage59/%s/ and unique files directly under Development/Logs/\n"%run+
 "==================================================================\n"
).encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY
upload_one "$OUT/output.log" "Development/output.log" 1

echo
echo "STAGE59_VERSION=$VERSION"
echo "STAGE59_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE59_RUN=$RUN"
echo "STAGE59_LOCAL_OUTPUT=$OUT"
echo "STAGE59_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage59/$RUN"
echo "STAGE59_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE59_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE59_SOURCE_MODIFIED=NO"
echo "STAGE59_BUILD=NOT_RUN"
echo "STAGE59_INSTALL=NOT_RUN"
echo "STAGE59_LOAD=NOT_RUN"
echo "STAGE59_OPENCORE_CHANGE=NONE"
