#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE33_ERROR: exit=$rc line=$LINENO" >&2; exit "$rc"' ERR
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PROJECT_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
if [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$PROJECT_NAME/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$HOME/Downloads/$PROJECT_NAME"
else echo "ERROR: project root not found; cd to project root and rerun."; exit 2; fi
for tool in python3 gh curl split shasum; do command -v "$tool" >/dev/null || { echo "ERROR: missing required tool: $tool"; exit 2; }; done
gh auth status >/dev/null
STAMP="$(date +%Y%m%d-%H%M%S)"
STAGE="$PROJECT/build/stage33-tx-dma-irq-skywalk-$STAMP"
mkdir -p "$STAGE" "$STAGE/parts"
REPORT="$STAGE/stage33-combined-integration-audit.txt"
echo "STAGE33_PROJECT=$PROJECT"
python3 - "$PROJECT" "$REPORT" <<'PY'
from pathlib import Path
import hashlib,re,subprocess,sys
root=Path(sys.argv[1]); out=Path(sys.argv[2])
ext={".c",".cc",".cpp",".cxx",".h",".hpp",".hh"}
skip={".git","build","DerivedData","SDK","Frameworks","Headers","PrivateHeaders","Pods","node_modules"}
patterns={
"OPS_BINDING":r"ieee80211_ops|\.tx\s*=|\.tx_sync\s*=|\.tx_async\s*=|->ops\s*=|\.ops\s*=",
"TX_ENTRY":r"\brtw_tx\s*\(|\brtw_pci_tx_|txDataFrame\s*\(|outputPacketWithCompletion|txSubmissionAction|startTx",
"SKB_TERMINAL":r"ieee80211_(tx_status|free_txskb)|dev_kfree_skb|kfree_skb|consume_skb|skb_queue_(purge|tail|head)|tx_(status|report|done|complete)",
"DMA_CALLBACKS":r"rtw88_dma_ops|alloc_coherent|free_coherent|map_single|unmap_single|sync_single_for_(cpu|device)|dma_mapping_error",
"DMA_UNSAFE":r"\(dma_addr_t\)\s*\(uintptr_t\)|page->phys\s*=|return\s*\(dma_addr_t\)\s*\(uintptr_t\)|dma_unmap_page.*\{\s*\}",
"DESC_ORDER":r"dma_sync|dma_wmb|wmb\s*\(|write_txbd|fill_tx|txbd|tx_desc|ring.*(wp|rp)|(wp|rp).*ring",
"IRQ_INSTALL":r"request_irq|request_threaded_irq|devm_request_threaded_irq|IOInterruptEventSource|g_irq_handler|g_irq_thread_fn",
"IRQ_QUIESCE":r"free_irq|devm_free_irq|synchronize_irq|disable_irq|cancel_work_sync|flush_work|tasklet_kill|napi_disable|napi_synchronize",
"SKYWALK_PATH":r"RTW88WCL|IOSkywalk|Skywalk|txSubmissionAction|drainCompletions|register.*queue|queue.*register|set.*Tx.*Queue|ifnet",
"STOP_REMOVE":r"rtw_pci_stop|rtw_pci_remove|stopDMA|free.*ring|deinit.*(tx|dma)|setBusMasterEnable|_dmaStopped|_shutdown",
}
rx={k:re.compile(v,re.I) for k,v in patterns.items()}
files=[]; errors=[]
for p in root.rglob("*"):
 if not p.is_file() or p.suffix.lower() not in ext: continue
 rel=p.relative_to(root)
 if any(x in skip for x in rel.parts): continue
 try: raw=p.read_bytes()
 except OSError as e: errors.append(f"{rel}: {e}"); continue
 if len(raw)>8_000_000: continue
 src=raw.decode("utf-8","replace"); lines=src.splitlines()
 hits={k:[i for i,s in enumerate(lines) if r.search(s)] for k,r in rx.items()}
 hits={k:v for k,v in hits.items() if v}
 if hits: files.append((rel.as_posix(),raw,lines,hits))
files.sort()
L=[
"RTL88WiFi Stage33 — combined TX/DMA/IRQ/Skywalk source-control-flow audit",
f"PROJECT: {root}",
"TARGET: macOS Sequoia 15.8.1 / build 24H32 / Intel x86_64",
"SOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE",
"KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED",
"METHOD: read-only C/C++ source scan with exact source line context and SHA-256; this is not runtime proof.",
f"ELIGIBLE_MATCHED_FILES: {len(files)}",f"READ_ERRORS: {len(errors)}"]
totals={k:0 for k in patterns}
for rel,raw,lines,hits in files:
 L += ["",f"=== {rel} | bytes={len(raw)} | sha256={hashlib.sha256(raw).hexdigest()} ==="]
 for k,idxs in hits.items():
  totals[k]+=len(idxs); L.append(f"[{k}] matches={len(idxs)}")
  shown=set()
  for i in idxs:
   for j in range(max(0,i-3),min(len(lines),i+4)): shown.add(j)
  prev=-2
  for j in sorted(shown):
   if j>prev+1: L.append("  ...")
   L.append(f"  {j+1:6d}: {lines[j]}")
   prev=j
L += ["","=== AUTOMATED CHECKLIST ==="]
checks=[
("C1 TX callback", "Find the exact live ieee80211_ops object, its assignment to the active hardware, and the callback target. A function definition or dead ops table is insufficient."),
("C2 TX ownership", "For success, ring-full, allocation/map failure, firmware rejection, IRQ completion, timeout, reset and removal: identify the single owner at every branch and exactly one terminal release/status."),
("C3 DMA callbacks", "Prove rtw88_dma_ops is fully populated and installed before every probe/allocation path. Reject null/partial callbacks; prove fallback CPU-pointer DMA addresses and fake page DMA addresses are unreachable."),
("C4 DMA ordering", "Verify map -> descriptor fill -> sync-for-device/write barrier -> doorbell; completion -> sync-for-CPU -> unmap -> skb terminal disposition. Check coherent allocation and teardown symmetry."),
("C5 IRQ lifecycle", "Prove event source/handler setup, disable, hardware interrupt mask, synchronize, bottom-half/work drain, and callback-context lifetime. Verify teardown order before ring memory is freed."),
("C6 Skywalk TX", "Trace active 24H32 queue registration/configuration -> packet conversion -> submit -> descriptor -> hardware completion -> completion queue -> packet release; verify backpressure, rollback and stop/deregister."),
("C7 stop/reset/remove", "Check bus-master/DMA fence, IRQ quiesce, worker drain, ring teardown and restart ordering; no callback may access freed state."),
]
for name,desc in checks: L.append(f"{name}: REVIEW_REQUIRED — {desc}")
L += ["","=== SCAN COUNTS ==="]+[f"{k}: {totals[k]}" for k in patterns]
L += ["","=== READ ERRORS ==="]+(errors or ["NONE"])
L += ["","=== LOCAL REPOSITORY HYGIENE ==="]
try:
 r=subprocess.run(["git","-C",str(root),"status","--short"],capture_output=True,text=True,timeout=20)
 L.append("git status --short exit="+str(r.returncode)); L.append(r.stdout.strip() or "(clean/no output)")
 if r.stderr.strip(): L.append("git status stderr: "+r.stderr.strip())
except Exception as e: L.append("git status unavailable: "+str(e))
try:
 r=subprocess.run(["git","-C",str(root),"diff","--check"],capture_output=True,text=True,timeout=20)
 L.append("git diff --check exit="+str(r.returncode)); L.append(r.stdout.strip() or "(no whitespace errors)")
 if r.stderr.strip(): L.append("git diff stderr: "+r.stderr.strip())
except Exception as e: L.append("git diff --check unavailable: "+str(e))
L += ["","=== STAGE33 RESULT ===",
"STATIC_SCAN: "+("PASS" if files and not errors else "REVIEW_REQUIRED"),
"INTEGRATION_GATES: REVIEW_REQUIRED — source-level scan only; human control-flow and ABI review required.",
"ACTIVATION_GATE: BLOCKED — do not install/load experimental Kext or modify OpenCore.",
"NO SOURCE FILES WERE MODIFIED BY THIS SCRIPT."]
out.write_text("\n".join(L)+"\n")
print("REPORT:",out); print("MATCHED_FILES:",len(files)); print("READ_ERRORS:",len(errors))
for k,v in totals.items(): print(k+"_MATCHES:",v)
print("REPORT_BYTES:",out.stat().st_size)
PY
test -s "$REPORT"
# Optional local syntax/hygiene checks; no build or driver activation.
if command -v shellcheck >/dev/null 2>&1; then shellcheck -x "$PROJECT/Development/stage33-combined-tx-dma-irq-skywalk-audit.sh" >"$STAGE/shellcheck.txt" 2>&1 || true; else echo "shellcheck not installed; skipped" >"$STAGE/shellcheck.txt"; fi
# Chunk reports below GitHub's reliable contents-API payload size.
split -b 300000 -d -a 3 "$REPORT" "$STAGE/parts/report-"
MANIFEST="$STAGE/manifest.txt"
: > "$MANIFEST"
upload_file() {
 local file="$1" path="$2" message="$3" payload="$4" response="$5" old="" put="" got=""
 old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
 python3 - "$file" "$old" "$message" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,sha,msg,dst=sys.argv[1:]
obj={"message":msg,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha: obj["sha"]=sha
pathlib.Path(dst).write_text(json.dumps(obj))
PY2
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
 put="$(python3 - "$response" <<'PY2'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY2
)"
 got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
 [[ "$put" == "$got" ]] || { echo "ERROR: readback SHA mismatch for $path"; return 1; }
 echo "UPLOAD_VERIFIED $path $got"
 UPLOAD_SHA="$got"
}
PARTS=0
for part in "$STAGE"/parts/report-*; do
 [[ -f "$part" ]] || continue
 base="$(basename "$part").txt"
 remote="Development/Logs/stage33/$base"
 upload_file "$part" "$remote" "Add immutable Stage33 audit report chunk $base" "$STAGE/upload.json" "$STAGE/upload-response.json"
 printf '%s %s %s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" >> "$MANIFEST"
 PARTS=$((PARTS+1))
done
[[ "$PARTS" -gt 0 ]] || { echo "ERROR: no report chunks generated"; exit 3; }
for aux in "$STAGE/shellcheck.txt"; do
 remote="Development/Logs/stage33/$(basename "$aux")"
 upload_file "$aux" "$remote" "Add Stage33 auxiliary test result" "$STAGE/aux.json" "$STAGE/aux-response.json"
 printf '%s %s %s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$aux" | tr -d ' ')" >> "$MANIFEST"
done
printf 'STAGE: 33\nREPORT_BYTES: %s\nREPORT_PARTS: %s\nTARGET: macOS Sequoia 15.8.1 build 24H32 x86_64\nSOURCE_CHANGES: NONE\nBUILD_INSTALL_LOAD: NOT RUN\nACTIVATION_GATE: BLOCKED\n' "$(wc -c < "$REPORT" | tr -d ' ')" "$PARTS" >> "$MANIFEST"
upload_file "$MANIFEST" "Development/Logs/stage33/manifest.txt" "Add Stage33 audit manifest" "$STAGE/manifest.json" "$STAGE/manifest-response.json"
echo "STAGE33_MANIFEST_SHA: $UPLOAD_SHA"
echo "STAGE33_REPORT_PARTS: $PARTS"
echo "STAGE33_LOG_DIRECTORY: https://github.com/$REPO/tree/main/Development/Logs/stage33"
echo "STAGE33_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
echo "SOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE"
