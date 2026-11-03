#!/bin/bash
# Stage 58 V2 — 24H32 QueueSet/LogicalLink registration transaction and ownership audit.
# VERSION_MARKER: STAGE58_V2_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE58_V2_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
STAGE57_RUN="run-20261102-140635-1b9b1c59aed9"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage58/$RUN"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
PREV57="$OUT/stage57-evidence"
mkdir -p "$TOOLS" "$CACHE" "$PREV57"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE58_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
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

RAW57="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage57/$STAGE57_RUN"
for name in audit-summary.txt callback-link-matrix.txt class-method-discovery.txt global-reference-inventory.txt manifest.txt method-status.txt native-method-bodies.txt queue-dispatch-disassembly.txt queue-sdk-callback-signatures.txt report.txt source-fingerprint.txt vtable-index.txt; do
 curl -fsSLo "$PREV57/$name" "$RAW57/$name"
done
python3 - "$PREV57" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={
 "audit-summary.txt":"9bed6a620b0e146658b6d9bf8dc2691a68d2fda2",
 "callback-link-matrix.txt":"dd48ef400317cd609a82945e0f4126976d4256d5",
 "class-method-discovery.txt":"d17fcbec6e65c2071695f0ea481facf945c2fcb5",
 "global-reference-inventory.txt":"ed509a205d68a2c7e9b5f748f8daf737e4898955",
 "manifest.txt":"45175849f2d115b83158a35c9ad7f5d4982093a5",
 "method-status.txt":"209e461c3665094357b20026d4622be9d3fc13e3",
 "native-method-bodies.txt":"65a27eaad3456e45e2cc9235f429864d0e49d956",
 "queue-dispatch-disassembly.txt":"02daf5f08cc98d25864f999f9ff82108083349d3",
 "queue-sdk-callback-signatures.txt":"4a8e9dd7dd202697119fdf5f62ff0a02a5e63699",
 "report.txt":"88cf04b4e53acffbe39d3f6b13a015de0198eca4",
 "source-fingerprint.txt":"67bfe72603cd4316bd9a9107de5c97e1c37f625c",
 "vtable-index.txt":"1b774c44f1e9ab026180f6ddf860ed1715d4fa5e"
}
for name,want in expected.items():
 data=(root/name).read_bytes()
 got=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
 print("STAGE57_GIT_BLOB_%s=%s"%(name,"MATCH" if got==want else "MISMATCH"))
 if got!=want: raise SystemExit("Stage57 evidence mismatch: "+name)
if "STAGE43_SOURCE_CONTINUITY=PASS" not in (root/"source-fingerprint.txt").read_text():
 raise SystemExit("Stage57 source fingerprint is not PASS")
if "APPLE_QUEUE_METHODS_DISASSEMBLED_PASS=40" not in (root/"audit-summary.txt").read_text():
 raise SystemExit("Stage57 Apple queue ABI audit is not complete")
PY

python3 - "$SRC" "$BOOTKC" "$CACHE" "$OBJDUMP" "$OUT" "$PREV57" <<'PY'
import os,pathlib,re,subprocess,sys
src=pathlib.Path(sys.argv[1])
cache=pathlib.Path(sys.argv[3])
objdump=sys.argv[4]
out=pathlib.Path(sys.argv[5])
prev57=pathlib.Path(sys.argv[6])
tools=out/"tools"
sys.path.insert(0,str(tools))
from kcfile import KC
import disasm
os.environ["LLVM_OBJDUMP"]=objdump
kc=KC(sys.argv[2])
parser=disasm.Disassembler(kc,str(cache))

classes={
 "IO80211InfraInterface":r"(registerInfraEthernetInterface)",
 "IOSkywalkEthernetInterface":r"(registerEthernetInterface|deregisterEthernetInterface)",
 "IOSkywalkNetworkInterface":r"(registerNetworkInterface|deregisterNetworkInterface|deleteLogicalLink)",
 "IOSkywalkPacketQueue":r"(setQueueSet)",
 "IOSkywalkQueueSet":r"(createWithQueues|initWithQueues|isWMMSchedModelCapable|setLogicalLink|getQueueSetNexusInfo|free)",
 "IOSkywalkLogicalLink":r"(createWithQueueSet|initWithQueueSet|getLogicalLinkNexusInfo|getQueueSet|setInterface|setDefaultLogicalLink|free)"
}
discovery=["STAGE58_24H32_QUEUESET_LOGICALLINK_REGISTRATION_AUDIT",
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

# QueueSet dispatches through virtual slot 0x218 (index 67); record the resolved target without assuming it is a queue-type classifier.
queue_classes=("IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue",
               "IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue")
slot_lines=["STAGE58_QUEUESET_VTABLE_DISPATCH_SLOT_AUDIT","SLOT_BYTE_OFFSET=0x218","SLOT_INDEX=67","SEMANTICS=record resolved virtual target; do not label it a queue-type classifier"]
queue_slot_symbols=[]
for cls in ("IOSkywalkPacketQueue",)+queue_classes:
 try: vt=kc.vtable(cls)
 except Exception as e:
  slot_lines.append("VTABLE_%s=ERROR:%s"%(cls,str(e))); continue
 if vt is None or len(vt)<=67:
  slot_lines.append("VTABLE_%s=SLOT_NOT_AVAILABLE"%cls); continue
 word,raw,tgt,nm=vt[67]
 owner=kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"
 slot_lines.append("QUEUESET_DISPATCH_SLOT class=%s target=0x%x owner=%s symbol=%s"%(cls,tgt,owner,nm))
 if cls in queue_classes: queue_slot_symbols.append(nm)
 # Capture adjacent slots as context; queue subclasses may share inherited slots.
 for idx in range(max(0,64),min(len(vt),71)):
  w,r,t,n=vt[idx]
  slot_lines.append("VTABLE_CONTEXT class=%s index=%d offset=0x%x target=0x%x symbol=%s"%(
   cls,idx,idx*8,t,n))
if len(queue_slot_symbols)==4 and set(queue_slot_symbols)=={"__ZNK20IOSkywalkPacketQueue12getFreeSpaceEv"}:
 slot_lines.append("ALL_FOUR_QUEUE_SUBCLASSES_RESOLVE_TO=IOSkywalkPacketQueue::getFreeSpace")
else:
 slot_lines.append("ALL_FOUR_QUEUE_SUBCLASSES_RESOLVE_TO=REVIEW_REQUIRED:"+repr(queue_slot_symbols))
(out/"vtable-dispatch-slot-context.txt").write_text("\n".join(slot_lines)+"\n")

# Resolve selected registration/ownership methods from the actual KC and disassemble.
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

# Extract native interface/controller/queue lifecycle bodies and SDK declarations.
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
 "RTW88WCLSkywalkQueues":["createQueues","destroyQueues"],
 "RTW88WCLInfraInterface":["prepareRegistrationInfo","clearRegistrationInfo","start","stop","free"],
 "RTW88WCLController":["start","stagedRxFrame","releaseNativeResources"],
 "RTW88WCLSkywalkRxAdapter":["checkForWork","stop"]
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
body_lines=["STAGE58_NATIVE_REGISTRATION_AND_QUEUE_OWNERSHIP_METHOD_BODIES",
            "SOURCE_FILES_SCANNED=%d"%len(source_files),
            "SELECTED_METHOD_DEFINITIONS_FOUND=%d"%len(records)]
for cls,name,path,line,sig,body in records:
 body_lines += ["\n===== %s::%s %s:%d ====="%(cls,name,path,line),sig,body[:20000]]
(out/"native-registration-method-bodies.txt").write_text("\n".join(body_lines)+"\n")

# Extract exact local SDK declarations/structures rather than guessing opaque info layouts.
sdk_names={"IOSkywalkQueueSet.h","IOSkywalkLogicalLink.h","IOSkywalkEthernetInterface.h",
           "IOSkywalkNetworkInterface.h","IOSkywalkPacketQueue.h",
           "IOSkywalkTxSubmissionQueue.h","IOSkywalkTxCompletionQueue.h",
           "IOSkywalkRxSubmissionQueue.h","IOSkywalkRxCompletionQueue.h",
           "IO80211InfraInterface.h"}
sdk_lines=["STAGE58_SDK_QUEUESET_LOGICALLINK_REGISTRATION_DECLARATIONS"]
for path,text in source_text.items():
 if pathlib.PurePosixPath(path).name not in sdk_names: continue
 ls=text.splitlines()
 rx=re.compile(r"getFreeSpace|queryByteFreeSpace|QueueSetInfo_s|LogicalLinkInfo_s|registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|deregisterNetworkInterface|createWithQueues|initWithQueues|createWithQueueSet|initWithQueueSet|setQueueSet|getQueueType|setLogicalLink|getQueueSetNexusInfo|getLogicalLinkNexusInfo|typedef .*Action|withPool\s*\(",re.I)
 picks=set()
 for i,line in enumerate(ls):
  if rx.search(line):
   for n in range(max(0,i-3),min(len(ls),i+5)):picks.add(n)
 if picks:
  sdk_lines.append("\n===== SDK_HEADER %s ====="%path)
  sdk_lines.extend("%5d %s"%(i+1,ls[i]) for i in sorted(picks))
(out/"sdk-queue-link-registration-headers.txt").write_text("\n".join(sdk_lines)+"\n")

# Direct method-body checks; comments are removed so prose cannot satisfy a check.
def code_only(s):
 s=re.sub(r"/\*.*?\*/"," ",s,flags=re.S)
 s=re.sub(r"//[^\n]*"," ",s)
 return s
scopes={}
for cls,name,path,line,sig,body in records:
 scopes.setdefault(cls+"::"+name,[]).append(code_only(body))
def scope_text(key):return "\n".join(scopes.get(key,[]))
checks=[
 ("controller creates the native infrastructure interface","RTW88WCLController::start",r"new\s+RTW88WCLInfraInterface|create.*InfraInterface"),
 ("controller allocates the Skywalk queue owner","RTW88WCLController::start",r"new\s+RTW88WCLSkywalkQueues"),
 ("controller calls Skywalk queue createQueues","RTW88WCLController::start",r"_skywalkQueues\s*->\s*createQueues\s*\("),
 ("controller reaches native Skywalk registration","RTW88WCLController::start",r"registerInfraEthernetInterface|registerEthernetInterface"),
 ("interface start prepares RegistrationInfo","RTW88WCLInfraInterface::start",r"prepareRegistrationInfo"),
 ("interface start invokes Apple registration","RTW88WCLInfraInterface::start",r"registerInfraEthernetInterface|registerEthernetInterface"),
 ("interface start creates or owns the four queues","RTW88WCLInfraInterface::start",r"RTW88WCLSkywalkQueues|createQueues"),
 ("queue creation constructs QueueSet","RTW88WCLSkywalkQueues::createQueues",r"IOSkywalkQueueSet|createWithQueues"),
 ("queue creation constructs LogicalLink","RTW88WCLSkywalkQueues::createQueues",r"IOSkywalkLogicalLink|createWithQueueSet"),
 ("queue teardown releases all queue objects before either pool","RTW88WCLSkywalkQueues::destroyQueues",r"_rxCompletion[\s\S]*_rxSubmission[\s\S]*_txCompletion[\s\S]*_txSubmission[\s\S]*_rxPool[\s\S]*_txPool"),
 ("registration source passes queue array and both pools","RTW88WCLInfraInterface::start",r"registerInfraEthernetInterface\s*\([^;]*_txPool[^;]*_rxPool"),
 ("RegistrationInfo helper is called by interface start","RTW88WCLInfraInterface::start",r"prepareRegistrationInfo\s*\("),
 ("RX staged ring is handed to networking queue","RTW88WCLController::stagedRxFrame",r"enqueuePacketsForNetworking|_rxCompletion")
]
matrix=["STAGE58_REGISTRATION_QUEUESET_LOGICALLINK_TRANSACTION_MATRIX",
        "APPLE_METHODS_RESOLVED=%d"%len(resolved),
        "APPLE_METHODS_DISASSEMBLED_PASS=%d"%sum("result=PASS" in x for x in status),
        "NATIVE_SOURCE_FILES_SCANNED=%d"%len(source_files),
        "NATIVE_METHOD_DEFINITIONS_FOUND=%d"%len(records)]
for label,key,pattern in checks:
 body=scope_text(key)
 found=re.search(pattern,body,re.I|re.S)
 matrix += ["\nCHECK="+label,"METHOD_SCOPE="+key,
            "RESULT="+("PRESENT" if found else "NOT_FOUND_IN_METHOD_BODY")]
 if found:matrix.append("MATCH="+found.group(0)[:260].replace("\n"," "))
 for item in records:
  k=item[0]+"::"+item[1]
  if k==key:
   matrix.append("SOURCE=%s:%d"%(item[2],item[3]))
(out/"transaction-matrix.txt").write_text("\n".join(matrix)+"\n")

# The SDK callback return is IOReturn; packetCount is a distinct argument.
callback=[
 "STAGE58_CALLBACK_RETURN_TYPE_CLARIFICATION",
 "SOURCE=Stage57 V2 SDK header extraction, pinned predecessor artifact",
 "IOSkywalkTxSubmissionQueueAction=IOReturn (*)(OSObject*, IOSkywalkTxSubmissionQueue*, const IOSkywalkPacket**, UInt32 packetCount, void*)",
 "IOSkywalkTxCompletionQueueAction=IOReturn (*)(OSObject*, IOSkywalkTxCompletionQueue*, IOSkywalkPacket**, UInt32 packetCount, void*)",
 "IOSkywalkRxSubmissionQueueAction=IOReturn (*)(OSObject*, IOSkywalkRxSubmissionQueue*, const IOSkywalkPacket**, UInt32 packetCount, void*)",
 "IOSkywalkRxCompletionQueueAction=IOReturn (*)(OSObject*, IOSkywalkRxCompletionQueue*, IOSkywalkPacket**, UInt32 packetCount, void*)",
 "INTERPRETATION=The callback result is an IOReturn status value; packetCount is a separate input argument.",
 "ZERO_STATUS=kIOReturnSuccess (not a packet count).",
 "CAUTION=Do not infer packet ownership transfer or accepted packet count from the callback return type alone. The queue dispatcher and packet state transitions must be reviewed together.",
 "STAGE56_NOTE=Any statement that callback return zero inherently means zero packets accepted is not established by the SDK typedef. This audit corrects that interpretation without asserting that the currently stubbed datapath is active."
]
(out/"callback-return-abi-clarification.txt").write_text("\n".join(callback)+"\n")

# Compact global call-site inventory for the registration transaction.
global_refs=["STAGE58_GLOBAL_REGISTRATION_AND_OWNERSHIP_REFERENCE_INVENTORY"]
patterns={
 "registration_api":r"registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|deregisterNetworkInterface",
 "queue_set_link_api":r"QueueSetInfo_s|LogicalLinkInfo_s|createWithQueues|initWithQueues|createWithQueueSet|initWithQueueSet|setLogicalLink|getQueueSetNexusInfo|getLogicalLinkNexusInfo",
 "queue_grouping":r"setQueueSet|getQueueType|queueSet",
 "queue_pool_owner":r"createQueues|destroyQueues|_txPool|_rxPool",
 "packet_handoff":r"enqueuePacketsForNetworking|stagedRxFrame|drainCompletions|submitPacket"
}
for key,pat in patterns.items():
 rx=re.compile(pat,re.I); found=[]
 for path,text in source_text.items():
  for m in rx.finditer(text):
   line=text.count("\n",0,m.start())+1
   lo=text.rfind("\n",0,m.start())+1; hi=text.find("\n",m.end())
   if hi<0:hi=len(text)
   found.append("%s:%d: %s"%(path,line,text[lo:hi].strip()[:400]))
   if len(found)>=160:break
  if len(found)>=160:break
 global_refs += ["\nREFERENCE="+key,"MATCHES_AT_LEAST=%d"%len(found)]+found
(out/"registration-reference-inventory.txt").write_text("\n".join(global_refs)+"\n")

summary=[
 "STAGE58_QUEUESET_LOGICALLINK_REGISTRATION_OWNERSHIP_AUDIT",
 "TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "APPLE_METHODS_RESOLVED=%d"%len(resolved),
 "APPLE_METHODS_DISASSEMBLED_PASS=%d"%sum("result=PASS" in x for x in status),
 "APPLE_CLASS_COUNT=%d"%len(classes),
 "QUEUESET_VIRTUAL_DISPATCH_SLOT=0x218 / index 67",
 "RESOLVED_VTABLE_TARGET=IOSkywalkPacketQueue::getFreeSpace",
 "NATIVE_SOURCE_FILES_SCANNED=%d"%len(source_files),
 "NATIVE_METHOD_DEFINITIONS_FOUND=%d"%len(records),
 "STAGE57_PREDECESSOR=VERIFIED",
 "STAGE43_SOURCE_CONTINUITY=PASS",
 "CALLBACK_RETURN_TYPE=IOReturn_STATUS_NOT_PACKET_COUNT",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN",
 "KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
PY

{
 echo "========== STAGE 58 QUEUESET / LOGICALLINK REGISTRATION AND OWNERSHIP AUDIT =========="
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "SOURCE_ROOT=$SOURCE_ROOT"
 echo "PREDECESSOR=Stage57 V2 $STAGE57_RUN"
 echo "SCOPE=24H32 interface registration, QueueSet/LogicalLink constructors, QueueSet virtual dispatch slot, SDK info structures, ownership and rollback"
 echo "CALLBACK_RETURN_ABI=IOReturn status; packet count is a separate argument"
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
 echo "QUEUESET_VIRTUAL_DISPATCH_SLOTS=$OUT/vtable-dispatch-slot-context.txt"
 echo "SDK_QUEUE_LINK_HEADERS=$OUT/sdk-queue-link-registration-headers.txt"
 echo "NATIVE_REGISTRATION_BODIES=$OUT/native-registration-method-bodies.txt"
 echo "TRANSACTION_MATRIX=$OUT/transaction-matrix.txt"
 echo "REGISTRATION_REFERENCE_INVENTORY=$OUT/registration-reference-inventory.txt"
 echo "CALLBACK_ABI_CLARIFICATION=$OUT/callback-return-abi-clarification.txt"
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
 echo "========== END STAGE 58 =========="
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
obj={"message":"Add Stage58 read-only QueueSet/LogicalLink ownership audit evidence",
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
 echo "STAGE=58"
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "PURPOSE=read-only 24H32 QueueSet/LogicalLink registration transaction and packet-queue ownership audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "PREDECESSOR=Stage57 V2 $STAGE57_RUN"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "ACTIVATION_GATE=BLOCKED"
 echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"

upload_artifact() {
 local file="$1" base group root
 base="$(basename "$file")"
 group="Development/Logs/stage58/$RUN/$base"
 root="Development/Logs/stage58-$RUN-$base"
 upload_one "$file" "$group" 0
 upload_one "$file" "$root" 0
 echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/class-method-discovery.txt "$OUT"/method-disassembly.txt "$OUT"/method-status.txt "$OUT"/vtable-dispatch-slot-context.txt "$OUT"/sdk-queue-link-registration-headers.txt "$OUT"/native-registration-method-bodies.txt "$OUT"/transaction-matrix.txt "$OUT"/registration-reference-inventory.txt "$OUT"/callback-return-abi-clarification.txt; do
 [[ -f "$f" ]] || fail "missing audit artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then
   upload_artifact "$f"
 else
   split -b 220k "$f" "$f.part-"
   for part in "$f".part-*; do upload_artifact "$part"; done
 fi
done
upload_one "$MAN" "Development/Logs/stage58/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage58-$RUN-manifest.txt" 0

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
old=base64.b64decode(json.load(open(remote))["content"])
entry=(
 "\n========== STAGE 58 QUEUESET / LOGICALLINK REGISTRATION AND OWNERSHIP AUDIT ==========\n"
 "STAGE58_RUN: %s\n"%run+
 "STAGE58_VERSION: %s\n"%version+
 "STAGE58_SCOPE: 24H32 interface registration, queue dispatch-slot resolution, QueueSet/LogicalLink metadata, queue ownership and rollback\n"+
 "STAGE58_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — registration/ownership audit only; no queue activation or hardware-test authorization\n"+
 "STAGE58_LOGS: Development/Logs/stage58/%s/ and unique files directly under Development/Logs/\n"%run+
 "==================================================================\n"
).encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY
upload_one "$OUT/output.log" "Development/output.log" 1

echo
echo "STAGE58_VERSION=$VERSION"
echo "STAGE58_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE58_RUN=$RUN"
echo "STAGE58_LOCAL_OUTPUT=$OUT"
echo "STAGE58_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage58/$RUN"
echo "STAGE58_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE58_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE58_SOURCE_MODIFIED=NO"
echo "STAGE58_BUILD=NOT_RUN"
echo "STAGE58_INSTALL=NOT_RUN"
echo "STAGE58_LOAD=NOT_RUN"
echo "STAGE58_OPENCORE_CHANGE=NONE"
