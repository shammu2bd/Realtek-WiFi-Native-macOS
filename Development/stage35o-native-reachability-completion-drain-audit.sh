#!/bin/bash
# Stage 35O — native controller -> PCI backend/probe reachability, special-TX
# dispatch call graph, and Skywalk completion-drain ownership audit.
# READ ONLY: no source edits, compilation, install, Kext load, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW="$SRC/../rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35O-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35O_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 shasum split find grep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$RTW/pci.c" ]] || { echo "ERROR: RTW88 PCI source is missing at $RTW/pci.c"; exit 3; }
[[ -f "$RTW/main.c" ]] || { echo "ERROR: RTW88 core source is missing at $RTW/main.c"; exit 4; }
[[ -f "$SRC/src/kext/RTW88IEEE80211.cpp" ]] || { echo "ERROR: native IEEE80211 source is missing"; exit 5; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 6; }

{
  echo "========== STAGE 35O: NATIVE REACHABILITY / SPECIAL TX / COMPLETION DRAIN AUDIT =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "source_root=$SOURCE_ROOT"
  echo "mode=read-only source inventory / cross-tree call-reference / dispatch audit"
  echo
} > "$REPORT"

python3 - "$SRC" "$RTW" >> "$REPORT" <<'PY'
import hashlib, os, pathlib, re, sys

src, rtw = map(pathlib.Path, sys.argv[1:])
roots = [("RTW88", rtw), ("COMPAT", src / "src/compat"), ("KEXT", src / "src/kext")]
extensions = {".c", ".cc", ".cpp", ".h", ".hpp", ".mm", ".m", ".mk", ".txt"}
files = []
for label, root in roots:
    if not root.is_dir():
        print("MISSING_ROOT=%s" % root)
        continue
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in {".git", "build", "DerivedData", "Products"} and not d.endswith(".dSYM")]
        for name in sorted(names):
            p = pathlib.Path(base) / name
            if p.suffix.lower() not in extensions and name not in {"Makefile"}:
                continue
            try:
                raw = p.read_bytes()
                text = raw.decode("utf-8", "replace")
            except OSError as e:
                print("READ_ERROR=%s:%s" % (p, e))
                continue
            files.append((label, p, text, raw))

def rel(p):
    try:
        return str(p.relative_to(src))
    except ValueError:
        try:
            return "../rtw88-stable/" + str(p.relative_to(rtw))
        except ValueError:
            return str(p)

def file_rows(name):
    return [(lab,p,t,raw) for lab,p,t,raw in files if p.name == name]

def print_windows(title, lab, p, text, patterns, before=12, after=28, cap=90):
    lines = text.splitlines()
    hits = []
    for i,line in enumerate(lines):
        s = line.strip()
        if s.startswith(("//", "*", "/*")):
            continue
        if any(rx.search(line) for rx in patterns):
            hits.append(i)
    windows = []
    for i in hits:
        lo, hi = max(0,i-before), min(len(lines),i+after+1)
        if windows and lo <= windows[-1][1]+2:
            windows[-1] = (windows[-1][0],max(windows[-1][1],hi))
        else:
            windows.append((lo,hi))
    print("\n=== %s | %s ===" % (title, rel(p)))
    print("MATCH_LINES=%d CONTEXT_WINDOWS=%d" % (len(hits),len(windows)))
    for lo,hi in windows[:cap]:
        print("\n[lines %d-%d]" % (lo+1,hi))
        for n in range(lo,hi):
            print("%5d %s" % (n+1,lines[n]))
    if len(windows)>cap:
        print("WINDOWS_TRUNCATED=%d" % (len(windows)-cap))

def scan_name(name, title, pats, before=12, after=28, cap=90):
    rows=file_rows(name)
    if not rows:
        print("\nFILE_NOT_FOUND=%s" % name)
    for lab,p,t,raw in rows:
        print_windows(title,lab,p,t,[re.compile(x) for x in pats],before,after,cap)

print("--- Source inventory and fingerprints ---")
print("SOURCE_FILES_SCANNED=%d" % len(files))
for lab,p,t,raw in files:
    if p.name in {
        "Makefile","pci.c","main.c","hci.c","tx.c","fw.c","mac80211.c",
        "rtw88_compat.c","skbuff.h","skbuff_tx_completion.h",
        "RTW88IEEE80211.cpp","RTW88IEEE80211.hpp","RTW88HwOps.cpp",
        "RTW88WCLPCIBackend.cpp","RTW88WCLPCIBackend.hpp",
        "RTW88WCLSkywalkTxAdapter.cpp","RTW88WCLSkywalkTxAdapter.hpp"
    } or ("wcl24h32" in str(p)):
        print("SOURCE path=%s bytes=%d sha256=%s" % (rel(p),len(raw),hashlib.sha256(raw).hexdigest()))

print("\n--- All WCL/native component files ---")
wcl = [(lab,p,t,raw) for lab,p,t,raw in files if "wcl24h32" in str(p).lower()]
print("WCL_SOURCE_FILES=%d" % len(wcl))
for lab,p,t,raw in wcl:
    print("WCL_FILE=%s bytes=%d" % (rel(p),len(raw)))

print("\n--- Build target and source membership hints ---")
for lab,p,t,raw in files:
    if p.name.lower() in {"makefile","makefile.local","project.pbxproj"} or p.suffix.lower() in {".mk"}:
        relevant=[(n,line.strip()) for n,line in enumerate(t.splitlines(),1)
                  if re.search(r"rtl88wifi-native|wcl24h32|RTW88WCL|RTW88IEEE80211|rtw88-stable|pci\.c",line,re.I)]
        if relevant:
            print("\nBUILD_FILE=%s MATCHES=%d" % (rel(p),len(relevant)))
            for n,line in relevant[:220]:
                print("  %d %s" % (n,line[:320]))
            if len(relevant)>220: print("  TRUNCATED=%d"%(len(relevant)-220))

print("\n--- Native controller and PCI backend lifecycle definitions/references ---")
native_patterns = [
    r"RTW88WCLPCIBackend", r"RTW88IEEE80211::createAirport",
    r"createAirport\s*\(", r"releaseNativeResources",
    r"rtw_pci_probe\s*\(", r"rtw_pci_remove\s*\(",
    r"rtw_core_init\s*\(", r"rtw_core_deinit\s*\(",
    r"rtw_core_start\s*\(", r"rtw_core_stop\s*\(",
    r"rtw88_compat_init\s*\(", r"rtw88_compat_exit\s*\(",
    r"setRadioRunning\s*\(", r"open\s*\(", r"close\s*\(",
    r"g_pci_dev_instance", r"rtw88_dma_ops", r"rtw88_pci_io_ops",
    r"bindRadioBackend", r"unbindRadioBackend"
]
for lab,p,t,raw in files:
    if lab != "KEXT" and p.name not in {"pci.c","main.c","mac80211.c","hci.c"}:
        continue
    if re.search(r"RTW88WCL|RTW88IEEE80211|Controller|PCIBackend|rtw_pci_probe|rtw_pci_remove|rtw_core_(init|deinit|start|stop)",t):
        print_windows("Native/probe lifecycle call sites",lab,p,t,
                      [re.compile(x) for x in native_patterns],10,24,42)

print("\n--- PCI probe path registration and teardown ---")
scan_name("pci.c","PCI ops / probe / remove / DMA and interrupt lifecycle",[
    r"rtw_pci_ops",r"\.write_data_rsvd_page",r"\.write_data_h2c",
    r"rtwdev->hci\.ops",r"rtw_pci_probe",r"rtw_pci_remove",
    r"rtw_core_init",r"rtw_core_deinit",r"rtw_core_start",
    r"rtw_core_stop",r"rtw_pci_stop",r"synchronize_irq",
    r"rtw_pci_dma_release",r"rtw_pci_free_trx_ring"
],before=12,after=32,cap=70)

print("\n--- Generic HCI wrappers and firmware callers for special TX ---")
for name in ["hci.c","hci.h","fw.c","tx.c","main.c"]:
    scan_name(name,"HCI/firmware/special TX dispatch "+name,[
        r"rtw_hci_write_data_rsvd_page",r"rtw_hci_write_data_h2c",
        r"write_data_rsvd_page",r"write_data_h2c",
        r"rtw_tx_rsvd_page",r"rsvd_page",
        r"rtw_tx_report_enqueue",r"rtw_tx_report_handle",
        r"rtw_tx_report_purge_timer",r"timer_delete_sync",
        r"rtw_core_init",r"rtw_core_deinit"
    ],before=10,after=24,cap=46)

print("\n--- All call/reference lines for critical reachability symbols ---")
symbols = [
    "rtw_pci_probe","rtw_pci_remove","rtw_core_init","rtw_core_deinit",
    "rtw_core_start","rtw_core_stop","rtw88_compat_init","rtw88_compat_exit",
    "rtw_hci_write_data_rsvd_page","rtw_hci_write_data_h2c",
    "write_data_rsvd_page","write_data_h2c",
    "rtw_pci_write_data_rsvd_page","rtw_pci_write_data_h2c",
    "drainCompletions","hasOutstandingCompletions",
    "outstandingCompletionCount","claimCompleted","backendCompletion",
    "releaseNativeResources","bindRadioBackend","unbindRadioBackend"
]
for symbol in symbols:
    rx=re.compile(r"(?<![A-Za-z0-9_])"+re.escape(symbol)+r"(?![A-Za-z0-9_])")
    hits=[]
    for lab,p,t,raw in files:
        for n,line in enumerate(t.splitlines(),1):
            st=line.strip()
            if st.startswith(("//","*")):
                continue
            if rx.search(line):
                hits.append((rel(p),n,st))
    print("\nSYMBOL=%s REFERENCES=%d" % (symbol,len(hits)))
    for path,n,line in hits[:120]:
        print("  %s:%d | %s" % (path,n,line[:340]))
    if len(hits)>120: print("  TRUNCATED=%d"%(len(hits)-120))

print("\n--- Skywalk completion adapter, controller drain caller, TicketPool and teardown ---")
for lab,p,t,raw in wcl:
    if re.search(r"drainCompletions|claimCompleted|hasOutstanding|outstandingCount|TicketPool|submitPacket|backendCompletion|CompletionSink|unbind\(",t):
        print_windows("WCL completion/ticket lifecycle",lab,p,t,[
            re.compile(r"drainCompletions"),re.compile(r"claimCompleted"),
            re.compile(r"hasOutstanding"),re.compile(r"outstandingCount"),
            re.compile(r"TicketPool"),re.compile(r"submitPacket"),
            re.compile(r"backendCompletion"),re.compile(r"CompletionSink"),
            re.compile(r"unbind\s*\("),re.compile(r"\bfree\s*\("),
            re.compile(r"\bstop\s*\("),re.compile(r"\bclose\s*\("),
            re.compile(r"releaseNativeResources")
        ],before=12,after=30,cap=65)

for name in ["RTW88WCLSkywalkTxAdapter.cpp","RTW88WCLSkywalkTxAdapter.hpp"]:
    scan_name(name,"Skywalk adapter API "+name,[
        r"drainCompletions",r"hasOutstanding",r"outstandingCompletionCount",
        r"TicketPool",r"submitPacket",r"backendCompletion",
        r"unbind\s*\(",r"\bfree\s*\(",r"stop\s*\(",r"close\s*\("
    ],before=10,after=30,cap=50)

print("\n--- TicketPool definitions and uses across all native source ---")
for lab,p,t,raw in files:
    if re.search(r"TicketPool",t):
        print_windows("TicketPool implementation/reference",lab,p,t,[
            re.compile(r"class\s+TicketPool"),re.compile(r"struct\s+TicketPool"),
            re.compile(r"TicketPool::"),re.compile(r"claimCompleted"),
            re.compile(r"reserve\s*\("),re.compile(r"complete\s*\("),
            re.compile(r"finish\s*\("),re.compile(r"hasOutstanding"),
            re.compile(r"outstandingCount"),re.compile(r"~TicketPool")
        ],before=10,after=30,cap=60)

print("\n--- Focused evidence flags (presence is not a reachability proof) ---")
def flag(label, value):
    print(label+"="+("YES" if value else "NO"))
all_text="\n".join(t for _,_,t,_ in files)
native_text="\n".join(t for lab,_,t,_ in files if lab=="KEXT")
pci=next((t for _,p,t,_ in files if p.name=="pci.c"),"")
tx=next((t for _,p,t,_ in files if p.name=="tx.c"),"")
main=next((t for _,p,t,_ in files if p.name=="main.c"),"")
flag("PCI_PROBE_DEFINITION_PRESENT",bool(re.search(r"\bint\s+rtw_pci_probe\s*\(",pci)))
flag("PCI_REMOVE_DEFINITION_PRESENT",bool(re.search(r"\bvoid\s+rtw_pci_remove\s*\(",pci)))
flag("NATIVE_KEXT_DIRECTLY_REFERENCES_PCI_PROBE",bool(re.search(r"\brtw_pci_probe\s*\(",native_text)))
flag("NATIVE_KEXT_DIRECTLY_REFERENCES_CORE_INIT",bool(re.search(r"\brtw_core_init\s*\(",native_text)))
flag("NATIVE_KEXT_DIRECTLY_REFERENCES_CORE_DEINIT",bool(re.search(r"\brtw_core_deinit\s*\(",native_text)))
flag("SPECIAL_WRITERS_REGISTERED_IN_PCI_OPS",
     ".write_data_rsvd_page = rtw_pci_write_data_rsvd_page" in pci and
     ".write_data_h2c = rtw_pci_write_data_h2c" in pci)
flag("SPECIAL_WRITERS_HAVE_NO_LOCAL_ERROR_FREE",
     bool(re.search(r"ret\s*=\s*rtw_pci_tx_write_data[\s\S]{0,220}if\s*\(ret\)[\s\S]{0,160}return\s+ret",pci)))
flag("TX_REPORT_TIMER_SYNCHRONOUSLY_DELETED_IN_CORE_DEINIT",
     bool(re.search(r"timer_delete_sync\s*\(\s*&rtwdev->tx_report\.purge_timer\s*\)",main)))
flag("TX_REPORT_QUEUE_PURGED_DURING_CORE_DEINIT",
     bool(re.search(r"timer_delete_sync[\s\S]{0,300}skb_queue_purge\s*\(\s*&rtwdev->tx_report\.queue",main)))
flag("ADAPTER_HAS_OUTSTANDING_TICKET_GUARD",
     bool(re.search(r"if\s*\(\s*_tickets\.hasOutstanding\s*\(\s*\)\s*\)",native_text)))
flag("ADAPTER_DRAIN_CALL_EXISTS",bool(re.search(r"->drainCompletions\s*\(",native_text)))
flag("ADAPTER_DRAIN_DEFINITION_EXISTS",bool(re.search(r"::drainCompletions\s*\(",native_text)))
flag("CONTROLLER_HAS_COMPLETION_DRAIN_CALL",bool(re.search(r"drainCompletions\s*\(",native_text)))
flag("COMPAT_CALLBACK_CONTEXT_CLEAR_IN_NATIVE_TREE",
     bool(re.search(r"rtw88_set_hw_callbacks\s*\(\s*nullptr\s*,\s*nullptr\s*\)",native_text)))
print("NOTE=Use call-site contexts and target membership; lexical presence alone does not prove runtime execution.")

print("\n--- Conclusion boundaries / open questions ---")
questions=[
 "Does the active native controller actually invoke rtw_pci_probe(), or does its PCI backend initialize a different path?",
 "If native code does not call rtw_pci_probe(), can the registered rtw_pci_ops special-TX writers be reached at all?",
 "Which controller method owns native PCI backend creation, radio binding, start, stop, and releaseNativeResources?",
 "Is RTW88WCLSkywalkTxAdapter::drainCompletions called by a live controller/queue event path, and who owns that event source?",
 "Does controller stop/free drain completed tickets, wait for outstanding tickets, or merely log and unbind?",
 "Can pending tickets remain indefinitely if a TX callback never arrives, and what is the timeout or forced-drain policy?",
 "Are reserved-page/H2C callbacks registered through a native PCI ops table anywhere besides the legacy rtw_pci_ops?",
 "Does the build target include the source that owns the Linux PCI probe and native controller, and what call graph connects them?"
]
for i,q in enumerate(questions,1):
    print("OPEN_QUESTION_%02d=%s"%(i,q))

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
  echo "--- End Stage 35O ---"
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
v=json.load(open(sys.argv[1]))
s=(v.get("content") or {}).get("sha")
if not s: raise SystemExit("Missing returned blob SHA: "+repr(v)[:700])
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
printf 'STAGE: 35O\nRUN: %s\nPURPOSE: native controller/PCI probe reachability, special TX dispatch, Skywalk completion drain and TicketPool teardown audit\n' "$RUN" >"$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35o/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35O native reachability audit $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >>"$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35o/$RUN/manifest.txt" "Add Stage35O manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35O_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35O_RUN=$RUN"
echo "STAGE35O_REPORT_PARTS=$COUNT"
echo "STAGE35O_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35o/$RUN"
