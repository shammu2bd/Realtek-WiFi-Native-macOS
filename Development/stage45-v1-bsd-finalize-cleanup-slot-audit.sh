#!/bin/bash
# Stage 45 — exact 24H32 BSD finalize cleanup virtual-slot ownership audit.
# VERSION_MARKER: STAGE45_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
echo "STAGE45_SCRIPT_VERSION=STAGE45_V1_20261102"
SOURCE_ROOT="${SOURCE_ROOT:-$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source}"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
EXPECTED_STAGE43_CPP="2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b"
EXPECTED_ABI_HEADER="63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb"
EXPECTED_INTERFACE_HEADER="9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4"

STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage45/$RUN"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$TOOLS" "$CACHE"
trap 'rc=$?; trap - ERR; echo "STAGE45_ERROR=exit:$rc line:$LINENO" >&2; if [[ -f "$UPLOAD_ERROR" ]]; then tail -60 "$UPLOAD_ERROR" >&2; fi; exit "$rc"' ERR

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

# Fetch the pinned fileset parser and verify the exact upstream Git blobs.
curl -fsSLo "$TOOLS/kcfile.py" "$UPSTREAM_RAW/kcfile.py"
curl -fsSLo "$TOOLS/disasm.py" "$UPSTREAM_RAW/disasm.py"
python3 - "$TOOLS" > "$OUT/upstream-verification.txt" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={
 "kcfile.py":"5d31e8a73e5cb175851e7407529456f223683589",
 "disasm.py":"d7777456f4700bc9815e765aed2313093ac133e9",
}
for name,want in expected.items():
    data=(root/name).read_bytes()
    got=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
    print("UPSTREAM_GIT_BLOB_%s=%s"%(name,"MATCH" if got==want else "MISMATCH"))
    print("UPSTREAM_GIT_BLOB_SHA_%s=%s"%(name,got))
    if got!=want: raise SystemExit("Pinned upstream file verification failed: "+name)
PY

{
  echo "========== STAGE 45: 24H32 BSD FINALIZE CLEANUP CALLBACK CONTRACT =========="
  echo "script_version=STAGE45_V1_20261102"
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
  echo "predecessor=Stage44 run-20261102-100836-5554bbfd0af8"
  echo "scope=finalizeBSDInterface cleanup virtual call at vtable offset 0x858, all relevant class vtables, and stop/free teardown methods"
  echo "SOURCE_MODIFIED=NO"
  echo "BUILD=NOT_RUN"
  echo
} > "$REPORT"
cat "$OUT/upstream-verification.txt" >> "$REPORT"

# Verify that the audited tree is exactly the Stage43 source state for both touched files.
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
PY
cat "$OUT/source-fingerprint.txt" >> "$REPORT"

# Record only the source declarations and implementations relevant to BSD lifecycle.
python3 - "$SRC" > "$OUT/source-context.txt" <<'PY'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1])
files=[
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
]
terms=re.compile(r"class (IO80211InfraInterface|IO80211InfraProtocol|RTW88WCLInfraInterface)|prepareBSDInterface|finalizeBSDInterface|initBSDInterfaceParameters|RTW88WCLInfraInterface::(start|stop|free)")
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
        a=max(0,i-7); b=min(len(lines),i+14)
        if spans and a<=spans[-1][1]:
            spans[-1]=(spans[-1][0],max(spans[-1][1],b))
        else:
            spans.append((a,b))
    for a,b in spans:
        print("--- lines %d-%d ---"%(a+1,b))
        for n in range(a,b): print("%5d %s"%(n+1,lines[n]))
    print("SOURCE_CONTEXT_HITS=%d"%len(hits))
PY

# Parse the target fileset, resolve exact lifecycle symbols, disassemble them,
# and inspect the relevant vtable slots to distinguish overrides from inheritance.
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

wanted=[
 ("IO80211InfraInterface.prepareBSDInterface","__ZN21IO80211InfraInterface19prepareBSDInterfaceEP7__ifnetj"),
 ("IO80211SkywalkInterface.prepareBSDInterface","__ZN23IO80211SkywalkInterface19prepareBSDInterfaceEP7__ifnetj"),
 ("IOSkywalkEthernetInterface.prepareBSDInterface","__ZN26IOSkywalkEthernetInterface19prepareBSDInterfaceEP7__ifnetj"),
 ("IOSkywalkNetworkInterface.prepareBSDInterface","__ZN25IOSkywalkNetworkInterface19prepareBSDInterfaceEP7__ifnetj"),
 ("IOSkywalkNetworkInterface.finalizeBSDInterface","__ZN25IOSkywalkNetworkInterface20finalizeBSDInterfaceEP7__ifnetj"),
 ("IO80211InfraInterface.initBSDInterfaceParameters","__ZN21IO80211InfraInterface26initBSDInterfaceParametersEP18ifnet_init_eparamsPP11sockaddr_dl"),
 ("IO80211InfraInterface.start","__ZN21IO80211InfraInterface5startEP9IOService"),
 ("IO80211InfraInterface.stop","__ZN21IO80211InfraInterface4stopEP9IOService"),
 ("IO80211InfraInterface.free","__ZN21IO80211InfraInterface4freeEv"),
 ("IOSkywalkNetworkInterface.stop","__ZN25IOSkywalkNetworkInterface4stopEP9IOService"),
 ("IOSkywalkNetworkInterface.free","__ZN25IOSkywalkNetworkInterface4freeEv"),
]
resolved=[]
print("\n--- Exact method resolution ---")
for label,sym in wanted:
    va=kc.find(sym)
    if va is None:
        print("SYMBOL_%s=NOT_FOUND"%label)
        continue
    owner=kc.owner(va)
    sym_owner=kc.sym_owner.get(va)
    print("SYMBOL_%s=0x%x"%(label,va))
    print("SYMBOL_NAME_%s=%s"%(label,sym))
    print("SYMBOL_FILES_OWNER_%s=%s"%(label,sym_owner or "UNKNOWN"))
    print("ADDRESS_FILES_OWNER_%s=%s"%(label,owner or "UNKNOWN"))
    if not owner or not sym_owner or owner!=sym_owner:
        print("OWNER_VALIDATION_%s=FAIL"%label)
        continue
    segs=[s for s in kc.entry_segs.get(owner,[]) if s[1] <= va < s[1]+s[2] and (s[5]&4)]
    if not segs:
        print("EXECUTABLE_SEGMENT_%s=NOT_FOUND"%label)
        continue
    end=kc.next_sym(va) or (va+0x1000)
    if end<=va or end>va+0x3000: end=va+0x1000
    resolved.append((label,sym,va,owner,end))

print("\n--- Relevant vtable implementations ---")
terms=("prepareBSDInterface","finalizeBSDInterface","initBSDInterfaceParameters","startEP9IOService","stopEP9IOService","freeEv")
for cls in ["IOSkywalkNetworkInterface","IOSkywalkEthernetInterface","IO80211SkywalkInterface","IO80211InfraInterface","IO80211InfraProtocol"]:
    try: vt=kc.vtable(cls)
    except Exception as e:
        print("VTABLE_%s=ERROR:%s"%(cls,str(e))); continue
    if vt is None:
        print("VTABLE_%s=NOT_FOUND"%cls); continue
    print("VTABLE_%s_ENTRIES=%d"%(cls,len(vt)))
    for idx,(word,raw,tgt,name) in enumerate(vt):
        if any(term in (name or "") for term in terms):
            print("VTABLE_MATCH class=%s offset=0x%x index=%d target=0x%x symbol=%s owner=%s"%(cls,idx*8,idx,tgt,name,kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"))


print("\n--- finalizeBSDInterface cleanup callback slot analysis ---")
# IOSkywalkNetworkInterface::finalizeBSDInterface dispatches through its vtable
# at byte offset 0x858. Resolve that exact slot for every relevant 24H32 class.
slot_targets={}
for cls in ["IOSkywalkNetworkInterface","IOSkywalkEthernetInterface","IO80211SkywalkInterface","IO80211InfraInterface","IO80211InfraProtocol"]:
    try:
        vt=kc.vtable(cls)
    except Exception as e:
        print("CLEANUP_VTABLE_%s=ERROR:%s"%(cls,str(e)))
        continue
    if vt is None:
        print("CLEANUP_VTABLE_%s=NOT_FOUND"%cls)
        continue
    for offset in (0x850,0x858,0x860):
        idx=offset//8
        if idx>=len(vt):
            print("VTABLE_SLOT class=%s offset=0x%x status=OUT_OF_RANGE entries=%d"%(cls,offset,len(vt)))
            continue
        word,raw,tgt,name=vt[idx]
        owner=kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"
        print("VTABLE_SLOT class=%s offset=0x%x index=%d target=0x%x symbol=%s owner=%s"%(cls,offset,idx,tgt,name or "UNNAMED",owner))
        if offset==0x858 and owner!="UNKNOWN" and tgt:
            slot_targets.setdefault((tgt,owner),{"names":[],"classes":[]})
            if name and name not in slot_targets[(tgt,owner)]["names"]:
                slot_targets[(tgt,owner)]["names"].append(name)
            slot_targets[(tgt,owner)]["classes"].append(cls)

for (va,owner),meta in sorted(slot_targets.items()):
    segs=[s for s in kc.entry_segs.get(owner,[]) if s[1] <= va < s[1]+s[2] and (s[5]&4)]
    label="cleanup_slot_0x858_"+"_".join(meta["classes"])
    sym=meta["names"][0] if meta["names"] else ("<unnamed-vtable-target-0x%x>"%va)
    if not segs:
        print("CLEANUP_TARGET_EXECUTABLE_SEGMENT=NOT_FOUND target=0x%x owner=%s"%(va,owner))
        continue
    end=kc.next_sym(va) or (va+0x1000)
    if end<=va or end>va+0x3000: end=va+0x1000
    resolved.append((label,sym,va,owner,end))
    print("CLEANUP_TARGET_RESOLVED label=%s address=0x%x owner=%s symbol=%s classes=%s"%(label,va,owner,sym,",".join(meta["classes"])))

print("CLEANUP_TARGETS_DISASSEMBLY_COUNT=%d"%len(slot_targets))

print("\n--- Fileset-aware method disassembly ---")
owners=sorted({item[3] for item in resolved})
for owner in owners:
    safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
    carved=pathlib.Path(cache)/(safe+".macho")
    kc.carve(owner,str(carved))
    print("CARVED_OWNER=%s"%owner)
    print("CARVED_BYTES=%d"%carved.stat().st_size)
    print("CARVED_FILE_TYPE="+subprocess.run(["file",str(carved)],text=True,capture_output=True).stdout.strip())
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
            print("OBJDUMP_ATTEMPT_%d_STDOUT_BEGIN"%idx)
            print(p.stdout[:18000].rstrip())
            print("OBJDUMP_ATTEMPT_%d_STDOUT_END"%idx)
        if p.returncode==0 and parsed_addrs:
            print("METHOD_DISASSEMBLY_%s=PASS"%label)
            success=True
            break
    if not success: print("METHOD_DISASSEMBLY_%s=REVIEW_REQUIRED"%label)

print("\n--- Audit totals ---")
print("METHODS_REQUESTED=%d"%(len(wanted)+len(slot_targets)))
print("METHODS_RESOLVED=%d"%len(resolved))
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
  kmutil showloaded --list-only 2>&1 | grep -E -i 'IO80211Family|IOSkywalkFamily|IONetworkingFamily' | head -80 || true
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
  echo "========== END STAGE 45 =========="
} >> "$REPORT"

split -b 220k "$REPORT" "$OUT/report-"
split -b 220k "$OUT/source-context.txt" "$OUT/source-context-"
split -b 220k "$OUT/abi-audit.txt" "$OUT/abi-audit-"

PAYLOAD_INDEX=0

# gh api can print its HTTP 404 JSON document to stdout even when the command
# exits non-zero. Never treat that document as a SHA: accept only a validated
# 40-character Git blob ID from a parsed JSON object's "sha" property.
github_contents_sha() {
  local remote_path="$1" raw
  raw="$(gh api "repos/$REPO/contents/$remote_path" 2>/dev/null || true)"
  printf '%s' "$raw" | python3 -c '
import json,re,sys
try:
    obj=json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
sha=obj.get("sha","") if isinstance(obj,dict) else ""
if isinstance(sha,str) and re.fullmatch(r"[0-9a-f]{40}",sha):
    print(sha)
'
}

upload_file() {
  local local_file="$1" remote_path="$2" message="$3" allow_update="${4:-0}"
  local old="" payload response put got local_blob

  local_blob="$(python3 - "$local_file" <<'PY2'
import hashlib,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest())
PY2
)"

  if [[ "$allow_update" == "1" ]]; then
    old="$(github_contents_sha "$remote_path")"
    if [[ ! "$old" =~ ^[0-9a-f]{40}$ ]]; then
      echo "UPDATE_TARGET_SHA_NOT_FOUND_OR_INVALID=$remote_path" >> "$UPLOAD_ERROR"
      return 1
    fi
  else
    old="$(github_contents_sha "$remote_path")"
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
if sha:
    obj["sha"]=sha
pathlib.Path(dst).write_text(json.dumps(obj),encoding="utf-8")
PY2

  if ! gh api --method PUT "repos/$REPO/contents/$remote_path" --input "$payload" > "$response" 2> "$OUT/gh-upload-error-$PAYLOAD_INDEX.txt"; then
    # Accept only if a competing/retried upload already stored identical bytes.
    got="$(github_contents_sha "$remote_path")"
    if [[ "$allow_update" != "1" && "$got" == "$local_blob" ]]; then
      UPLOAD_SHA="$got"
      echo "RACE_IDENTICAL_FILE_ACCEPTED=$remote_path SHA=$got" >> "$OUT/upload-verification.txt"
      return 0
    fi
    cat "$OUT/gh-upload-error-$PAYLOAD_INDEX.txt" >> "$UPLOAD_ERROR" || true
    echo "UPLOAD_FAILED_PATH=$remote_path EXPECTED_LOCAL_SHA=$local_blob REMOTE_SHA=${got:-MISSING}" >> "$UPLOAD_ERROR"
    return 1
  fi

  put="$(python3 - "$response" <<'PY2'
import json,re,sys
try:
    v=json.load(open(sys.argv[1]))
except Exception as e:
    raise SystemExit("Invalid GitHub upload response: "+str(e))
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
  echo "STAGE: 44"
  echo "RUN: $RUN"
  echo "PURPOSE: read-only exact 24H32 finalizeBSDInterface cleanup callback at vtable offset 0x858 and teardown ownership audit"
  echo "TARGET: macOS $OSVER / $BUILD / $ARCH"
  echo "PREDECESSOR: Stage43 source state $EXPECTED_STAGE43_CPP"
  echo "SOURCE_MODIFIED: NO"
  echo "BUILD: NOT_RUN"
  echo "ACTIVATION_GATE: BLOCKED"
  echo "LOCAL_OUTPUT: $OUT"
} > "$MANIFEST"

# Every artifact is retained twice: grouped by run and as unique root-level filenames.
upload_artifact() {
  local f="$1" suffix="$2" root_name group_name
  root_name="stage45-$RUN-$suffix"
  local base
  base="$(basename "$f")"
  [[ "$base" == *.txt ]] || base="$base.txt"
  group_name="Development/Logs/stage45/$RUN/$base"
  upload_file "$f" "$group_name" "Add Stage45 grouped log $RUN $(basename "$f")"
  echo "GROUPED_ARTIFACT=$group_name | GITHUB_BLOB=$UPLOAD_SHA" >> "$MANIFEST"
  upload_file "$f" "Development/Logs/$root_name" "Add unique Stage45 log $RUN $suffix"
  echo "ROOT_ARTIFACT=Development/Logs/$root_name | GITHUB_BLOB=$UPLOAD_SHA | BYTES=$(wc -c < "$f" | tr -d ' ')" >> "$MANIFEST"
}

for part in "$OUT"/report-*; do
  [[ -f "$part" ]] || continue
  suffix="$(basename "$part")"
  [[ "$suffix" == *.txt ]] || suffix="$suffix.txt"
  upload_artifact "$part" "$suffix"
done
for part in "$OUT"/source-context-* "$OUT"/abi-audit-*; do
  [[ -f "$part" ]] || continue
  base="$(basename "$part")"
  [[ "$base" == *.txt ]] || base="$base.txt"
  upload_artifact "$part" "$base"
done
upload_artifact "$OUT/source-fingerprint.txt" "source-fingerprint.txt"
upload_artifact "$OUT/upstream-verification.txt" "upstream-verification.txt"

# Include the manifest itself in both locations; all preceding file names are now recorded.
upload_file "$MANIFEST" "Development/Logs/stage45/$RUN/manifest.txt" "Add Stage45 grouped manifest $RUN"
MANIFEST_SHA="$UPLOAD_SHA"
upload_file "$MANIFEST" "Development/Logs/stage45-$RUN-manifest.txt" "Add unique Stage45 manifest $RUN"
ROOT_MANIFEST_SHA="$UPLOAD_SHA"

# Append Stage45 summary to Development/output.log without discarding prior entries.
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$EXPECTED_STAGE43_CPP" <<'PY'
import base64,json,pathlib,sys
remote,out,run,expected=sys.argv[1:]
obj=json.load(open(remote))
old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 45 BSD FINALIZE CLEANUP SLOT AUDIT ==========\n"
 f"STAGE45_RUN: {run}\n"
 "STAGE45_SCOPE: inherited IOSkywalkNetworkInterface::finalizeBSDInterface virtual cleanup target at vtable offset 0x858, class-specific ownership and teardown review\n"
 f"STAGE43_SOURCE_BASELINE: {expected}\n"
 "STAGE45_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"
 "ACTIVATION_GATE: BLOCKED — identifying the Apple cleanup callback does not implement queue registration, TX/RX completion, publication, or driver teardown\n"
 f"STAGE45_LOGS: Development/Logs/stage45/{run}/ and unique files directly under Development/Logs/\n"
 "==============================================================\n"
).encode()
pathlib.Path(out).write_bytes(old.rstrip()+entry)
PY
upload_file "$OUT/output.log" "Development/output.log" "Append Stage45 BSD lifecycle audit result $RUN" 1

echo
echo "STAGE45_SCRIPT_VERSION=STAGE45_V1_20261102"
echo "STAGE45_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE45_RUN=$RUN"
echo "STAGE45_LOCAL_OUTPUT=$OUT"
echo "STAGE45_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage45/$RUN"
echo "STAGE45_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE45_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE45_SOURCE_MODIFIED=NO"
echo "STAGE45_BUILD=NOT_RUN"
echo "STAGE45_INSTALL=NOT_RUN"
echo "STAGE45_LOAD=NOT_RUN"
echo "STAGE45_OPENCORE_CHANGE=NONE"
