#!/bin/bash
# Stage127: read-only Apple 24H32 power setter call graph and vtable slot audit.
# No driver changes/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
set -uo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
EXPECTED_KC_SHA="8e95c4ec87ed99e3732354f32ad9eed45b7607e7bc7034f32ff7437e0c6ec878"
BASE_STAGE125="3d02ef10e353bb80d032980ffe2e7d28b90fd7da"
INFRA_SETTER="__ZN21IO80211InfraInterface18setInterfaceEnableEb"
SKYWALK_SETTER="__ZN23IO80211SkywalkInterface18setInterfaceEnableEb"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$ROOT" ]]; then echo "ERROR: run inside the existing project checkout"; exit 2; fi
cd "$ROOT" || exit 2

CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
if [[ -z "$CURRENT_BRANCH" ]]; then CURRENT_BRANCH="DETACHED_OR_UNKNOWN"; fi
WORKTREE_STATUS_ENTRIES="$(git status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ -z "$WORKTREE_STATUS_ENTRIES" ]]; then WORKTREE_STATUS_ENTRIES="UNKNOWN"; fi
TARGET="$(sw_vers -productVersion 2>/dev/null || true)"
BUILD="$(sw_vers -buildVersion 2>/dev/null || true)"
ARCH="$(uname -m)"
if [[ "$TARGET" != "15.8.1" || "$BUILD" != "24H32" || "$ARCH" != "x86_64" ]]; then
  echo "ERROR: expected macOS 15.8.1 24H32 x86_64; found $TARGET $BUILD $ARCH"; exit 3
fi

TOOLCHAIN="/Applications/Xcode_16.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
NM="$TOOLCHAIN/llvm-nm"
OTOOL="$(command -v otool 2>/dev/null || true)"
if [[ ! -x "$NM" || -z "$OTOOL" || ! -x "$OTOOL" ]]; then
  echo "ERROR: Xcode 16.4 llvm-nm and macOS otool are required"; exit 4
fi

KC_OVERRIDE="$(printenv STAGE127_KC_MACHO 2>/dev/null || true)"
if [[ -n "$KC_OVERRIDE" ]]; then
  KC="$KC_OVERRIDE"
else
  KC="$(find "$HOME/Developer" -type f -path '*/kc-cache/com.apple.iokit.IO80211Family.macho' -print -quit 2>/dev/null || true)"
fi
if [[ -z "$KC" || ! -f "$KC" ]]; then
  echo "ERROR: Stage120 extracted IO80211Family Mach-O not found; set STAGE127_KC_MACHO"; exit 5
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMPROOT="$(printenv TMPDIR 2>/dev/null || printf /tmp)"
REPORT="$(mktemp "$TMPROOT/stage127-apple-power-callgraph-XXXXXX")" || exit 6
NM_FILE="$(mktemp "$TMPROOT/stage127-nm-XXXXXX")" || exit 6
DUMP_FILE="$(mktemp "$TMPROOT/stage127-dump-XXXXXX")" || exit 6
LOAD_FILE="$(mktemp "$TMPROOT/stage127-load-XXXXXX")" || exit 6
trap 'rm -f "$NM_FILE" "$DUMP_FILE" "$LOAD_FILE"' EXIT

KC_SHA="$(shasum -a 256 "$KC" | awk '{print $1}')"
if [[ "$KC_SHA" != "$EXPECTED_KC_SHA" ]]; then
  echo "ERROR: Apple IO80211Family Mach-O does not match Stage126 pin"
  echo "EXPECTED=$EXPECTED_KC_SHA"; echo "ACTUAL=$KC_SHA"; exit 7
fi
SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null || printf UNKNOWN)"
if ! "$NM" -n --defined-only "$KC" >"$NM_FILE" 2>&1; then
  echo "ERROR: llvm-nm failed"; sed -n '1,30p' "$NM_FILE"; exit 8
fi
if ! "$OTOOL" -l "$KC" >"$LOAD_FILE" 2>&1; then
  echo "ERROR: otool -l failed"; sed -n '1,30p' "$LOAD_FILE"; exit 9
fi

SYMBOL_RE='^(__ZN21IO80211InfraInterface18setInterfaceEnableEb|__ZN22IO80211MacAddressAgent18setInterfaceEnableEb|__ZN23IO80211SkywalkInterface18isInterfaceEnabledEv|__ZN23IO80211SkywalkInterface18setInterfaceEnableEb)$'
FIRST_SYMBOL="$(python3 - "$NM_FILE" "$SYMBOL_RE" <<'PY'
import pathlib, re, sys
entries=[]
for line in pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines():
    f=line.split()
    if len(f)>=3 and re.fullmatch(r"[0-9a-fA-F]+",f[0]) and re.fullmatch(sys.argv[2],f[-1]):
        entries.append((int(f[0],16),f[-1]))
if not entries: raise SystemExit(2)
print(min(entries)[1])
PY
)"
if [[ -z "$FIRST_SYMBOL" ]]; then echo "ERROR: exact Stage126 power symbols were not found"; exit 10; fi

if "$OTOOL" -arch x86_64 -tvV -p "$FIRST_SYMBOL" "$KC" >"$DUMP_FILE" 2>&1; then OTOOL_RC=0; else OTOOL_RC=$?; fi
if [[ "$OTOOL_RC" -ne 0 ]] || ! grep -Fq "$INFRA_SETTER" "$DUMP_FILE"; then
  echo "ERROR: otool dump failed or omitted infrastructure setter"; echo "OTOOL_EXIT=$OTOOL_RC"; sed -n '1,40p' "$DUMP_FILE"; exit 11
fi

{
  echo "========== STAGE127 APPLE POWER CALL GRAPH / VTABLE AUDIT =========="
  echo "STAGE127_SOURCE_COMMIT=$SOURCE_COMMIT"
  echo "STAGE127_EXECUTION_BRANCH=$CURRENT_BRANCH"
  echo "STAGE127_WORKTREE_STATUS_ENTRIES=$WORKTREE_STATUS_ENTRIES"
  echo "STAGE127_STAGE125_BASE=$BASE_STAGE125"
  echo "STAGE127_TARGET=$TARGET BUILD=$BUILD ARCH=$ARCH"
  echo "STAGE127_SCOPE=READ_ONLY_DIRECT_CALLER_AND_VTABLE_SLOT_AUDIT"
  echo "STAGE127_KC_MACHO_SHA256=$KC_SHA"
  echo "STAGE127_KC_MACHO_PATH=$KC"
  echo "STAGE127_DUMP_START_SYMBOL=$FIRST_SYMBOL"
  echo "STAGE127_OTOOL_EXIT_CODE=$OTOOL_RC"
  echo "STAGE127_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
  echo "STAGE127_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
  echo
  echo "--- Direct symbolized call sites ---"
  python3 - "$DUMP_FILE" "$NM_FILE" "$INFRA_SETTER" "$SKYWALK_SETTER" <<'PY'
import pathlib, re, sys
dump,nmpath,infra,sky=sys.argv[1:]
nm={}
for line in pathlib.Path(nmpath).read_text(errors="replace").splitlines():
    f=line.split()
    if len(f)>=3 and re.fullmatch(r"[0-9a-fA-F]+",f[0]):
        nm[f[-1]]=int(f[0],16)
lines=pathlib.Path(dump).read_text(errors="replace").splitlines()
targets={infra:"INFRA_SETTER",sky:"SKYWALK_SETTER"}
hits={k:[] for k in targets}
current="UNKNOWN_FUNCTION"
for line in lines:
    s=line.strip()
    if s.endswith(":") and not re.match(r"^(?:0x)?[0-9a-fA-F]{8,}:?$",s):
        current=s[:-1]
    m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):\s*(.*)$",line)
    if not m: continue
    addr=int(m.group(1),16); asm=m.group(2)
    if not re.search(r"\bcallq?\b",asm): continue
    am=re.search(r"\bcallq?\s+(?:0x)?([0-9a-fA-F]{8,})",asm)
    calladdr=int(am.group(1),16) if am else None
    for target in targets:
        if target in asm or (calladdr is not None and calladdr==nm.get(target)):
            hits[target].append((current,addr,line.strip()))
for target,kind in targets.items():
    print(f"STAGE127_{kind}_DIRECT_CALL_COUNT={len(hits[target])}")
    for fn,addr,line in hits[target][:50]:
        print(f"CALLER={fn} CALLSITE=0x{addr:x}")
        print("  "+line)
    if not hits[target]: print(f"STAGE127_{kind}_DIRECT_CALLS=NONE_FOUND_IN_DUMP")
PY
  echo
  echo "--- Relevant Apple vtable symbols ---"
  grep -E '__ZTV[0-9]+IO80211(InfraInterface|SkywalkInterface)' "$NM_FILE" || true
  echo
  echo "--- Resolve virtual byte offset 0xD58 ---"
  python3 - "$NM_FILE" "$LOAD_FILE" "$KC" <<'PY'
import pathlib, re, struct, sys
nm_path,load_path,macho=sys.argv[1:]
nm_lines=pathlib.Path(nm_path).read_text(errors="replace").splitlines()
load_lines=pathlib.Path(load_path).read_text(errors="replace").splitlines()
symbols=[]; text_symbols=[]
for line in nm_lines:
    f=line.split()
    if len(f)<3 or not re.fullmatch(r"[0-9a-fA-F]+",f[0]): continue
    addr=int(f[0],16); typ=f[-2]; name=f[-1]
    if typ.upper()=="T": text_symbols.append((addr,name))
    if "__ZTV" in name and ("IO80211InfraInterface" in name or "IO80211SkywalkInterface" in name):
        symbols.append((addr,typ,name))
sections=[]; i=0
while i<len(load_lines):
    if load_lines[i].strip()=="Section":
        block=[]; i+=1
        while i<len(load_lines) and load_lines[i].strip()!="Section" and not load_lines[i].startswith("Load command"):
            block.append(load_lines[i]); i+=1
        fields={}
        for line in block:
            m=re.match(r"\s*(sectname|segname|addr|size|offset)\s+(\S+)",line)
            if m: fields[m.group(1)]=m.group(2)
        if all(k in fields for k in ("sectname","segname","addr","size","offset")):
            try: sections.append((fields["segname"],fields["sectname"],int(fields["addr"],0),int(fields["size"],0),int(fields["offset"],0)))
            except ValueError: pass
        continue
    i+=1
raw=pathlib.Path(macho).read_bytes()
def read_qword(vaddr):
    for seg,sect,addr,size,off in sections:
        if addr<=vaddr and vaddr+8<=addr+size and off:
            fileoff=off+(vaddr-addr)
            if fileoff+8<=len(raw):
                return struct.unpack("<Q",raw[fileoff:fileoff+8])[0],seg,sect,fileoff
    return None
if not symbols: print("STAGE127_VTABLE_SYMBOLS=NOT_FOUND")
for vaddr,typ,name in sorted(symbols):
    print(f"VTABLE_SYMBOL={name} TYPE={typ} ADDRESS=0x{vaddr:x}")
    for mode,slot_addr in (("ITANIUM_ADDRESS_POINT_PLUS_0xD58",vaddr+0x10+0xD58),
                           ("RAW_SYMBOL_PLUS_0xD58",vaddr+0xD58)):
        item=read_qword(slot_addr)
        print(f"  {mode}_VIRTUAL_ADDRESS=0x{slot_addr:x}")
        if item is None:
            print(f"  {mode}_STATUS=NO_FILE_BACKED_SECTION"); continue
        val,seg,sect,fileoff=item
        print(f"  {mode}_SECTION={seg},{sect} FILE_OFFSET=0x{fileoff:x}")
        print(f"  {mode}_RAW_TARGET=0x{val:x}")
        near=[(a,n) for a,n in text_symbols if a<=val]
        if val and near:
            a,n=max(near); delta=val-a
            if delta<=0x2000:
                print(f"  {mode}_NEAREST_TEXT_SYMBOL={n} SYMBOL_ADDRESS=0x{a:x} DELTA=0x{delta:x}")
            else: print(f"  {mode}_NEAREST_TEXT_SYMBOL=NO_CLOSE_TEXT_SYMBOL")
        else: print(f"  {mode}_NEAREST_TEXT_SYMBOL=UNRESOLVED")
PY
  echo
  echo "--- Power-related controller/interface entry points ---"
  grep -E ' T __ZN.*IO80211(Controller|InfraInterface|SkywalkInterface).*(getPOWER|setPOWER|enable|disable|setInterfaceEnable|isInterfaceEnabled)' "$NM_FILE" | sed -n '1,80p' || true
  echo
  echo "STAGE127_VTABLE_OFFSET_BYTES=0xD58"
  echo "STAGE127_VTABLE_SLOT_INDEX_DECIMAL=427"
  echo "STAGE127_VTABLE_ADDRESS_POINT_ASSUMPTION=ITANIUM_ABI_VTABLE_SYMBOL_PLUS_0x10"
  echo "STAGE127_CALL_GRAPH_SCOPE=DIRECT_SYMBOLIZED_CALL_TARGETS_ONLY"
  echo "STAGE127_POWER_CALL_GRAPH=REVIEW_REQUIRED_UNTIL_VTABLE_OWNER_AND_CALLERS_RESOLVED"
  echo "STAGE127_DRIVER_SOURCE_MODIFIED=NO"
  echo "STAGE127_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
  echo "STAGE127_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
  echo "========== END STAGE127 =========="
} >"$REPORT"

echo "===== STAGE127 SUMMARY ====="
grep -aE '^(STAGE127_|VTABLE_SYMBOL=|  (ITANIUM|RAW_SYMBOL)|CALLER=|  callq|ERROR:)' "$REPORT" | tail -140 || true
echo "STAGE127_LOCAL_REPORT=$REPORT"

python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64, hashlib, json, pathlib, subprocess, sys, tempfile, time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest=f"Development/Logs/stage127-apple-power-callgraph-{stamp}.log"
payload={"message":"Stage127: publish read-only Apple 24H32 power call-graph and vtable audit",
         "branch":"main","content":base64.b64encode(data).decode("ascii")}
expected=hashlib.sha1(f"blob {len(data)}\0".encode("ascii")+data).hexdigest()
last_error=""
for attempt in range(1,4):
    with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
        json.dump(payload,f); f.flush()
        r=subprocess.run(["gh","api","--method","PUT",f"repos/{repo}/contents/{dest}","--input",f.name],
                         capture_output=True,text=True)
    if r.returncode==0:
        try: actual=json.loads(r.stdout).get("content",{}).get("sha")
        except Exception: actual=None
        if actual==expected:
            print("STAGE127_UPLOAD=PASS"); print("STAGE127_UPLOAD_BYTES="+str(len(data)))
            print("STAGE127_UPLOAD_SHA="+actual); print("STAGE127_GITHUB_PATH="+dest)
            print("STAGE127_GITHUB_URL=https://github.com/"+repo+"/blob/main/"+dest); break
        last_error="GitHub SHA mismatch: "+str(actual)
    else: last_error=r.stderr.strip() or r.stdout.strip()
    check=subprocess.run(["gh","api",f"repos/{repo}/contents/{dest}?ref=main"],capture_output=True,text=True)
    if check.returncode==0:
        try: existing=json.loads(check.stdout).get("sha")
        except Exception: existing=None
        if existing==expected:
            print("STAGE127_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT")
            print("STAGE127_UPLOAD_BYTES="+str(len(data))); print("STAGE127_UPLOAD_SHA="+existing)
            print("STAGE127_GITHUB_PATH="+dest)
            print("STAGE127_GITHUB_URL=https://github.com/"+repo+"/blob/main/"+dest); break
        print("STAGE127_UPLOAD=DESTINATION_EXISTS_WITH_DIFFERENT_SHA")
        print("EXPECTED="+expected); print("EXISTING="+str(existing)); raise SystemExit(8)
    print(f"STAGE127_UPLOAD_ATTEMPT={attempt}_FAILED")
    if attempt<3: time.sleep(attempt*3)
else:
    print("STAGE127_UPLOAD=FAILED"); print(last_error); raise SystemExit(9)
PY
