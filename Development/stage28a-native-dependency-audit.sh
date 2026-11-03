#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
NEW_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
PROJECT="$HOME/Downloads/$NEW_NAME"
DRIVER="$PROJECT/driver/RTL88WiFi"
SRC="$DRIVER/src/kext"
OUT="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage28a-native-dependency-audit-$STAMP"
REPORT="$STAGE_DIR/native-dependency-report.txt"

if [ ! -f "$PROJECT/BUILD_NAME.txt" ] || [ ! -f "$DRIVER/Makefile" ]; then
    echo "ERROR: Stage26 project or Makefile missing: $PROJECT" >&2
    exit 2
fi
for source in \
    wcl24h32/RTW88WCLController.cpp \
    wcl24h32/RTW88WCLInfraInterface.cpp \
    wcl24h32/RTW88WCLPCIBackend.cpp \
    wcl24h32/RTW88WCLSkywalkQueues.cpp \
    wcl24h32/RTW88WCLSkywalkTxAdapter.cpp \
    wcl24h32/RTW88WCLSkywalkRxAdapter.cpp; do
    [ -f "$SRC/$source" ] || { echo "ERROR: required WCL source missing: $source" >&2; exit 3; }
done

mkdir -p "$STAGE_DIR"

# Preserve the current remote Development log before appending.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh api "repos/$REPO/contents/Development/output.log" --jq '.content' 2>/dev/null | \
        python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' \
        > "$STAGE_DIR/output.log.github-before" 2>/dev/null; then
        if [ -s "$STAGE_DIR/output.log.github-before" ]; then cp "$STAGE_DIR/output.log.github-before" "$OUT"; fi
    fi
fi

{
    echo
    echo "RTL88WiFi Stage28a — native 24H32 dependency and object-boundary audit"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "PROJECT: $PROJECT"
    echo "DRIVER: $DRIVER"
    echo "STAGE_DIR: $STAGE_DIR"
    echo "SCOPE: read-only source/include/symbol/object inventory; no source edits, build, install or load."
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
} >> "$OUT"

python3 - "$DRIVER" "$SRC" "$REPORT" <<'PY'
from pathlib import Path
import collections
import re
import shlex
import subprocess
import sys

driver, srcroot, report = map(Path, sys.argv[1:])
mk = (driver / "Makefile").read_text(errors="replace")
wcl_rel = [
    "wcl24h32/RTW88WCLController.cpp",
    "wcl24h32/RTW88WCLInfraInterface.cpp",
    "wcl24h32/RTW88WCLPCIBackend.cpp",
    "wcl24h32/RTW88WCLSkywalkQueues.cpp",
    "wcl24h32/RTW88WCLSkywalkTxAdapter.cpp",
    "wcl24h32/RTW88WCLSkywalkRxAdapter.cpp",
]
wcl_names = [Path(x).name for x in wcl_rel]
expected_objs = {Path(x).stem + ".o": driver / "build/wcl24h32" / (Path(x).stem + ".o") for x in wcl_rel}

out = []
out.append("=== 1. Makefile architecture and target declarations ===")
for i, line in enumerate(mk.splitlines(), 1):
    if 325 <= i <= 486 and re.search(r"AIRPORT_|WCL24H32|ALL_OBJS|rtl88wifi|OUT_BIN|KEXT_SRCS|OBJS\s*:?=", line, re.I):
        out.append(f"{i}: {line}")
out.append("")
out.append("=== 2. Native WCL source includes, classes and selected external API references ===")
class_rx = re.compile(r"\b(?:class|struct)\s+([A-Za-z_]\w*)")
api_rx = re.compile(r"\b(?:IO80211|IOSkywalk|IOPCIDevice|IOPCIDevice|IOEthernet|IONetwork|RTW88WCL|RTW88IEEE|RTW88Hw|RTL88WiFi)\w*")
for rel in wcl_rel:
    p = srcroot / rel
    text = p.read_text(errors="replace")
    out.append(f"\n--- {rel} ---")
    incs = re.findall(r'^\s*#\s*include\s*[<"]([^>"]+)[>"]', text, re.M)
    out.append("INCLUDES:")
    out.extend("  " + x for x in incs[:100])
    classes = sorted(set(class_rx.findall(text)))
    out.append("CLASS_STRUCT_NAMES: " + (", ".join(classes) if classes else "(none detected)"))
    apis = sorted(set(api_rx.findall(text)))
    out.append("API_TYPE_NAMES: " + (", ".join(apis[:120]) if apis else "(none detected)"))
    out.append("SOURCE_BYTES: " + str(p.stat().st_size))

out.append("\n=== 3. Existing WCL object files ===")
for name, path in expected_objs.items():
    out.append(f"{name}: {'PRESENT' if path.is_file() else 'MISSING'} {path}")

nm = subprocess.run(["xcrun", "--find", "nm"], text=True, capture_output=True)
nm_path = nm.stdout.strip() if nm.returncode == 0 else "nm"
out.append("\nNM_TOOL: " + nm_path)
if not (driver / "build").exists():
    out.append("ERROR: build directory absent; WCL objects have not been compiled here.")
    report.write_text("\n".join(out) + "\n")
    print(report.read_text())
    raise SystemExit(0)

# Read symbols from all built .o files. This is an inventory only; nm does not link.
object_files = sorted((driver / "build").rglob("*.o"))
defined_by = collections.defaultdict(set)
undefined_by_obj = {}
defined_by_obj = {}
nm_failures = []
for obj in object_files:
    proc = subprocess.run([nm_path, "-g", str(obj)], text=True, capture_output=True)
    if proc.returncode not in (0, 1):
        nm_failures.append(f"{obj}: {proc.stderr.strip()[:200]}")
    defs, undefs = set(), set()
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        sym_type = parts[-2] if len(parts) >= 3 else parts[0]
        symbol = parts[-1]
        if sym_type == "U":
            undefs.add(symbol)
        elif len(sym_type) == 1 and sym_type.upper() in set("ABCDGIRSTVW"):
            defs.add(symbol)
            defined_by[symbol].add(obj)
    defined_by_obj[obj] = defs
    undefined_by_obj[obj] = undefs

out.append("\n=== 4. Built object inventory by build directory ===")
groups = collections.defaultdict(list)
for p in object_files:
    rel = p.relative_to(driver / "build")
    group = rel.parts[0] if rel.parts else "(root)"
    groups[group].append(p)
for group in sorted(groups):
    out.append(f"{group}: {len(groups[group])} object files")

out.append("\n=== 5. Undefined WCL symbols satisfied by other local objects ===")
native_paths = [expected_objs[Path(x).stem + ".o"] for x in wcl_rel]
for obj in native_paths:
    out.append(f"\n--- {obj.name} ---")
    if obj not in undefined_by_obj:
        out.append("OBJECT_SYMBOLS: NOT AVAILABLE")
        continue
    undefs = sorted(undefined_by_obj[obj])
    matched = []
    unmatched = []
    for sym in undefs:
        providers = sorted(p for p in defined_by.get(sym, set()) if p != obj)
        if providers:
            matched.append((sym, providers))
        else:
            unmatched.append(sym)
    out.append(f"UNDEFINED_SYMBOL_COUNT: {len(undefs)}")
    out.append(f"LOCAL_OBJECT_PROVIDERS: {len(matched)}")
    for sym, providers in matched[:160]:
        relproviders = ", ".join(str(p.relative_to(driver / "build")) for p in providers[:4])
        out.append(f"  {sym} <= {relproviders}")
    out.append(f"UNRESOLVED_OUTSIDE_BUILT_OBJECTS_COUNT: {len(unmatched)}")
    for sym in unmatched[:100]:
        out.append(f"  {sym}")
    if len(matched) > 160: out.append("  [additional provider matches omitted]")
    if len(unmatched) > 100: out.append("  [additional undefined symbols omitted]")

out.append("\n=== 6. Duplicate externally visible symbols between native WCL objects and legacy AIRPORT objects ===")
native_set = set(native_paths)
airport_dir = driver / "build/airport"
airport_objs = sorted(airport_dir.glob("*.o")) if airport_dir.exists() else []
for obj in native_paths:
    defs = defined_by_obj.get(obj, set())
    collisions = []
    for legacy in airport_objs:
        overlap = defs.intersection(defined_by_obj.get(legacy, set()))
        important = sorted(s for s in overlap if any(k in s for k in ("IO80211", "IOSkywalk", "RTL88WiFi", "RTW88", "__ZTV", "__ZTI")))
        if important:
            collisions.append((legacy, important))
    out.append(f"{obj.name}:")
    if not collisions:
        out.append("  NO_OBVIOUS_NAMED_COLLISIONS_WITH_AIRPORT_OBJECTS")
    else:
        for legacy, symbols in collisions:
            out.append(f"  {legacy.name}: " + ", ".join(symbols[:50]))

out.append("\n=== 7. Existing link composition from most recent Stage27d dry-run ===")
dry_candidates = sorted((driver / "build").glob("stage27d-link-integration-audit-*/make-forced-dry-run.txt"))
if not dry_candidates:
    # Stage directories can be beside build output; search project/build.
    dry_candidates = sorted((driver.parent.parent / "build").glob("stage27d-link-integration-audit-*/make-forced-dry-run.txt"))
if not dry_candidates:
    out.append("STAGE27D_DRYRUN: NOT FOUND")
else:
    dry = dry_candidates[-1]
    out.append("STAGE27D_DRYRUN: " + str(dry))
    lines = dry.read_text(errors="replace").splitlines()
    for line in lines:
        if "-static" in line and "-kext" in line and " -o " in line:
            try:
                args = shlex.split(line.strip())
            except ValueError:
                continue
            objs = [x for x in args if x.endswith(".o")]
            out.append("FINAL_LINK_OBJECT_COUNT: " + str(len(objs)))
            for x in objs:
                if "/airport/" in x or "/wcl24h32/" in x or "/kext/" in x:
                    out.append("  " + x)
            break

out.append("\n=== 8. Audit summary ===")
out.append("BUILT_OBJECT_FILE_COUNT: " + str(len(object_files)))
out.append("WCL_OBJECTS_PRESENT: " + str(sum(p.is_file() for p in native_paths)) + "/6")
out.append("NM_FAILURE_COUNT: " + str(len(nm_failures)))
for x in nm_failures[:20]: out.append("  " + x)
out.append("LIMIT: this audit maps source includes and object symbols only; it does not prove runtime ABI correctness or safe queue registration.")
report.write_text("\n".join(out) + "\n")
print(report.read_text())
PY

{
    echo
    echo "STAGE28A_NATIVE_DEPENDENCY_AUDIT:"
    cat "$REPORT"
    echo "SOURCE_FILES_MODIFIED: NONE"
    echo "BUILD: NOT RUN"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
    echo "QUEUE_REGISTRATION: STILL DISABLED"
} >> "$OUT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    API_PATH="repos/$REPO/contents/Development/output.log"
    REMOTE_SHA="$(gh api "$API_PATH" --jq '.sha' 2>/dev/null || true)"
    B64="$(base64 < "$OUT" | tr -d '\n')"
    if [ -n "$REMOTE_SHA" ]; then
        gh api --method PUT "$API_PATH" \
            -f message="Stage28a native 24H32 dependency/object audit" \
            -f content="$B64" -f sha="$REMOTE_SHA" >/dev/null
        echo "GITHUB_UPLOAD_STATUS: SUCCESS — Development/output.log updated"
    else
        echo "GITHUB_UPLOAD_STATUS: FAILED — remote output.log SHA unavailable"
    fi
else
    echo "GITHUB_UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — local report retained"
fi

echo "REPORT: $REPORT"
echo "OUTPUT_LOG: $OUT"
