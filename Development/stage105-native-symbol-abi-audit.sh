#!/bin/bash
# Stage105 — target 24H32 native-kext symbol-provider, Mach-O and signing audit.
# READ ONLY: no build, sign, stage, install, load, activate, or OpenCore changes.
set -u
set -o pipefail

EXPECTED_BRANCH="work/stage91-tx-submission-callback-v1"
BUILD_COMMIT="fcc0da3577e64d8b6b40ec10ea68e289a742efd9"
EXPECTED_BIN_SHA="5d63db951e4a5c0228d4d73e664ab8e9457fc1fe805cce23444fe022f04f2513"
EXPECTED_ZIP_SHA="e4338c6721534dbe73546d8e61030f7efd21b2638fb31151426181535ca24f4f"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside repository."; exit 2; }
cd "$ROOT" || exit 2
BRANCH="$(git branch --show-current)"
if [ "$BRANCH" != "$EXPECTED_BRANCH" ]; then
  echo "ERROR: expected branch $EXPECTED_BRANCH; found $BRANCH"; exit 2
fi
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "ERROR: working tree is not clean; refusing to include unrelated changes."
  git status --short
  exit 2
fi

BUNDLE="driver/RTL88WiFi/build/out/RTL88WiFiNative.kext"
BIN="$BUNDLE/Contents/MacOS/RTL88WiFiNative"
PLIST="$BUNDLE/Contents/Info.plist"
ZIP="driver/RTL88WiFi/build/out/RTL88WiFiNative-24H32-unsigned.zip"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_REL="Development/Logs/stage105-native-symbol-abi-audit-${STAMP}.log"
mkdir -p Development/Logs || exit 2
LOG="$ROOT/$LOG_REL"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stage105.XXXXXX")" || exit 2
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
exec > >(tee "$LOG") 2>&1

PASS=0; FAIL=0; WARN=0
pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
warn() { WARN=$((WARN + 1)); echo "WARN: $*"; }
capture() {
  local name="$1"; shift
  local rc
  "$@" > "$TMP/$name.txt" 2>&1
  rc=$?
  printf '%s\n' "$rc" > "$TMP/$name.rc"
  echo "COMMAND_${name}_EXIT=$rc"
  return 0
}
get_rc() { [ -f "$TMP/$1.rc" ] && cat "$TMP/$1.rc" || echo 999; }
excerpt() {
  echo "----- $1 (first ${2:-100} lines) -----"
  if [ -f "$TMP/$1.txt" ]; then sed -n "1,${2:-100}p" "$TMP/$1.txt"; else echo "NO_CAPTURE"; fi
  echo "----- END $1 -----"
}

echo "========== STAGE105 NATIVE SYMBOL / 24H32 ABI AUDIT =========="
echo "UTC_STAMP=$STAMP"
echo "REPOSITORY=$ROOT"
echo "BRANCH=$BRANCH"
echo "CURRENT_HEAD=$(git rev-parse HEAD)"
echo "STAGE103_BUILD_SOURCE_COMMIT=$BUILD_COMMIT"
echo "SCOPE=READ_ONLY_MACHO_SYMBOLS_KMUTIL_PROVIDER_RESOLUTION_DEPENDENCIES_SIGNING"
echo "BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
echo "HARDWARE_TEST=NOT_RUN"

for t in sw_vers uname file lipo otool nm plutil shasum python3 kmutil codesign git; do
  if command -v "$t" >/dev/null 2>&1; then pass "tool available: $t"; else fail "required audit tool missing: $t"; fi
done

OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo UNKNOWN)"
OS_BUILD="$(sw_vers -buildVersion 2>/dev/null || echo UNKNOWN)"
ARCH="$(uname -m 2>/dev/null || echo UNKNOWN)"
echo "HOST_PRODUCT_VERSION=$OS_VERSION"
echo "HOST_BUILD_VERSION=$OS_BUILD"
echo "HOST_ARCH=$ARCH"
if [ "$OS_VERSION" = "15.8.1" ] && [ "$OS_BUILD" = "24H32" ] && [ "$ARCH" = "x86_64" ]; then
  pass "host matches pinned Sequoia 15.8.1 build 24H32 x86_64"
else
  fail "host does not match pinned macOS 15.8.1 / 24H32 / x86_64"
fi

for p in "$BUNDLE" "$BIN" "$PLIST" "$ZIP"; do
  if [ -e "$p" ]; then pass "artifact present: $p"; else fail "artifact missing: $p"; fi
done

ACTUAL_BIN_SHA=""
ACTUAL_ZIP_SHA=""
if [ -f "$BIN" ]; then
  ACTUAL_BIN_SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
  echo "STAGE105_BINARY_SHA256=$ACTUAL_BIN_SHA"
  if [ "$ACTUAL_BIN_SHA" = "$EXPECTED_BIN_SHA" ]; then pass "binary SHA matches Stage104-audited executable"; else fail "binary SHA differs from Stage104-audited executable"; fi

  capture binary-file file "$BIN"
  capture binary-arch lipo -archs "$BIN"
  capture macho-header otool -hv "$BIN"
  capture macho-load-commands otool -l "$BIN"
  capture linked-images otool -L "$BIN"
  capture nm-undefined nm -u "$BIN"
  capture nm-metadata nm -m "$BIN"
  capture codesign-details codesign -dv --verbose=4 "$BUNDLE"
  capture codesign-verify codesign --verify --deep --strict "$BUNDLE"

  excerpt binary-file 20
  excerpt binary-arch 10
  excerpt macho-header 30
  echo "----- LC_SYMTAB / LC_DYSYMTAB / dylib load-command inventory -----"
  grep -A24 -E 'cmd LC_SYMTAB|cmd LC_DYSYMTAB|cmd LC_LOAD_DYLIB|cmd LC_LOAD_WEAK_DYLIB|cmd LC_REEXPORT_DYLIB' "$TMP/macho-load-commands.txt" | head -180 || true
  echo "----- END load-command inventory -----"
  excerpt linked-images 60
  excerpt nm-undefined 45
  excerpt nm-metadata 45
  excerpt codesign-details 50
  excerpt codesign-verify 30

  python3 - "$TMP" <<'PY'
from pathlib import Path
import re,sys
root=Path(sys.argv[1])
hdr=(root/"macho-header.txt").read_text(errors="replace")
load=(root/"macho-load-commands.txt").read_text(errors="replace")
undef=(root/"nm-undefined.txt").read_text(errors="replace")
rows=[]
for line in undef.splitlines():
 s=line.strip()
 if not s or s.endswith(":") or s.startswith("nm:"): continue
 rows.append(s)
m=re.search(r"cmd LC_DYSYMTAB([\s\S]*?)(?=\n\s*Load command|\Z)",load)
nundef=None
if m:
 x=re.search(r"nundefsym\s+(\d+)",m.group(1))
 if x: nundef=int(x.group(1))
flags_line=next((x.strip() for x in hdr.splitlines() if "MH_MAGIC" in x or "KEXTBUNDLE" in x),"")
has_noundefs="NOUNDEFS" in hdr
has_twolevel="TWOLEVEL" in hdr
print("MACHO_HEADER_FLAGS_LINE="+flags_line)
print("MACHO_FLAG_NOUNDEFS="+str(has_noundefs).upper())
print("MACHO_FLAG_TWOLEVEL="+str(has_twolevel).upper())
print("NM_UNDEFINED_NONEMPTY_RECORDS="+str(len(rows)))
print("DYSYMTAB_NUNDEFSYM="+(str(nundef) if nundef is not None else "NOT_PARSED"))
if nundef is not None and nundef != len(rows):
 print("SYMBOL_COUNT_CROSSCHECK=REVIEW_REQUIRED (inspect raw captures)")
else:
 print("SYMBOL_COUNT_CROSSCHECK=CONSISTENT_OR_NOT_AVAILABLE")
if has_noundefs and has_twolevel:
 print("NOUNDEFS_INTERPRETATION=ld64 sets MH_TWOLEVEL and MH_NOUNDEFS together for two-level namespace output; the flag alone does not establish zero kext imports")
else:
 print("NOUNDEFS_INTERPRETATION=use LC_DYSYMTAB and kmutil provider-resolution results")
PY
else
  warn "binary absent; Mach-O and symbol checks skipped"
fi

if [ -f "$PLIST" ]; then
  capture plist-lint plutil -lint "$PLIST"
  excerpt plist-lint 20
  if python3 - "$PLIST" <<'PY'
import plistlib,sys
p=plistlib.load(open(sys.argv[1],"rb"))
assert p.get("CFBundleIdentifier")=="io.github.x1ren41l.RTL88WiFi",p.get("CFBundleIdentifier")
assert p.get("CFBundleExecutable")=="RTL88WiFiNative",p.get("CFBundleExecutable")
assert p.get("CFBundlePackageType")=="KEXT",p.get("CFBundlePackageType")
libs=p.get("OSBundleLibraries",{})
want={"com.apple.iokit.IO80211Family":"1200.13.1","com.apple.iokit.IOSkywalkFamily":"1.0","com.apple.iokit.IOPCIFamily":"2.9","com.apple.iokit.IONetworkingFamily":"3.4"}
for k,v in want.items(): assert libs.get(k)==v,(k,libs.get(k),v)
assert "com.apple.iokit.IO80211FamilyLegacy" not in libs
matches=[]
for x in p.get("IOKitPersonalities",{}).values():
 if x.get("IOClass")=="RTW88WCLController" and x.get("IOProviderClass")=="IOPCIDevice":
  if {"0xC82110EC","0xB82110EC"} <= set(x.get("IOPCIMatch","").split()): matches.append(x)
assert matches,"RTL8821CE personality not found"
print("PLIST_BUNDLE_ID="+p["CFBundleIdentifier"])
print("PLIST_EXECUTABLE="+p["CFBundleExecutable"])
print("PLIST_DEPENDENCIES=PASS")
print("PLIST_IO80211FAMILYLEGACY=ABSENT")
print("PLIST_RTL8821CE_PCI_MATCH=PASS")
PY
  then pass "bundle metadata, native dependencies and RTL8821CE PCI personality"; else fail "bundle metadata/dependency/PCI personality check"; fi
else
  fail "Info.plist unavailable"
fi

if [ -f "$ZIP" ]; then
  ACTUAL_ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
  echo "STAGE105_ARCHIVE_SHA256=$ACTUAL_ZIP_SHA"
  if [ "$ACTUAL_ZIP_SHA" = "$EXPECTED_ZIP_SHA" ]; then pass "archive SHA matches Stage104 audit"; else fail "archive SHA differs from Stage104 audit"; fi
fi

KMUTIL_LIB_RC=999; KMUTIL_UNDEF_RC=999; KMUTIL_MULTI_RC=999; KMUTIL_XML_RC=999; KMUTIL_DIAG_RC=999
if command -v kmutil >/dev/null 2>&1 && [ -d "$BUNDLE" ]; then
  capture kmutil-libraries kmutil libraries -p "$BUNDLE"
  KMUTIL_LIB_RC="$(get_rc kmutil-libraries)"
  capture kmutil-undefined kmutil libraries -p "$BUNDLE" --undef-symbols
  KMUTIL_UNDEF_RC="$(get_rc kmutil-undefined)"
  capture kmutil-multiple kmutil libraries -p "$BUNDLE" --multdef-symbols
  KMUTIL_MULTI_RC="$(get_rc kmutil-multiple)"
  capture kmutil-xml kmutil libraries -p "$BUNDLE" --xml
  KMUTIL_XML_RC="$(get_rc kmutil-xml)"
  capture kmutil-diagnostics kmutil print-diagnostics -p "$BUNDLE" -D
  KMUTIL_DIAG_RC="$(get_rc kmutil-diagnostics)"
  echo "KMUTIL_LIBRARIES_EXIT=$KMUTIL_LIB_RC"
  echo "KMUTIL_UNDEFINED_EXIT=$KMUTIL_UNDEF_RC"
  echo "KMUTIL_MULTIPLE_DEFINITION_EXIT=$KMUTIL_MULTI_RC"
  echo "KMUTIL_XML_EXIT=$KMUTIL_XML_RC"
  echo "KMUTIL_PRINT_DIAGNOSTICS_EXIT=$KMUTIL_DIAG_RC"
  excerpt kmutil-libraries 160
  excerpt kmutil-undefined 180
  excerpt kmutil-multiple 100
  excerpt kmutil-xml 100
  excerpt kmutil-diagnostics 160
  if [ "$KMUTIL_LIB_RC" -eq 0 ] && [ "$KMUTIL_UNDEF_RC" -eq 0 ] && [ "$KMUTIL_MULTI_RC" -eq 0 ]; then
    pass "kmutil reports no unresolved or multiply-defined kernel-collection symbols"
  else
    fail "kmutil symbol-provider resolution did not pass cleanly"
  fi
else
  fail "kmutil or native bundle unavailable; kernel-collection resolution not run"
fi

SIGNING_STATE="UNKNOWN"
if [ -f "$TMP/codesign-verify.txt" ]; then
  if [ "$(get_rc codesign-verify)" -eq 0 ]; then
    SIGNING_STATE="VALID_SIGNATURE"
    pass "codesign verification accepted the bundle signature"
  elif grep -Eqi 'code object is not signed at all|not signed' "$TMP/codesign-verify.txt" "$TMP/codesign-details.txt" 2>/dev/null; then
    SIGNING_STATE="UNSIGNED"
    warn "bundle is unsigned as expected from Stage103; this blocks normal-policy loading"
  else
    SIGNING_STATE="INVALID_OR_UNVERIFIABLE"
    fail "codesign reported an invalid or unrecognized signature state"
  fi
fi
echo "STAGE105_SIGNING_STATE=$SIGNING_STATE"

if git cat-file -e "${BUILD_COMMIT}^{commit}" 2>/dev/null &&
   git merge-base --is-ancestor "$BUILD_COMMIT" HEAD &&
   git diff --quiet "$BUILD_COMMIT" HEAD -- driver/RTL88WiFi driver/rtw88-stable; then
  pass "Stage103 build source remains unchanged through current HEAD"
else
  fail "driver/build source provenance changed or Stage103 commit unavailable"
fi

if [ -f "$TMP/kmutil-diagnostics.txt" ]; then
  if grep -Eqi 'Filesystem error: Invalid ownership|not owned by root|ownership' "$TMP/kmutil-diagnostics.txt"; then
    warn "kmutil diagnostics mention bundle ownership; installed staging copy would need correct ownership"
  fi
  if grep -Eqi 'Authenticating extension failed|Bad code signature|not signed|signature' "$TMP/kmutil-diagnostics.txt"; then
    warn "kmutil diagnostics mention signature/authentication; no security changes attempted"
  fi
fi

RESULT="PASS"
[ "$FAIL" -eq 0 ] || RESULT="REVIEW_REQUIRED"
if [ "$SIGNING_STATE" = "UNSIGNED" ]; then
  LOAD_READINESS="BLOCKED_UNSIGNED"
elif [ "$SIGNING_STATE" != "VALID_SIGNATURE" ]; then
  LOAD_READINESS="BLOCKED_SIGNATURE_REVIEW"
else
  LOAD_READINESS="BLOCKED_PENDING_EXPLICIT_RUNTIME_TEST_AUTHORIZATION"
fi

echo
echo "========== STAGE105 SUMMARY =========="
echo "STAGE105_PASS_COUNT=$PASS"
echo "STAGE105_FAIL_COUNT=$FAIL"
echo "STAGE105_WARN_COUNT=$WARN"
echo "STAGE105_RESULT=$RESULT"
echo "STAGE105_KMUTIL_LIBRARIES_EXIT=$KMUTIL_LIB_RC"
echo "STAGE105_KMUTIL_UNDEFINED_EXIT=$KMUTIL_UNDEF_RC"
echo "STAGE105_KMUTIL_MULTIPLE_DEFINITION_EXIT=$KMUTIL_MULTI_RC"
echo "STAGE105_SIGNING_STATE=$SIGNING_STATE"
echo "STAGE105_LOAD_READINESS=$LOAD_READINESS"
echo "STAGE105_BINARY_SHA256=$ACTUAL_BIN_SHA"
echo "STAGE105_DETAIL_LOG=$LOG_REL"
echo "BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE HARDWARE_TEST=NOT_RUN"
echo "======================================"

{
  echo
  echo "========== STAGE105 NATIVE SYMBOL / 24H32 ABI AUDIT =========="
  echo "STAGE105_RESULT=$RESULT"
  echo "STAGE105_PASS_COUNT=$PASS"
  echo "STAGE105_FAIL_COUNT=$FAIL"
  echo "STAGE105_WARN_COUNT=$WARN"
  echo "STAGE105_KMUTIL_LIBRARIES_EXIT=$KMUTIL_LIB_RC"
  echo "STAGE105_KMUTIL_UNDEFINED_EXIT=$KMUTIL_UNDEF_RC"
  echo "STAGE105_KMUTIL_MULTIPLE_DEFINITION_EXIT=$KMUTIL_MULTI_RC"
  echo "STAGE105_SIGNING_STATE=$SIGNING_STATE"
  echo "STAGE105_LOAD_READINESS=$LOAD_READINESS"
  echo "STAGE105_BINARY_SHA256=$ACTUAL_BIN_SHA"
  echo "STAGE105_DETAIL_LOG=$LOG_REL"
  echo "STAGE105_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE HARDWARE_TEST=NOT_RUN"
  echo "STAGE105_NATIVE_ACTIVATION=BLOCKED"
  echo "STAGE105_PR4_MERGE=BLOCKED"
  echo "==============================================================="
} >> Development/output.log

git add Development/output.log
git add -f "$LOG_REL"
if ! git diff --cached --quiet; then
  git commit -m "Stage105: record target 24H32 symbol and ABI audit" || exit 3
  if git push origin "$EXPECTED_BRANCH"; then echo "STAGE105_LOG_UPLOAD=PUSHED"; else echo "STAGE105_LOG_UPLOAD=PUSH_FAILED"; exit 3; fi
else
  echo "STAGE105_LOG_UPLOAD=NO_CHANGES"
fi

[ "$FAIL" -eq 0 ]
