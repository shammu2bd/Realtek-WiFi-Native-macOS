#!/bin/bash
# Stage109 — read-only native bundle, kernel-symbol and EFI-parity audit.
# No build, signing, install/load, EFI writes, SIP/NVRAM changes or hardware tests.
set -u
set -o pipefail

EXPECTED_BRANCH="work/stage91-tx-submission-callback-v1"
STAGE108_COMMIT="61e755e"
EXPECTED_BIN_SHA="409137db0772c6f5326af89f9f6dc699f8f18a13eb9025bc194b58e5bb92cd0a"
NATIVE_ID="io.github.x1ren41l.RTL88WiFi"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside repository"; exit 2; }
cd "$ROOT" || exit 2
[ "$(git branch --show-current)" = "$EXPECTED_BRANCH" ] || { echo "ERROR: expected branch $EXPECTED_BRANCH"; exit 2; }
if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree is not clean; preserve local changes first."
  git status --short
  exit 2
fi
git cat-file -e "${STAGE108_COMMIT}^{commit}" 2>/dev/null || { echo "ERROR: Stage108 source/log commit unavailable"; exit 2; }
git merge-base --is-ancestor "$STAGE108_COMMIT" HEAD || { echo "ERROR: Stage108 commit is not an ancestor of HEAD"; exit 2; }

BUNDLE="driver/RTL88WiFi/build/out/RTL88WiFiNative.kext"
BIN="$BUNDLE/Contents/MacOS/RTL88WiFiNative"
PLIST="$BUNDLE/Contents/Info.plist"
[ -s "$BIN" ] && [ -s "$PLIST" ] || { echo "ERROR: Stage108 native bundle is missing; rerun Stage108 first"; exit 2; }

mkdir -p Development/Logs || exit 2
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_REL="Development/Logs/stage109-native-bundle-readiness-${STAMP}.log"
LOG="$ROOT/$LOG_REL"
TMP_BASE="${TMPDIR:-/tmp}"
[ -d "$TMP_BASE" ] && [ -w "$TMP_BASE" ] || TMP_BASE="/tmp"
TMP="$(mktemp -d "$TMP_BASE/stage109.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
exec 3>&1 4>&2
exec > >(tee "$LOG") 2>&1

PASS=0; FAIL=0; WARN=0
pass(){ PASS=$((PASS+1)); echo "PASS: $*"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $*"; }
warn(){ WARN=$((WARN+1)); echo "WARN: $*"; }
capture(){ local n="$1"; shift; "$@" >"$TMP/$n.txt" 2>&1; local r=$?; echo "$r" >"$TMP/$n.rc"; echo "COMMAND_${n}_EXIT=$r"; return 0; }
rc(){ [ -f "$TMP/$1.rc" ] && cat "$TMP/$1.rc" || echo 999; }
excerpt(){ echo "----- $1 (first ${2:-80} lines) -----"; [ -f "$TMP/$1.txt" ] && sed -n "1,${2:-80}p" "$TMP/$1.txt" || echo "NO_CAPTURE"; echo "----- END $1 -----"; }

echo "========== STAGE109 NATIVE BUNDLE READINESS AUDIT =========="
echo "UTC_STAMP=$STAMP"
echo "BRANCH=$EXPECTED_BRANCH"
echo "HEAD=$(git rev-parse HEAD)"
echo "STAGE108_BASE_COMMIT=$STAGE108_COMMIT"
echo "SCOPE=READ_ONLY_BUNDLE_METADATA_MACHO_KMUTIL_SIGNATURE_EFI_PARITY"
echo "BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN"

for t in sw_vers uname file lipo otool nm plutil shasum python3 kmutil codesign csrutil git; do
  if command -v "$t" >/dev/null 2>&1; then pass "tool available: $t"; else fail "required audit tool missing: $t"; fi
done
OS="$(sw_vers -productVersion 2>/dev/null || echo UNKNOWN)"
BUILD="$(sw_vers -buildVersion 2>/dev/null || echo UNKNOWN)"
ARCH="$(uname -m 2>/dev/null || echo UNKNOWN)"
echo "HOST_PRODUCT_VERSION=$OS"
echo "HOST_BUILD_VERSION=$BUILD"
echo "HOST_ARCH=$ARCH"
if [ "$OS" = "15.8.1" ] && [ "$BUILD" = "24H32" ] && [ "$ARCH" = "x86_64" ]; then
  pass "host matches macOS 15.8.1 build 24H32 x86_64"
else
  fail "host differs from pinned target"
fi

BIN_SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
echo "STAGE109_NATIVE_BINARY_SHA256=$BIN_SHA"
if [ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ]; then pass "binary matches the successful Stage108 native link"; else fail "binary does not match Stage108 build hash"; fi
capture binary-file file "$BIN"
capture binary-arch lipo -archs "$BIN"
capture macho-header otool -hv "$BIN"
capture macho-load-commands otool -l "$BIN"
capture linked-images otool -L "$BIN"
capture nm-undefined nm -u "$BIN"
capture nm-metadata nm -m "$BIN"
excerpt binary-file 12
excerpt binary-arch 12
excerpt macho-header 24
excerpt linked-images 50
excerpt nm-undefined 60
excerpt nm-metadata 60
if [ "$(rc binary-file)" -eq 0 ] && grep -q 'Mach-O 64-bit kext bundle x86_64' "$TMP/binary-file.txt"; then pass "Mach-O executable is x86_64 kext bundle"; else fail "Mach-O executable type/architecture check"; fi
if [ "$(rc binary-arch)" -eq 0 ] && grep -qw x86_64 "$TMP/binary-arch.txt"; then pass "lipo confirms x86_64 architecture"; else fail "lipo architecture verification"; fi

capture plist-lint plutil -lint "$PLIST"
excerpt plist-lint 12
if [ "$(rc plist-lint)" -eq 0 ] && python3 - "$PLIST" <<'PY'
import plistlib,sys
p=plistlib.load(open(sys.argv[1],"rb"))
assert p.get("CFBundleIdentifier")=="io.github.x1ren41l.RTL88WiFi",p.get("CFBundleIdentifier")
assert p.get("CFBundleExecutable")=="RTL88WiFiNative",p.get("CFBundleExecutable")
assert p.get("CFBundlePackageType")=="KEXT",p.get("CFBundlePackageType")
assert p.get("LSMinimumSystemVersion")=="15.0",p.get("LSMinimumSystemVersion")
libs=p.get("OSBundleLibraries",{})
for k in ("com.apple.iokit.IO80211Family","com.apple.iokit.IOSkywalkFamily","com.apple.iokit.IOPCIFamily"):
    assert isinstance(libs.get(k),str) and libs[k].strip(),(k,libs.get(k))
assert "com.apple.iokit.IO80211FamilyLegacy" not in libs
personalities=p.get("IOKitPersonalities",{})
matches=[x for x in personalities.values() if isinstance(x,dict) and x.get("IOClass")=="RTW88WCLController" and x.get("IOProviderClass")=="IOPCIDevice" and {"0xC82110EC","0xB82110EC"} <= set(str(x.get("IOPCIMatch","")).split())]
assert len(matches)==1,("native RTL8821CE personality count",len(matches))
print("PLIST_IDENTITY=PASS")
print("PLIST_NATIVE_DEPENDENCIES=PASS")
print("PLIST_LEGACY_IO80211_ABSENT=PASS")
print("PLIST_RTL8821CE_PERSONALITY=PASS")
print("PLIST_BUNDLE_ID="+p["CFBundleIdentifier"])
print("PLIST_DEPENDENCIES="+",".join(sorted(libs)))
PY
then
  pass "native Info.plist identity, dependencies and RTL8821CE personality"
else
  fail "native Info.plist contract"
fi

# Confirm the native link graph uses only the shared kmod metadata object,
# not the legacy Airport controller/interface frontend objects.
if grep -E '^NATIVE_ALL_OBJS[[:space:]]*:?=' driver/RTL88WiFi/Makefile | grep -q 'AIRPORT_KMOD_OBJ' &&
   ! grep -E '^NATIVE_ALL_OBJS[[:space:]]*:?=' driver/RTL88WiFi/Makefile | grep -q 'AIRPORT_KEXT_OBJS'; then
  pass "native link graph excludes legacy Airport frontend objects"
else
  fail "native link graph contains unexpected legacy frontend object list"
fi
if grep -E '^NATIVE_ALL_OBJS[[:space:]]*:?=' driver/RTL88WiFi/Makefile | grep -q 'WCL24H32_CONTROLLER_OBJ' &&
   grep -E '^NATIVE_ALL_OBJS[[:space:]]*:?=' driver/RTL88WiFi/Makefile | grep -q 'WCL24H32_INFRA_OBJ'; then
  pass "native link graph includes the 24H32 controller and infra interface"
else
  fail "native link graph is missing required WCL objects"
fi
if grep -q 'KMOD_EXPLICIT_DECL(io.github.x1ren41l.RTL88WiFi' driver/RTL88WiFi/src/kext/kmod_info.c; then
  pass "native kmod metadata identifier agrees with native bundle identifier"
else
  fail "native kmod metadata identifier mismatch"
fi

capture kmutil-libraries kmutil libraries -p "$BUNDLE"
capture kmutil-undefined kmutil libraries -p "$BUNDLE" --undef-symbols
capture kmutil-multiple kmutil libraries -p "$BUNDLE" --multdef-symbols
capture kmutil-xml kmutil libraries -p "$BUNDLE" --xml
capture kmutil-diagnostics kmutil print-diagnostics -p "$BUNDLE" -D
for n in kmutil-libraries kmutil-undefined kmutil-multiple kmutil-xml kmutil-diagnostics; do excerpt "$n" 120; done
KMUTIL_LIB_RC="$(rc kmutil-libraries)"
KMUTIL_UNDEF_RC="$(rc kmutil-undefined)"
KMUTIL_MULTI_RC="$(rc kmutil-multiple)"
KMUTIL_XML_RC="$(rc kmutil-xml)"
KMUTIL_DIAG_RC="$(rc kmutil-diagnostics)"
if [ "$KMUTIL_LIB_RC" -eq 0 ] && [ "$KMUTIL_UNDEF_RC" -eq 0 ] && [ "$KMUTIL_MULTI_RC" -eq 0 ]; then
  pass "kmutil provider, undefined-symbol and multiple-definition analysis completed successfully"
else
  fail "kmutil provider/symbol resolution failed"
fi
if [ "$KMUTIL_XML_RC" -eq 0 ]; then pass "kmutil dependency XML generation completed"; else warn "kmutil XML output unavailable"; fi
if [ "$KMUTIL_DIAG_RC" -eq 0 ]; then pass "kmutil diagnostics command completed"; else warn "kmutil diagnostics command unavailable or rejected the candidate"; fi

capture codesign-details codesign -dv --verbose=4 "$BUNDLE"
capture codesign-verify codesign --verify --deep --strict "$BUNDLE"
excerpt codesign-details 60
excerpt codesign-verify 40
SIGNING_STATE=UNKNOWN
if [ "$(rc codesign-verify)" -eq 0 ]; then
  SIGNING_STATE=SIGNED_VALID
  warn "bundle has a verifiable signature; signing was not performed by Stage109"
elif grep -Eqi 'code object is not signed at all|not signed' "$TMP/codesign-verify.txt" "$TMP/codesign-details.txt" 2>/dev/null; then
  SIGNING_STATE=UNSIGNED
  warn "bundle is unsigned; load acceptance remains blocked pending a permitted signing path"
else
  SIGNING_STATE=INVALID_OR_UNVERIFIABLE
  fail "bundle signature state is invalid or ambiguous"
fi
echo "STAGE109_SIGNING_STATE=$SIGNING_STATE"

capture sip-status csrutil status
excerpt sip-status 20
if grep -Eqi 'System Integrity Protection status: enabled|System Integrity Protection is enabled' "$TMP/sip-status.txt"; then
  SIP_STATE=ENABLED; pass "SIP remains enabled"
else
  SIP_STATE=NOT_CONFIRMED_ENABLED; warn "SIP enabled state not confirmed by csrutil"
fi
echo "STAGE109_SIP_STATE=$SIP_STATE"

# Read-only USB EFI inspection. No EFI is mounted or modified by this runner.
CONFIG_PATH="${OPENCORE_CONFIG:-}"
if [ -n "$CONFIG_PATH" ]; then
  [ -f "$CONFIG_PATH" ] || { echo "ERROR: OPENCORE_CONFIG is not a readable file"; exit 2; }
  CONFIG_SOURCE=EXPLICIT_READ_ONLY_PATH
elif [ -f "/Volumes/EFI/EFI/OC/config.plist" ]; then
  CONFIG_PATH="/Volumes/EFI/EFI/OC/config.plist"; CONFIG_SOURCE=KNOWN_USB_EFI_PATH
else
  CONFIGS="$TMP/configs.txt"
  python3 - <<'PY' > "$CONFIGS"
from pathlib import Path
for p in sorted(Path("/Volumes").glob("*/EFI/OC/config.plist")):
    if p.is_file(): print(p)
PY
  COUNT="$(wc -l < "$CONFIGS" | tr -d ' ')"
  if [ "$COUNT" = "1" ]; then CONFIG_PATH="$(cat "$CONFIGS")"; CONFIG_SOURCE=UNIQUE_MOUNTED_EFI
  elif [ "$COUNT" = "0" ]; then CONFIG_PATH=""; CONFIG_SOURCE=NOT_FOUND
  else CONFIG_PATH=""; CONFIG_SOURCE=AMBIGUOUS; fi
fi
echo "STAGE109_EFI_CONFIG_SOURCE=$CONFIG_SOURCE"
EFI_RESULT=NOT_ASSESSED
EFI_NATIVE_COUNT=UNKNOWN
EFI_LEGACY_COUNT=UNKNOWN
EFI_HASH_MATCH=UNKNOWN
EFI_SKYWALK_BLOCK=UNKNOWN
if [ -n "$CONFIG_PATH" ]; then
  capture efi-plist-lint plutil -lint "$CONFIG_PATH"
  if [ "$(rc efi-plist-lint)" -eq 0 ] && python3 - "$CONFIG_PATH" "$EXPECTED_BIN_SHA" "$NATIVE_ID" > "$TMP/efi-inspection.txt" <<'PY'
import hashlib,plistlib,sys
from pathlib import Path
cfgpath=Path(sys.argv[1]).resolve()
expected=sys.argv[2]
native_id=sys.argv[3]
with cfgpath.open("rb") as f: cfg=plistlib.load(f)
ocdir=cfgpath.parent
entries=cfg.get("Kernel",{}).get("Add",[])
native=[]; legacy=[]; hash_results=[]
for i,e in enumerate(entries):
    bp=str(e.get("BundlePath",""))
    exe=str(e.get("ExecutablePath",""))
    enabled=bool(e.get("Enabled",False))
    candidates=[ocdir/"Kexts"/bp,ocdir/bp]
    bundle=next((x for x in candidates if bp and x.is_dir()),candidates[0])
    ip=bundle/"Contents/Info.plist"
    ident=""
    if ip.is_file():
        try:
            with ip.open("rb") as f: ident=str(plistlib.load(f).get("CFBundleIdentifier",""))
        except Exception: ident="PLIST_READ_ERROR"
    is_native=(Path(bp).name=="RTL88WiFiNative.kext" and Path(exe).name=="RTL88WiFiNative")
    if is_native:
        digest_path=bundle/exe
        digest=hashlib.sha256(digest_path.read_bytes()).hexdigest() if digest_path.is_file() else "MISSING"
        hash_results.append(digest==expected)
        native.append((i,enabled,bp,ident,digest))
    elif ident.lower()==native_id.lower() or "RTL88WIFI.KEXT" in bp.upper():
        legacy.append((i,enabled,bp,ident))
    if is_native or (ident.lower()==native_id.lower()) or "RTL88WIFI" in bp.upper():
        print(f"EFI_WIFI_ENTRY[{i}]=enabled:{enabled};bundle:{bp};id:{ident};executable:{exe}")
print("EFI_NATIVE_COUNT="+str(len(native)))
print("EFI_NATIVE_ENABLED="+str(sum(1 for x in native if x[1])))
print("EFI_LEGACY_COLLISION_COUNT="+str(len(legacy)))
print("EFI_NATIVE_HASH_MATCH="+str(bool(hash_results) and all(hash_results)))
print("EFI_NATIVE_HASHES="+",".join(x[4] for x in native))
blocked=[x for x in cfg.get("Kernel",{}).get("Block",[]) if x.get("Enabled") and x.get("BundleIdentifier")=="com.apple.iokit.IOSkywalkFamily"]
print("EFI_IOSKYWALK_BLOCK_ENABLED="+str(bool(blocked)))
misc=cfg.get("Misc",{}).get("Security",{})
print("EFI_SECURE_BOOT_MODEL="+str(misc.get("SecureBootModel","UNKNOWN")))
print("EFI_VAULT="+str(misc.get("Vault","UNKNOWN")))
PY
  then
    cat "$TMP/efi-inspection.txt"
    EFI_RESULT=PARSED
    EFI_NATIVE_COUNT="$(sed -n 's/^EFI_NATIVE_COUNT=//p' "$TMP/efi-inspection.txt")"
    EFI_LEGACY_COUNT="$(sed -n 's/^EFI_LEGACY_COLLISION_COUNT=//p' "$TMP/efi-inspection.txt")"
    EFI_HASH_MATCH="$(sed -n 's/^EFI_NATIVE_HASH_MATCH=//p' "$TMP/efi-inspection.txt")"
    EFI_SKYWALK_BLOCK="$(sed -n 's/^EFI_IOSKYWALK_BLOCK_ENABLED=//p' "$TMP/efi-inspection.txt")"
    if [ "$EFI_NATIVE_COUNT" = "1" ] && grep -q '^EFI_NATIVE_ENABLED=1$' "$TMP/efi-inspection.txt"; then pass "EFI has exactly one enabled native Kernel Add entry"; else warn "EFI native Kernel Add entry missing, disabled or duplicated"; fi
    if [ "$EFI_HASH_MATCH" = "True" ]; then pass "EFI native executable hash matches Stage108 build"; else warn "EFI copy is not the Stage108 executable (or is missing)"; fi
    if [ "$EFI_LEGACY_COUNT" = "0" ]; then pass "no separate legacy RTL88WiFi entry collides with native bundle ID"; else warn "legacy RTL88WiFi entry shares the native bundle ID; do not inject both"; fi
    if [ "$EFI_SKYWALK_BLOCK" = "False" ]; then pass "EFI does not block IOSkywalkFamily"; else fail "EFI actively blocks IOSkywalkFamily required by native bundle"; fi
  else
    EFI_RESULT=PARSE_FAILED; fail "mounted EFI config plist could not be parsed"
  fi
else
  warn "no unique mounted EFI config found; EFI parity not assessed"
fi

capture loaded-kexts kmutil showloaded
if [ "$(rc loaded-kexts)" -eq 0 ]; then
  grep -Ei 'RTL88|Realtek|IO80211FamilyLegacy|IOSkywalkFamily' "$TMP/loaded-kexts.txt" || echo "NO_MATCHING_REALTEK_OR_WIFI_FAMILY_KEXTS_REPORTED"
  pass "read-only loaded-kext inventory completed"
else
  warn "kmutil showloaded unavailable"
fi

if [ "$SIGNING_STATE" = "UNSIGNED" ]; then
  LOAD_READINESS=BLOCKED_UNSIGNED
elif [ "$SIGNING_STATE" = "INVALID_OR_UNVERIFIABLE" ]; then
  LOAD_READINESS=BLOCKED_SIGNATURE_REVIEW
else
  LOAD_READINESS=NOT_PROVEN_REQUIRES_EXPLICIT_RUNTIME_AUTHORIZATION
fi
if [ "$FAIL" -eq 0 ]; then RESULT=AUDIT_COMPLETE; else RESULT=REVIEW_REQUIRED; fi

echo
echo "========== STAGE109 SUMMARY =========="
echo "STAGE109_PASS_COUNT=$PASS"
echo "STAGE109_FAIL_COUNT=$FAIL"
echo "STAGE109_WARN_COUNT=$WARN"
echo "STAGE109_RESULT=$RESULT"
echo "STAGE109_KMUTIL_LIBRARIES_EXIT=$KMUTIL_LIB_RC"
echo "STAGE109_KMUTIL_UNDEFINED_EXIT=$KMUTIL_UNDEF_RC"
echo "STAGE109_KMUTIL_MULTIPLE_DEFINITION_EXIT=$KMUTIL_MULTI_RC"
echo "STAGE109_SIGNING_STATE=$SIGNING_STATE"
echo "STAGE109_SIP_STATE=$SIP_STATE"
echo "STAGE109_EFI_CONFIG_RESULT=$EFI_RESULT"
echo "STAGE109_EFI_NATIVE_COUNT=$EFI_NATIVE_COUNT"
echo "STAGE109_EFI_LEGACY_COLLISION_COUNT=$EFI_LEGACY_COUNT"
echo "STAGE109_EFI_BINARY_HASH_MATCH=$EFI_HASH_MATCH"
echo "STAGE109_EFI_IOSKYWALK_BLOCK=$EFI_SKYWALK_BLOCK"
echo "STAGE109_LOAD_READINESS=$LOAD_READINESS"
echo "STAGE109_NATIVE_BINARY_SHA256=$BIN_SHA"
echo "STAGE109_DETAIL_LOG=$LOG_REL"
echo "BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN"
echo "======================================"

{
  echo
  echo "========== STAGE109 NATIVE BUNDLE READINESS AUDIT =========="
  echo "STAGE109_RESULT=$RESULT"
  echo "STAGE109_PASS_COUNT=$PASS"
  echo "STAGE109_FAIL_COUNT=$FAIL"
  echo "STAGE109_WARN_COUNT=$WARN"
  echo "STAGE109_KMUTIL_LIBRARIES_EXIT=$KMUTIL_LIB_RC"
  echo "STAGE109_KMUTIL_UNDEFINED_EXIT=$KMUTIL_UNDEF_RC"
  echo "STAGE109_KMUTIL_MULTIPLE_DEFINITION_EXIT=$KMUTIL_MULTI_RC"
  echo "STAGE109_SIGNING_STATE=$SIGNING_STATE"
  echo "STAGE109_SIP_STATE=$SIP_STATE"
  echo "STAGE109_EFI_CONFIG_RESULT=$EFI_RESULT"
  echo "STAGE109_EFI_NATIVE_COUNT=$EFI_NATIVE_COUNT"
  echo "STAGE109_EFI_LEGACY_COLLISION_COUNT=$EFI_LEGACY_COUNT"
  echo "STAGE109_EFI_BINARY_HASH_MATCH=$EFI_HASH_MATCH"
  echo "STAGE109_EFI_IOSKYWALK_BLOCK=$EFI_SKYWALK_BLOCK"
  echo "STAGE109_LOAD_READINESS=$LOAD_READINESS"
  echo "STAGE109_NATIVE_BINARY_SHA256=$BIN_SHA"
  echo "STAGE109_DETAIL_LOG=$LOG_REL"
  echo "STAGE109_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN"
  echo "STAGE109_NATIVE_ACTIVATION=BLOCKED_PENDING_SIGNING_AND_EXCLUSIVE_EFI_REVIEW"
  echo "STAGE109_PR4_MERGE=BLOCKED"
  echo "============================================================"
} >> Development/output.log

exec 1>&3 2>&4
git add Development/output.log
git add -f "$LOG_REL"
git diff --cached --check || exit 3
git commit -m "Stage109: record native bundle readiness audit" || exit 3
git push origin "$EXPECTED_BRANCH" || { echo "STAGE109_LOG_UPLOAD=PUSH_FAILED" >&3; exit 3; }
echo "STAGE109_LOG_UPLOAD=PUSHED" >&3
echo "Stage109 audit finished: $RESULT; report: $LOG_REL" >&3
[ "$FAIL" -eq 0 ]
