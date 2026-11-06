#!/bin/bash
# Stage126: read-only, address-bounded Apple 24H32 Wi-Fi power-state disassembly.
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
[[ "$TARGET" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || {
  echo "ERROR: expected macOS 15.8.1 24H32 x86_64; found $TARGET $BUILD $ARCH"
  exit 3
}

TOOLCHAIN="/Applications/Xcode_16.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
OBJDUMP="$TOOLCHAIN/llvm-objdump"
NM="$TOOLCHAIN/llvm-nm"
[[ -x "$OBJDUMP" && -x "$NM" ]] || {
  echo "ERROR: Xcode 16.4 llvm-objdump/llvm-nm not found"
  exit 4
}

if [[ -n "${STAGE126_KC_MACHO:-}" ]]; then
  KC="$STAGE126_KC_MACHO"
else
  KC="$(find "$HOME/Developer" -type f -path '*/kc-cache/com.apple.iokit.IO80211Family.macho' -print -quit 2>/dev/null || true)"
fi
[[ -n "$KC" && -f "$KC" ]] || {
  echo "ERROR: Stage120 extracted com.apple.iokit.IO80211Family.macho not found; set STAGE126_KC_MACHO to its exact path"
  exit 5
}

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMPROOT="${TMPDIR:-/tmp}"
REPORT="$(mktemp "${TMPROOT%/}/stage126-apple-power-state-XXXXXX")"
NM_FILE="$(mktemp "${TMPROOT%/}/stage126-nm-XXXXXX")"
DUMP_FILE="$(mktemp "${TMPROOT%/}/stage126-dump-XXXXXX")"
trap 'rm -f "$NM_FILE" "$DUMP_FILE"' EXIT
KC_SHA="$(shasum -a 256 "$KC" | awk '{print $1}')"
SOURCE_COMMIT="$(git rev-parse HEAD)"

# A numeric nm listing lets us calculate a bounded address window per exact method.
if ! "$NM" -n --defined-only "$KC" >"$NM_FILE" 2>&1; then
  echo "ERROR: llvm-nm failed:"
  sed -n '1,25p' "$NM_FILE"
  exit 6
fi

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
  echo "--- Exact Apple power-state symbols (numeric nm entries) ---"

  SYMBOL_RE='^(__ZN21IO80211InfraInterface18setInterfaceEnableEb|__ZN22IO80211MacAddressAgent18setInterfaceEnableEb|__ZN23IO80211SkywalkInterface14enableDatapathEv|__ZN23IO80211SkywalkInterface15disableDatapathEv|__ZN23IO80211SkywalkInterface18isInterfaceEnabledEv|__ZN23IO80211SkywalkInterface18setInterfaceEnableEb|__ZN23IO80211SkywalkInterface6enableEj|__ZN23IO80211SkywalkInterface7disableEj)$'
  SYMBOL_LINES="$(awk -v re="$SYMBOL_RE" '$NF ~ re {print}' "$NM_FILE")"
  printf "%s\n" "$SYMBOL_LINES"
  SYMBOLS="$(printf "%s\n" "$SYMBOL_LINES" | awk 'NF {print $NF}' | sort -u)"

  echo
  echo "--- Address-bounded Mach-O method disassembly ---"
  echo "STAGE126_DISASSEMBLY_METHOD=--macho --disassemble --start-address --stop-address"
  echo "STAGE126_RANGE_POLICY=from_exact_nm_symbol_to_next_global_text_symbol_capped_at_1536_bytes"
  COUNT=0
  VERIFIED_COUNT=0
  while IFS= read -r SYMBOL; do
    [[ -n "$SYMBOL" ]] || continue
    COUNT=$((COUNT+1))
    echo "===== SYMBOL $SYMBOL ====="

    RANGE="$(python3 - "$NM_FILE" "$SYMBOL" <<'PY'
import pathlib, re, sys
path, target = sys.argv[1], sys.argv[2]
entries=[]
for line in pathlib.Path(path).read_text(errors="replace").splitlines():
    fields=line.split()
    if len(fields) < 3 or not re.fullmatch(r"[0-9a-fA-F]+", fields[0]):
        continue
    try:
        address=int(fields[0],16)
    except ValueError:
        continue
    entries.append((address, fields[-2], fields[-1]))
matches=[a for a,t,n in entries if n == target]
if not matches:
    raise SystemExit(2)
start=min(matches)
next_global=[a for a,t,n in entries if a > start and t.upper() == "T"]
candidate=min(next_global) if next_global else start+0x600
end=min(candidate, start+0x600)
reason="NEXT_GLOBAL_TEXT_SYMBOL" if candidate <= start+0x600 else "SAFETY_CAP"
if end <= start:
    raise SystemExit(3)
print(f"{start:x} {end:x} {end-start:x} {reason}")
PY
)" || {
      echo "STAGE126_SYMBOL_DISASSEMBLY=SYMBOL_RANGE_NOT_FOUND"
      continue
    }

    read -r START END RANGE_BYTES RANGE_REASON <<< "$RANGE"
    echo "STAGE126_SYMBOL_START=0x$START"
    echo "STAGE126_SYMBOL_STOP=0x$END"
    echo "STAGE126_SYMBOL_RANGE_BYTES=0x$RANGE_BYTES"
    echo "STAGE126_SYMBOL_RANGE_REASON=$RANGE_REASON"

    if "$OBJDUMP" --macho --disassemble --start-address="0x$START" --stop-address="0x$END" "$KC" >"$DUMP_FILE" 2>&1; then
      DUMP_RC=0
    else
      DUMP_RC=$?
    fi

    if [[ "$DUMP_RC" -ne 0 ]]; then
      echo "STAGE126_SYMBOL_DISASSEMBLY=OBJDUMP_FAILED EXIT=$DUMP_RC"
      sed -n '1,18p' "$DUMP_FILE"
      continue
    fi

    if grep -Eqi 'unknown argument|unknown option|error:' "$DUMP_FILE"; then
      echo "STAGE126_SYMBOL_DISASSEMBLY=OBJDUMP_REPORTED_ERROR"
      sed -n '1,18p' "$DUMP_FILE"
      continue
    fi

    if VERIFY="$(python3 - "$DUMP_FILE" "$START" "$END" <<'PY'
import pathlib, re, sys
path, start_s, end_s=sys.argv[1:]
start, end=int(start_s,16), int(end_s,16)
addresses=[]
for line in pathlib.Path(path).read_text(errors="replace").splitlines():
    m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):", line)
    if m:
        addresses.append(int(m.group(1),16))
if not addresses:
    print("NO_INSTRUCTION_ADDRESSES")
    raise SystemExit(1)
outside=[a for a in addresses if not (start <= a < end)]
if outside:
    print(f"OUT_OF_RANGE_ADDRESSES={len(outside)}")
    raise SystemExit(2)
print(f"INSTRUCTION_ADDRESS_COUNT={len(addresses)}")
PY
)"; then
      echo "STAGE126_SYMBOL_DISASSEMBLY=VERIFIED_ADDRESS_BOUNDED"
      echo "$VERIFY"
      VERIFIED_COUNT=$((VERIFIED_COUNT+1))
      cat "$DUMP_FILE"
    else
      VERIFY_RC=$?
      echo "STAGE126_SYMBOL_DISASSEMBLY=NOT_VERIFIED EXIT=$VERIFY_RC"
      echo "$VERIFY"
      sed -n '1,60p' "$DUMP_FILE"
    fi
  done <<< "$SYMBOLS"

  echo "STAGE126_POWER_SYMBOL_COUNT=$COUNT"
  echo "STAGE126_POWER_DISASSEMBLY_VERIFIED_COUNT=$VERIFIED_COUNT"
  if [[ "$COUNT" -eq 0 ]]; then
    echo "STAGE126_POWER_METHODS=NOT_FOUND"
  elif [[ "$VERIFIED_COUNT" -eq "$COUNT" ]]; then
    echo "STAGE126_POWER_METHODS=ALL_ADDRESS_BOUNDED"
  else
    echo "STAGE126_POWER_METHODS=INCOMPLETE"
  fi

  echo
  echo "--- Apple controller power selector symbols ---"
  grep -E 'IO80211Controller.*(getPOWER|setPOWER)' "$NM_FILE" || true
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
import base64, hashlib, json, pathlib, subprocess, sys, tempfile, time
report=pathlib.Path(sys.argv[1])
stamp, repo=sys.argv[2:]
data=report.read_bytes()
dest=f"Development/Logs/stage126-apple-power-state-{stamp}.log"
payload={
    "message":"Stage126: publish address-bounded read-only Apple 24H32 power-state ABI audit",
    "branch":"main",
    "content":base64.b64encode(data).decode("ascii")
}
expected=hashlib.sha1(f"blob {len(data)}\0".encode("ascii")+data).hexdigest()
last_error=""
for attempt in range(1,4):
    with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
        json.dump(payload,f)
        f.flush()
        r=subprocess.run(
            ["gh","api","--method","PUT",f"repos/{repo}/contents/{dest}","--input",f.name],
            capture_output=True,text=True
        )
    if r.returncode == 0:
        try:
            obj=json.loads(r.stdout)
            actual=obj.get("content",{}).get("sha")
        except Exception:
            actual=None
        if actual == expected:
            print("STAGE126_UPLOAD=PASS")
            print("STAGE126_UPLOAD_BYTES="+str(len(data)))
            print("STAGE126_UPLOAD_SHA="+actual)
            print("STAGE126_GITHUB_PATH="+dest)
            print("STAGE126_GITHUB_URL=https://github.com/"+repo+"/blob/main/"+dest)
            break
        last_error="GitHub content SHA verification mismatch: "+str(actual)
    else:
        last_error=r.stderr.strip() or r.stdout.strip()
    print(f"STAGE126_UPLOAD_ATTEMPT={attempt}_FAILED")
    if attempt < 3:
        time.sleep(3*attempt)
else:
    print("STAGE126_UPLOAD=FAILED")
    print(last_error)
    raise SystemExit(7)
PY
