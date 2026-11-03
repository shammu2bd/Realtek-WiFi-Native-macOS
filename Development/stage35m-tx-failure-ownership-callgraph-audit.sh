#!/bin/bash
# Stage 35M — trace TX map-failure ownership, direct callers, deferred TX status,
# completion-token disposition, and reset/teardown reclamation.
# Read-only static audit. No build, source edits, install, Kext load, or OpenCore edits.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW="$SRC/../rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35M-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35M_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 shasum split find grep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$RTW/pci.c" ]] || { echo "ERROR: expected RTW88 PCI source missing"; exit 3; }
[[ -f "$RTW/tx.c" ]] || { echo "ERROR: expected RTW88 TX source missing"; exit 4; }
[[ -f "$SRC/src/compat/linux/dma-mapping.h" ]] || { echo "ERROR: DMA compatibility header missing"; exit 5; }
[[ -f "$SRC/src/kext/RTW88IEEE80211.cpp" ]] || { echo "ERROR: native IEEE80211 source missing"; exit 6; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 7; }

{
  echo "========== STAGE 35M: TX FAILURE OWNERSHIP / CALL-GRAPH AUDIT =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "source_root=$SOURCE_ROOT"
  echo "mode=read-only static definition/call-site/ownership trace"
  echo
} > "$REPORT"

python3 - "$SRC" "$RTW" "$OUT" >> "$REPORT" <<'PY'
import hashlib, os, pathlib, re, sys

src, rtw, out = map(pathlib.Path, sys.argv[1:])
roots = [("RTW88", rtw), ("COMPAT", src / "src/compat"), ("KEXT", src / "src/kext")]
extensions = {".c", ".cc", ".cpp", ".h", ".hpp"}
sources = []
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
                sources.append((label, p, text, raw))

def rel(p):
    try:
        return str(p.relative_to(src))
    except ValueError:
        try:
            return "../rtw88-stable/" + str(p.relative_to(rtw))
        except ValueError:
            return str(p)

def line_no(s, pos):
    return s.count("\n", 0, pos) + 1

def skip_ws_comments(s, i):
    n = len(s)
    while i < n:
        if s[i].isspace():
            i += 1
        elif s.startswith("//", i):
            j = s.find("\n", i + 2)
            return n if j < 0 else skip_ws_comments(s, j + 1)
        elif s.startswith("/*", i):
            j = s.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            break
    return i

def matching_delimiter(s, start, opening, closing):
    depth = 0
    i = start
    state = "normal"
    escaped = False
    while i < len(s):
        c = s[i]
        nxt = s[i:i+2]
        if state == "line":
            if c == "\n": state = "normal"
        elif state == "block":
            if nxt == "*/":
                state = "normal"
                i += 1
        elif state in ("string", "char"):
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif (state == "string" and c == '"') or (state == "char" and c == "'"):
                state = "normal"
        else:
            if nxt == "//":
                state = "line"
                i += 1
            elif nxt == "/*":
                state = "block"
                i += 1
            elif c == '"':
                state = "string"
            elif c == "'":
                state = "char"
            elif c == opening:
                depth += 1
            elif c == closing:
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    return None

def find_definition(text, qualified_name):
    # Match a real function definition: balanced parameter list followed by a body.
    short = qualified_name.split("::")[-1]
    pattern = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(short) + r"\s*\(")
    for m in pattern.finditer(text):
        op = text.find("(", m.start(), m.end())
        cp = matching_delimiter(text, op, "(", ")")
        if cp is None:
            continue
        after = skip_ws_comments(text, cp + 1)
        # Permit simple trailing qualifiers/noexcept, but reject declarations/calls.
        while after < len(text) and text[after] != "{":
            if text[after] in ";":
                break
            if text[after] == "\n" and text[after+1:after+12].lstrip().startswith(("return", "if ", "else")):
                break
            after += 1
        if after >= len(text) or text[after] != "{":
            continue
        # A C++ qualified name must actually appear before this occurrence.
        if "::" in qualified_name:
            prefix = text[max(0, m.start()-180):m.start()]
            if not re.search(re.escape(qualified_name.rsplit("::", 1)[0]) + r"\s*::\s*$", prefix):
                # Some declarations use line breaks between class and method; keep trying.
                continue
        end = matching_delimiter(text, after, "{", "}")
        if end is not None:
            return m.start(), after, end
    return None

by_name = {}
for label, p, text, raw in sources:
    for name in [
        "rtw_pci_tx_write_data",
        "rtw_pci_write_data_rsvd_page",
        "rtw_pci_free_tx_ring_skbs",
        "rtw_pci_dma_release",
        "rtw_pci_release_rsvd_page",
        "rtw_tx",
        "rtw_tx_report_enqueue",
        "rtw_tx_report_handle",
        "rtw_tx_report",
        "rtw_ops_tx",
        "rtw88_skb_tx_completion_report",
        "rtw88_skb_tx_completion_dispose",
        "txDataFrame",
        "outputPacketWithCompletion",
        "compat_tx_status",
        "txStatus",
    ]:
        found = find_definition(text, name)
        if found:
            by_name.setdefault(name, []).append((label, p, text, found))

print("--- Source inventory ---")
print("SOURCE_FILES_SCANNED=%d" % len(sources))
for label, p, text, raw in sources:
    if p.name in {"pci.c", "tx.c", "main.c", "dma-mapping.h", "rtw88_compat.c",
                  "skbuff.h", "RTW88HwOps.cpp", "RTW88WCLPCIBackend.cpp",
                  "RTW88IEEE80211.cpp"}:
        print("SOURCE path=%s bytes=%d sha256=%s" % (rel(p), len(raw), hashlib.sha256(raw).hexdigest()))

def emit_function(name, max_lines=220):
    rows = by_name.get(name, [])
    print("\n=== FUNCTION %s definitions=%d ===" % (name, len(rows)))
    if not rows:
        print("DEFINITION_NOT_FOUND")
        return
    for label, p, text, (start, brace, end) in rows[:5]:
        start_line, end_line = line_no(text, start), line_no(text, end)
        print("FILE=%s LINES=%d-%d" % (rel(p), start_line, end_line))
        lines = text.splitlines()
        lo = start_line - 1
        hi = min(end_line, lo + max_lines)
        for n in range(lo, hi):
            print("%5d %s" % (n + 1, lines[n]))
        if hi < end_line:
            print("FUNCTION_BODY_TRUNCATED_LINES=%d" % (end_line-hi))

targets = [
    "rtw_pci_tx_write_data",
    "rtw_pci_write_data_rsvd_page",
    "rtw_pci_free_tx_ring_skbs",
    "rtw_pci_dma_release",
    "rtw_pci_release_rsvd_page",
    "rtw_tx",
    "rtw_tx_report_enqueue",
    "rtw_tx_report_handle",
    "rtw_tx_report",
    "rtw_ops_tx",
    "rtw88_skb_tx_completion_report",
    "rtw88_skb_tx_completion_dispose",
    "txDataFrame",
    "outputPacketWithCompletion",
    "compat_tx_status",
    "txStatus",
]
print("\n--- Complete relevant function bodies (bounded) ---")
for name in targets:
    emit_function(name, 180)

print("\n--- Direct caller/reference inventory ---")
patterns = {
    "rtw_pci_tx_write_data": r"\brtw_pci_tx_write_data\s*\(",
    "rtw_pci_write_data_rsvd_page": r"\brtw_pci_write_data_rsvd_page\s*\(",
    "rtw_tx": r"\brtw_tx\s*\(",
    "rtw_tx_report_enqueue": r"\brtw_tx_report_enqueue\s*\(",
    "rtw_tx_report": r"\brtw_tx_report\s*\(",
    "rtw88_skb_tx_completion_report": r"\brtw88_skb_tx_completion_report\s*\(",
    "txDataFrame": r"\btxDataFrame\s*\(",
    "outputPacketWithCompletion": r"\boutputPacketWithCompletion\s*\(",
}
for name, pat in patterns.items():
    rx = re.compile(pat)
    hits = []
    for label, p, text, raw in sources:
        for n, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith(("//", "*")):
                continue
            if rx.search(line):
                hits.append((label, p, n, stripped))
    print("\nCALL_REFERENCES %s=%d" % (name, len(hits)))
    for label, p, n, line in hits[:100]:
        print("  %s:%d | %s" % (rel(p), n, line[:300]))
    if len(hits) > 100:
        print("  TRUNCATED=%d" % (len(hits)-100))

print("\n--- TX-specific terminal disposition and ownership sites ---")
ownership_rx = re.compile(
    r"\b(dma_map_single|dma_unmap_single|dma_mapping_error|skb_push|skb_pull|"
    r"skb_queue_tail|skb_dequeue|rtw_tx_report_enqueue|ieee80211_tx_status|"
    r"dev_kfree_skb\w*|kfree_skb|rtw88_skb_tx_completion_report|"
    r"tx_completion|completionCookie|completionContext)\b"
)
for label, p, text, raw in sources:
    if p.name not in {"pci.c", "tx.c", "main.c", "rtw88_compat.c", "skbuff.h",
                      "RTW88IEEE80211.cpp", "RTW88HwOps.cpp"}:
        continue
    hits = [(n, line.strip()) for n, line in enumerate(text.splitlines(), 1)
            if ownership_rx.search(line) and not line.strip().startswith(("//", "*"))]
    if hits:
        print("\nFILE=%s OWNERSHIP_HITS=%d" % (rel(p), len(hits)))
        for n, line in hits[:180]:
            print("  %d %s" % (n, line[:280]))
        if len(hits) > 180:
            print("  TRUNCATED=%d" % (len(hits)-180))

print("\n--- Map failure ordering assertions ---")
pci = next((t for label,p,t,raw in sources if p.name == "pci.c"), "")
compat = next((t for label,p,t,raw in sources if p.name == "rtw88_compat.c"), "")
dma = next((t for label,p,t,raw in sources if p.name == "dma-mapping.h"), "")
ieee = next((t for label,p,t,raw in sources if p.name == "RTW88IEEE80211.cpp"), "")
skbuff = next((t for label,p,t,raw in sources if p.name == "skbuff.h"), "")
def yes(v): return "YES" if v else "NO"
push = pci.find("skb_push(skb, chip->tx_pkt_desc_sz)")
mapcall = pci.find("dma_map_single(&rtwpci->pdev->dev", max(push, 0))
maperr = pci.find("dma_mapping_error(&rtwpci->pdev->dev", max(mapcall, 0))
ret = pci.find("return -EBUSY", max(maperr, 0))
print("TX_PUSH_PRECEDES_MAP=" + yes(push >= 0 and mapcall > push))
print("TX_MAP_PRECEDES_ERROR_CHECK=" + yes(mapcall >= 0 and maperr > mapcall))
print("TX_MAP_FAILURE_RETURNS_ERROR=" + yes(maperr >= 0 and ret > maperr))
print("TX_MAP_FAILURE_BRANCH_HAS_LOCAL_SKB_FREE=" + yes(bool(re.search(r"dma_mapping_error[\s\S]{0,240}(dev_kfree_skb|kfree_skb)", pci))))
print("TX_MAP_FAILURE_CALLER_CLEANUP_REQUIRES_CALLER_TRACE=YES")
print("TX_NORMAL_COMPLETION_UNMAP_BEFORE_SKB_PULL=" + yes(bool(re.search(r"dma_unmap_single[\s\S]{0,180}skb_pull", pci))))
print("TX_COMPLETION_QUEUE_RETAINS_SKB_FOR_STATUS=" + yes("rtw_tx_report_enqueue" in pci))
print("TX_RING_DRAIN_UNMAP_BEFORE_FREE=" + yes(bool(re.search(r"dma_unmap_single[\s\S]{0,180}dev_kfree_skb", pci))))
print("TX_RESERVED_PAGE_RELEASE_UNMAP_BEFORE_FREE=" + yes(bool(re.search(r"dma_unmap_single[\s\S]{0,180}dev_kfree_skb_any", pci))))
print("COMPAT_TX_STATUS_CALLBACK_HAS_FALLBACK_FREE=" + yes(bool(re.search(r"ieee80211_tx_status_irqsafe[\s\S]{0,260}else\s+kfree_skb", compat))))
print("KEXT_TX_STATUS_CALLBACK_FREES_SKB=" + yes(bool(re.search(r"compat_tx_status[\s\S]{0,280}kfree_skb\s*\(\s*skb\s*\)", ieee))))
print("DMA_TO_DEVICE_BOUNCE_COPY=" + yes(bool(re.search(r"dir\s*==\s*1\s*\|\|\s*dir\s*==\s*2[\s\S]{0,80}memcpy\s*\(\s*bounce\s*,\s*ptr\s*,\s*size", next((t for label,p,t,raw in sources if p.name == "RTW88HwOps.cpp"), "")))))
print("EMPTY_SYNC_FOR_DEVICE_CALLBACK=" + yes(bool(re.search(r"compat_dma_sync_dev\s*\([^)]*\)\s*\{\s*\}", next((t for label,p,t,raw in sources if p.name == "RTW88HwOps.cpp"), ""), re.S))))
print("NOTE=These are static assertions, not runtime proof or exactly-once verification.")

print("\n--- Explicit unresolved questions for the next engineering review ---")
questions = [
    "Does every caller of rtw_pci_tx_write_data free or otherwise terminally dispose of skb when it returns -EBUSY after skb_push?",
    "Does a failed reserved-page submission restore skb state or free it exactly once?",
    "Does rtw_tx or its ops callback dispose of an skb when the driver is stopped or the PCI queue rejects it?",
    "Can an skb be freed by both the PCI error path and the kext completion-token fallback?",
    "Does TX-status queue teardown flush all queued skbs and invoke each completion token exactly once?",
    "Can reset/timeout/removal reclaim the same TX skb concurrently with interrupt completion?",
    "Can global DMA callback lease teardown occur while any mapped TX skb remains queued?",
    "Are management, H2C, beacon/reserved-page, EAPOL, and normal data packets all covered by distinct terminal ownership paths?",
]
for i, q in enumerate(questions, 1):
    print("OPEN_QUESTION_%02d=%s" % (i, q))

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
  echo "--- End Stage 35M ---"
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
printf 'STAGE: 35M\nRUN: %s\nPURPOSE: TX map-failure ownership, caller graph, deferred status, completion-token and teardown audit\n' "$RUN" >"$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35m/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35M TX ownership audit $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >>"$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35m/$RUN/manifest.txt" "Add Stage35M manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35M_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35M_RUN=$RUN"
echo "STAGE35M_REPORT_PARTS=$COUNT"
echo "STAGE35M_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35m/$RUN"
