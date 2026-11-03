#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
NEW_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
PROJECT="$HOME/Downloads/$NEW_NAME"
DRIVER="$PROJECT/driver/RTL88WiFi"
SRC="$DRIVER/src/kext/wcl24h32"
OUT="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage27d-link-integration-audit-$STAMP"
DRYRUN="$STAGE_DIR/make-forced-dry-run.txt"
STATUS="$STAGE_DIR/status.txt"
FINAL_RC=0

if [ ! -f "$PROJECT/BUILD_NAME.txt" ] || [ ! -f "$DRIVER/Makefile" ]; then
    echo "ERROR: Stage26 project or Makefile missing: $PROJECT" >&2
    exit 2
fi
mkdir -p "$STAGE_DIR"

# Preserve the latest remote log before appending.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh api "repos/$REPO/contents/Development/output.log" --jq '.content' 2>/dev/null | \
        python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' \
        > "$STAGE_DIR/output.log.github-before" 2>/dev/null; then
        if [ -s "$STAGE_DIR/output.log.github-before" ]; then cp "$STAGE_DIR/output.log.github-before" "$OUT"; fi
    fi
fi

{
    echo
    echo "RTL88WiFi Stage27d — Makefile compile-to-link integration audit (dry-run only)"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "PROJECT: $PROJECT"
    echo "DRIVER: $DRIVER"
    echo "STAGE_DIR: $STAGE_DIR"
    echo "CONTEXT: Stage27c forced build returned exit 0, but its SHA256 matched Stage23; verify that WCL objects are linked into the final kext."
    echo "SCOPE: inspect exact compiler -c commands and final linker object inputs; do not compile, install or load."
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
} >> "$OUT"

cd "$DRIVER"
set +e
make -B -n -j1 rtl88wifi > "$DRYRUN" 2>&1
DRY_RC=$?
set -e

if [ "$DRY_RC" -ne 0 ]; then
    {
        echo "MAKE_DRY_RUN: FAIL exit=$DRY_RC"
        tail -100 "$DRYRUN"
    } | tee "$STATUS"
    FINAL_RC=3
else
    set +e
    python3 - "$DRYRUN" "$STATUS" <<'PY'
from pathlib import Path
import shlex, sys

dryrun = Path(sys.argv[1])
status = Path(sys.argv[2])
lines = dryrun.read_text(errors="replace").splitlines()

targets = [
    "RTW88WCLController.cpp",
    "RTW88WCLPCIBackend.cpp",
    "RTW88WCLSkywalkQueues.cpp",
]
compile_outputs = {}
compile_lines = {}
link_commands = []

for lineno, line in enumerate(lines, 1):
    stripped = line.strip()
    if not stripped.startswith(("xcrun clang++ ", "clang++ ")):
        continue
    try:
        args = shlex.split(stripped)
    except ValueError:
        continue
    if "-c" in args and "-o" in args:
        try:
            src = args[args.index("-c") + 1]
            obj = args[args.index("-o") + 1]
        except IndexError:
            continue
        for name in targets:
            if src.endswith("/" + name) or src == name:
                compile_outputs[name] = obj
                compile_lines[name] = lineno
    if "-static" in args and "-o" in args and "-kext" in args:
        try:
            output = args[args.index("-o") + 1]
        except IndexError:
            continue
        if output.endswith("/RTL88WiFi.kext/Contents/MacOS/RTL88WiFi"):
            objects = [arg for arg in args if arg.endswith(".o")]
            link_commands.append((lineno, output, objects, line))

out = []
out.append("MAKE_DRY_RUN: PASS")
out.append("WCL_SOURCE_COMPILE_AUDIT:")
for name in targets:
    if name in compile_outputs:
        out.append(f"  COMPILE: PASS {name} -> {compile_outputs[name]} (dry-run line {compile_lines[name]})")
    else:
        out.append(f"  COMPILE: FAIL {name} has no compiler -c command in dry-run")
if not link_commands:
    out.append("FINAL_KEXT_LINK_COMMAND: NOT FOUND")
    out.append("FINAL_KEXT_LINK: FAIL")
    final_link_objects = set()
else:
    # There should be one final kext linker invocation; inspect the last matching one.
    lineno, output, objects, command = link_commands[-1]
    out.append(f"FINAL_KEXT_LINK_COMMAND_LINE: {lineno}")
    out.append(f"FINAL_KEXT_OUTPUT: {output}")
    final_link_objects = set(objects)
    out.append("WCL_OBJECT_LINK_AUDIT:")
    for name in targets:
        obj = compile_outputs.get(name)
        if obj is None:
            out.append(f"  LINK: BLOCKED — no compile output discovered for {name}")
            continue
        # Normalize harmless ./ prefixes while preserving actual build path.
        norm_obj = obj.removeprefix("./")
        linked = any(x.removeprefix("./") == norm_obj for x in final_link_objects)
        out.append(f"  LINK: {'PASS' if linked else 'FAIL'} {name} -> {obj}")
    missing = [name for name in targets if name in compile_outputs and
               compile_outputs[name].removeprefix("./") not in
               {x.removeprefix("./") for x in final_link_objects}]
    if missing:
        out.append("FINAL_KEXT_LINK: FAIL — compiled WCL object(s) omitted from final link: " + ", ".join(missing))
    else:
        out.append("FINAL_KEXT_LINK: PASS — all audited WCL objects are explicit final-link inputs")

all_compiled = all(name in compile_outputs for name in targets)
all_linked = bool(link_commands) and all(
    name in compile_outputs and compile_outputs[name].removeprefix("./") in
    {x.removeprefix("./") for x in link_commands[-1][2]}
    for name in targets
)
out.append("AUDIT_RESULT: " + ("PASS" if all_compiled and all_linked else "FAIL-CLOSED"))
out.append("BUILD: NOT RUN")
out.append("INSTALL: NOT RUN")
out.append("LOAD: NOT RUN")
status.write_text("\n".join(out) + "\n")
print(status.read_text())
if not all_compiled or not all_linked:
    raise SystemExit(10)
PY
    PY_RC=$?
    set -e
    if [ "$PY_RC" -ne 0 ]; then FINAL_RC=4; fi
fi

{
    echo
    echo "STAGE27D_LINK_INTEGRATION_AUDIT:"
    cat "$STATUS"
    echo "DRYRUN_LOG: $DRYRUN"
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
        gh api --method PUT "$API_PATH" -f message="Stage27d Makefile compile-to-link audit" -f content="$B64" -f sha="$REMOTE_SHA" >/dev/null
        echo "GITHUB_UPLOAD_STATUS: SUCCESS — Development/output.log updated"
    else
        echo "GITHUB_UPLOAD_STATUS: FAILED — remote output.log SHA unavailable"
    fi
else
    echo "GITHUB_UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — report retained locally"
fi

echo "STATUS_FILE: $STATUS"
echo "DRYRUN_LOG: $DRYRUN"
echo "REPORT: $OUT"
exit "$FINAL_RC"
