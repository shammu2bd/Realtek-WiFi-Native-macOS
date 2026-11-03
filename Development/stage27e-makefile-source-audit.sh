#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
NEW_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
PROJECT="$HOME/Downloads/$NEW_NAME"
DRIVER="$PROJECT/driver/RTL88WiFi"
OUT="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage27e-makefile-source-audit-$STAMP"
STATUS="$STAGE_DIR/status.txt"
MAKEFILES="$STAGE_DIR/makefile-inventory.txt"
LINKMAP="$STAGE_DIR/link-map.txt"
FINAL_RC=0

if [ ! -f "$PROJECT/BUILD_NAME.txt" ] || [ ! -f "$DRIVER/Makefile" ]; then
    echo "ERROR: Stage26 project/Makefile missing: $PROJECT" >&2
    exit 2
fi
mkdir -p "$STAGE_DIR"

# Preserve latest GitHub log before appending.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh api "repos/$REPO/contents/Development/output.log" --jq '.content' 2>/dev/null | \
        python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' \
        > "$STAGE_DIR/output.log.github-before" 2>/dev/null; then
        if [ -s "$STAGE_DIR/output.log.github-before" ]; then cp "$STAGE_DIR/output.log.github-before" "$OUT"; fi
    fi
fi

{
    echo
    echo "RTL88WiFi Stage27e — read-only Makefile source/object integration inventory"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "PROJECT: $PROJECT"
    echo "DRIVER: $DRIVER"
    echo "STAGE_DIR: $STAGE_DIR"
    echo "PURPOSE: locate the Makefile object-list omission diagnosed by Stage27d."
    echo "SCOPE: read-only inventory and dry-run log parsing; no source changes, compilation, install or load."
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
} >> "$OUT"

python3 - "$DRIVER" "$MAKEFILES" <<'PY'
from pathlib import Path
import re, sys
root, output = Path(sys.argv[1]), Path(sys.argv[2])
rx = re.compile(r"WCL|wcl24h32|OBJS|OBJECTS|SRCS|SOURCES|LDFLAGS|LD[A-Z_]*\s*[:?+]?=|rtl88wifi|RTW88WCL", re.I)
skip = {"build", ".git", ".svn"}
files = []
for p in sorted(root.rglob("*")):
    if not p.is_file() or p.suffix not in {".mk", ".make", ".sh"} and p.name != "Makefile":
        continue
    rel = p.relative_to(root)
    if any(part in skip for part in rel.parts):
        continue
    files.append(p)
chunks = []
total = 0
for p in files:
    try: lines = p.read_text(errors="replace").splitlines()
    except OSError: continue
    hits = [i for i, line in enumerate(lines) if rx.search(line)]
    if not hits: continue
    chunks.append(f"\n===== {p.relative_to(root)} ({len(lines)} lines) =====")
    selected = set()
    for i in hits:
        selected.update(range(max(0, i-3), min(len(lines), i+4)))
    prev = -2
    for i in sorted(selected):
        if i > prev + 1: chunks.append("...")
        chunks.append(f"{i+1}: {lines[i]}")
        prev = i
        total += 1
        if total >= 500:
            chunks.append("[500 matching/context lines cap reached]")
            break
    if total >= 500: break
output.write_text("\n".join(chunks) if chunks else "NO MAKEFILE MATCHES")
print("MAKEFILE_FILES_SCANNED:", len(files))
print("MATCHING_CONTEXT_LINES:", total)
print("REPORT:", output)
PY

# Locate latest Stage27d dry-run and derive the real source->object->link mapping.
LATEST_DRYRUN="$(find "$PROJECT/build" -type f -path '*/stage27d-link-integration-audit-*/make-forced-dry-run.txt' -print 2>/dev/null | sort | tail -1)"
if [ -n "$LATEST_DRYRUN" ]; then
    python3 - "$LATEST_DRYRUN" "$LINKMAP" <<'PY'
from pathlib import Path
import re, shlex, sys
dry, out = Path(sys.argv[1]), Path(sys.argv[2])
targets = ("RTW88WCLController.cpp", "RTW88WCLPCIBackend.cpp", "RTW88WCLSkywalkQueues.cpp")
lines = dry.read_text(errors="replace").splitlines()
compiled = {}
links = []
for no, raw in enumerate(lines, 1):
    s = raw.strip()
    if not s.startswith(("xcrun clang++ ", "clang++ ")): continue
    try: args = shlex.split(s)
    except ValueError: continue
    if "-c" in args and "-o" in args:
        try: source, obj = args[args.index("-c")+1], args[args.index("-o")+1]
        except IndexError: continue
        for t in targets:
            if source.endswith("/"+t) or source == t:
                compiled[t] = (obj, no)
    if "-static" in args and "-kext" in args and "-o" in args:
        try: dest = args[args.index("-o")+1]
        except IndexError: continue
        if dest.endswith("/RTL88WiFi.kext/Contents/MacOS/RTL88WiFi"):
            links.append((no, dest, [x for x in args if x.endswith(".o")]))
outlines = [f"DRYRUN_SOURCE: {dry}", "SOURCE_TO_OBJECT_COMPILE_RULES:"]
for t in targets:
    if t in compiled:
        obj, line = compiled[t]
        outlines.append(f"  {t} -> {obj} (line {line})")
    else: outlines.append(f"  MISSING COMPILE RULE: {t}")
outlines.append("FINAL_KEXT_LINK:")
if not links:
    outlines.append("  NOT FOUND")
else:
    no, dest, objects = links[-1]
    outlines.append(f"  line {no}: {dest}")
    objset = set(objects)
    for t in targets:
        obj = compiled.get(t, (None,))[0]
        outlines.append(f"  {'LINKED' if obj in objset else 'NOT LINKED'}: {obj or t}")
    outlines.append("  OBJECT_INPUTS:")
    outlines.extend("    " + x for x in objects)
out.write_text("\n".join(outlines) + "\n")
print(out.read_text())
PY
else
    echo "STAGE27D_DRYRUN: NOT_FOUND" > "$LINKMAP"
fi

{
    echo "MAKEFILE_INVENTORY:"
    cat "$MAKEFILES"
    echo
    echo "COMPILE_TO_LINK_MAP:"
    cat "$LINKMAP"
} > "$STATUS"

{
    echo
    echo "STAGE27E_MAKEFILE_SOURCE_AUDIT:"
    cat "$STATUS"
    echo "BUILD: NOT RUN"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "SOURCE_FILES_MODIFIED: NONE"
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
    echo "QUEUE_REGISTRATION: STILL DISABLED"
} >> "$OUT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    API_PATH="repos/$REPO/contents/Development/output.log"
    REMOTE_SHA="$(gh api "$API_PATH" --jq '.sha' 2>/dev/null || true)"
    B64="$(base64 < "$OUT" | tr -d '\n')"
    if [ -n "$REMOTE_SHA" ]; then
        gh api --method PUT "$API_PATH" -f message="Stage27e Makefile object-list source audit" -f content="$B64" -f sha="$REMOTE_SHA" >/dev/null
        echo "GITHUB_UPLOAD_STATUS: SUCCESS — Development/output.log updated"
    else
        echo "GITHUB_UPLOAD_STATUS: FAILED — remote output.log SHA unavailable"
    fi
else
    echo "GITHUB_UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — report retained locally"
fi

echo "STATUS_FILE: $STATUS"
echo "MAKEFILE_INVENTORY: $MAKEFILES"
echo "LINK_MAP: $LINKMAP"
echo "REPORT: $OUT"
exit "$FINAL_RC"
