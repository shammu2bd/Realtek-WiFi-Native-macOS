#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE34_ERROR: exit=$rc line=$LINENO" >&2; exit "$rc"' ERR
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PROJECT_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
if [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$PROJECT_NAME/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$HOME/Downloads/$PROJECT_NAME"
else echo "ERROR: project root not found; cd to project root and rerun."; exit 2; fi
for tool in python3 gh curl split shasum; do command -v "$tool" >/dev/null || { echo "ERROR: missing required tool: $tool"; exit 2; }; done
gh auth status >/dev/null
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN="run-$STAMP"
STAGE="$PROJECT/build/stage34-source-safety-$STAMP"
mkdir -p "$STAGE/parts"
REPORT="$STAGE/stage34-source-integration-safety-audit.txt"
echo "STAGE34_PROJECT=$PROJECT"
python3 - "$PROJECT" "$REPORT" <<'PY'
from pathlib import Path
import hashlib,re,subprocess,sys
root=Path(sys.argv[1]); out=Path(sys.argv[2])
ext={".c",".cc",".cpp",".cxx",".h",".hpp",".hh",".pbxproj",".mk",".xcconfig"}
skip={".git","build","DerivedData","SDK","Frameworks","Headers","PrivateHeaders","Pods","node_modules"}
patterns={
"BUILD_SOURCES":r"RTW88HwOps\.cpp|RTW88PCIDevice\.cpp|RTW88WCLPCIBackend\.cpp|RTW88WCLSkywalkQueues\.cpp|RTW88IEEE80211\.cpp|SOURCES|PRODUCT_BUNDLE_IDENTIFIER|PBXSourcesBuildPhase",
"OPS_TABLE":r"struct\s+ieee80211_ops|const\s+struct\s+ieee80211_ops|ieee80211_ops",
"TX_CALL_GRAPH":r"\brtw_tx\s*\(|\brtw_pci_tx_write_data\s*\(|txDataFrame\s*\(|outputPacketWithCompletion|txSubmissionAction",
"TX_TERMINAL":r"ieee80211_(tx_status|free_txskb)|dev_kfree_skb|kfree_skb|consume_skb|skb_queue_(purge|tail|head)|backendCompletion|completeTicket",
"DMA_GLOBALS":r"rtw88_dma_ops|struct\s+rtw88_dma_alloc_ops|_dma_ops",
"DMA_IMPL":r"compat_dma_(alloc|free|map|unmap|sync)|syncBounceFor|dma_mapping_error|dma_set_mask_and_coherent",
"DMA_ORDER":r"dma_sync_single_for_(cpu|device)|dma_wmb|wmb\s*\(|write_txbd|fill_tx|txbd|tx_desc|doorbell",
"IRQ":r"request_irq|request_threaded_irq|devm_request_threaded_irq|IOInterruptEventSource|g_irq_handler|g_irq_thread_fn|handleInterrupt",
"IRQ_DRAIN":r"free_irq|devm_free_irq|synchronize_irq|disable_irq|cancel_work_sync|flush_work|tasklet_kill|napi_disable|napi_synchronize|removeEventSource",
"SKYWALK_REGISTER":r"registerEthernetInterface|RegistrationInfo|set.*Queue|register.*queue|IOSkywalk.*Queue|txSubmissionAction",
"SKYWALK_LIFETIME":r"submitPacket|backendCompletion|drainCompletions|hasOutstanding|unbind|destroyQueues|complete",
"STOP_REMOVE":r"rtw_pci_stop|rtw_pci_remove|stopDMA|free.*ring|deinit.*(tx|dma)|setBusMasterEnable|_dmaStopped|_shutdown|stop\(",
}
rx={k:re.compile(v,re.I) for k,v in patterns.items()}
files=[]; errors=[]
for p in root.rglob("*"):
 if not p.is_file() or (p.suffix.lower() not in ext and p.name not in {"Makefile"}) or any(x in skip for x in p.relative_to(root).parts): continue
 try: raw=p.read_bytes()
 except OSError as e: errors.append(f"{p.relative_to(root)}: {e}"); continue
 if len(raw)>8_000_000: continue
 lines=raw.decode("utf-8","replace").splitlines()
 hits={k:[i for i,s in enumerate(lines) if r.search(s)] for k,r in rx.items()}
 hits={k:v for k,v in hits.items() if v}
 if hits: files.append((p.relative_to(root).as_posix(),raw,lines,hits))
files.sort()
def git(args):
 try:
  p=subprocess.run(["git","-C",str(root),*args],capture_output=True,text=True,timeout=30)
  return p.returncode,p.stdout.strip(),p.stderr.strip()
 except Exception as e: return 999,"",str(e)
rc,gitroot,giterr=git(["rev-parse","--show-toplevel"])
tracked=set()
if rc==0:
 trc,tout,terr=git(["ls-files"])
 tracked=set(tout.splitlines()) if trc==0 else set()
statusrc,statusout,statuserr=git(["status","--short"])
diffrc,diffout,differr=git(["diff","--check"])
totals={k:0 for k in patterns}
L=[
"RTL88WiFi Stage34 — targeted source-level integration and safety audit",
f"PROJECT: {root}","TARGET: macOS Sequoia 15.8.1 / build 24H32 / Intel x86_64",
"SOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE",
"METHOD: read-only recursive source scan; source excerpts, SHA-256 fingerprints, git tracking and repository-root checks.",
"LIMIT: static evidence only; no compiler, hardware, runtime, ABI or concurrency proof.",
f"ELIGIBLE_MATCHED_FILES: {len(files)}",f"READ_ERRORS: {len(errors)}",
f"GIT_ROOT_EXIT: {rc}",f"GIT_ROOT: {gitroot or '(unavailable)'}",f"GIT_ROOT_ERROR: {giterr or '(none)'}",
f"GIT_TRACKED_SOURCE_COUNT: {len(tracked)}"]
for rel,raw,lines,hits in files:
 L += ["",f"=== {rel} | bytes={len(raw)} | sha256={hashlib.sha256(raw).hexdigest()} | git_tracked={'yes' if rel in tracked else 'no'} ==="]
 for key,idxs in hits.items():
  totals[key]+=len(idxs); L.append(f"[{key}] matches={len(idxs)}")
  shown=set()
  for i in idxs:
   for j in range(max(0,i-5),min(len(lines),i+7)): shown.add(j)
  prev=-2
  for j in sorted(shown):
   if j>prev+1:L.append("  ...")
   L.append(f"  {j+1:6d}: {lines[j]}"); prev=j
L += ["","=== TARGETED REVIEW QUESTIONS ===",
"C1 OPS/TX BINDING: identify the live active TX callback and its registration/dispatch. A function declaration, Linux reference implementation or unreferenced ops table is not proof.",
"C2 TX OWNERSHIP: trace accepted, rejected, ring-full, map failure, hardware completion, firmware TX report timeout, reset and remove. Distinguish skb release/status from Skywalk packet completion; prove exactly one terminal event.",
"C3 DMA REGISTRATION: enumerate every definition/assignment of rtw88_dma_ops and _dma_ops; verify translation-unit/linkage and active backend. Prove all six callbacks are valid before first DMA allocation and remain alive until final unmap/free.",
"C4 DMA CORRECTNESS: prove CPU↔device visibility, bounce-buffer copy direction, sync-for-device semantics, descriptor publication barrier and MMIO doorbell order. Check mapping-error and mask behavior.",
"C5 IRQ QUIESCE: trace interrupt source creation/enable, hardware mask, event source disable/remove, synchronize, threaded handler/work drain and object lifetime before freeing rings/backend.",
"C6 SKYwalk REGISTRATION: prove actual RegistrationInfo/interface registration and queue/ring binding; queue allocation alone is not active datapath. Trace rollback and deregistration.",
"C7 STOP/RESET/REMOVE: prove bus mastering/DMA is stopped and fenced before freeing descriptors/bounce maps; ensure restart reinitializes callbacks and queues.",
"",
"=== GIT HYGIENE ===",f"git status --short exit={statusrc}",statusout or "(no output)",f"git status stderr={statuserr or '(none)'}",f"git diff --check exit={diffrc}",diffout or "(no whitespace errors)",f"git diff stderr={differr or '(none)'}",
"NOTE: a source file absent from git ls-files is not committed/tracked in this checkout; verify the exact source revision before relying on GitHub-only review.",
"","=== SCAN COUNTS ==="]+[f"{k}: {v}" for k,v in totals.items()]
L += ["","=== READ ERRORS ==="]+(errors or ["NONE"])
L += ["","=== STAGE34 RESULT ===",
"STATIC_SCAN: "+("PASS" if files and not errors else "REVIEW_REQUIRED"),
"INTEGRATION_GATES: REVIEW_REQUIRED — manual call-graph, ownership, DMA, IRQ and ABI review remains required.",
"ACTIVATION_GATE: BLOCKED — do not install/load experimental Kext or modify OpenCore.",
"NO SOURCE FILES WERE MODIFIED BY THIS SCRIPT."]
out.write_text("\n".join(L)+"\n")
print("REPORT:",out,"\nMATCHED_FILES:",len(files),"\nREAD_ERRORS:",len(errors),"\nGIT_ROOT_EXIT:",rc,"\nGIT_TRACKED_SOURCE_COUNT:",len(tracked))
for k,v in totals.items(): print(k+"_MATCHES:",v)
print("REPORT_BYTES:",out.stat().st_size)
PY
test -s "$REPORT"
if command -v shellcheck >/dev/null 2>&1; then shellcheck "$PROJECT/Development/stage34-source-integration-safety-audit.sh" >"$STAGE/shellcheck.txt" 2>&1 || true; else echo "shellcheck not installed; skipped" >"$STAGE/shellcheck.txt"; fi
split -b 300000 -d -a 3 "$REPORT" "$STAGE/parts/report-"
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
 name="$(basename "$part").txt"; remote="Development/Logs/stage34/$RUN/$name"
 upload_file "$part" "$remote" "Add immutable Stage34 audit chunk $RUN/$name" "$STAGE/upload.json" "$STAGE/upload-response.json"
 printf '%s %s %s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" >>"$MANIFEST"
 PARTS=$((PARTS+1))
done
remote="Development/Logs/stage34/$RUN/shellcheck.txt"
upload_file "$STAGE/shellcheck.txt" "$remote" "Add Stage34 shellcheck result $RUN" "$STAGE/aux.json" "$STAGE/aux-response.json"
printf '%s %s %s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$STAGE/shellcheck.txt" | tr -d ' ')" >>"$MANIFEST"
printf 'STAGE: 34\nRUN: %s\nREPORT_BYTES: %s\nREPORT_PARTS: %s\nTARGET: macOS Sequoia 15.8.1 build 24H32 x86_64\nSOURCE_CHANGES: NONE\nBUILD_INSTALL_LOAD: NOT RUN\nACTIVATION_GATE: BLOCKED\n' "$RUN" "$(wc -c <"$REPORT" | tr -d ' ')" "$PARTS" >>"$MANIFEST"
upload_file "$MANIFEST" "Development/Logs/stage34/$RUN/manifest.txt" "Add Stage34 immutable manifest $RUN" "$STAGE/manifest.json" "$STAGE/manifest-response.json"
echo "STAGE34_MANIFEST_SHA: $UPLOAD_SHA"
echo "STAGE34_REPORT_PARTS: $PARTS"
echo "STAGE34_LOG_DIRECTORY: https://github.com/$REPO/tree/main/Development/Logs/stage34/$RUN"
echo "STAGE34_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
echo "SOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE"
