#!/bin/bash
# Stage126: read-only disassembly audit of Apple 24H32 Wi-Fi power-state methods.
# No driver edits/build/sign/install/load/unload, hardware activation, or OC/EFI changes.
set -euo pipefail
EXPECTED_BRANCH="work/stage126-apple-power-state-abi-audit"
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BASE_STAGE125="3d02ef10e353bb80d032980ffe2e7d28b90fd7da"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
[[ "$(git branch --show-current)" == "$EXPECTED_BRANCH" ]] || { echo "ERROR: expected branch $EXPECTED_BRANCH"; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "ERROR: working tree must be clean"; git status --short; exit 2; }
git merge-base --is-ancestor "$BASE_STAGE125" HEAD || { echo "ERROR: Stage126 ancestry mismatch"; exit 2; }
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
  echo "STAGE126_STAGE125_BASE=$BASE_STAGE125"
  echo "STAGE126_TARGET=$TARGET BUILD=$BUILD ARCH=$ARCH"
  echo "STAGE126_SCOPE=READ_ONLY_APPLE_24H32_POWER_METHOD_DISASSEMBLY"
  echo "STAGE126_KC_MACHO_SHA256=$KC_SHA"
  echo "STAGE126_KC_MACHO_PATH=$KC"
  echo "STAGE126_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
  echo "STAGE126_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
  echo
  echo "--- Candidate Apple power symbols (raw mangled names) ---"
  "$NM" --defined-only "$KC" 2>&1 | grep -E 'setInterfaceEnable|isInterfaceEnabled|IO80211InfraInterface.*enable|IO80211InfraInterface.*disable|IO80211SkywalkInterface.*enable|IO80211SkywalkInterface.*disable' || true
  echo
  echo "--- Disassembly of matched Apple power methods ---"
  SYMBOLS="$("$NM" --defined-only "$KC" 2>/dev/null | awk '{print $NF}' | grep -E 'setInterfaceEnable|isInterfaceEnabled|IO80211InfraInterface.*enable|IO80211InfraInterface.*disable|IO80211SkywalkInterface.*enable|IO80211SkywalkInterface.*disable' | sort -u || true)"
  COUNT=0
  while IFS= read -r SYMBOL; do
    [[ -n "$SYMBOL" ]] || continue
    COUNT=$((COUNT+1))
    echo "===== SYMBOL $SYMBOL ====="
    "$OBJDUMP" --macho --disassemble --symbolize-operands --demangle --disassemble-symbols="$SYMBOL" "$KC" 2>&1 || true
  done <<< "$SYMBOLS"
  echo "STAGE126_POWER_SYMBOL_COUNT=$COUNT"
  if [[ "$COUNT" -eq 0 ]]; then echo "STAGE126_POWER_METHODS=NOT_FOUND"; else echo "STAGE126_POWER_METHODS=DISASSEMBLED_CANDIDATES"; fi
  echo
  echo "--- Apple controller power selector symbols ---"
  "$NM" --defined-only "$KC" 2>&1 | grep -E 'IO80211Controller.*(getPOWER|setPOWER)' || true
  echo
  echo "STAGE126_POWER_CALL_GRAPH=REVIEW_REQUIRED"
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
data=report.read_bytes()
dest=f"Development/Logs/stage126-apple-power-state-{stamp}.log"
payload={"message":"Stage126: publish read-only Apple 24H32 power-state ABI audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
    json.dump(payload,f); f.flush()
    r=subprocess.run(["gh","api","--method","PUT",f"repos/{repo}/contents/{dest}","--input",f.name],capture_output=True,text=True)
if r.returncode:
    print("STAGE126_UPLOAD=FAILED"); print(r.stderr.strip()); sys.exit(r.returncode)
obj=json.loads(r.stdout)
expected=hashlib.sha1(f"blob {len(data)}\\0".encode("ascii")+data).hexdigest()
actual=obj.get("content",{}).get("sha")
if actual!=expected:
    print("STAGE126_UPLOAD=VERIFY_REQUIRED"); print("EXPECTED="+expected); print("ACTUAL="+str(actual)); sys.exit(4)
print("STAGE126_UPLOAD=PASS")
print("STAGE126_UPLOAD_SHA="+actual)
print("STAGE126_GITHUB_PATH="+dest)
print("STAGE126_GITHUB_URL=https://github.com/"+repo+"/blob/main/"+dest)
PY
