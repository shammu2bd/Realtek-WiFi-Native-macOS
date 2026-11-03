#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PROJECT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-stage14-generic-skywalk-segment-abi"
if [ -n "$(printenv RTL88_PROJECT 2>/dev/null || true)" ]; then PROJECT="$(printenv RTL88_PROJECT)"; fi
DRIVER="$PROJECT/driver/RTL88WiFi"
KEXT="$DRIVER/build/out/RTL88WiFi.kext"
BIN="$KEXT/Contents/MacOS/RTL88WiFi"
INFO="$KEXT/Contents/Info.plist"
SRCROOT="$DRIVER/src/kext"
OUT="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage24-binary-lifecycle-audit-$STAMP"
mkdir -p "$STAGE_DIR"

run_capture() {
    name="$1"
    shift
    if "$@" > "$STAGE_DIR/$name.txt" 2>&1; then
        echo "PASS: $name" >> "$STAGE_DIR/tool-status.txt"
    else
        rc=$?
        echo "WARN: $name exit=$rc" >> "$STAGE_DIR/tool-status.txt"
    fi
}

if [ ! -f "$BIN" ]; then
    echo "ERROR: Stage23 kext binary not found: $BIN" >&2
    exit 2
fi

: > "$STAGE_DIR/tool-status.txt"
run_capture binary-file file "$BIN"
if command -v lipo >/dev/null 2>&1; then run_capture binary-architecture lipo -info "$BIN"; fi
if command -v otool >/dev/null 2>&1; then
    run_capture macho-header otool -hv "$BIN"
    run_capture linked-libraries otool -L "$BIN"
fi
if command -v nm >/dev/null 2>&1; then run_capture undefined-symbols nm -u "$BIN"; fi
if [ -f "$INFO" ]; then
    run_capture plist-summary plutil -p "$INFO"
    run_capture plist-libraries plutil -extract OSBundleLibraries xml1 -o - "$INFO"
else
    echo "WARN: built Info.plist missing at $INFO" >> "$STAGE_DIR/tool-status.txt"
fi
if command -v kextlibs >/dev/null 2>&1; then
    run_capture kextlibs-undefined kextlibs -undef-symbols "$KEXT"
else
    echo "INFO: kextlibs command not found" >> "$STAGE_DIR/tool-status.txt"
fi
if command -v codesign >/dev/null 2>&1; then
    run_capture codesign-details codesign -dv --verbose=4 "$KEXT"
else
    echo "INFO: codesign command not found" >> "$STAGE_DIR/tool-status.txt"
fi

python3 - "$SRCROOT" "$STAGE_DIR/source-lifecycle-excerpts.txt" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
out = Path(sys.argv[2])
terms = re.compile(
    r"releaseNativeResources|destroyQueues|setRadioRunning|"
    r"register.*(Queue|Ethernet|Network|Interface)|unregister|"
    r"synchroniz|disable|stop\(|free\(|drain|fence|"
    r"release.*(Pool|Queue)|"
    r"enable.*(Queue|Interface)",
    re.I,
)
files = sorted(p for p in root.rglob("*") if p.suffix in {".cpp", ".hpp", ".h"} and ("WCL" in p.name or p.name == "RTL88WiFi.cpp"))
chunks = []
for p in files:
    try:
        lines = p.read_text(errors="replace").splitlines()
    except OSError:
        continue
    hits = [i for i, line in enumerate(lines) if terms.search(line)]
    if not hits:
        continue
    chunks.append(f"\n===== {p} =====")
    last_end = -2
    shown = 0
    for i in hits:
        start, end = max(0, i - 10), min(len(lines), i + 28)
        if start <= last_end:
            continue
        chunks.append(f"--- lines {start+1}-{end} (match: {lines[i].strip()}) ---")
        chunks.extend(f"{j+1}: {lines[j]}" for j in range(start, end))
        last_end = end
        shown += end - start
        if shown >= 260:
            chunks.append("[excerpt limit reached for this file]")
            break
out.write_text("\n".join(chunks) if chunks else "NO LIFECYCLE MATCHES FOUND under " + str(root))
print(f"SOURCE_FILES_SCANNED: {len(files)}")
print(f"FILES_WITH_LIFECYCLE_MATCHES: {sum(1 for c in chunks if c.startswith('===== '))}")
PY

{
    echo "RTL88WiFi Stage 24 — binary and queue lifecycle audit"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "HOST: $(sw_vers -productVersion 2>/dev/null || echo unknown) / $(sw_vers -buildVersion 2>/dev/null || echo unknown)"
    echo "ARCH: $(uname -m)"
    echo "PROJECT: $PROJECT"
    echo "KEXT: $KEXT"
    echo "STAGE_DIR: $STAGE_DIR"
    echo "BINARY_SHA256: $(shasum -a 256 "$BIN" | awk '{print $1}')"
    echo
    echo "========== TOOL STATUS =========="
    cat "$STAGE_DIR/tool-status.txt"
    echo
    for f in binary-file binary-architecture macho-header linked-libraries plist-libraries kextlibs-undefined codesign-details; do
        if [ -f "$STAGE_DIR/$f.txt" ]; then
            echo "========== $f =========="
            cat "$STAGE_DIR/$f.txt"
        fi
    done
    echo
    echo "========== UNDEFINED SYMBOLS: SKY​​WALK / IO80211 =========="
    if [ -f "$STAGE_DIR/undefined-symbols.txt" ]; then
        grep -Ei 'Skywalk|IO80211|Apple80211|NetworkInterface|EthernetInterface' "$STAGE_DIR/undefined-symbols.txt" | head -160 || true
    fi
    echo
    echo "========== SOURCE LIFECYCLE EXCERPTS =========="
    cat "$STAGE_DIR/source-lifecycle-excerpts.txt"
    echo
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "QUEUE_REGISTRATION: STILL DISABLED"
    echo "DATAPATH_ACTIVATION: BLOCKED_PENDING_LIFECYCLE_AND_TEARDOWN_REVIEW"
} > "$OUT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    SHA="$(gh api "repos/$REPO/contents/Development/output.log" --jq '.sha' 2>/dev/null || true)"
    B64="$(base64 < "$OUT" | tr -d '\n')"
    if [ -n "$SHA" ]; then
        gh api --method PUT "repos/$REPO/contents/Development/output.log" \
            -f message="Stage 24 binary and lifecycle audit" \
            -f content="$B64" -f sha="$SHA" >/dev/null
        echo "UPLOAD_STATUS: SUCCESS — https://github.com/$REPO/blob/main/Development/output.log"
    else
        echo "UPLOAD_STATUS: GH_AUTH_OK_BUT_OUTPUT_LOG_SHA_NOT_RETRIEVED"
    fi
else
    echo "UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — output.log is ready for existing GitHub runlog uploader."
fi
echo "REPORT: $OUT"
echo "RAW_AUDIT_DIR: $STAGE_DIR"
