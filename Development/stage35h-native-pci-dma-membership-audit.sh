#!/bin/bash
# Stage 35H — audit native PCI/DMA source membership, linker inputs, and stale artifacts.
# Read-only: make -n -B only; source tree and artifacts are inspected, never changed.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35H-$RUN"
REPORT="$OUT/report.txt"
DRYRUN="$OUT/native-dry-run.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35H_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
for tool in gh python3 make shasum split grep find nm file; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" ]] || { echo "ERROR: Stage26 Makefile missing: $SRC/Makefile"; exit 3; }
[[ -f "$SRC/src/kext/RTW88PCIDevice.cpp" ]] || { echo "ERROR: RTW88PCIDevice.cpp missing from expected source tree"; exit 4; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated. Run gh auth login."; exit 5; }

{
 echo "========== STAGE 35H: NATIVE PCI/DMA MEMBERSHIP AUDIT =========="
 echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
 echo "host=$(hostname 2>/dev/null || echo unknown)"
 echo "source_root=$SOURCE_ROOT"
 echo "target=rtl88wifi-native"
 echo "mode=read-only source inspection + make -n -B"
 echo
 echo "--- Makefile safety preflight ---"
} > "$REPORT"

python3 - "$SRC/Makefile" "$SRC/build" "$OUT/preflight.txt" <<'PY'
import pathlib,re,sys
mk,build,out=map(pathlib.Path,sys.argv[1:])
lines=mk.read_text(errors="replace").splitlines()
issues=[]; notes=[]
for n,line in enumerate(lines,1):
    if "$(shell" in line or "\${shell" in line:
        expr=line.split("$(shell",1)[-1].split(")",1)[0] if "$(shell" in line else line.split("\${shell",1)[-1].split("}",1)[0]
        commands=re.findall(r"(?:^|[|;&()]\s*)([A-Za-z_][A-Za-z0-9_.-]*)",expr)
        bad=[c for c in commands if c not in {"sysctl","pwd","xcrun","echo"}]
        if bad: issues.append("UNSAFE_PARSE_SHELL line %d commands=%s"%(n,bad))
        else: notes.append("READ_ONLY_PARSE_SHELL line %d: %s"%(n,line.strip()))
    if "$(MAKE)" in line or "\${MAKE}" in line: issues.append("RECURSIVE_MAKE line %d: %s"%(n,line.strip()))
    if any(x in line for x in ("$(file","\${file","$(guile","$(eval")): issues.append("SIDE_EFFECT_MAKE_FUNCTION line %d: %s"%(n,line.strip()))
    if re.match(r"^\t[ \t]*[ @+-]*\+",line): issues.append("FORCE_RECIPE line %d: %s"%(n,line.strip()))
depfiles=list(build.rglob("*.d")) if build.exists() else []
for p in depfiles:
    try: d=p.read_text(errors="replace")
    except OSError as e: issues.append("DEPFILE_READ_ERROR %s %s"%(p,e)); continue
    if any(x in d for x in ("$(MAKE)","$(shell","\${shell","$(file","$(eval")) or re.search(r"(?m)^\t[ \t]*[ @+-]*\+",d):
        issues.append("UNSAFE_INCLUDED_DEPFILE %s"%p)
print("DEPFILES_SCANNED=%d"%len(depfiles))
for x in notes: print(x)
for x in issues: print("BLOCKER="+x)
print("PREFLIGHT="+("BLOCKED" if issues else "PASS"))
pathlib.Path(out).write_text("PREFLIGHT="+("BLOCKED" if issues else "PASS")+"\n"+"\n".join(notes+issues)+"\n")
PY
cat "$OUT/preflight.txt" >> "$REPORT"

if ! grep -q '^PREFLIGHT=PASS$' "$OUT/preflight.txt"; then
  echo "NATIVE_DRY_RUN=SKIPPED_PREFLIGHT_BLOCKED" >> "$REPORT"
else
  set +e
  (cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -n -B -f Makefile rtl88wifi-native) > "$DRYRUN" 2>&1
  MAKE_RC=$?
  set -e
  echo "MAKE_DRY_RUN_EXIT=$MAKE_RC" >> "$REPORT"
fi

python3 - "$SRC" "$DRYRUN" "$OUT" >> "$REPORT" <<'PY2'
import hashlib,os,pathlib,re,shlex,subprocess,sys
src,dryrun,out=map(pathlib.Path,sys.argv[1:])
mk=(src/"Makefile").read_text(errors="replace")
lines=mk.splitlines()
print("\n--- Makefile declaration context ---")
keys=("RTW88PCIDevice.cpp","NATIVE_CORE_SRCS","NATIVE_CORE_OBJS","NATIVE_ALL_OBJS","AIRPORT_KEXT_SRCS","AIRPORT_KEXT_OBJS","WCL24H32_PCI_BACKEND_OBJ","rtl88wifi-native")
for i,line in enumerate(lines,1):
    if any(k in line for k in keys):
        lo=max(1,i-3); hi=min(len(lines),i+4)
        print("\n[Makefile lines %d-%d]"%(lo,hi))
        for n in range(lo,hi+1): print("%4d %s"%(n,lines[n-1]))
print("\n--- Source-level PCI/DMA symbol scan ---")
patterns=re.compile(r"RTW88PCIDevice|rtw88_dma_ops|\bdma_ops\b|dma_alloc_coherent|dma_map_single|dma_unmap_single|dma_set_mask|set_dma_ops|rtw88_pci_probe|request_irq|IOInterruptEventSource")
for root in [src/"src/kext",src/"src/compat"]:
    for base,dirs,files in os.walk(root):
        dirs[:]=[d for d in dirs if d not in {".git","build"}]
        for name in sorted(files):
            p=pathlib.Path(base)/name
            if p.suffix.lower() not in {".c",".cc",".cpp",".h",".hpp"}: continue
            try: content=p.read_text(errors="replace").splitlines()
            except OSError: continue
            for n,line in enumerate(content,1):
                if patterns.search(line): print("%s:%d:%s"%(p.relative_to(src),n,line.strip()[:260]))
print("\n--- Forced dry-run compile and link graph ---")
output=dryrun.read_text(errors="replace") if dryrun.exists() else ""
print("DRY_RUN_FILE_EXISTS=%s"%dryrun.exists())
compile_map=[]; link_lines=[]
for line in output.splitlines():
    try: args=shlex.split(line)
    except ValueError: continue
    if not args: continue
    if "-c" in args and "-o" in args:
        try:
            source=args[args.index("-c")+1]; obj=args[args.index("-o")+1]
            if source.endswith((".c",".cc",".cpp")): compile_map.append((source,obj))
        except IndexError: pass
    if "-o" in args and any(x.endswith("RTL88WiFiNative") for x in args):
        link_lines.append(args)
print("COMPILE_TRANSLATIONS=%d"%len(compile_map))
for source,obj in compile_map: print("COMPILE %s => %s"%(source,obj))
print("NATIVE_LINK_COMMANDS=%d"%len(link_lines))
linked_objects=[]
for args in link_lines:
    oi=args.index("-o"); output_path=args[oi+1]
    objs=[x for x in args[oi+2:] if x.endswith(".o")]
    linked_objects.extend(objs)
    print("LINK_OUTPUT="+output_path)
    print("LINK_OBJECT_COUNT=%d"%len(objs))
    for o in objs: print("LINK_OBJECT="+o)
print("\n--- Membership determinations ---")
pcisrc=[(s,o) for s,o in compile_map if s.endswith("/RTW88PCIDevice.cpp")]
print("PCIDEVICE_SOURCE_COMPILE_COUNT=%d"%len(pcisrc))
print("PCIDEVICE_OBJECT_LINKED=%s"%("YES" if any(x.endswith("/RTW88PCIDevice.o") for x in linked_objects) else "NO"))
for name in ["RTW88HwOps.o","RTW88WCLRadioBridge.o","RTW88WCLWorkQueue.o","RTW88WCLController.o","RTW88WCLInfraInterface.o","RTW88WCLPCIBackend.o","RTW88WCLSkywalkQueues.o","RTW88WCLSkywalkTxAdapter.o","RTW88WCLSkywalkRxAdapter.o"]:
    print("%s_LINKED=%s"%(name,"YES" if any(x.endswith("/"+name) for x in linked_objects) else "NO"))
print("\n--- Existing object / binary evidence (read-only; may be stale) ---")
candidates=[src/"build/native/RTW88HwOps.o",src/"build/airport/RTW88PCIDevice.o",src/"build/native/RTW88PCIDevice.o",src/"build/out/RTL88WiFiNative.kext/Contents/MacOS/RTL88WiFiNative"]
for p in candidates:
    print("ARTIFACT path=%s exists=%s"%(p.relative_to(src),p.exists()))
    if p.exists():
        st=p.stat()
        print("  bytes=%d mtime_epoch=%d sha256=%s"%(st.st_size,int(st.st_mtime),hashlib.sha256(p.read_bytes()).hexdigest()))
        try:
            f=subprocess.run(["file",str(p)],capture_output=True,text=True,timeout=10)
            print("  file=%s"%(f.stdout.strip() or f.stderr.strip()))
        except Exception as e: print("  file_error=%s"%e)
        if p.suffix==".o" or p.name=="RTL88WiFiNative":
            try:
                nm=subprocess.run(["nm","-g",str(p)],capture_output=True,text=True,timeout=20)
                print("  nm_exit=%d"%nm.returncode)
                for line in nm.stdout.splitlines():
                    if re.search(r"dma_ops|rtw88_dma|RTW88PCIDevice|rtw88_pci|IOInterrupt",line,re.I): print("  SYMBOL "+line[:300])
                if nm.returncode: print("  nm_error="+nm.stderr[:600])
            except Exception as e: print("  nm_error=%s"%e)
print("\n--- Safety boundary ---")
print("SOURCE_TREE_MODIFIED=NO")
print("BUILD=NOT_RUN")
print("INSTALL=NOT_RUN")
print("LOAD=NOT_RUN")
print("OPENCORE_MODIFIED=NO")
PY2

{
 echo
 echo "--- Final status ---"
 echo "DRY_RUN_COMMANDS_SAVED=$DRYRUN"
 echo "REPORT=$REPORT"
 echo "ACTUAL_BUILD=NOT_RUN"
 echo "KEXT_INSTALL=NOT_RUN"
 echo "KEXT_LOAD=NOT_RUN"
 echo "HARDWARE_TEST=NOT_RUN"
 echo "========== END STAGE 35H =========="
} >> "$REPORT"

mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"
upload_file() {
 local file="$1" path="$2" msg="$3" payload="$4" response="$5" old put got
 old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
 python3 - "$file" "$old" "$msg" "$payload" <<'PY3'
import base64,json,pathlib,sys
f,sha,msg,dest=sys.argv[1:]
v={"message":msg,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha:v["sha"]=sha
pathlib.Path(dest).write_text(json.dumps(v))
PY3
 if ! gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" >"$response" 2>"$UPLOAD_ERROR"; then
   echo "UPLOAD_FAILED_PATH=$path" >>"$UPLOAD_ERROR"
   echo "AUTH_ACCOUNT=$(gh api user --jq .login 2>&1 || true)" >>"$UPLOAD_ERROR"
   echo "REPO_PERMISSION=$(gh api "repos/$REPO" --jq '.full_name + " push=" + (.permissions.push|tostring)' 2>&1 || true)" >>"$UPLOAD_ERROR"
   return 1
 fi
 put="$(python3 - "$response" <<'PY3'
import json,sys
v=json.load(open(sys.argv[1])); s=(v.get("content") or {}).get("sha")
if not s: raise SystemExit("Missing returned blob SHA: "+repr(v)[:700])
print(s)
PY3
)"
 got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
 [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >>"$UPLOAD_ERROR"; return 1; }
 UPLOAD_SHA="$got"
}
MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 35H\nRUN: %s\nTARGET: rtl88wifi-native\n' "$RUN" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
 [[ -f "$part" ]] || continue
 name="$(basename "$part").txt"
 remote="Development/Logs/stage35h/$RUN/$name"
 upload_file "$part" "$remote" "Add Stage35H PCI DMA membership audit $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
 printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
 COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35h/$RUN/manifest.txt" "Add Stage35H manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35H_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35H_RUN=$RUN"
echo "STAGE35H_REPORT_PARTS=$COUNT"
echo "STAGE35H_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35h/$RUN"
