#!/bin/bash
# Stage 35N — audit reserved-page/H2C TX ownership and deferred TX-status teardown.
# Read-only source audit. No edits, build, install, Kext load, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW="$SRC/../rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35N-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35N_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 shasum split find grep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$RTW/pci.c" ]] || { echo "ERROR: expected RTW88 PCI source missing"; exit 3; }
[[ -f "$RTW/tx.c" ]] || { echo "ERROR: expected RTW88 TX source missing"; exit 4; }
[[ -f "$SRC/src/compat/linux/skbuff_tx_completion.h" ]] || { echo "ERROR: TX completion header missing"; exit 5; }
[[ -f "$SRC/src/kext/RTW88IEEE80211.cpp" ]] || { echo "ERROR: native IEEE80211 source missing"; exit 6; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 7; }

{
  echo "========== STAGE 35N: SPECIAL TX / DEFERRED STATUS / TEARDOWN AUDIT =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "source_root=$SOURCE_ROOT"
  echo "mode=read-only source/reference/lifecycle audit"
  echo
} > "$REPORT"

python3 - "$SRC" "$RTW" "$OUT" >> "$REPORT" <<'PY'
import hashlib, os, pathlib, re, sys

src, rtw, out = map(pathlib.Path, sys.argv[1:])
roots = [("RTW88", rtw), ("COMPAT", src / "src/compat"), ("KEXT", src / "src/kext")]
extensions = {".c", ".cc", ".cpp", ".h", ".hpp"}
all_files = []
for label, root in roots:
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in {".git", "build", "DerivedData"} and not d.endswith(".dSYM")]
        for name in sorted(names):
            p = pathlib.Path(base) / name
            if p.suffix.lower() in extensions:
                try:
                    raw = p.read_bytes()
                    text = raw.decode("utf-8", "replace")
                except OSError:
                    continue
                all_files.append((label, p, text, raw))

def rel(p):
    try:
        return str(p.relative_to(src))
    except ValueError:
        try:
            return "../rtw88-stable/" + str(p.relative_to(rtw))
        except ValueError:
            return str(p)

def contexts(title, p, text, patterns, before=14, after=26, max_windows=55):
    lines = text.splitlines()
    hits = []
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith(("//", "*")):
            continue
        if any(rx.search(line) for rx in patterns):
            hits.append(i)
    windows = []
    for i in hits:
        lo, hi = max(0, i-before), min(len(lines), i+after+1)
        if windows and lo <= windows[-1][1] + 2:
            windows[-1] = (windows[-1][0], max(windows[-1][1], hi))
        else:
            windows.append((lo, hi))
    print("\n=== %s | %s ===" % (title, rel(p)))
    print("MATCH_LINES=%d CONTEXT_WINDOWS=%d" % (len(hits), len(windows)))
    for lo, hi in windows[:max_windows]:
        print("\n[lines %d-%d]" % (lo+1, hi))
        for n in range(lo, hi):
            print("%5d %s" % (n+1, lines[n]))
    if len(windows) > max_windows:
        print("CONTEXT_WINDOWS_TRUNCATED=%d" % (len(windows)-max_windows))

def select(basename):
    return [(label,p,text,raw) for label,p,text,raw in all_files if p.name == basename]

def emit_named(basename, title, pats, before=14, after=26, limit=65):
    rows = select(basename)
    if not rows:
        print("\nMISSING_FILE=%s" % basename)
        return
    for label,p,text,raw in rows:
        contexts(title, p, text, [re.compile(x) for x in pats], before, after, limit)

print("--- Inventory and source fingerprints ---")
print("SOURCE_FILES_SCANNED=%d" % len(all_files))
for basename in ["pci.c","tx.c","main.c","mac80211.c","skbuff.h",
                 "skbuff_tx_completion.h","rtw88_compat.c","RTW88HwOps.cpp",
                 "RTW88WCLPCIBackend.cpp","RTW88IEEE80211.cpp",
                 "RTW88WCLSkywalkTxAdapter.cpp","RTW88WCLSkywalkTxAdapter.hpp"]:
    for label,p,text,raw in select(basename):
        print("SOURCE path=%s bytes=%d sha256=%s" %
              (rel(p), len(raw), hashlib.sha256(raw).hexdigest()))

print("\n--- PCI special-queue writers, dispatch table, and every symbol reference ---")
emit_named("pci.c", "PCI TX special queues and caller wiring", [
    r"rtw_pci_tx_write_data", r"rtw_pci_write_data_rsvd_page",
    r"RTW_TX_QUEUE_H2C", r"RTW_TX_QUEUE_BCN", r"write_data_h2c",
    r"write_data_rsvd", r"rtw_pci_ops", r"tx_write",
    r"rtw_pci_free_tx_ring_skbs", r"rtw_pci_dma_release",
    r"ieee80211_free_txskb"
], before=10, after=38, limit=90)

print("\n--- TX report queue: all queue operations, timer setup, purge and teardown ---")
emit_named("tx.c", "Deferred TX report lifecycle", [
    r"tx_report", r"purge_timer", r"status_driver_data",
    r"skb_queue_purge", r"skb_queue_head_init", r"timer",
    r"ieee80211_tx_status", r"del_timer", r"timer_delete",
    r"cancel_work", r"rtw_tx_report"
], before=12, after=35, limit=100)

print("\n--- RTW88 core lifecycle and HCI dispatch ---")
for basename in ["main.c","mac80211.c","pci.c"]:
    emit_named(basename, "Core/HCI lifecycle " + basename, [
        r"rtw_core_stop", r"rtw_core_deinit", r"rtw_tx_report",
        r"tx_report", r"rtw_hci_tx_write", r"rtw_hci_ops",
        r"write_data_rsvd_page", r"write_data_h2c",
        r"ieee80211_free_txskb", r"rtw_pci_dma_release",
        r"rtw_pci_free_trx_ring"
    ], before=10, after=28, limit=50)

print("\n--- skb free helper and token claiming/reporting ---")
emit_named("skbuff.h", "skbuff.h free and completion integration", [
    r"static inline void kfree_skb", r"tx_completion",
    r"dev_kfree_skb_any", r"dev_kfree_skb_irq"
], before=10, after=28, limit=35)
emit_named("skbuff_tx_completion.h", "TX completion token state machine", [
    r"rtw88_skb_tx_completion", r"atomic", r"claim",
    r"dispatch", r"bind", r"dispose", r"release"
], before=8, after=30, limit=40)

print("\n--- Compat callbacks, workqueue flush and teardown ---")
emit_named("rtw88_compat.c", "Compatibility datapath and callback teardown", [
    r"ieee80211_tx_status", r"g_hw_cbs", r"g_kext_hw",
    r"rtw88_set_hw_callbacks", r"purge", r"flush_workqueue",
    r"cancel_work_sync", r"queue_work", r"skb_queue_purge",
    r"kfree_skb", r"free_txskb", r"datapath_wq"
], before=10, after=28, limit=70)

print("\n--- Native WCL packet adapter callback/queue/teardown ---")
emit_named("RTW88WCLSkywalkTxAdapter.cpp", "Native Skywalk TX adapter", [
    r"outputPacketWithCompletion", r"completion", r"enqueue",
    r"drain", r"stop", r"close", r"teardown", r"callback",
    r"pending", r"flush", r"free"
], before=10, after=30, limit=70)

print("\n--- Native state-machine TX completion and shutdown paths ---")
emit_named("RTW88IEEE80211.cpp", "Native TX callback and shutdown references", [
    r"outputPacketWithCompletion", r"compat_tx_status",
    r"RTW88IEEE80211::txStatus", r"rtw88_skb_tx_completion_report",
    r"clear.*completion", r"txDataFrame", r"powerOff",
    r"releaseNativeResources", r"rtw_core_stop",
    r"rtw88_set_hw_callbacks"
], before=10, after=26, limit=80)

print("\n--- Cross-tree symbol-reference counts (including function-pointer assignments) ---")
symbols = [
    "rtw_pci_write_data_rsvd_page",
    "rtw_pci_tx_write_data",
    "rtw_pci_write_data_h2c",
    "rtw_tx_report_enqueue",
    "rtw_tx_report_handle",
    "rtw_tx_report_purge_timer",
    "rtw_tx_report_purge",
    "rtw88_skb_tx_completion_claim",
    "rtw88_skb_tx_completion_dispatch",
    "rtw88_skb_tx_completion_report",
    "rtw88_skb_tx_completion_bind",
    "ieee80211_free_txskb",
]
for symbol in symbols:
    rx = re.compile(r"\b" + re.escape(symbol) + r"\b")
    hits = []
    for label,p,text,raw in all_files:
        for n,line in enumerate(text.splitlines(),1):
            st=line.strip()
            if st.startswith(("//","*")):
                continue
            if rx.search(line):
                hits.append((rel(p),n,st))
    print("\nSYMBOL=%s REFERENCES=%d" % (symbol,len(hits)))
    for path,n,line in hits[:80]:
        print("  %s:%d | %s" % (path,n,line[:280]))
    if len(hits)>80:
        print("  TRUNCATED=%d" % (len(hits)-80))

print("\n--- Focused logic assertions ---")
pci = next((t for label,p,t,raw in all_files if p.name=="pci.c"), "")
tx = next((t for label,p,t,raw in all_files if p.name=="tx.c"), "")
skbuff = next((t for label,p,t,raw in all_files if p.name=="skbuff.h"), "")
completion = next((t for label,p,t,raw in all_files if p.name=="skbuff_tx_completion.h"), "")
compat = next((t for label,p,t,raw in all_files if p.name=="rtw88_compat.c"), "")
def yes(v): return "YES" if v else "NO"
print("RESERVED_PAGE_WRITER_SYMBOL_PRESENT=" + yes("rtw_pci_write_data_rsvd_page" in pci))
print("RESERVED_PAGE_WRITER_REGISTERED_IN_HCI_TABLE=" +
      yes(bool(re.search(r"\.\w+\s*=\s*rtw_pci_write_data_rsvd_page",pci))))
print("RESERVED_PAGE_FAILURE_BRANCH_FREES_SKB=" +
      yes(bool(re.search(r"rtw_pci_tx_write_data[\s\S]{0,180}if\s*\(ret\)[\s\S]{0,180}(dev_kfree_skb|kfree_skb)",pci))))
print("H2C_WRITER_HAS_LOCAL_ERROR_CLEANUP=" +
      yes(bool(re.search(r"(?:write_data_h2c|write_h2c)[\s\S]{0,450}(dev_kfree_skb|kfree_skb|ieee80211_free_txskb)",pci))))
print("TX_REPORT_QUEUE_PURGE_SYMBOL_PRESENT=" +
      yes(bool(re.search(r"(purge|flush|destroy)[A-Za-z0-9_]*tx_report|(purge|flush|destroy)[A-Za-z0-9_]*\([^)]*tx_report",tx,re.I))))
print("TX_REPORT_TIMER_CANCEL_PRESENT=" +
      yes(bool(re.search(r"(del_timer|timer_delete|del_timer_sync)\s*\([^)]*purge_timer",tx))))
print("TX_REPORT_QUEUE_EXPLICIT_PURGE_PRESENT=" +
      yes(bool(re.search(r"skb_queue_purge\s*\([^)]*tx_report",tx))))
print("TX_REPORT_QUEUE_STATUS_CALLBACK_PRESENT=" +
      yes("ieee80211_tx_status_irqsafe" in tx or "ieee80211_tx_status(" in tx))
print("SKB_FREE_REPORTS_FAILED_COMPLETION=" +
      yes(bool(re.search(r"kfree_skb[\s\S]{0,250}rtw88_skb_tx_completion_report|rtw88_skb_tx_completion_report[\s\S]{0,150}false",skbuff))))
print("TOKEN_CLAIM_USES_ATOMIC_EXCHANGE_OR_CAS=" +
      yes(bool(re.search(r"atomic_(?:exchange|compare_exchange)|__atomic_(?:exchange|compare_exchange)|OSCompareAndSwap",completion))))
print("TOKEN_DISPATCH_HAS_RELEASE=" + yes("release" in completion and "dispatch" in completion))
print("COMPAT_CALLBACK_CLEAR_PRESENT=" + yes("rtw88_set_hw_callbacks(nullptr, nullptr)" in compat))
print("NOTE=Absence of a named purge helper is not proof of a leak; inspect the full contexts and caller/registration map.")

print("\n--- Review questions ---")
questions = [
 "Is rtw_pci_write_data_rsvd_page reachable from the active PCI HCI ops table or is it an unused helper?",
 "If reserved-page TX is reachable, who frees the skb after rtw_pci_tx_write_data returns an error?",
 "Does the H2C writer dispose of its skb on every map/queue failure?",
 "When and where is the deferred TX report timer stopped during device stop/deinit?",
 "Are all skbs in the deferred TX report queue drained and completion-reported before rtwdev is freed?",
 "Can purge-timer callback race a matching C2H TX report and both consume the same skb?",
 "Does the completion token claim operation guarantee one terminal callback under duplicate free/status races?",
 "Does native Skywalk adapter shutdown wait for all completion records and outstanding cookies?",
 "Are interrupt/NAPI workers synchronized before the PCI TX ring and DMA mappings are reclaimed?",
]
for i,q in enumerate(questions,1):
    print("OPEN_QUESTION_%02d=%s" % (i,q))

print("\n--- Safety boundary ---")
print("SOURCE_TREE_MODIFIED=NO")
print("BUILD=NOT_RUN")
print("INSTALL=NOT_RUN")
print("LOAD=NOT_RUN")
print("OPENCORE_MODIFIED=NO")
print("HARDWARE_TEST=NOT_RUN")
PY

{
  echo
  echo "--- End Stage 35N ---"
  echo "ACTUAL_BUILD=NOT_RUN"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "HARDWARE_TEST=NOT_RUN"
} >> "$REPORT"

mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"

upload_file() {
  local file="$1" path="$2" msg="$3" payload="$4" response="$5" old put got
  old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
  python3 - "$file" "$old" "$msg" "$payload" <<'PY2'
import base64, json, pathlib, sys
f, sha, msg, dest = sys.argv[1:]
v = {"message": msg, "content": base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha:
    v["sha"] = sha
pathlib.Path(dest).write_text(json.dumps(v))
PY2
  if ! gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" >"$response" 2>"$UPLOAD_ERROR"; then
    echo "UPLOAD_FAILED_PATH=$path" >>"$UPLOAD_ERROR"
    echo "AUTH_ACCOUNT=$(gh api user --jq .login 2>&1 || true)" >>"$UPLOAD_ERROR"
    echo "REPO_PERMISSION=$(gh api "repos/$REPO" --jq '.full_name + " push=" + (.permissions.push|tostring)' 2>&1 || true)" >>"$UPLOAD_ERROR"
    return 1
  fi
  put="$(python3 - "$response" <<'PY2'
import json, sys
v = json.load(open(sys.argv[1]))
s = (v.get("content") or {}).get("sha")
if not s:
    raise SystemExit("Missing returned blob SHA: " + repr(v)[:700])
print(s)
PY2
)"
  got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
  [[ "$put" == "$got" ]] || {
    echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >>"$UPLOAD_ERROR"
    return 1
  }
  UPLOAD_SHA="$got"
}

MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 35N\nRUN: %s\nPURPOSE: reserved-page/H2C TX cleanup, deferred TX-status queue, timer and completion-token teardown audit\n' "$RUN" >"$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35n/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35N special TX and TX status audit $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >>"$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35n/$RUN/manifest.txt" "Add Stage35N manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35N_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35N_RUN=$RUN"
echo "STAGE35N_REPORT_PARTS=$COUNT"
echo "STAGE35N_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35n/$RUN"
