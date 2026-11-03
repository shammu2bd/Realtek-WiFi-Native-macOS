#!/bin/bash
# Stage 35: read-only native build/source-membership audit.
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE35_ERROR: exit=$rc line=$LINENO" >&2; exit "$rc"' ERR
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PROJECT_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
if [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$PROJECT_NAME/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$HOME/Downloads/$PROJECT_NAME"
else
  echo "ERROR: project root not found. Run from the project root or restore it under ~/Downloads/$PROJECT_NAME."
  exit 2
fi
for tool in python3 gh curl shasum split plutil; do
  command -v "$tool" >/dev/null || { echo "ERROR: missing required tool: $tool"; exit 2; }
done
gh auth status >/dev/null
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN="run-$STAMP"
STAGE="$PROJECT/build/stage35-native-build-audit-$STAMP"
mkdir -p "$STAGE/parts"
REPORT="$STAGE/stage35-native-build-source-membership-audit.txt"
echo "STAGE35_PROJECT=$PROJECT"
python3 - "$PROJECT" "$REPORT" <<'PY'
from pathlib import Path
import hashlib, json, re, subprocess, sys
root=Path(sys.argv[1]).resolve(); out=Path(sys.argv[2])
def run(cmd, cwd=None):
    try:
        p=subprocess.run(cmd,cwd=cwd,capture_output=True,text=True,timeout=45)
        return p.returncode,p.stdout,p.stderr
    except Exception as e: return 999,"",str(e)
def git(args):
    return run(["git","-C",str(root),*args])
# Git root and complete state are recorded independently; no assumption that root==project.
grc,groot,gerr=git(["rev-parse","--show-toplevel"])
if grc==0:
    headrc,head,headerr=git(["rev-parse","HEAD"])
    branchrc,branch,brancherr=git(["branch","--show-current"])
    statusrc,status,statuserr=git(["status","--porcelain=v2","--branch","--untracked-files=all"])
    trackedrc,tracked,trackederr=git(["ls-files"])
    changedrc,changed,changederr=git(["diff","--name-status"])
    stagedrc,staged,stagederr=git(["diff","--cached","--name-status"])
    untrackedrc,untracked,untrackederr=git(["ls-files","--others","--exclude-standard"])
    diffcheckrc,diffcheck,diffcheckerr=git(["diff","--check"])
else:
    headrc=branchrc=statusrc=trackedrc=changedrc=stagedrc=untrackedrc=diffcheckrc=999
    head=branch=status=tracked=changed=staged=untracked=diffcheck=""
    headerr=brancherr=statuserr=trackederr=changederr=stagederr=untrackederr=diffcheckerr="git root unavailable"
gitroot=Path(groot.strip()).resolve() if grc==0 else None
tracked_set=set(tracked.splitlines()) if trackedrc==0 else set()
def relgit(p):
    try: return p.resolve().relative_to(gitroot).as_posix() if gitroot else ""
    except ValueError: return ""
# Inventory likely project/build descriptors.
descriptors=[]
for p in root.rglob("*"):
    if not p.is_file(): continue
    parts=set(p.relative_to(root).parts)
    if parts & {".git","build","DerivedData","Pods","node_modules","vendor"}: continue
    n=p.name.lower()
    if n=="makefile" or n.endswith((".mk",".xcodeproj")) or n=="project.pbxproj" or n.endswith((".xcconfig",".xcscheme")):
        if p.stat().st_size < 8_000_000: descriptors.append(p)
descriptors.sort()
# Extract Xcode targets and exact PBXSourcesBuildPhase membership using plutil's OpenStep plist parser.
xcode=[]; xcode_errors=[]
for pbx in [p for p in descriptors if p.name=="project.pbxproj"]:
    jrc,jout,jerr=run(["plutil","-convert","json","-o","-",str(pbx)])
    if jrc: xcode_errors.append(f"{pbx.relative_to(root)}: plutil failed: {jerr.strip()}"); continue
    try: obj=json.loads(jout)["objects"]
    except Exception as e: xcode_errors.append(f"{pbx.relative_to(root)}: JSON parse failed: {e}"); continue
    refs={}
    for oid,o in obj.items():
        if o.get("isa")=="PBXFileReference":
            refs[oid]=o.get("path") or o.get("name") or oid
    builds={}
    for oid,o in obj.items():
        if o.get("isa")=="PBXBuildFile":
            fr=o.get("fileRef") or o.get("fileRef") # explicit file refs only
            if fr: builds[oid]=refs.get(fr, f"UNRESOLVED_FILE_REF:{fr}")
    phases={}
    for oid,o in obj.items():
        if o.get("isa")=="PBXSourcesBuildPhase":
            phases[oid]=[builds[x] for x in o.get("files",[]) if x in builds]
    for oid,o in obj.items():
        if o.get("isa") in ("PBXNativeTarget","PBXAggregateTarget"):
            phaseids=o.get("buildPhases",[])
            src=[]
            for ph in phaseids: src += phases.get(ph,[])
            xcode.append({"project":pbx.relative_to(root).as_posix(),"target":o.get("name",oid),"productType":o.get("productType",""),"productName":o.get("productName",""),"sources":src})
# Makefiles: preserve literal declarations, include relationships and relevant source/object variables.
make_data=[]
for mf in [p for p in descriptors if p.name.lower()=="makefile" or p.suffix.lower()==".mk"]:
    try: lines=mf.read_text(errors="replace").splitlines()
    except Exception as e: make_data.append((mf.relative_to(root).as_posix(),[f"READ_ERROR: {e}"])); continue
    selected=[]
    for i,line in enumerate(lines):
        if re.search(r'(^\s*(-?include|sinclude)\b|\b(SRCS?|SOURCES?|OBJS?|OBJECTS?|TARGET|PRODUCT|KEXT|MODULE|CXX|CC)\s*[:+?]?=|\.cpp|\.cc|\.cxx|\.c\b|\$\(wildcard)',line,re.I):
            selected.append(f"{i+1}: {line}")
    make_data.append((mf.relative_to(root).as_posix(),selected))
# Scan code symbols: distinguish definitions from declarations/references; report file/line and context.
source_ext={".c",".cc",".cpp",".cxx",".h",".hpp",".hh",".m",".mm"}
symbol_patterns={
 "dma_ops_definition": re.compile(r'(?m)^\s*(?:static\s+)?(?:const\s+)?(?:struct\s+\w+\s+)?(?:rtw88_dma_ops|_dma_ops)\s*(?:=|\{)'),
 "dma_ops_assignment": re.compile(r'\b(?:rtw88_dma_ops|_dma_ops)\s*='),
 "dma_ops_reference": re.compile(r'\b(?:rtw88_dma_ops|_dma_ops)\b'),
 "native_tx": re.compile(r'\b(?:rtw_ops_tx|rtw_tx|rtw_pci_tx_write_data|txDataFrame|outputPacketWithCompletion|txSubmissionAction)\b'),
}
hits={k:[] for k in symbol_patterns}; source_files=[]; read_errors=[]
skip={".git","build","DerivedData","Pods","node_modules","vendor"}
for p in root.rglob("*"):
    if not p.is_file() or p.suffix.lower() not in source_ext or set(p.relative_to(root).parts)&skip: continue
    try: lines=p.read_text(errors="replace").splitlines()
    except Exception as e: read_errors.append(f"{p.relative_to(root)}: {e}"); continue
    source_files.append(p)
    for i,line in enumerate(lines):
        stripped=line.strip()
        if stripped.startswith(("//","/*","*")): continue
        for k,rx in symbol_patterns.items():
            if rx.search(line):
                hits[k].append((p.relative_to(root).as_posix(),i+1,line.strip()))
# Match Xcode file paths to on-disk paths with cautious basename fallback flagged as ambiguous.
def resolve_source(project_file, item):
    base=Path(project_file).parent
    candidates=[(base/item).resolve(),(root/item).resolve(),(root/"driver"/"RTL88WiFi"/item).resolve()]
    for c in candidates:
        if c.is_file():
            try:return c.relative_to(root).as_posix(),"exact"
            except ValueError: pass
    found=list(root.rglob(Path(item).name)) if Path(item).name else []
    found=[p for p in found if p.is_file() and not (set(p.relative_to(root).parts)&skip)]
    if len(found)==1:return found[0].relative_to(root).as_posix(),"basename-unique"
    if len(found)>1:return "AMBIGUOUS:"+",".join(p.relative_to(root).as_posix() for p in found[:8]),"ambiguous"
    return "MISSING:"+item,"missing"
# Summarize candidate experimental Kext target(s) without assuming names.
L=[
"RTL88WiFi Stage35 — native build and source-membership audit",
f"PROJECT_ROOT: {root}",
"TARGET: macOS Sequoia 15.8.1 / build 24H32 / Intel x86_64",
"MODE: READ-ONLY; no source edits, build, install, load, or OpenCore changes.",
"PURPOSE: identify actual project root/Git state, build targets and source membership; resolve _dma_ops linkage evidence.",
"",
"=== GIT STATE ===",
f"git rev-parse exit={grc}",f"git root={groot.strip() or '(unavailable)'}",f"git root stderr={gerr.strip() or '(none)'}",
f"HEAD exit={headrc}: {head.strip() or '(unavailable)'}",f"branch exit={branchrc}: {branch.strip() or '(unavailable or detached)'}",
f"status exit={statusrc}",status.strip() or "(clean/no output/unavailable)",
f"tracked files exit={trackedrc}; count={len(tracked_set)}",
f"changed unstaged exit={changedrc}",changed.strip() or "(none/unavailable)",
f"changed staged exit={stagedrc}",staged.strip() or "(none/unavailable)",
f"untracked exit={untrackedrc}",untracked.strip() or "(none/unavailable)",
f"git diff --check exit={diffcheckrc}",diffcheck.strip() or "(no whitespace errors/unavailable)",
"NOTE: Git state is valid only if the detected Git root actually contains this project checkout; paths outside the Git root are not treated as tracked.",
"",
"=== BUILD DESCRIPTOR INVENTORY ===",
]
for p in descriptors:
    try: size=p.stat().st_size
    except: size=-1
    rg=relgit(p)
    L.append(f"{p.relative_to(root).as_posix()} | bytes={size} | inside_git_root={'yes' if rg else 'no'} | tracked={'yes' if rg in tracked_set else 'no' if rg else 'not-applicable'}")
L += ["","=== XCODE TARGETS AND PBXSourcesBuildPhase MEMBERSHIP ==="]
if not xcode: L.append("NO Xcode PBXNativeTarget/PBXSourcesBuildPhase membership extracted.")
for target in xcode:
    L += ["",f"PROJECT: {target['project']}",f"TARGET: {target['target']} | productType={target['productType']} | productName={target['productName']}",f"SOURCE_BUILD_FILE_COUNT: {len(target['sources'])}"]
    for item in target["sources"]:
        resolved,how=resolve_source(target["project"],item)
        rg=relgit(root/resolved) if not resolved.startswith(("MISSING:","AMBIGUOUS:")) else ""
        L.append(f"  {item} => {resolved} [{how}] git_tracked={'yes' if rg in tracked_set else 'no' if rg else 'unknown'}")
L += ["","=== MAKEFILE SOURCE/TARGET DECLARATIONS ==="]
for path,lines in make_data:
    L += ["",f"--- {path} ---"] + (["  "+x for x in lines] if lines else ["(no relevant declarations matched)"])
L += ["","=== _dma_ops DEFINITIONS / ASSIGNMENTS / REFERENCES ==="]
for k,items in hits.items():
    L += ["",f"[{k}] count={len(items)}"]
    for path,line,text in items: L.append(f"  {path}:{line}: {text}")
# Evaluate whether definition translation units are members of each discovered Xcode target.
L += ["","=== LINKAGE RESOLUTION ==="]
defs=hits["dma_ops_definition"]
if len(defs)==0: L.append("No definition-shaped _dma_ops/rtw88_dma_ops declaration found by the conservative definition matcher; inspect assignments and source excerpts.")
elif len(defs)==1: L.append(f"ONE definition-shaped occurrence repository-wide: {defs[0][0]}:{defs[0][1]}. This alone does not prove the symbol is externally linked or included in the experimental target.")
else: L.append(f"MULTIPLE definition-shaped occurrences repository-wide: {len(defs)}. They are not automatically duplicate linked symbols; target membership and linkage/storage class must be checked.")
for t in xcode:
    members=set()
    for item in t["sources"]:
        resolved,how=resolve_source(t["project"],item)
        if not resolved.startswith(("MISSING:","AMBIGUOUS:")): members.add(resolved)
    present=[d for d in defs if d[0] in members]
    L.append(f"TARGET {t['target']}: definition TUs linked by PBXSourcesBuildPhase = {len(present)} / {len(defs)}; "+(", ".join(f"{x[0]}:{x[1]}" for x in present) if present else "none identified"))
if not xcode: L.append("Cannot resolve linked definition count: no Xcode source build phase was parsed. Makefile text is reported but not treated as proof of final linker membership.")
L += ["","=== AUDIT LIMITATIONS / ERRORS ===",f"Xcode parse errors: {len(xcode_errors)}"] + (xcode_errors or ["NONE"])
L += [f"Source read errors: {len(read_errors)}"] + (read_errors or ["NONE"])
L += ["","=== STAGE35 DECISION ===",
"PROJECT_ROOT: established from the requested driver/RTL88WiFi/Makefile path.",
"GIT_STATE: "+("AVAILABLE" if grc==0 else "UNAVAILABLE — resolve checkout/repository root before claiming tracked state."),
"BUILD_MEMBERSHIP: "+("XCODE TARGET SOURCE MEMBERSHIP EXTRACTED" if xcode else "NOT PROVEN — no Xcode target source phase parsed; inspect Makefile/build invocation."),
"DMA_OPS_LINKAGE: "+("REVIEW_REQUIRED — inspect storage class, target membership, and duplicate-symbol rules." if len(defs)>1 else "REVIEW_REQUIRED — confirm the single candidate definition is linked and active." if len(defs)==1 else "UNRESOLVED — no conservative definition found."),
"ACTIVATION_GATE: BLOCKED until the exact experimental Kext target, all linked translation units, and one unambiguous active DMA ops implementation are proven.",
"NO SOURCE FILES WERE MODIFIED. BUILD/INSTALL/LOAD NOT RUN. OPENCORE UNCHANGED."]
out.write_text("\n".join(L)+"\n")
print("REPORT:",out)
print("GIT_ROOT:",groot.strip() or "UNAVAILABLE")
print("GIT_HEAD:",head.strip() or "UNAVAILABLE")
print("XCODE_TARGETS:",len(xcode))
for t in xcode: print("XCODE_TARGET:",t["target"],"SOURCE_FILES:",len(t["sources"]))
print("DMA_OPS_DEFINITION_OCCURRENCES:",len(defs))
for d in defs: print("DMA_OPS_DEF:",d[0]+":"+str(d[1]),d[2])
print("REPORT_BYTES:",out.stat().st_size)
PY
test -s "$REPORT"
if command -v shellcheck >/dev/null 2>&1; then shellcheck "$PROJECT/Development/stage35-native-build-source-membership-audit.sh" >"$STAGE/shellcheck.txt" 2>&1 || true; else echo "shellcheck not installed; skipped" >"$STAGE/shellcheck.txt"; fi
split -b 280000 -d -a 3 "$REPORT" "$STAGE/parts/report-"
MANIFEST="$STAGE/manifest.txt"; : > "$MANIFEST"
upload_file() {
  local file="$1" path="$2" message="$3" payload="$4" response="$5" old="" put="" got=""
  old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
  python3 - "$file" "$old" "$message" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,sha,msg,dst=sys.argv[1:]
o={"message":msg,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha:o["sha"]=sha
pathlib.Path(dst).write_text(json.dumps(o))
PY2
  gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" >"$response"
  put="$(python3 - "$response" <<'PY2'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY2
)"
  got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
  [[ "$put" == "$got" ]] || { echo "ERROR: readback SHA mismatch: $path"; return 1; }
  UPLOAD_SHA="$got"; echo "UPLOAD_VERIFIED $path $got"
}
PARTS=0
for part in "$STAGE"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"; remote="Development/Logs/stage35/$RUN/$name"
  upload_file "$part" "$remote" "Add immutable Stage35 audit chunk $RUN/$name" "$STAGE/upload.json" "$STAGE/upload-response.json"
  printf '%s %s %s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" >>"$MANIFEST"
  PARTS=$((PARTS+1))
done
remote="Development/Logs/stage35/$RUN/shellcheck.txt"
upload_file "$STAGE/shellcheck.txt" "$remote" "Add Stage35 shellcheck result $RUN" "$STAGE/aux.json" "$STAGE/aux-response.json"
printf '%s %s %s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$STAGE/shellcheck.txt" | tr -d ' ')" >>"$MANIFEST"
printf 'STAGE: 35\nRUN: %s\nREPORT_BYTES: %s\nREPORT_PARTS: %s\nTARGET: macOS Sequoia 15.8.1 build 24H32 x86_64\nSOURCE_CHANGES: NONE\nBUILD_INSTALL_LOAD: NOT RUN\nACTIVATION_GATE: BLOCKED\n' "$RUN" "$(wc -c <"$REPORT" | tr -d ' ')" "$PARTS" >>"$MANIFEST"
upload_file "$MANIFEST" "Development/Logs/stage35/$RUN/manifest.txt" "Add Stage35 immutable manifest $RUN" "$STAGE/manifest.json" "$STAGE/manifest-response.json"
echo "STAGE35_MANIFEST_SHA: $UPLOAD_SHA"
echo "STAGE35_REPORT_PARTS: $PARTS"
echo "STAGE35_LOG_DIRECTORY: https://github.com/$REPO/tree/main/Development/Logs/stage35/$RUN"
echo "STAGE35_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
echo "SOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE"
