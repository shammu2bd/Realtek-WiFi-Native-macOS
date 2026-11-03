#!/bin/bash
# Stage 55 — native source-to-Apple interface factory and registration reachability crosswalk.
# VERSION_MARKER: STAGE55_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE55_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage55/$RUN"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
mkdir -p "$TOOLS" "$CACHE"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE55_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }

for t in curl gh python3 shasum split grep awk sw_vers uname xcrun file wc; do
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
expected={
 "kcfile.py":"5d31e8a73e5cb175851e7407529456f223683589",
 "disasm.py":"d7777456f4700bc9815e765aed2313093ac133e9"
}
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
lines=[]
for rel,want in items.items():
    p=src/rel
    got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
    lines += ["FILE="+rel,"EXPECTED_SHA256="+want,"ACTUAL_SHA256="+got,
              "RESULT="+("MATCH" if got==want else "MISMATCH")]
ok=all(x=="RESULT=MATCH" for x in lines if x.startswith("RESULT="))
(out/"source-fingerprint.txt").write_text(
    "\n".join(lines)+"\nSTAGE43_SOURCE_CONTINUITY="+("PASS" if ok else "REVIEW_REQUIRED")+"\n")
if not ok: raise SystemExit("Stage43 source baseline changed; stop")
PY

python3 - "$SRC" "$OUT" <<'PY'
import pathlib,re,sys
src,out=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
files=[
 "src/kext/wcl24h32/RTW88WCL24H32ABI.hpp",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
 "src/kext/wcl24h32/RTW88WCLController.hpp",
 "src/kext/wcl24h32/RTW88WCLController.cpp",
 "src/kext/RTL88WiFi.hpp",
 "src/kext/RTL88WiFi.cpp"
]
terms=re.compile(r"getPrimarySkywalkInterface|setPrimarySkywalkInterface|createSkywalkInterface|"
                 r"registerInfraEthernetInterface|IO80211InfraProtocol|IO80211InfraInterface|"
                 r"IO80211SkywalkInterface|initRegistrationInfo|prepareRegistrationInfo|"
                 r"OSDefineMetaClassAndStructors|OSDeclareDefaultStructors|registerService")
out_lines=["STAGE55_NATIVE_SOURCE_CONTRACT_CONTEXT"]
for rel in files:
    p=src/rel
    out_lines.append("\n===== "+rel+" =====")
    if not p.is_file():
        out_lines.append("STATUS=MISSING"); continue
    lines=p.read_text(errors="replace").splitlines()
    hits=[i for i,line in enumerate(lines) if terms.search(line)]
    emitted=set()
    out_lines.append("TOTAL_LINES=%d MATCHES=%d"%(len(lines),len(hits)))
    for i in hits:
        for n in range(max(0,i-4),min(len(lines),i+7)):
            if n not in emitted:
                out_lines.append("%5d %s"%(n+1,lines[n])); emitted.add(n)
            if len(emitted)>220: break
        if len(emitted)>220:
            out_lines.append("TRUNCATED_AT_220_CONTEXT_LINES"); break
(out/"source-contract-context.txt").write_text("\n".join(out_lines)+"\n")
PY


STAGE54_RUN="run-20261102-132405-fb0df18fd221"
STAGE54_RAW="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage54/$STAGE54_RUN"
EVIDENCE="$OUT/stage54-evidence"
mkdir -p "$EVIDENCE"
for name in method-status.txt abi-method-disassembly.txt vtable-index.txt audit-summary.txt manifest.txt; do
  curl -fsSLo "$EVIDENCE/$name" "$STAGE54_RAW/$name"
done
python3 - "$EVIDENCE" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={
 "method-status.txt":"b98d9ccae181bddc097a80f9cb6a9e7ac5db562c",
 "abi-method-disassembly.txt":"7d8097882272209299958ffd32e03f7ec8f142cb",
 "vtable-index.txt":"1ee8ad86d008bbb2d24b15dee3be2588d13cc2c6",
 "audit-summary.txt":"c414956ae66eb688ea992891c7988e5a8acb935f",
 "manifest.txt":"cea35e88b505cd87532979e648511edc4f14ec6d"
}
for name,want in expected.items():
 data=(root/name).read_bytes()
 got=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
 print("STAGE54_EVIDENCE_%s=%s"%(name,"MATCH" if got==want else "MISMATCH"))
 if got!=want: raise SystemExit("Stage54 evidence integrity failure: "+name)
PY

python3 - "$SRC" "$OUT" "$EVIDENCE" <<'PY'
import pathlib,re,sys
src,out,evidence=map(pathlib.Path,sys.argv[1:])
status=(evidence/"method-status.txt").read_text(errors="replace").splitlines()
passes=[x for x in status if x.startswith("METHOD_STATUS ") and x.endswith("result=PASS")]
symbols=[
 "__ZN23IO80211SkywalkInterface4initEP9IOServiceP10ether_addr",
 "__ZN23IO80211SkywalkInterface5startEP9IOService",
 "__ZN21IO80211InfraInterface5startEP9IOService",
 "__ZN21IO80211InfraInterface30registerInfraEthernetInterface",
 "__ZN16AppleBCMWLANCore16skywalkInfraInitEv",
 "__ZN16AppleBCMWLANCore22createSkywalkInterface",
 "__ZN16AppleBCMWLANCore23destroySkywalkInterface",
 "__ZN28AppleBCMWLANSkywalkInterface5startEP16AppleBCMWLANCore"]
missing=[x for x in symbols if not any(x in y for y in passes)]
if len(status)!=17 or len(passes)!=17 or missing:
 raise SystemExit("Stage54 predecessor evidence incomplete: rows=%d pass=%d missing=%s"%(len(status),len(passes),",".join(missing)))

files=sorted(p for p in src.rglob("*") if p.is_file() and p.suffix.lower() in (".cpp",".cc",".cxx",".hpp",".h",".hh")
             and not any(x.startswith(".") or x in ("build","out","DerivedData") for x in p.relative_to(src).parts))

def body_at(text,start):
 op=text.find("{",start); semi=text.find(";",start)
 if op<0 or (semi>=0 and semi<op): return None
 depth=0; state="c"; quote=""; i=op
 while i<len(text):
  c=text[i]; n=text[i+1] if i+1<len(text) else ""
  if state=="line":
   if c=="\n": state="c"
  elif state=="block":
   if c=="*" and n=="/": state="c"; i+=1
  elif state=="str":
   if c=="\\": i+=1
   elif c==quote: state="c"
  else:
   if c=="/" and n=="/": state="line"; i+=1
   elif c=="/" and n=="*": state="block"; i+=1
   elif c in ("'","\""): state="str"; quote=c
   elif c=="{": depth+=1
   elif c=="}":
    depth-=1
    if depth==0: return text[op:i+1]
  i+=1
 return text[op:]

targets=[
 ("RTW88WCLController","start"),("RTW88WCLController","releaseNativeResources"),("RTW88WCLController","free"),
 ("RTW88WCLInfraInterface","init"),("RTW88WCLInfraInterface","attachRadio"),
 ("RTW88WCLInfraInterface","start"),("RTW88WCLInfraInterface","stop"),("RTW88WCLInfraInterface","free")]
records=[]
for p in files:
 text=p.read_text(errors="replace")
 for cls,name in targets:
  pat=re.compile(r"\b"+cls+r"\s*::\s*"+name+r"\s*\(")
  for m in pat.finditer(text):
   b=body_at(text,m.end())
   if b is None: continue
   records.append((cls,name,str(p.relative_to(src)),text.count("\n",0,m.start())+1,b))

bodies=["STAGE55_NATIVE_METHOD_BODY_REACHABILITY"]
for cls,name,path,line,b in records:
 bodies += ["\n===== %s::%s %s:%d ====="%(cls,name,path,line),b[:20000]]
(out/"method-body-audit.txt").write_text("\n".join(bodies)+"\n")

keys={
 "interface_instance_reference":r"\bRTW88WCLInfraInterface\b",
 "provider_init_call":r"(?:IO80211InfraProtocol|IO80211SkywalkInterface)::init\s*\(",
 "radio_attach_call":r"\battachRadio\s*\(",
 "primary_interface_getter_or_setter":r"\b(?:setPrimarySkywalkInterface|getPrimarySkywalkInterface)\s*\(",
 "interface_prepare_or_start":r"\b(?:prepareBSDInterface|prepareInterface)\s*\(",
 "infra_registration":r"\bregisterInfraEthernetInterface\s*\(",
 "registration_info_init":r"\binitRegistrationInfo\s*\(",
 "ethernet_registration":r"\bregisterEthernetInterface\s*\(",
 "network_registration":r"\bregisterNetworkInterface\s*\(",
 "queue_set_create_or_init":r"\b(?:createWithQueues|createQueueSet|initWithQueues)\s*\(",
 "logical_link_create":r"\b(?:createWithQueueSet|createLogicalLink)\s*\(",
 "tx_adapter_calls":r"\b(?:submitPacket|drainCompletions)\s*\(",
 "rx_adapter_calls":r"\b(?:enqueuePacketsForNetworking|refill)\s*\(",
 "callback_names":r"\b(?:transmit|txComplete|receive|rxComplete|submitPacket|enqueuePacketsForNetworking)\s*\("}
def hits_for(pattern,records_in,limit=60):
 rx=re.compile(pattern,re.I); hits=[]
 for path,body in records_in:
  for m in rx.finditer(body):
   line=body.count("\n",0,m.start())+1
   a=body.rfind("\n",0,m.start())+1; z=body.find("\n",m.end())
   if z<0: z=len(body)
   hits.append((path,line,body[a:z].strip()[:350]))
   if len(hits)>=limit: return hits
 return hits

selected=[("%s::%s %s:%d"%(c,n,p,l),b) for c,n,p,l,b in records]
cross=["STAGE55_NATIVE_SOURCE_TO_STAGE54_ABI_CROSSWALK","SOURCE_FILES_SCANNED=%d"%len(files),
       "SELECTED_METHOD_DEFINITIONS_FOUND=%d"%len(records),"STAGE54_DISASSEMBLY_PASS=17/17"]
for key,pattern in keys.items():
 h=hits_for(pattern,selected,100)
 cross += ["\nREFERENCE=%s"%key,"MATCHES_IN_SELECTED_METHODS=%d"%len(h)]
 for p,l,snip in h[:40]: cross.append("  %s:%d: %s"%(p,l,snip))
 if not h: cross.append("  RESULT=NOT_FOUND_IN_SELECTED_METHOD_BODIES")
(out/"source-factory-crosswalk.txt").write_text("\n".join(cross)+"\n")

by={}
for cls,name,path,line,b in records:
 by.setdefault(cls+"::"+name,[]).append((path+"::"+cls+"::"+name,b))
checks=[
 ("controller constructs interface","RTW88WCLController::start",r"(?:new\s+|OSMakeUnique\s*<\s*)RTW88WCLInfraInterface"),
 ("controller calls attachRadio","RTW88WCLController::start",r"\battachRadio\s*\("),
 ("controller publishes primary interface","RTW88WCLController::start",r"\b(?:setPrimarySkywalkInterface|getPrimarySkywalkInterface)\s*\("),
 ("controller explicitly prepares interface","RTW88WCLController::start",r"\b(?:prepareBSDInterface|prepareInterface)\s*\("),
 ("interface init calls base initializer","RTW88WCLInfraInterface::init",r"(?:IO80211InfraProtocol|IO80211SkywalkInterface)::init\s*\("),
 ("interface start calls infra registration","RTW88WCLInfraInterface::start",r"\bregisterInfraEthernetInterface\s*\("),
 ("interface start initializes registration info","RTW88WCLInfraInterface::start",r"\binitRegistrationInfo\s*\("),
 ("interface start calls Ethernet registration","RTW88WCLInfraInterface::start",r"\bregisterEthernetInterface\s*\("),
 ("interface start calls Network registration","RTW88WCLInfraInterface::start",r"\bregisterNetworkInterface\s*\("),
 ("interface path creates QueueSet","RTW88WCLInfraInterface::start",r"\b(?:createWithQueues|createQueueSet|initWithQueues)\s*\("),
 ("interface path creates LogicalLink","RTW88WCLInfraInterface::start",r"\b(?:createWithQueueSet|createLogicalLink)\s*\("),
 ("interface path invokes TX adapter","RTW88WCLInfraInterface::start",r"\b(?:submitPacket|drainCompletions)\s*\("),
 ("interface path invokes RX adapter","RTW88WCLInfraInterface::start",r"\b(?:enqueuePacketsForNetworking|refill)\s*\(")]
matrix=["STAGE55_CONTROLLER_INTERFACE_REGISTRATION_AND_DATAPATH_MATRIX"]
for label,method,pattern in checks:
 h=hits_for(pattern,by.get(method,[]),80)
 matrix += ["\nCHECK="+label,"METHOD="+method,"RESULT="+("PRESENT" if h else "NOT_FOUND_IN_METHOD_BODY")]
 for p,l,snip in h[:20]: matrix.append("EVIDENCE=%s:%d: %s"%(p,l,snip))
(out/"reachability-matrix.txt").write_text("\n".join(matrix)+"\n")

inventory=["STAGE55_GLOBAL_SOURCE_REFERENCE_INVENTORY"]
all_sources=[(str(p.relative_to(src)),p.read_text(errors="replace")) for p in files]
for key,pattern in keys.items():
 h=hits_for(pattern,all_sources,100)
 inventory += ["\nREFERENCE=%s"%key,"MATCHES=%d"%len(h)]
 for p,l,snip in h[:60]: inventory.append("%s:%d: %s"%(p,l,snip))
(out/"source-reference-inventory.txt").write_text("\n".join(inventory)+"\n")

summary=[
 "STAGE55_NATIVE_FACTORY_REGISTRATION_REACHABILITY_AUDIT",
 "TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "SOURCE_FILES_SCANNED=%d"%len(files),
 "SELECTED_METHOD_DEFINITIONS_FOUND=%d"%len(records),
 "STAGE54_REQUIRED_METHODS_PASS=17/17",
 "STAGE54_EXACT_PROVIDER_INITIALIZER=PASS",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN",
 "KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
PY

{
 echo "========== STAGE 55 NATIVE SOURCE / FACTORY / REGISTRATION REACHABILITY AUDIT =========="
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "SOURCE_ROOT=$SOURCE_ROOT"
 echo "PREDECESSOR=Stage54 V2 run-20261102-132405-fb0df18fd221"
 echo "SCOPE=correlate verified Stage54 Apple ABI methods with native controller/interface construction, attach, publication, registration, QueueSet/LogicalLink and TX/RX callback reachability"
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
 echo "SOURCE_CONTRACT_CONTEXT=$OUT/source-contract-context.txt"
 echo "STAGE54_EVIDENCE=$EVIDENCE"
 echo "STAGE54_METHOD_STATUS=$EVIDENCE/method-status.txt"
 echo "STAGE54_ABI_DISASSEMBLY=$EVIDENCE/abi-method-disassembly.txt"
 echo "STAGE54_VTABLE_INDEX=$EVIDENCE/vtable-index.txt"
 echo "SOURCE_FACTORY_CROSSWALK=$OUT/source-factory-crosswalk.txt"
 echo "METHOD_BODY_AUDIT=$OUT/method-body-audit.txt"
 echo "REACHABILITY_MATRIX=$OUT/reachability-matrix.txt"
 echo "SOURCE_REFERENCE_INVENTORY=$OUT/source-reference-inventory.txt"
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
 echo "========== END STAGE 55 =========="
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
obj={"message":"Add Stage55 read-only IO80211 interface factory and vtable audit evidence",
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
 echo "STAGE=55"
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "PURPOSE=read-only native source-to-ABI factory, registration and TX/RX datapath reachability crosswalk"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "PREDECESSOR=Stage54 V2 run-20261102-132405-fb0df18fd221"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "ACTIVATION_GATE=BLOCKED"
 echo "STAGE54_PREDECESSOR=run-20261102-132405-fb0df18fd221"
 echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"

upload_artifact() {
 local file="$1" base group root
 base="$(basename "$file")"
 group="Development/Logs/stage55/$RUN/$base"
 root="Development/Logs/stage55-$RUN-$base"
 upload_one "$file" "$group" 0
 upload_one "$file" "$root" 0
 echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/source-contract-context.txt "$OUT"/source-factory-crosswalk.txt "$OUT"/method-body-audit.txt "$OUT"/reachability-matrix.txt "$OUT"/source-reference-inventory.txt; do
 [[ -f "$f" ]] || fail "missing audit artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then
   upload_artifact "$f"
 else
   split -b 220k "$f" "$f.part-"
   for part in "$f".part-*; do upload_artifact "$part"; done
 fi
done
# Freeze manifest after all artifact paths have been appended.
upload_one "$MAN" "Development/Logs/stage55/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage55-$RUN-manifest.txt" 0

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote))
old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 55 NATIVE SOURCE / FACTORY / REGISTRATION REACHABILITY AUDIT ==========\n"
 "STAGE55_RUN: %s\n"%run+
 "STAGE55_VERSION: %s\n"%version+
 "STAGE55_SCOPE: correlate Stage54 verified initializer/factory/lifecycle ABI methods with native controller/interface construction, attach, publication, registration and packet callback edges\n"+
 "STAGE55_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — source crosswalk only; this does not implement registration or connect packet callbacks\n"+
 "STAGE55_LOGS: Development/Logs/stage55/%s/ and unique files directly under Development/Logs/\n"%run+
 "==================================================================\n"
).encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY
upload_one "$OUT/output.log" "Development/output.log" 1

echo
echo "STAGE55_VERSION=$VERSION"
echo "STAGE55_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE55_RUN=$RUN"
echo "STAGE55_LOCAL_OUTPUT=$OUT"
echo "STAGE55_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage55/$RUN"
echo "STAGE55_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE55_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE55_SOURCE_MODIFIED=NO"
echo "STAGE55_BUILD=NOT_RUN"
echo "STAGE55_INSTALL=NOT_RUN"
echo "STAGE55_LOAD=NOT_RUN"
echo "STAGE55_OPENCORE_CHANGE=NONE"
