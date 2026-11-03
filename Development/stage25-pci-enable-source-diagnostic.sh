#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PROJECT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-stage14-generic-skywalk-segment-abi"
if [ -n "$(printenv RTL88_PROJECT 2>/dev/null || true)" ]; then PROJECT="$(printenv RTL88_PROJECT)"; fi
PCI="$PROJECT/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLPCIBackend.cpp"
OUT="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage25-pci-enable-diagnostic-$STAMP"
mkdir -p "$STAGE_DIR"

if [ ! -f "$PCI" ]; then
  echo "ERROR: PCI source missing: $PCI" >&2
  exit 2
fi
if [ -f "$OUT" ]; then cp -p "$OUT" "$STAGE_DIR/output.log.before"; fi

python3 - "$PCI" "$STAGE_DIR" "$OUT" <<'PY'
from pathlib import Path
import hashlib
import sys

src_path, stage_dir, out_path = map(Path, sys.argv[1:])
src = src_path.read_text()

def brace_end(text, opening):
    depth = 0
    state = "normal"
    i = opening
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if state == "normal":
            if ch == "/" and nxt == "/":
                state = "line"; i += 2; continue
            if ch == "/" and nxt == "*":
                state = "block"; i += 2; continue
            if ch == '"':
                state = "string"; i += 1; continue
            if ch == "'":
                state = "char"; i += 1; continue
            if ch == "{": depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0: return i + 1
        elif state == "line":
            if ch == "\n": state = "normal"
        elif state == "block":
            if ch == "*" and nxt == "/":
                state = "normal"; i += 2; continue
        elif state in ("string", "char"):
            if ch == chr(92): i += 2; continue
            if (state == "string" and ch == '"') or (state == "char" and ch == "'"):
                state = "normal"
        i += 1
    raise RuntimeError("unmatched C++ braces")

needle = "RTW88WCLPCIBackend::setRadioRunning("
pos = src.find(needle)
if pos < 0:
    raise SystemExit("ERROR: setRadioRunning definition not found")
line_start = src.rfind("\n", 0, pos) + 1
brace = src.find("{", pos)
if brace < 0:
    raise SystemExit("ERROR: setRadioRunning body opening brace not found")
end = brace_end(src, brace)
func = src[line_start:end]
line_no = src.count("\n", 0, line_start) + 1
(stage_dir / "setRadioRunning.actual.cpp.txt").write_text(func)

# Extract the exact branch used by the failed Stage25 guard.
cond = "if ((command & 0x0006U) != 0x0006U)"
branch_pos = func.find(cond)
branch_text = "NOT PRESENT"
branch_line = "n/a"
if branch_pos >= 0:
    b = func.find("{", branch_pos)
    e = brace_end(func, b)
    branch_text = func[branch_pos:e]
    branch_line = str(line_no + func.count("\n", 0, branch_pos))
(stage_dir / "pci-enable-failure-branch.txt").write_text(branch_text)

report = []
report.append("RTL88WiFi Stage25 PCI-enable source diagnostic")
report.append("DATE: " + __import__("datetime").datetime.now().astimezone().isoformat(timespec="seconds"))
report.append("PROJECT: " + str(src_path.parents[5]) if len(src_path.parents) > 5 else "PROJECT: unavailable")
report.append("PCI_SOURCE: " + str(src_path))
report.append("PCI_SOURCE_SHA256: " + hashlib.sha256(src_path.read_bytes()).hexdigest())
report.append("FUNCTION_START_LINE: " + str(line_no))
report.append("TARGET_BRANCH_START_LINE: " + branch_line)
report.append("TARGET_BRANCH_MATCHES: " + str(src.count(cond)))
report.append("")
report.append("===== ACTUAL setRadioRunning() DEFINITION =====")
report.append(func)
report.append("")
report.append("===== EXACT PCI ENABLE FAILURE BRANCH =====")
report.append(branch_text)
report.append("")
report.append("DIAGNOSTIC ONLY: no source files modified; no build/install/load performed.")
report.append("STAGE_DIR: " + str(stage_dir))
new = "\n".join(report) + "\n"

previous = (stage_dir / "output.log.before").read_text(errors="replace") if (stage_dir / "output.log.before").exists() else ""
out_path.write_text(previous.rstrip() + "\n\n" + new if previous else new)
print(new)
PY

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  SHA="$(gh api "repos/$REPO/contents/Development/output.log" --jq '.sha' 2>/dev/null || true)"
  B64="$(base64 < "$OUT" | tr -d '\n')"
  if [ -n "$SHA" ]; then
    gh api --method PUT "repos/$REPO/contents/Development/output.log" \
      -f message="Stage 25 PCI enable source-shape diagnostic" \
      -f content="$B64" -f sha="$SHA" >/dev/null
    echo "UPLOAD_STATUS: SUCCESS — https://github.com/$REPO/blob/main/Development/output.log"
  else
    echo "UPLOAD_STATUS: GH_AUTH_OK_BUT_OUTPUT_LOG_SHA_NOT_RETRIEVED"
  fi
else
  echo "UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — output.log ready for existing uploader."
fi
echo "REPORT: $OUT"
echo "DIAGNOSTIC_ARTIFACTS: $STAGE_DIR"
