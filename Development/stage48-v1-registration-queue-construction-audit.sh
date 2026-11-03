#!/bin/bash
# Stage 48 — 24H32 registration bridge, queue construction and callback contract audit.
# VERSION_MARKER: STAGE48_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
echo "STAGE48_SCRIPT_VERSION=STAGE48_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
EXPECTED_STAGE43_CPP="2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b"
EXPECTED_ABI_HEADER="63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb"
EXPECTED_INTERFACE_HEADER="9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4"

STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage48/$RUN"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$TOOLS" "$CACHE"
trap 'rc=$?; trap - ERR; echo "STAGE48_ERROR=exit:$rc line:$LINENO" >&2; if [[ -f "$UPLOAD_ERROR" ]]; then tail -60 "$UPLOAD_ERROR" >&2; fi; exit "$rc"' ERR

fail() { echo "ERROR: $*" >&2; exit 2; }
for tool in curl gh python3 shasum split grep awk sw_vers uname xcrun kmutil file; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool missing: $tool"
done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 project not found at $SRC"
[[ -f "$BOOTKC" ]] || fail "BootKernelExtensions.kc not found"
[[ -f "$SRC/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp" ]] || fail "native interface source missing"
[[ -f "$SRC/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp" ]] || fail "24H32 ABI header missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run gh auth login"

BUILD="$(sw_vers -buildVersion)"
OSVER="$(sw_vers -productVersion)"
ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "target mismatch: expected macOS 15.8.1 / 24H32 / x86_64; got $OSVER / $BUILD / $ARCH"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump not found through the selected Xcode"
export LLVM_OBJDUMP="$OBJDUMP"

curl -fsSLo "$TOOLS/kcfile.py" "$UPSTREAM_RAW/kcfile.py"
curl -fsSLo "$TOOLS/disasm.py" "$UPSTREAM_RAW/disasm.py"
python3 - "$TOOLS" > "$OUT/upstream-verification.txt" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={"kcfile.py":"5d31e8a73e5cb175851e7407529456f223683589",
          "disasm.py":"d7777456f4700bc9815e765aed2313093ac133e9"}
for name,want in expected.items():
    data=(root/name).read_bytes()
    got=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
    print("UPSTREAM_GIT_BLOB_%s=%s"%(name,"MATCH" if got==want else "MISMATCH"))
    print("UPSTREAM_GIT_BLOB_SHA_%s=%s"%(name,got))
    if got!=want: raise SystemExit("Pinned upstream file verification failed: "+name)
PY

{
  echo "========== STAGE 48: 24H32 REGISTRATION / QUEUE-CONSTRUCTION / CALLBACK CONTRACT =========="
  echo "script_version=STAGE48_V1_20261102"
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "product_version=$OSVER"
  echo "build_version=$BUILD"
  echo "architecture=$ARCH"
  echo "source_root=$SOURCE_ROOT"
  echo "local_run_output=$OUT"
  echo "boot_kernel_collection=$BOOTKC"
  echo "llvm_objdump=$OBJDUMP"
  echo "upstream_toolkit=watchthelight-labs/WTLKcAbi"
  echo "upstream_commit=$UPSTREAM_COMMIT"
  echo "predecessor=Stage47 run-20261102-113242-ae14b45342fc"
  echo "scope=IO80211InfraInterface::registerInfraEthernetInterface, IOSkywalkEthernetInterface registration wrappers, queue-set construction, packet-queue constructors and TX/RX callback-bearing methods"
  echo "SOURCE_MODIFIED=NO"
  echo "BUILD=NOT_RUN"
  echo
} > "$REPORT"
cat "$OUT/upstream-verification.txt" >> "$REPORT"

python3 - "$SRC" "$EXPECTED_STAGE43_CPP" "$EXPECTED_ABI_HEADER" "$EXPECTED_INTERFACE_HEADER" > "$OUT/source-fingerprint.txt" <<'PY'
import hashlib,pathlib,sys
src=pathlib.Path(sys.argv[1])
items={
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":sys.argv[2],
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":sys.argv[3],
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":sys.argv[4],
}
bad=[]
for rel,want in items.items():
    p=src/rel
    got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
    print("SOURCE_FILE=%s"%rel)
    print("EXPECTED_SHA256=%s"%want)
    print("ACTUAL_SHA256=%s"%got)
    print("SOURCE_FINGERPRINT=%s"%("MATCH" if got==want else "MISMATCH"))
    if got!=want: bad.append(rel)
print("STAGE43_SOURCE_CONTINUITY="+("PASS" if not bad else "REVIEW_REQUIRED"))
if bad: raise SystemExit("Stage43 source baseline mismatch; stop before ABI conclusions")
PY
cat "$OUT/source-fingerprint.txt" >> "$REPORT"

# Capture the ABI declarations and native call-sites most relevant to registration.
python3 - "$SRC" > "$OUT/source-context.txt" <<'PY'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1])
required=[
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
]
extra=[]
name_re=re.compile(r"(controller|interface|queue|packet|datapath|wcl)",re.I)
for p in sorted((root/"src").rglob("*")):
    if p.is_file() and p.suffix.lower() in (".cpp",".hpp",".h",".c") and name_re.search(p.name):
        rel=str(p.relative_to(root))
        if rel not in required: extra.append(rel)
files=required+extra[:45]
terms=re.compile(
 r"registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|"
 r"initRegistrationInfo|deregisterEthernetInterface|deregisterNetworkInterface|"
 r"IOSkywalkEthernetInterface|IOSkywalkNetworkInterface|IOSkywalkQueueSet|"
 r"IOSkywalkLogicalLink|IOSkywalkPacketQueue|IOSkywalk(TxSubmission|RxSubmission|TxCompletion|RxCompletion)Queue|"
 r"IOSkywalkPacketBufferPool|initWithPool|createWithQueues|initWithQueues|"
 r"packetCompletion|bufferCompletion|completePackets|enqueuePackets|"
 r"clearRegistrationInfo|RegistrationInfo|QueueSetInfo|LogicalLinkInfo"
)
print("SOURCE_CONTEXT_FILE_COUNT=%d"%len(files))
for rel in files:
    p=root/rel
    print("\n===== SOURCE_CONTEXT %s ====="%rel)
    if not p.is_file():
        print("STATUS=MISSING")
        continue
    lines=p.read_text(errors="replace").splitlines()
    hits=[i for i,line in enumerate(lines) if terms.search(line)]
    spans=[]
    for i in hits:
        a=max(0,i-6); b=min(len(lines),i+11)
        if spans and a<=spans[-1][1]: spans[-1]=(spans[-1][0],max(spans[-1][1],b))
        else: spans.append((a,b))
    total=0
    for a,b in spans:
        if total>=180: break
        print("--- lines %d-%d ---"%(a+1,b))
        for n in range(a,min(b,a+min(30,180-total))):
            print("%5d %s"%(n+1,lines[n])); total+=1
    print("SOURCE_CONTEXT_HITS=%d"%len(hits))
PY

python3 - "$TOOLS" "$BOOTKC" "$CACHE" "$OBJDUMP" > "$OUT/abi-audit.txt" <<'PY'
import os,pathlib,re,subprocess,sys
tools,kc_path,cache,objdump=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
import disasm
os.environ["LLVM_OBJDUMP"]=objdump
kc=KC(kc_path)
parser=disasm.Disassembler(kc,cache)
print("BOOTKC_SHA256="+kc.sha256())
print("FILESET_ENTRY_COUNT=%d"%len(kc.entries))

classes={
 "IO80211InfraInterface":r"(registerInfraEthernetInterface|start|stop|free)",
 "IOSkywalkEthernetInterface":r"(initRegistrationInfo|registerEthernetInterface|deregisterEthernetInterface|start|stop|free)",
 "IOSkywalkNetworkInterface":r"(registerNetworkInterface|registerNetworkInterfaceWithLogicalLink|deregisterNetworkInterface|deregisterLogicalLink|start|stop|free)",
 "IOSkywalkQueueSet":r"(createWithQueues|initWithQueues|initialize|isWMMSchedModelCapable|setLogicalLink|getQueueSetNexusInfo|free)",
 "IOSkywalkLogicalLink":r"(createWithQueueSet|initWithQueueSet|getQueueSet|getLogicalLinkNexusInfo|setInterface|setDefaultLogicalLink|free)",
 "IOSkywalkPacketQueue":r"(initWithPool|initialize|setQueueSet|getQueueSet|getPacketBufferPool|setPacketBufferPool|packetCompletion|bufferCompletion|free)",
 "IOSkywalkTxSubmissionQueue":r"(initWithPool|initialize|packetSubmission|packetCompletion|free|submit|enqueue|dequeue|complete)",
 "IOSkywalkRxSubmissionQueue":r"(initWithPool|initialize|packetSubmission|packetCompletion|free|submit|enqueue|dequeue|complete)",
 "IOSkywalkTxCompletionQueue":r"(initWithPool|initialize|completePackets|enqueuePackets|free|submit|dequeue)",
 "IOSkywalkRxCompletionQueue":r"(initWithPool|initialize|enqueuePackets|free|complete|dequeue)",
 "IOSkywalkPacketBufferPool":r"(initWithName|releaseAllPackets|releaseAllMemorySegments|allocatePacket|deallocatePacket|completePreparedPacket|free|release)",
 "AppleBCMWLANSkywalkInterface":r"(start|stop|register|free)",
}
resolved=[]
known_addresses=set()
dynamic_additions=0
class_methods={}

def add_target(label,va,sym):
    global dynamic_additions
    owner=kc.owner(va)
    sym_owner=kc.sym_owner.get(va)
    if not owner or not sym_owner or owner!=sym_owner:
        print("TARGET_OWNER_VALIDATION_FAIL label=%s address=0x%x symbol_owner=%s address_owner=%s"%(label,va,sym_owner or "UNKNOWN",owner or "UNKNOWN"))
        return False
    segs=[seg for seg in kc.entry_segs.get(owner,[]) if seg[1]<=va<seg[1]+seg[2] and (seg[5]&4)]
    if not segs:
        print("TARGET_NOT_EXECUTABLE label=%s address=0x%x owner=%s"%(label,va,owner))
        return False
    if va in known_addresses: return False
    end=kc.next_sym(va) or (va+0x1000)
    if end<=va or end>va+0x5000: end=va+0x1000
    resolved.append((label,sym,va,owner,end))
    known_addresses.add(va)
    dynamic_additions+=1
    return True

print("\n--- Registration bridge and constructor symbol discovery ---")
for cls,pattern in classes.items():
    print("CLASS_SCAN=%s"%cls)
    try: methods=kc.methods(cls)
    except Exception as e:
        print("CLASS_SCAN_%s=UNAVAILABLE:%s"%(cls,str(e)))
        continue
    hits=[(va,nm) for va,nm in methods if re.search(pattern,nm)]
    class_methods[cls]=hits
    print("CLASS_METHOD_MATCH_COUNT_%s=%d"%(cls,len(hits)))
    for idx,(va,nm) in enumerate(hits):
        owner=kc.owner(va) or kc.sym_owner.get(va) or "UNKNOWN"
        print("CLASS_METHOD class=%s address=0x%x owner=%s symbol=%s"%(cls,va,owner,nm))
        limit=36 if cls in ("IO80211InfraInterface","IOSkywalkEthernetInterface","IOSkywalkNetworkInterface") else 18
        if idx<limit: add_target("%s.method_%02d"%(cls,idx),va,nm)

print("\n--- Queue constructor / callback-bearing symbol signatures ---")
for cls in ("IOSkywalkPacketQueue","IOSkywalkTxSubmissionQueue","IOSkywalkRxSubmissionQueue",
            "IOSkywalkTxCompletionQueue","IOSkywalkRxCompletionQueue"):
    for va,nm in class_methods.get(cls,[]):
        if "initWithPool" in nm or any(x in nm for x in ("packetCompletion","bufferCompletion","completePackets","enqueuePackets")):
            print("CALLBACK_SIGNATURE class=%s address=0x%x symbol=%s"%(cls,va,nm))

global_pattern=re.compile(
 r"(registerInfraEthernetInterface|IOSkywalkEthernetInterface|IOSkywalkNetworkInterface|"
 r"IOSkywalkQueueSet|IOSkywalkLogicalLink|IOSkywalkPacketQueue|"
 r"IOSkywalk(TxSubmission|RxSubmission|TxCompletion|RxCompletion)Queue|AppleBCMWLANSkywalkInterface)"
)
method_pattern=re.compile(
 r"(register|deregister|initRegistrationInfo|initWithPool|createWithQueues|initWithQueues|"
 r"initialize|setQueueSet|setLogicalLink|getQueueSet|setInterface|setDefaultLogicalLink|"
 r"packetCompletion|bufferCompletion|completePackets|enqueuePackets|isWMMSchedModelCapable)"
)
global_hits=[]
for nm,va in kc.byname.items():
    if not nm.startswith("__ZN") or not global_pattern.search(nm) or not method_pattern.search(nm): continue
    owner=kc.owner(va) or kc.sym_owner.get(va) or "UNKNOWN"
    if owner not in ("com.apple.iokit.IOSkywalkFamily","com.apple.iokit.IO80211Family"): continue
    segs=[seg for seg in kc.entry_segs.get(owner,[]) if seg[1]<=va<seg[1]+seg[2] and (seg[5]&4)]
    if segs: global_hits.append((va,nm,owner))
global_hits=sorted(set(global_hits))
print("GLOBAL_REGISTRATION_QUEUE_SYMBOL_MATCHES=%d"%len(global_hits))
for idx,(va,nm,owner) in enumerate(global_hits):
    print("GLOBAL_REGISTRATION_QUEUE_SYMBOL address=0x%x owner=%s symbol=%s"%(va,owner,nm))
    if idx<120: add_target("global_registration_queue_%03d"%idx,va,nm)

print("\n--- Registration / queue callback vtable mapping ---")
for cls in classes:
    try: vt=kc.vtable(cls)
    except Exception as e:
        print("VTABLE_%s=ERROR:%s"%(cls,str(e))); continue
    if vt is None:
        print("VTABLE_%s=NOT_FOUND"%cls); continue
    print("VTABLE_%s_ENTRIES=%d"%(cls,len(vt)))
    count=0
    for idx,(_word,_raw,tgt,nm) in enumerate(vt):
        if re.search(r"(register|initWithPool|packetCompletion|bufferCompletion|completePackets|enqueuePackets|setQueueSet|setLogicalLink|freeEv|startEP9IOService|stopEP9IOService)",nm or "",re.I):
            owner=kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"
            print("VTABLE_MATCH class=%s offset=0x%x index=%d target=0x%x owner=%s symbol=%s"%(cls,idx*8,idx,tgt,owner,nm))
            count+=1
    print("VTABLE_MATCH_COUNT_%s=%d"%(cls,count))

print("DYNAMIC_METHOD_TARGETS_ADDED=%d"%dynamic_additions)
print("\n--- Fileset-aware method disassembly ---")
owners=sorted({item[3] for item in resolved})
for owner in owners:
    safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
    carved=pathlib.Path(cache)/(safe+".macho")
    kc.carve(owner,str(carved))
    print("CARVED_OWNER=%s"%owner)
    print("CARVED_BYTES=%d"%carved.stat().st_size)
    print("CARVED_FILE_TYPE="+subprocess.run(["file",str(carved)],text=True,capture_output=True).stdout.strip())
passes=0
failures=0
for label,sym,va,owner,end in resolved:
    safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
    carved=pathlib.Path(cache)/(safe+".macho")
    print("\n=== METHOD %s ==="%label)
    print("SYMBOL=%s"%sym)
    print("ADDRESS=0x%x"%va)
    print("OWNER=%s"%owner)
    print("RANGE=0x%x..0x%x"%(va,end))
    attempts=[
      ["-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved)],
      ["-d","--no-show-raw-insn","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved)],
      ["-d","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved)],
    ]
    success=False
    for idx,args in enumerate(attempts,1):
        p=subprocess.run([objdump]+args,text=True,capture_output=True)
        parsed_addrs,parsed_ins=parser._parse(p.stdout)
        print("OBJDUMP_ATTEMPT_%d_EXIT=%d"%(idx,p.returncode))
        print("OBJDUMP_ATTEMPT_%d_INSTRUCTIONS=%d"%(idx,len(parsed_addrs)))
        if p.stderr.strip(): print("OBJDUMP_ATTEMPT_%d_STDERR=%s"%(idx,p.stderr.strip()[:1800]))
        if p.stdout.strip():
            for line in p.stdout.splitlines():
                m=re.search(r"\bcall[q]?\s+.*<([^>]+)>",line)
                if m: print("DIRECT_CALL_EDGE=%s"%m.group(1))
            print("OBJDUMP_ATTEMPT_%d_STDOUT_BEGIN"%idx)
            print(p.stdout[:16000].rstrip())
            print("OBJDUMP_ATTEMPT_%d_STDOUT_END"%idx)
        if p.returncode==0 and parsed_addrs:
            print("METHOD_DISASSEMBLY_%s=PASS"%label)
            success=True
            passes+=1
            break
    if not success:
        print("METHOD_DISASSEMBLY_%s=REVIEW_REQUIRED"%label)
        failures+=1

print("\n--- Audit totals ---")
print("METHODS_REQUESTED=%d"%len(resolved))
print("METHODS_RESOLVED=%d"%passes)
print("METHODS_REVIEW_REQUIRED=%d"%failures)
print("KERNEL_COLLECTION_OPEN_MODE=READ_ONLY")
PY

{
  echo
  echo "--- Source and ABI evidence ---"
  cat "$OUT/source-context.txt"
  echo
  cat "$OUT/abi-audit.txt"
  echo
  echo "--- Runtime context ---"
  kmutil showloaded --list-only 2>&1 | grep -E -i 'IO80211Family|IOSkywalkFamily|IONetworkingFamily|AppleBCMWLAN' | head -100 || true
  echo
  echo "--- Safety boundary ---"
  echo "SOURCE_TREE_MODIFIED=NO"
  echo "BUILD=NOT_RUN"
  echo "CODESIGN=NOT_RUN"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
  echo "SIP_NVRAM_MODIFIED=NO"
  echo "HARDWARE_TEST=NOT_RUN"
  echo "SYSTEM_FILES_MODIFIED=NO"
  echo "LOCAL_RUN_FOLDER=$OUT"
  echo "========== END STAGE 48 =========="
} >> "$REPORT"

split -b 220k "$REPORT" "$OUT/report-"
split -b 220k "$OUT/source-context.txt" "$OUT/source-context-"
split -b 220k "$OUT/abi-audit.txt" "$OUT/abi-audit-"

PAYLOAD_INDEX=0
github_contents_sha() {
  local remote_path="$1" raw
  raw="$(gh api "repos/$REPO/contents/$remote_path" 2>/dev/null || true)"
  printf '%s' "$raw" | python3 -c '
import json,re,sys
try: obj=json.load(sys.stdin)
except Exception: raise SystemExit(0)
sha=obj.get("sha","") if isinstance(obj,dict) else ""
if isinstance(sha,str) and re.fullmatch(r"[0-9a-f]{40}",sha): print(sha)
'
}

upload_file() {
  local local_file="$1" remote_path="$2" message="$3" allow_update="$4"
  local old="" payload response put got local_blob
  local_blob="$(python3 - "$local_file" <<'PY2'
import hashlib,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest())
PY2
)"
  old="$(github_contents_sha "$remote_path")"
  if [[ "$allow_update" == "1" ]]; then
    [[ "$old" =~ ^[0-9a-f]{40}$ ]] || { echo "UPDATE_TARGET_SHA_NOT_FOUND_OR_INVALID=$remote_path" >> "$UPLOAD_ERROR"; return 1; }
  else
    if [[ -n "$old" ]]; then
      if [[ "$old" == "$local_blob" ]]; then
        UPLOAD_SHA="$old"
        echo "EXISTING_IDENTICAL_FILE_ACCEPTED=$remote_path SHA=$old" >> "$OUT/upload-verification.txt"
        return 0
      fi
      echo "REFUSING_TO_OVERWRITE_DIFFERENT_FILE=$remote_path EXISTING_SHA=$old LOCAL_SHA=$local_blob" >> "$UPLOAD_ERROR"
      return 1
    fi
  fi

  PAYLOAD_INDEX=$((PAYLOAD_INDEX+1))
  payload="$OUT/payload-$PAYLOAD_INDEX.json"
  response="$OUT/response-$PAYLOAD_INDEX.json"
  python3 - "$local_file" "$old" "$message" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,sha,msg,dst=sys.argv[1:]
obj={"message":msg,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha: obj["sha"]=sha
pathlib.Path(dst).write_text(json.dumps(obj),encoding="utf-8")
PY2
  if ! gh api --method PUT "repos/$REPO/contents/$remote_path" --input "$payload" > "$response" 2> "$OUT/gh-upload-error-$PAYLOAD_INDEX.txt"; then
    got="$(github_contents_sha "$remote_path")"
    if [[ "$allow_update" != "1" && "$got" == "$local_blob" ]]; then
      UPLOAD_SHA="$got"
      echo "RACE_IDENTICAL_FILE_ACCEPTED=$remote_path SHA=$got" >> "$OUT/upload-verification.txt"
      return 0
    fi
    cat "$OUT/gh-upload-error-$PAYLOAD_INDEX.txt" >> "$UPLOAD_ERROR" || true
    if [[ -z "$got" ]]; then got="MISSING"; fi
    echo "UPLOAD_FAILED_PATH=$remote_path EXPECTED_LOCAL_SHA=$local_blob REMOTE_SHA=$got" >> "$UPLOAD_ERROR"
    return 1
  fi
  put="$(python3 - "$response" <<'PY2'
import json,re,sys
v=json.load(open(sys.argv[1]))
sha=(v.get("content") or {}).get("sha")
if not isinstance(sha,str) or not re.fullmatch(r"[0-9a-f]{40}",sha):
    raise SystemExit("GitHub response missing valid content blob SHA")
print(sha)
PY2
)"
  got="$(github_contents_sha "$remote_path")"
  [[ "$put" == "$got" && "$got" == "$local_blob" ]] || {
    echo "READBACK_SHA_MISMATCH=$remote_path put=$put got=$got expected=$local_blob" >> "$UPLOAD_ERROR"
    return 1
  }
  UPLOAD_SHA="$got"
}

MANIFEST="$OUT/manifest.txt"
{
  echo "STAGE: 48"
  echo "RUN: $RUN"
  echo "PURPOSE: read-only exact 24H32 registration bridge, queue-set construction, packet-queue initialization and callback-bearing TX/RX method audit"
  echo "TARGET: macOS $OSVER / $BUILD / $ARCH"
  echo "PREDECESSOR: Stage47 run-20261102-113242-ae14b45342fc"
  echo "SOURCE_MODIFIED: NO"
  echo "BUILD: NOT_RUN"
  echo "ACTIVATION_GATE: BLOCKED"
  echo "LOCAL_OUTPUT: $OUT"
} > "$MANIFEST"

upload_artifact() {
  local f="$1" suffix="$2" base group_name root_name
  base="$(basename "$f")"
  [[ "$base" == *.txt ]] || base="$base.txt"
  group_name="Development/Logs/stage48/$RUN/$base"
  root_name="Development/Logs/stage48-$RUN-$suffix"
  upload_file "$f" "$group_name" "Add Stage48 grouped audit artifact $RUN $base" "0"
  echo "GROUPED_ARTIFACT=$group_name | GITHUB_BLOB=$UPLOAD_SHA" >> "$MANIFEST"
  upload_file "$f" "$root_name" "Add unique Stage48 audit artifact $RUN $suffix" "0"
  echo "ROOT_ARTIFACT=$root_name | GITHUB_BLOB=$UPLOAD_SHA | BYTES=$(wc -c < "$f" | tr -d ' ')" >> "$MANIFEST"
}
for part in "$OUT"/report-*; do [[ -f "$part" ]] || continue; upload_artifact "$part" "$(basename "$part")"; done
for part in "$OUT"/source-context-* "$OUT"/abi-audit-*; do [[ -f "$part" ]] || continue; upload_artifact "$part" "$(basename "$part")"; done
upload_artifact "$OUT/source-fingerprint.txt" "source-fingerprint.txt"
upload_artifact "$OUT/upstream-verification.txt" "upstream-verification.txt"
upload_file "$MANIFEST" "Development/Logs/stage48/$RUN/manifest.txt" "Add Stage48 grouped manifest $RUN" "0"
upload_file "$MANIFEST" "Development/Logs/stage48-$RUN-manifest.txt" "Add unique Stage48 manifest $RUN" "0"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$EXPECTED_STAGE43_CPP" <<'PY'
import base64,json,pathlib,sys
remote,out,run,expected=sys.argv[1:]
obj=json.load(open(remote))
old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 48 REGISTRATION / QUEUE-CONSTRUCTION / CALLBACK AUDIT ==========\n"
 f"STAGE48_RUN: {run}\n"
 "STAGE48_SCOPE: IO80211InfraInterface::registerInfraEthernetInterface, IOSkywalkEthernetInterface registration wrappers, queue-set construction, packet-queue constructors and TX/RX callback-bearing methods\n"
 f"STAGE43_SOURCE_BASELINE: {expected}\n"
 "STAGE48_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"
 "ACTIVATION_GATE: BLOCKED — this audit maps Apple's registration and callback ABI; it does not implement queue creation, TX/RX completion, publication or safe rollback in RTL88WiFi\n"
 f"STAGE48_LOGS: Development/Logs/stage48/{run}/ and unique files directly under Development/Logs/\n"
 "==============================================================\n"
).encode()
pathlib.Path(out).write_bytes(old.rstrip()+entry)
PY
upload_file "$OUT/output.log" "Development/output.log" "Append Stage48 registration and queue ABI audit $RUN" "1"

echo
echo "STAGE48_SCRIPT_VERSION=STAGE48_V1_20261102"
echo "STAGE48_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE48_RUN=$RUN"
echo "STAGE48_LOCAL_OUTPUT=$OUT"
echo "STAGE48_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage48/$RUN"
echo "STAGE48_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE48_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE48_SOURCE_MODIFIED=NO"
echo "STAGE48_BUILD=NOT_RUN"
echo "STAGE48_INSTALL=NOT_RUN"
echo "STAGE48_LOAD=NOT_RUN"
echo "STAGE48_OPENCORE_CHANGE=NONE"
