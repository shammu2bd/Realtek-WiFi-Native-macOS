#!/bin/bash
# Stage 54 — exact IO80211 provider initializer, interface factory and lifecycle audit.
# VERSION_MARKER: STAGE54_V2_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE54_V2_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage54/$RUN"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
mkdir -p "$TOOLS" "$CACHE"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE54_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
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
out_lines=["STAGE54_NATIVE_SOURCE_CONTRACT_CONTEXT"]
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

python3 - "$TOOLS" "$BOOTKC" "$CACHE" "$OBJDUMP" "$OUT" <<'PY'
import os,pathlib,re,subprocess,sys
tools,kc_path,cache,objdump,out=sys.argv[1:]
out=pathlib.Path(out)
sys.path.insert(0,tools)
from kcfile import KC
import disasm
os.environ["LLVM_OBJDUMP"]=objdump
kc=KC(kc_path)
parser=disasm.Disassembler(kc,cache)

classes={
 "IO80211Controller":r"(getPrimarySkywalkInterface)",
 "IO80211SkywalkInterface":r"(initEP9IOServiceP10ether_addr|startEP9IOService|stopEP9IOService|freeEv)",
 "IO80211InfraInterface":r"(startEP9IOService|registerInfraEthernetInterface|stopEP9IOService|freeEv)",
 "IO80211InfraProtocol":r"(start|stop|free|init)",
 "AppleBCMWLANSkywalkInterface":r"(initWithProviderAndParameters|startEP9IOService|startEP16AppleBCMWLANCore|stopEP9IOService|freeEv)",
 "AppleBCMWLANCore":r"(skywalkInfraInit|createSkywalkInterface|destroySkywalkInterface|getSkywalkInterface)"
}
class_hits={}
discovery=[
 "STAGE54_EXACT_INTERFACE_INITIALIZER_AND_FACTORY_AUDIT",
 "BOOTKC_SHA256="+kc.sha256(),
 "FILESET_ENTRY_COUNT=%d"%len(kc.entries),
 "OBJDUMP="+objdump
]
for cls,pat in classes.items():
    try:
        methods=kc.methods(cls)
    except Exception as e:
        class_hits[cls]=[]
        discovery.append("CLASS_SCAN_%s=ERROR:%s"%(cls,str(e)))
        continue
    hits=[(va,nm) for va,nm in methods if re.search(pat,nm,re.I)]
    class_hits[cls]=hits
    discovery.append("\nCLASS=%s METHODS_TOTAL=%d MATCHES=%d"%(cls,len(methods),len(hits)))
    for va,nm in hits[:160]:
        discovery.append("METHOD class=%s address=0x%x owner=%s symbol=%s"%(
            cls,va,kc.owner(va) or kc.sym_owner.get(va) or "UNKNOWN",nm))

vt_classes=("IO80211Controller","IO80211SkywalkInterface","IO80211InfraInterface",
            "IO80211InfraProtocol","AppleBCMWLANSkywalkInterface")
vt_pat=re.compile(r"getPrimarySkywalkInterface|registerInfraEthernetInterface|"
                  r"startEP9IOService|initEP9IOService|initWithProviderAndParameters|"
                  r"createSkywalkInterface|destroySkywalkInterface|skywalkInfraInit",re.I)
vtable_lines=["STAGE54_VTABLE_SLOT_INDEX"]
for cls in vt_classes:
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

# Select the exact init(IOService*, ether_addr*) overload, not initIvars().
wanted=[
 ("IO80211Controller",r"getPrimarySkywalkInterface"),
 ("IO80211SkywalkInterface",r"initEP9IOServiceP10ether_addr"),
 ("IO80211SkywalkInterface",r"startEP9IOService"),
 ("IO80211SkywalkInterface",r"stopEP9IOService"),
 ("IO80211SkywalkInterface",r"freeEv"),
 ("IO80211InfraInterface",r"startEP9IOService"),
 ("IO80211InfraInterface",r"registerInfraEthernetInterface"),
 ("IO80211InfraInterface",r"stopEP9IOService"),
 ("IO80211InfraInterface",r"freeEv"),
 ("AppleBCMWLANSkywalkInterface",r"initWithProviderAndParameters"),
 ("AppleBCMWLANSkywalkInterface",r"startEP9IOService"),
 ("AppleBCMWLANSkywalkInterface",r"startEP16AppleBCMWLANCore"),
 ("AppleBCMWLANSkywalkInterface",r"stopEP9IOService"),
 ("AppleBCMWLANCore",r"skywalkInfraInit"),
 ("AppleBCMWLANCore",r"createSkywalkInterface"),
 ("AppleBCMWLANCore",r"destroySkywalkInterface"),
 ("AppleBCMWLANCore",r"getSkywalkInterface")
]
resolved=[]
missing=[]
seen=set()
for cls,pattern in wanted:
    matches=[(va,nm) for va,nm in class_hits.get(cls,[]) if re.search(pattern,nm,re.I)]
    if not matches:
        missing.append("REQUIRED_METHOD_NOT_FOUND class=%s pattern=%s"%(cls,pattern))
        continue
    for va,nm in matches:
        if va in seen: continue
        seen.add(va)
        owner=kc.owner(va) or kc.sym_owner.get(va)
        sym_owner=kc.sym_owner.get(va)
        if not owner or owner!=sym_owner:
            missing.append("METHOD_OWNER_VALIDATION=FAIL class=%s symbol=%s owner=%s sym_owner=%s"%(cls,nm,owner,sym_owner))
            continue
        segs=[x for x in kc.entry_segs.get(owner,[]) if x[1]<=va<x[1]+x[2] and (x[5]&4)]
        if not segs:
            missing.append("METHOD_EXECUTABLE_SEGMENT=NOT_FOUND class=%s symbol=%s"%(cls,nm))
            continue
        end=kc.next_sym(va) or (va+0x1000)
        if end<=va or end>va+0x20000: end=va+0x1000
        resolved.append((cls,nm,va,owner,end))

discovery.extend(missing)
discovery.append("\nMETHODS_SELECTED_FOR_DISASSEMBLY=%d"%len(resolved))
discovery.append("REQUIRED_SELECTIONS=%d"%len(wanted))
discovery.append("REQUIRED_SELECTIONS_MISSING=%d"%len(missing))
all_disasm=[]
status=[]
for owner in sorted({x[3] for x in resolved}):
    safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
    carved=pathlib.Path(cache)/(safe+".macho")
    kc.carve(owner,str(carved))
    discovery.append("CARVED_OWNER=%s BYTES=%d"%(owner,carved.stat().st_size))
    for line in subprocess.run(["file",str(carved)],text=True,capture_output=True).stdout.splitlines():
        discovery.append("CARVED_FILE="+line)
    for cls,nm,va,o,end in [x for x in resolved if x[3]==owner]:
        all_disasm.append("\n===== METHOD class=%s symbol=%s address=0x%x owner=%s range=0x%x..0x%x ====="%(
            cls,nm,va,o,va,end))
        attempts=[
          ["-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved)],
          ["-d","--no-show-raw-insn","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved)],
          ["-d","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved)]
        ]
        success=False; count=0
        for idx,args in enumerate(attempts,1):
            p=subprocess.run([objdump]+args,text=True,capture_output=True)
            parsed_addrs,parsed_ins=parser._parse(p.stdout)
            count=len(parsed_addrs)
            all_disasm.append("OBJDUMP_ATTEMPT_%d_EXIT=%d INSTRUCTIONS=%d"%(idx,p.returncode,count))
            if p.stderr.strip(): all_disasm.append("STDERR="+p.stderr[:1200])
            if p.stdout.strip():
                all_disasm.append("DISASSEMBLY_BEGIN")
                all_disasm.append(p.stdout[:50000].rstrip())
                all_disasm.append("DISASSEMBLY_END")
            if p.returncode==0 and count:
                all_disasm.append("METHOD_DISASSEMBLY=PASS")
                success=True; break
        if not success: all_disasm.append("METHOD_DISASSEMBLY=REVIEW_REQUIRED")
        status.append("METHOD_STATUS class=%s symbol=%s address=0x%x instructions=%d result=%s"%(
            cls,nm,va,count,"PASS" if success else "REVIEW_REQUIRED"))

(out/"abi-method-disassembly.txt").write_text("\n".join(all_disasm)+"\n")
(out/"class-discovery.txt").write_text("\n".join(discovery)+"\n")
edge_lines=["STAGE54_DIRECT_CALL_AND_INDIRECT_DISPATCH_INDEX"]
for block in "\n".join(all_disasm).split("\n===== METHOD "):
    if not block.strip(): continue
    header=block.splitlines()[0]
    calls=[ln.strip() for ln in block.splitlines() if re.search(r"\b(call|jmp)[q]?\s+",ln)]
    if calls:
        edge_lines.append("\nMETHOD="+header)
        edge_lines.extend(calls[:260])
(out/"call-edge-index.txt").write_text("\n".join(edge_lines)+"\n")
(out/"method-status.txt").write_text("\n".join(status+missing)+"\n")

summary=[
 "STAGE54_EXACT_INTERFACE_INITIALIZER_AND_FACTORY_AUDIT",
 "TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "CLASS_SCANS=%d"%len(classes),
 "VTABLE_CLASSES=%d"%len(vt_classes),
 "REQUIRED_METHOD_SELECTIONS=%d"%len(wanted),
 "METHODS_RESOLVED=%d"%len(resolved),
 "METHODS_DISASSEMBLED_PASS=%d"%sum("result=PASS" in x for x in status),
 "REQUIRED_METHODS_MISSING=%d"%len(missing),
 "EXACT_SKYWALK_PROVIDER_INIT_SELECTED="+("YES" if any("initEP9IOServiceP10ether_addr" in x[1] for x in resolved) else "NO"),
 "BOOTKC_SHA256="+kc.sha256(),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN",
 "KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
PY

{
 echo "========== STAGE 54 EXACT INTERFACE INITIALIZER / FACTORY / LIFECYCLE AUDIT =========="
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "SOURCE_ROOT=$SOURCE_ROOT"
 echo "PREDECESSOR=Stage53 V2 run-20261102-130406-23ab158090aa"
 echo "SCOPE=exact provider initializer, IO80211 interface/controller lifecycle, primary-interface getter, AppleBCMWLANCore interface factory and start/registration call chains"
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
 echo "CLASS_DISCOVERY=$OUT/class-discovery.txt"
 echo "VTABLE_INDEX=$OUT/vtable-index.txt"
 echo "ABI_METHOD_DISASSEMBLY=$OUT/abi-method-disassembly.txt"
 echo "CALL_EDGE_INDEX=$OUT/call-edge-index.txt"
 echo "SOURCE_CONTRACT_CONTEXT=$OUT/source-contract-context.txt"
 echo "METHOD_STATUS=$OUT/method-status.txt"
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
 echo "========== END STAGE 54 =========="
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
obj={"message":"Add Stage54 read-only IO80211 interface factory and vtable audit evidence",
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
 echo "STAGE=54"
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "PURPOSE=read-only exact provider initializer, factory and interface lifecycle ABI audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "PREDECESSOR=Stage53 V2 run-20261102-130406-23ab158090aa"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "ACTIVATION_GATE=BLOCKED"
 echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"

upload_artifact() {
 local file="$1" base group root
 base="$(basename "$file")"
 group="Development/Logs/stage54/$RUN/$base"
 root="Development/Logs/stage54-$RUN-$base"
 upload_one "$file" "$group" 0
 upload_one "$file" "$root" 0
 echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/source-contract-context.txt "$OUT"/class-discovery.txt "$OUT"/vtable-index.txt "$OUT"/abi-method-disassembly.txt "$OUT"/call-edge-index.txt "$OUT"/method-status.txt; do
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
upload_one "$MAN" "Development/Logs/stage54/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage54-$RUN-manifest.txt" 0

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote))
old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 54 EXACT INTERFACE INITIALIZER / FACTORY / LIFECYCLE AUDIT ==========\n"
 "STAGE54_RUN: %s\n"%run+
 "STAGE54_VERSION: %s\n"%version+
 "STAGE54_SCOPE: exact IO80211SkywalkInterface provider initializer, interface/controller lifecycle methods, primary-interface getter and AppleBCMWLANCore factory/start lifecycle methods\n"+
 "STAGE54_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — read-only ABI and call-path evidence; no driver registration implementation or hardware-test authorization\n"+
 "STAGE54_LOGS: Development/Logs/stage54/%s/ and unique files directly under Development/Logs/\n"%run+
 "==================================================================\n"
).encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY
upload_one "$OUT/output.log" "Development/output.log" 1

echo
echo "STAGE54_VERSION=$VERSION"
echo "STAGE54_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE54_RUN=$RUN"
echo "STAGE54_LOCAL_OUTPUT=$OUT"
echo "STAGE54_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage54/$RUN"
echo "STAGE54_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE54_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE54_SOURCE_MODIFIED=NO"
echo "STAGE54_BUILD=NOT_RUN"
echo "STAGE54_INSTALL=NOT_RUN"
echo "STAGE54_LOAD=NOT_RUN"
echo "STAGE54_OPENCORE_CHANGE=NONE"
