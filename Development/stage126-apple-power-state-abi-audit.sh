#!/bin/bash
# Stage126: read-only disassembly audit of Apple 24H32 Wi-Fi power-state methods.
# No driver edits/build/sign/install/load/unload, hardware activation, or OC/EFI changes.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BASE_STAGE125="3d02ef10e353bb80d032980ffe2e7d28b90fd7da"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
WORKTREE_STATUS_ENTRIES="$(git status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')"
TARGET="$(sw_vers -productVersion)"
BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
[[ "$TARGET" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: expected macOS 15.8.1 24H32 x86_64; found $TARGET $BUILD $ARCH"; exit 3; }
OBJDUMP="/Applications/Xcode_16.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-objdump"
NM="/Applications/Xcode_16.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-nm"
[[ -x "$OBJDUMP" && -x "$NM" ]] || { echo "ERROR: Xcode 16.4 llvm-objdump/llvm-nm not found"; exit 4; }
if [[ -n "${STAGE126_KC_MACHO:-}" ]]; then
  KC="$STAGE126_KC_MACHO"
else
  KC="$(find "$HOME/Developer" -type f -path '*/kc-cache/com.apple.iokit.IO80211Family.macho' -print -quit 2>/dev/null || true)"
fi
[[ -n "$KC" && -f "$KC" ]] || { echo "ERROR: Stage120 extracted com.apple.iokit.IO80211Family.macho not found; set STAGE126_KC_MACHO to its exact path"; exit 5; }
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMPROOT="${TMPDIR:-/tmp}"
REPORT="$(mktemp "${TMPROOT%/}/stage126-apple-power-state-XXXXXX")"
KC_SHA="$(shasum -a 256 "$KC" | awk '{print $1}')"
SOURCE_COMMIT="$(git rev-parse HEAD)"
{
  echo "========== STAGE126 APPLE POWER STATE ABI AUDIT =========="
  echo "STAGE126_SOURCE_COMMIT=$SOURCE_COMMIT"
  echo "STAGE126_EXECUTION_BRANCH=${CURRENT_BRANCH:-DETACHED_OR_UNKNOWN}"
  echo "STAGE126_WORKTREE_STATUS_ENTRIES=${WORKTREE_STATUS_ENTRIES:-UNKNOWN}"
  echo "STAGE126_STAGE125_BASE=$BASE_STAGE125"
  echo "STAGE126_TARGET=$TARGET BUILD=$BUILD ARCH=$ARCH"
  echo "STAGE126_SCOPE=READ_ONLY_APPLE_24H32_POWER_METHOD_DISASSEMBLY"
  echo "STAGE126_KC_MACHO_SHA256=$KC_SHA"
  echo "STAGE126_KC_MACHO_PATH=$KC"
  echo "STAGE126_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
  echo "STAGE126_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
  echo
  echo "--- Exact Apple power-state symbols (nm entries) ---"
  SYMBOL_RE='^(__ZN21IO80211InfraInterface18setInterfaceEnableEb|__ZN22IO80211MacAddressAgent18setInterfaceEnableEb|__ZN23IO80211SkywalkInterface14enableDatapathEv|__ZN23IO80211SkywalkInterface15disableDatapathEv|__ZN23IO80211SkywalkInterface18isInterfaceEnabledEv|__ZN23IO80211SkywalkInterface18setInterfaceEnableEb|__ZN23IO80211SkywalkInterface6enableEj|__ZN23IO80211SkywalkInterface7disableEj)$'
  NM_LIST="$("$NM" --defined-only "$KC" 2>&1 || true)"
  SYMBOL_LINES="$(printf "%s\n" "$NM_LIST" | awk -v re="$SYMBOL_RE" '$NF ~ re {print}' || true)"
  printf "%s\n" "$SYMBOL_LINES"
  SYMBOLS="$(printf "%s\n" "$SYMBOL_LINES" | awk '{print $NF}' | sort -u)"
  echo
  echo "--- Mach-O-specific exact-symbol disassembly ---"
  COUNT=0
  VERIFIED_COUNT=0
  while IFS= read -r SYMBOL; do
    [[ -n "$SYMBOL" ]] || continue
    COUNT=$((COUNT+1))
    echo "===== SYMBOL $SYMBOL ====="
    DUMP="$("$OBJDUMP" --macho --disassemble-symbols="$SYMBOL" "$KC" 2>&1 || true)"
    if printf "%s\n" "$DUMP" | grep -Eqi 'unknown argument|unknown option|error:'; then
      echo "STAGE126_SYMBOL_DISASSEMBLY=TOOL_OPTION_ERROR"
      printf "%s\n" "$DUMP" | head -12
    elif printf "%s\n" "$DUMP" | grep -Fq "$SYMBOL"; then
      if ! printf "%s\n" "$DUMP" | grep -Eq "^[[:space:]]*[0-9a-f]+[[:space:]]+<$SYMBOL>:"; then
        echo "STAGE126_SYMBOL_DISASSEMBLY=NOT_ISOLATED"
        printf "%s\n" "$DUMP" | head -35
      else
        echo "STAGE126_SYMBOL_DISASSEMBLY=VERIFIED"
        VERIFIED_COUNT=$((VERIFIED_COUNT+1))
        printf "%s\n" "$DUMP"
      fi
    else
      echo "STAGE126_SYMBOL_DISASSEMBLY=NOT_FOUND_OR_NOT_ISOLATED"
      printf "%s\n" "$DUMP" | head -25
    fi
  done <<< "$SYMBOLS"
  echo "STAGE126_POWER_SYMBOL_COUNT=$COUNT"
  echo "STAGE126_POWER_DISASSEMBLY_VERIFIED_COUNT=$VERIFIED_COUNT"
  if [[ "$COUNT" -eq 0 ]]; then echo "STAGE126_POWER_METHODS=NOT_FOUND"; elif [[ "$VERIFIED_COUNT" -eq "$COUNT" ]]; then echo "STAGE126_POWER_METHODS=VERIFIED"; else echo "STAGE126_POWER_METHODS=INCOMPLETE_OR_NOT_ISOLATED"; fi
  echo
  echo "--- Apple controller power selector symbols ---"
  printf "%s\n" "$NM_LIST" | grep -E 'IO80211Controller.*(getPOWER|setPOWER)' || true
  echo
  echo "STAGE126_POWER_CALL_GRAPH=REVIEW_REQUIRED"
  echo "STAGE126_DISASSEMBLY_TOOL_OPTION=--disassemble-symbols"
  echo "STAGE126_DRIVER_SOURCE_MODIFIED=NO"
  echo "STAGE126_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
  echo "STAGE126_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
  echo "========== END STAGE126 =========="
} >"$REPORT"
echo "===== STAGE126 SUMMARY ====="
grep -aE '^(STAGE126_|ERROR:|===== SYMBOL)' "$REPORT" | tail -100 || true
echo "STAGE126_LOCAL_REPORT=$REPORT"
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64, hashlib, json, pathlib, subprocess, sys, tempfile
report=pathlib.Path(sys.argv[1]); stamp=sys.argv[2]; repo=sys.argv[3]
full=report.read_bytes()
data=full
compacted=False
# Preserve the full report locally; bound GitHub Contents API payload size.
if len(data) > 700_000:
    lines=full.decode("utf-8", "replace").splitlines()
    out=[]; in_symbol=False; kept=0
    for line in lines:
        if line.startswith("===== SYMBOL "):
            in_symbol=True; kept=0; out.append(line); continue
        if line.startswith("STAGE126_") or line.startswith("==========") or line.startswith("---"):
            in_symbol=False; out.append(line); continue
        if in_symbol and kept < 80:
            out.append(line); kept += 1
    out.append("STAGE126_UPLOAD_COMPACTED=YES")
    out.append("STAGE126_FULL_REPORT_BYTES="+str(len(full)))
    data=("\n".join(out)+"\n").encode()
    compacted=True
if len(data) > 850_000:
    raise SystemExit("STAGE126_UPLOAD=TOO_LARGE_AFTER_COMPACTION bytes="+str(len(data)))
dest=f"Development/Logs/stage126-apple-power-state-{stamp}.log"
payload={"message":"Stage126: publish targeted read-only Apple 24H32 power-state ABI audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
    json.dump(payload,f); f.flush()
    r=subprocess.run(["gh","api","--method","PUT",f"repos/{repo}/contents/{dest}","--input",f.name],capture_output=True,text=True)
if r.returncode:
    print("STAGE126_UPLOAD=FAILED")
    print("STAGE126_UPLOAD_BYTES="+str(len(data)))
    print(r.stderr.strip())
    sys.exit(r.returncode)
obj=json.loads(r.stdout)
expected=hashlib.sha1(f"blob {len(data)}\0".encode("ascii")+data).hexdigest()
actual=obj.get("content",{}).get("sha")
if actual!=expected:
    print("STAGE126_UPLOAD=VERIFY_REQUIRED"); print("EXPECTED="+expected); print("ACTUAL="+str(actual)); sys.exit(4)
print("STAGE126_UPLOAD=PASS")
print("STAGE126_UPLOAD_BYTES="+str(len(data)))
print("STAGE126_UPLOAD_COMPACTED="+("YES" if compacted else "NO"))
print("STAGE126_UPLOAD_SHA="+actual)
print("STAGE126_GITHUB_PATH="+dest)
print("STAGE126_GITHUB_URL=https://github.com/"+repo+"/blob/main/"+dest)
PY
