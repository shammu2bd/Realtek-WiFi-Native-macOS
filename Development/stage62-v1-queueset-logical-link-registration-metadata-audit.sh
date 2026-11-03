#!/bin/bash
# Stage 62 — 24H32 QueueSetInfo_s / LogicalLinkInfo_s registration metadata audit.
# VERSION_MARKER: STAGE62_V1_20261102
# READ ONLY: no driver edits, build, signing, install/load, OpenCore, SIP or NVRAM changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE62_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
STAGE61_RUN="run-20261102-152354-434ec3c3ae26"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage62/$RUN"
TOOLS="$OUT/tools"; PREV61="$OUT/stage61-evidence"; CACHE="$OUT/kc-cache"
mkdir -p "$TOOLS" "$PREV61" "$CACHE"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE62_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }
for t in curl gh python3 shasum grep awk sw_vers uname xcrun wc tr split; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
[[ -f "$BOOTKC" ]] || fail "BootKernelExtensions.kc not found"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "expected 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump not found through selected Xcode"
curl -fsSLo "$TOOLS/kcfile.py" "$UPSTREAM_RAW/kcfile.py"
python3 - "$TOOLS/kcfile.py" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
got=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
want="5d31e8a73e5cb175851e7407529456f223683589"
print("PINNED_KCFILE_GIT_BLOB_SHA="+got)
if got!=want: raise SystemExit("Pinned WTLKcAbi parser mismatch")
PY

# Pin every Stage61 artifact before deriving Stage62 conclusions.
while IFS=' ' read -r name want; do
 [[ -n "$name" ]] || continue
 curl -fsSLo "$PREV61/$name" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage61/$STAGE61_RUN/$name"
 got="$(python3 - "$PREV61/$name" <<'PY2'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY2
)"
 [[ "$got" == "$want" ]] || fail "Stage61 evidence SHA mismatch: $name expected=$want actual=$got"
 echo "STAGE61_EVIDENCE_VERIFIED=$name SHA=$got"
done <<'EOF'
audit-summary.txt 0bd6d1c41871f7a4659c8499265b5533170fd116
manifest.txt 0b02bd57f81c951b0b388d80696662cb03a8b5b6
method-status.txt 4188f32c9fde054a22edbadaf6fdf998100a07e0
queue-command-method-disassembly.txt 0e2edad27bfd9b0346d1d0bc44fbb2cc539fdf43
queue-descriptor-record-matrix.txt 04c68bd635f16bc7a51615031f8950d620ba0818
queueset-classification-jump-tables.txt 7b017c03a4f008ba017a0f40d557132a3f623f2f
queueset-init-disassembly.txt 80d8fd7434a835f3cc6a072edb36419bfcfdd5d6
report.txt a0f0939677919c1057da1308a7b70ae37fb13ebc
source-fingerprint.txt 67bfe72603cd4316bd9a9107de5c97e1c37f625c
vtable-addresspoint-recheck.txt 6825ca8f603c20790e424a765229ab602f24423d
EOF

python3 - "$TOOLS" "$BOOTKC" "$SRC" "$PREV61" "$OUT" "$CACHE" "$OBJDUMP" "$OSVER" "$BUILD" "$ARCH" "$RUN" <<'PY3'
import re,sys,pathlib,subprocess
tools,bootkc,src,prev,out,cache,objdump,osver,build,arch,run=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
srcp=pathlib.Path(src); prevp=pathlib.Path(prev); outp=pathlib.Path(out); cachep=pathlib.Path(cache)
kc=KC(bootkc); issues=[]; owners={}; bodies={}; method_records=[]; all_dis=[]
specs=[
 ("IOSkywalkNetworkInterface","queue_array_registration",r"24registerNetworkInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueue"),
 ("IOSkywalkNetworkInterface","logical_link_registration",r"24registerNetworkInterfaceEPKNS_16RegistrationInfoEP20IOSkywalkLogicalLink"),
 ("IOSkywalkNetworkInterface","network_deregistration",r"26deregisterNetworkInterfaceEj"),
 ("IOSkywalkNetworkInterface","delete_logical_link",r"17deleteLogicalLinkEP20IOSkywalkLogicalLink"),
 ("IOSkywalkEthernetInterface","ethernet_registration_wrapper",r"25registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueue"),
 ("IOSkywalkEthernetInterface","ethernet_deregistration_wrapper",r"27deregisterEthernetInterfaceEj"),
 ("IO80211InfraInterface","infra_registration_wrapper",r"30registerInfraEthernetInterface"),
 ("IOSkywalkQueueSet","queueset_create",r"16createWithQueuesEPP20IOSkywalkPacketQueuemPNS_14QueueSetInfo_sE"),
 ("IOSkywalkQueueSet","queueset_init",r"14initWithQueuesEPP20IOSkywalkPacketQueuemPNS_14QueueSetInfo_sE"),
 ("IOSkywalkQueueSet","queueset_free",r"4freeEv"),
 ("IOSkywalkLogicalLink","logical_link_create",r"18createWithQueueSetEPP17IOSkywalkQueueSetmPNS_17LogicalLinkInfo_sE"),
 ("IOSkywalkLogicalLink","logical_link_init",r"16initWithQueueSetEPP17IOSkywalkQueueSetmPNS_17LogicalLinkInfo_sE"),
 ("IOSkywalkLogicalLink","logical_link_free",r"4freeEv"),
 ("IOSkywalkLogicalLink","logical_link_nexus_info_getter",r"23getLogicalLinkNexusInfoEv"),
]
for cls,label,pat in specs:
 hits=[(va,nm) for va,nm in kc.methods(cls) if re.search(pat,nm)]
 if len(hits)!=1:
  issues.append("METHOD_RESOLUTION_%s_%s_COUNT_%d"%(cls,label,len(hits))); continue
 va,nm=hits[0]; owner=kc.owner(va) or kc.sym_owner.get(va)
 if not owner or owner!=kc.sym_owner.get(va):
  issues.append("METHOD_OWNER_VALIDATION_"+label); continue
 if owner not in owners:
  carved=cachep/(re.sub(r"[^A-Za-z0-9_.-]","_",owner)+".macho")
  kc.carve(owner,str(carved)); owners[owner]=carved
 end=kc.next_sym(va) or va+0x1000
 if end<=va or end>va+0x20000: end=va+0x1000
 p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%va,
                   "--stop-address=0x%x"%end,str(owners[owner])],text=True,capture_output=True)
 count=sum(1 for x in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",x))
 ok=p.returncode==0 and count>0
 method_records.append("METHOD_STATUS class=%s label=%s symbol=%s address=0x%x owner=%s instructions=%d result=%s"%(
  cls,label,nm,va,owner,count,"PASS" if ok else "FAIL"))
 if not ok: issues.append("METHOD_DISASSEMBLY_"+label)
 bodies[label]=p.stdout
 all_dis += ["\n===== METHOD class=%s label=%s symbol=%s address=0x%x ====="%(cls,label,nm,va),
              "OBJDUMP_EXIT=%d INSTRUCTIONS=%d"%(p.returncode,count),
              "DISASSEMBLY_BEGIN",p.stdout[:75000].rstrip(),"DISASSEMBLY_END"]

def norm(s): return re.sub(r"\s+"," ",s.lower())
def has(s,p): return re.search(p,norm(s)) is not None
reg=bodies.get("queue_array_registration","")
qinit=bodies.get("queueset_init","")
qcreate=bodies.get("queueset_create","")
llcreate=bodies.get("logical_link_create","")
llinit=bodies.get("logical_link_init","")
llfree=bodies.get("logical_link_free","")
qfree=bodies.get("queueset_free","")
ndereg=bodies.get("network_deregistration","")
nlink=bodies.get("logical_link_registration","")

# The array-form registration wrapper chooses a 32-bit QueueSet control word,
# builds a separate LogicalLink initializer, creates QueueSet then LogicalLink,
# registers the LogicalLink, and releases local construction references.
caller_checks={
 "QUEUESET_CONTROL_WORD_0x3":has(reg,r"mov dword ptr \[rbp - 0x84\], 0x3"),
 "QUEUESET_CONTROL_WORD_0xb":has(reg,r"mov dword ptr \[rbp - 0x84\], 0xb"),
 "QUEUESET_INFO_POINTER":has(reg,r"lea rdx, \[rbp - 0x84\]"),
 "LOGICAL_LINK_INFO_POINTER":has(reg,r"lea rdx, \[rbp - 0x80\]"),
 "LOGICAL_LINK_INFO_10_QWORD_COPY":has(reg,r"mov ecx, 0xa") and has(reg,r"rep movsq"),
 "LOGICAL_LINK_INFO_FIRST_DWORD_1":has(reg,r"mov dword ptr \[rdx\], 0x1"),
 "QUEUESET_FACTORY_CALL":has(reg,r"call .*createWithQueues"),
 "LOGICAL_LINK_FACTORY_CALL":has(reg,r"call .*createWithQueueSet"),
 "REGISTER_LOGICAL_LINK_OVERLOAD":has(reg,r"call .*registerNetworkInterface.*LogicalLink"),
}
for name,ok in caller_checks.items():
 if not ok: issues.append("REGISTRATION_CALLER_"+name+"_MISSING")

# QueueSet init receives queues/count/control-word pointer in the C++ ABI.
# Only byte 0 bit 3 and the full 32-bit word at offset 0 are read here.
qset_checks={
 "CONTROL_WORD_BIT_0x8_TEST":has(qinit,r"test byte ptr \[rbx\], 0x8"),
 "CONTROL_WORD_FULL_DWORD_READ":has(qinit,r"mov ecx, dword ptr \[rbx\]"),
 "CONTROL_WORD_COPIED_TO_NEXUS_METADATA":has(qinit,r"mov dword ptr \[rax\], ecx"),
 "OPTIONAL_EXTRA_NEXUS_ALLOCATION":has(qinit,r"mov qword ptr \[r14 \+ 0x40\], rax"),
 "CREATE_WITH_QUEUES_ALLOCATION_SIZE_0x80":has(qcreate,r"mov esi, 0x80"),
 "CREATE_WITH_QUEUES_FORWARDS_CONTROL_POINTER":has(qcreate,r"mov rcx, r14"),
}
for name,ok in qset_checks.items():
 if not ok: issues.append("QUEUESET_INFO_"+name+"_MISSING")

# LogicalLink init only consumes the first 32-bit word in this path; do not
# assume the entire caller's 0x50-byte stack staging area is the SDK struct size.
ll_checks={
 "INIT_FORWARDS_INFO_POINTER":has(llcreate,r"mov rcx, r14") and has(llcreate,r"call .*initWithQueueSet"),
 "INIT_READS_FIRST_DWORD":has(llinit,r"mov eax, dword ptr \[rax\]"),
 "FIRST_DWORD_STORED_IN_LINK_NEXUS_INFO":has(llinit,r"mov dword ptr \[rdi\], eax"),
 "LINK_STORES_BACK_POINTER":has(llinit,r"mov qword ptr \[rdi \+ 0x8\], rbx"),
 "QUEUESET_ARRAY_ALLOCATION":has(llinit,r"mov qword ptr \[rbx \+ 0x10\], rax"),
 "LINK_QUEUESET_COUNT_STORED":has(llinit,r"mov qword ptr \[rbx \+ 0x28\], r15"),
 "QUEUESET_LINK_ATTACHMENT":has(llinit,r"call .*setLogicalLink"),
 "QUEUESET_RETAIN":has(llinit,r"call qword ptr \[rax \+ 0x20\]"),
 "CREATE_WITH_QUEUESET_ALLOCATION_SIZE_0x30":has(llcreate,r"mov esi, 0x30"),
}
for name,ok in ll_checks.items():
 if not ok: issues.append("LOGICALLINK_INFO_"+name+"_MISSING")

# Count accepted by the observed LogicalLink initializer is 1..16 inclusive:
# rcx = count - 17; unsigned compare against -16 rejects values outside range.
count_check=has(llinit,r"lea rcx, \[rdx - 0x11\]") and has(llinit,r"cmp rcx, -0x10")
if not count_check: issues.append("LOGICAL_LINK_QUEUESET_COUNT_GUARD_NOT_FOUND")
# QueueSetInfo_s / LogicalLinkInfo_s declarations remain absent from the SDK
# and driver source; enumerate exact occurrences and declaration-like hits.
source_files=sorted(p for p in srcp.rglob("*") if p.is_file() and p.suffix.lower() in (".h",".hpp",".hh",".cpp",".cc",".cxx"))
refs=[]
for p in source_files:
 try: lines=p.read_text(errors="replace").splitlines()
 except Exception: continue
 rel=str(p.relative_to(srcp))
 for i,line in enumerate(lines):
  if "QueueSetInfo_s" in line or "LogicalLinkInfo_s" in line:
   refs.append("%s:%d:%s"%(rel,i+1,line.strip()[:240]))
decls=[x for x in refs if re.search(r"\b(struct|class|typedef)\b",x)]
inventory=[
 "STAGE62_PRIVATE_REGISTRATION_METADATA_SOURCE_INVENTORY",
 "SOURCE_FILES_SCANNED=%d"%len(source_files),
 "OPAQUE_TYPE_REFERENCES=%d"%len(refs),
 "DECLARATION_LIKE_LINES=%d"%len(decls),
 "NOTE=declaration-like text is reviewed verbatim below; it is not accepted as a definition without a concrete type body"]
inventory+=refs[:100]
if len(refs)>100: inventory.append("TRUNCATED_REFERENCES=%d"%(len(refs)-100))
(outp/"private-metadata-source-inventory.txt").write_text("\n".join(inventory)+"\n")

queue_info=[
 "STAGE62_QUEUESET_INFO_S_CALLER_CALLEE_CROSSWALK",
 "CALLER=IOSkywalkNetworkInterface queue-array registerNetworkInterface overload",
 "STACK_WORD_ADDRESS=rbp-0x84 (4-byte local is explicitly written before factory call)",
 "CONTROL_WORD_VALUES=0x3 when WMM sched-model check is false; 0xb when true",
 "FACTORY=IOSkywalkQueueSet::createWithQueues(queues, queueCount, QueueSetInfo_s*)",
 "CALLEE=IOSkywalkQueueSet::initWithQueues(queues, queueCount, QueueSetInfo_s*)",
 "OBSERVED_READS=byte 0 bit 3 test; 32-bit word at offset 0 copied to QueueSet nexus metadata",
 "OBSERVED_EFFECT=bit 3 gates optional extra QueueSet allocation; other bits are passed through in the copied dword",
 "SIZE_LIMIT=at least 4 readable bytes are required by this call path; complete private struct size/layout is not proven",
 "SDK_DECLARATION=not found in Stage61 source inventory; no guessed public layout is emitted",
 ""]+["CHECK=%s RESULT=%s"%(k,"PASS" if v else "FAIL") for k,v in caller_checks.items()]+[
 ""]+["CHECK=%s RESULT=%s"%(k,"PASS" if v else "FAIL") for k,v in qset_checks.items()]
(outp/"queueset-info-word-crosswalk.txt").write_text("\n".join(queue_info)+"\n")

logical_info=[
 "STAGE62_LOGICALLINK_INFO_S_CALLER_CALLEE_CROSSWALK",
 "CALLER=IOSkywalkNetworkInterface queue-array registerNetworkInterface overload",
 "STAGING_BUFFER=rbp-0x80; caller copies 10 qwords (0x50 bytes) from a static report-channel-name pointer table",
 "FIRST_WORD=caller overwrites the first 32-bit word with 1 before LogicalLink::createWithQueueSet",
 "FACTORY=IOSkywalkLogicalLink::createWithQueueSet(queueSetArray, queueSetCount=1, LogicalLinkInfo_s*)",
 "CALLEE=IOSkywalkLogicalLink::initWithQueueSet(queueSetArray, queueSetCount, LogicalLinkInfo_s*)",
 "OBSERVED_READ=initWithQueueSet reads the first 32-bit word at info+0 and stores it in the link's nexus-info record",
 "UNREAD_BYTES=the selected init method does not visibly consume the remaining 0x4c bytes of the caller's 0x50-byte staging buffer",
 "SIZE_LIMIT=0x50 bytes are staged by the caller; the private type's formal sizeof/alignment is not established by these observations",
 "LINK_COUNT=caller passes one QueueSet; initializer's observed accepted count range is 1..16",
 "LIFETIME=initializer retains each QueueSet, attaches the LogicalLink pointer, and records per-QueueSet nexus info",
 ""]+["CHECK=%s RESULT=%s"%(k,"PASS" if v else "FAIL") for k,v in ll_checks.items()]
(outp/"logical-link-info-crosswalk.txt").write_text("\n".join(logical_info)+"\n")

life=[
 "STAGE62_REGISTRATION_AND_ROLLBACK_LIFECYCLE_MATRIX",
 "APPLE_SEQUENCE=queue-array registration -> QueueSet create -> LogicalLink create -> registerNetworkInterface(LogicalLink overload)",
 "QUEUESET_FACTORY_ALLOCATES_OBJECT_AND_CALLS_INIT="+("PASS" if has(qcreate,r"call .*initWithQueues") else "FAIL"),
 "LOGICALLINK_FACTORY_ALLOCATES_OBJECT_AND_CALLS_INIT="+("PASS" if has(llcreate,r"call .*initWithQueueSet") else "FAIL"),
 "LOGICALLINK_INIT_RETAINS_AND_ATTACHES_QUEUESETS="+("PASS" if ll_checks["QUEUESET_RETAIN"] and ll_checks["QUEUESET_LINK_ATTACHMENT"] else "FAIL"),
 "LOGICALLINK_FREE_DETACHES_QUEUESETS="+("PASS" if has(llfree,r"call .*setLogicalLink") else "REVIEW_REQUIRED"),
 "QUEUESET_FREE_DETACHES_QUEUES="+("PASS" if has(qfree,r"call .*setQueueSet") else "REVIEW_REQUIRED"),
 "NETWORK_INTERFACE_DEREGISTRATION_PRESENT="+("PASS" if bool(ndereg) else "FAIL"),
 "NETWORK_INTERFACE_LOGICAL_LINK_OVERLOAD_PRESENT="+("PASS" if bool(nlink) else "FAIL"),
 "IO80211_INFRA_REGISTRATION_WRAPPER_PRESENT="+("PASS" if bool(bodies.get("infra_registration_wrapper")) else "FAIL"),
 "NATIVE_DRIVER_CURRENTLY_CALLS_APPLE_REGISTRATION=NO (Stage61 predecessor matrix)",
 "ACTIVATION_GATE=BLOCKED; this report describes Apple's observed transaction, not a driver implementation"]
(outp/"registration-lifecycle-matrix.txt").write_text("\n".join(life)+"\n")

(outp/"method-disassembly.txt").write_text("STAGE62_APPLE_REGISTRATION_AND_PRIVATE_METADATA_METHODS\n"+"\n".join(all_dis)+"\n")
(outp/"method-status.txt").write_text("\n".join(method_records)+"\n")
fp=(prevp/"source-fingerprint.txt").read_text(errors="replace")
fp_pass=fp.count("RESULT=MATCH")==3 and "STAGE43_SOURCE_CONTINUITY=PASS" in fp
if not fp_pass: issues.append("STAGE43_SOURCE_CONTINUITY_FAIL")
(outp/"source-fingerprint.txt").write_text(fp)

summary=[
 "STAGE62_QUEUESET_LOGICALLINK_REGISTRATION_METADATA_AUDIT",
 "TARGET=%s/%s/%s"%(osver,build,arch),
 "STAGE61_PREDECESSOR_EVIDENCE=10/10_PINS_PASS",
 "STAGE43_SOURCE_CONTINUITY="+("PASS" if fp_pass else "FAIL"),
 "APPLE_METHODS_DISASSEMBLED=%d/%d"%(len(method_records),len(specs)),
 "QUEUESET_CONTROL_WORD_CALLER_CHECKS=%d/%d"%(sum(caller_checks.values()),len(caller_checks)),
 "QUEUESET_CONTROL_WORD_CALLEE_CHECKS=%d/%d"%(sum(qset_checks.values()),len(qset_checks)),
 "LOGICALLINK_INFO_CALLER_CALLEE_CHECKS=%d/%d"%(sum(ll_checks.values()),len(ll_checks)),
 "QUEUESET_CONTROL_WORD_VALUES=0x3_OR_0xb;_BIT_3_ENABLES_OPTIONAL_EXTRA_NEXUS_ALLOCATION",
 "QUEUESET_INFO_MINIMUM_OBSERVED_READ=4_BYTES;_FULL_PRIVATE_SIZE_UNRESOLVED",
 "LOGICALLINK_INFO_CALLER_STAGING=0x50_BYTES;_CALLEE_READS_FIRST_DWORD_ONLY",
 "LOGICALLINK_INFO_FORMAL_SIZE=UNRESOLVED",
 "LOGICALLINK_INIT_QUEUESET_COUNT=1 (observed accepted range 1..16)",
 "PRIVATE_TYPE_DECLARATIONS=NOT_FOUND_IN_SCANNED_DRIVER_AND_SDK_SOURCES" if not decls else "PRIVATE_TYPE_DECLARATIONS=REVIEW_REQUIRED",
 "NATIVE_DRIVER_REGISTRATION=NOT_IMPLEMENTED",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "RESULT="+("PASS" if not issues and len(method_records)==len(specs) and all(caller_checks.values()) and all(qset_checks.values()) and all(ll_checks.values()) and count_check else "REVIEW_REQUIRED")]
summary += ["ISSUE="+x for x in issues]
(outp/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 62 QUEUESET / LOGICALLINK REGISTRATION METADATA AUDIT ==========",
 "VERSION=STAGE62_V1_20261102","RUN="+run,"TARGET=%s/%s/%s"%(osver,build,arch),
 "PREDECESSOR=Stage61 V1 "+(prevp/"manifest.txt").read_text().split("RUN=")[1].splitlines()[0],
 "PURPOSE=trace the private QueueSetInfo_s and LogicalLinkInfo_s values passed by Apple's queue-array registration wrapper",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 "QUEUESET_INFO=Apple stages a 32-bit control word with values 0x3 or 0xb; QueueSet init tests bit 3 and copies the whole dword.",
 "QUEUESET_INFO_LIMIT=the call path proves at least a 4-byte readable word; exact private structure sizeof/layout is not proven.",
 "LOGICALLINK_INFO=caller stages 0x50 bytes from a static 10-qword table and overwrites the first dword with 1; selected initializer reads that first dword.",
 "LOGICALLINK_INFO_LIMIT=the 0x50-byte staging size is observed, but the full formal private structure size/alignment is not proven by these method bodies.",
 "TRANSACTION=QueueSet creation precedes LogicalLink creation, then the LogicalLink overload performs network-interface registration.",
 "LIFETIME=LogicalLink initializer retains/attaches QueueSets; free/deregister paths are included for review.",
 "ACTIVATION_GATE=BLOCKED — native driver has not connected RegistrationInfo, queue arrays, pools, callbacks, packet ownership or rollback to this Apple transaction.",
 "",
 "SOURCE_TREE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN","========== END STAGE 62 =========="]
(outp/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
if issues or len(method_records)!=len(specs) or not all(caller_checks.values()) or not all(qset_checks.values()) or not all(ll_checks.values()) or not count_check:
 raise SystemExit("Stage62 review required; do not continue to implementation")
PY3

cat "$OUT/audit-summary.txt"
echo
echo "QueueSetInfo crosswalk: $OUT/queueset-info-word-crosswalk.txt"
echo "LogicalLinkInfo crosswalk: $OUT/logical-link-info-crosswalk.txt"
echo "Registration lifecycle matrix: $OUT/registration-lifecycle-matrix.txt"
echo "Source inventory: $OUT/private-metadata-source-inventory.txt"
echo "Method disassembly: $OUT/method-disassembly.txt"

github_sha(){ gh api "repos/$REPO/contents/$1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha",""))' 2>/dev/null || true; }
blob_sha(){ python3 - "$1" <<'PY4'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY4
}
PAYLOAD_INDEX=0
upload_one(){
 local file="$1" path="$2" allow="$3" expected old payload response put got
 expected="$(blob_sha "$file")"; old="$(github_sha "$path")"
 if [[ "$allow" == 1 ]]; then
  [[ "$old" =~ ^[0-9a-f]{40}$ ]] || { echo "UPDATE_TARGET_SHA_NOT_FOUND=$path" >> "$UPLOAD_ERROR"; return 1; }
 elif [[ -n "$old" ]]; then
  if [[ "$old" == "$expected" ]]; then echo "IDENTICAL_EXISTING=$path SHA=$old" >> "$OUT/upload-verification.txt"; return 0; fi
  echo "REFUSE_OVERWRITE_DIFFERENT_FILE=$path REMOTE=$old LOCAL=$expected" >> "$UPLOAD_ERROR"; return 1
 fi
 PAYLOAD_INDEX=$((PAYLOAD_INDEX+1)); payload="$OUT/payload-$PAYLOAD_INDEX.json"; response="$OUT/response-$PAYLOAD_INDEX.json"
 python3 - "$file" "$old" "$payload" <<'PY5'
import base64,json,pathlib,sys
f,sha,dst=sys.argv[1:]
obj={"message":"Add Stage62 read-only QueueSet and LogicalLink registration metadata audit","content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha: obj["sha"]=sha
pathlib.Path(dst).write_text(json.dumps(obj),encoding="utf-8")
PY5
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
 put="$(python3 - "$response" <<'PY6'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY6
)"
 got="$(github_sha "$path")"
 [[ "$put" == "$got" && "$got" == "$expected" ]] || { echo "READBACK_SHA_MISMATCH=$path PUT=$put GOT=$got EXPECTED=$expected" >> "$UPLOAD_ERROR"; return 1; }
 echo "VERIFIED=$path SHA=$got" >> "$OUT/upload-verification.txt"
}
MAN="$OUT/manifest.txt"
{
 echo "STAGE=62"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=read-only QueueSetInfo_s and LogicalLinkInfo_s registration metadata audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage61 V1 $STAGE61_RUN"
 echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"; echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"
upload_artifact(){
 local file="$1" base group root
 base="$(basename "$file")"; group="Development/Logs/stage62/$RUN/$base"; root="Development/Logs/stage62-$RUN-$base"
 upload_one "$file" "$group" 0; upload_one "$file" "$root" 0
 echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/method-status.txt "$OUT"/method-disassembly.txt "$OUT"/queueset-info-word-crosswalk.txt "$OUT"/logical-link-info-crosswalk.txt "$OUT"/registration-lifecycle-matrix.txt "$OUT"/private-metadata-source-inventory.txt; do
 [[ -f "$f" ]] || fail "missing audit artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then upload_artifact "$f"; else split -b 220k "$f" "$f.part-"; for part in "$f".part-*; do upload_artifact "$part"; done; fi
done
upload_one "$MAN" "Development/Logs/stage62/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage62-$RUN-manifest.txt" 0
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY7'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
old=base64.b64decode(json.load(open(remote))["content"])
entry=(
 "\n========== STAGE 62 QUEUESET / LOGICALLINK REGISTRATION METADATA AUDIT ==========\n"
 "STAGE62_RUN: %s\n"%run+
 "STAGE62_VERSION: %s\n"%version+
 "STAGE62_SCOPE: 24H32 QueueSetInfo_s control-word and LogicalLinkInfo_s caller/callee transaction/ownership trace\n"+
 "STAGE62_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — private registration metadata traced; native queue registration and TX/RX packet ownership remain open\n"+
 "STAGE62_LOGS: Development/Logs/stage62/%s/ and unique files directly under Development/Logs/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY7
upload_one "$OUT/output.log" "Development/output.log" 1
echo
echo "STAGE62_VERSION=$VERSION"
echo "STAGE62_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE62_RUN=$RUN"
echo "STAGE62_LOCAL_OUTPUT=$OUT"
echo "STAGE62_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage62/$RUN"
echo "STAGE62_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE62_SOURCE_MODIFIED=NO"
echo "STAGE62_BUILD=NOT_RUN"
echo "STAGE62_INSTALL=NOT_RUN"
echo "STAGE62_LOAD=NOT_RUN"
echo "STAGE62_OPENCORE_CHANGE=NONE"
echo "STAGE62_ACTIVATION_GATE=BLOCKED"
