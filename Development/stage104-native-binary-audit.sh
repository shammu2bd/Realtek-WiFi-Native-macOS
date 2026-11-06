#!/bin/bash
# Stage104 — read-only audit of the Stage103 native kext bundle and ZIP.
# Does not build, sign, install, load, activate, or modify OpenCore.
set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: run this from inside the Realtek-WiFi-Native-macOS Git repository."
  exit 2
}
cd "$ROOT" || exit 2

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_REL="Development/Logs/stage104-native-binary-audit-${STAMP}.log"
mkdir -p Development/Logs
LOG="$ROOT/$LOG_REL"
exec > >(tee "$LOG") 2>&1

BUNDLE="driver/RTL88WiFi/build/out/RTL88WiFiNative.kext"
BIN="$BUNDLE/Contents/MacOS/RTL88WiFiNative"
PLIST="$BUNDLE/Contents/Info.plist"
ZIP="driver/RTL88WiFi/build/out/RTL88WiFiNative-24H32-unsigned.zip"
BUILD_COMMIT="fcc0da3577e64d8b6b40ec10ea68e289a742efd9"
EXPECTED_BUNDLE_ID="io.github.x1ren41l.RTL88WiFi"
EXPECTED_EXECUTABLE="RTL88WiFiNative"
EXPECTED_ARCHIVE_SHA="e4338c6721534dbe73546d8e61030f7efd21b2638fb31151426181535ca24f4f"

FAIL=0
PASS=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stage104.XXXXXX")" || exit 2
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
info() { echo "INFO: $*"; }

echo "===== STAGE104 NATIVE BINARY / DEPENDENCY AUDIT ====="
echo "UTC_STAMP=$STAMP"
echo "REPOSITORY=$ROOT"
echo "CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
echo "STAGE103_BUILD_SOURCE_COMMIT=$BUILD_COMMIT"
echo "SCOPE=READ_ONLY_BINARY_AND_ARCHIVE_AUDIT"
echo "INSTALL=NOT_RUN LOAD=NOT_RUN SIGNING=NOT_RUN OPENCORE_CHANGE=NONE"

for p in "$BUNDLE" "$BIN" "$PLIST" "$ZIP"; do
  if [ -e "$p" ]; then pass "present: $p"; else fail "missing: $p"; fi
done

if [ -f "$PLIST" ]; then
  if plutil -lint "$PLIST"; then pass "Info.plist syntax"; else fail "Info.plist syntax"; fi
  if python3 - "$PLIST" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p.get("CFBundleIdentifier") == "io.github.x1ren41l.RTL88WiFi", p.get("CFBundleIdentifier")
assert p.get("CFBundleExecutable") == "RTL88WiFiNative", p.get("CFBundleExecutable")
assert p.get("CFBundlePackageType") == "KEXT", p.get("CFBundlePackageType")
assert p.get("LSMinimumSystemVersion") == "15.0", p.get("LSMinimumSystemVersion")
deps = p.get("OSBundleLibraries", {})
required = {
    "com.apple.iokit.IO80211Family": "1200.13.1",
    "com.apple.iokit.IOSkywalkFamily": "1.0",
    "com.apple.iokit.IOPCIFamily": "2.9",
    "com.apple.iokit.IONetworkingFamily": "3.4",
}
for key, value in required.items():
    assert deps.get(key) == value, (key, deps.get(key), value)
assert "com.apple.iokit.IO80211FamilyLegacy" not in deps, "legacy dependency present"
personalities = p.get("IOKitPersonalities", {})
matches = [v for v in personalities.values()
           if v.get("IOProviderClass") == "IOPCIDevice"
           and v.get("IOClass") == "RTW88WCLController"
           and set(v.get("IOPCIMatch", "").split()) >= {"0xC82110EC", "0xB82110EC"}]
assert matches, "RTL8821CE PCI personality or IDs missing"
print("PLIST_BUNDLE_ID=" + p["CFBundleIdentifier"])
print("PLIST_EXECUTABLE=" + p["CFBundleExecutable"])
print("PLIST_MINIMUM_MACOS=" + p["LSMinimumSystemVersion"])
print("PLIST_NATIVE_PCI_MATCH=0xC82110EC 0xB82110EC")
print("PLIST_REQUIRED_DEPENDENCIES=PASS")
print("PLIST_IO80211FAMILYLEGACY=ABSENT")
print("PLIST_IOSKYWALKFAMILY=DECLARED")
PY
  then pass "native bundle metadata, dependencies and RTL8821CE personality"; else fail "native bundle metadata/dependency/personality validation"; fi
fi

if [ -f "$BIN" ]; then
  file "$BIN"
  if lipo "$BIN" -verify_arch x86_64; then pass "x86_64 architecture"; else fail "x86_64 architecture"; fi
  ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
  echo "BINARY_ARCHS=$ARCHS"
  if [ "$ARCHS" = "x86_64" ]; then pass "single-architecture native binary"; else fail "unexpected binary architectures: $ARCHS"; fi
  dwarfdump --uuid "$BIN" 2>&1 || true
  shasum -a 256 "$BIN"
  otool -hv "$BIN" 2>&1 | head -20
  otool -L "$BIN" 2>&1 | head -40
  nm -u "$BIN" > "$TMP/undefined-symbols.txt" 2>&1 || true
  UNDEF_COUNT="$(wc -l < "$TMP/undefined-symbols.txt" | tr -d ' ')"
  echo "UNDEFINED_SYMBOL_RECORD_COUNT=$UNDEF_COUNT"
  echo "UNDEFINED_SYMBOL_SAMPLE_BEGIN"
  head -30 "$TMP/undefined-symbols.txt"
  echo "UNDEFINED_SYMBOL_SAMPLE_END"
  pass "Mach-O metadata and undefined-symbol inventory captured (not treated as runtime proof)"
fi

if [ -f "$ZIP" ] && [ -d "$BUNDLE" ]; then
  ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
  echo "STAGE104_ARCHIVE_SHA256=$ZIP_SHA"
  if [ "$ZIP_SHA" = "$EXPECTED_ARCHIVE_SHA" ]; then
    pass "archive SHA matches Stage103 validated archive"
  else
    info "archive SHA differs from Stage103 reference; inspect whether the bundle was regenerated"
  fi
  mkdir -p "$TMP/extracted"
  if ditto -x -k "$ZIP" "$TMP/extracted"; then
    EXTRACTED="$TMP/extracted/RTL88WiFiNative.kext"
    if [ -d "$EXTRACTED" ]; then
      if diff -qr "$BUNDLE" "$EXTRACTED"; then pass "ZIP contents exactly match local kext bundle"; else fail "ZIP/bundle content mismatch"; fi
      if [ -f "$EXTRACTED/Contents/MacOS/RTL88WiFiNative" ] && [ -f "$EXTRACTED/Contents/Info.plist" ]; then
        pass "ZIP contains expected kext structure"
      else
        fail "ZIP missing expected executable or Info.plist"
      fi
    else
      fail "ZIP does not contain RTL88WiFiNative.kext at archive root"
    fi
  else
    fail "ZIP extraction/integrity"
  fi
fi

if git cat-file -e "${BUILD_COMMIT}^{commit}" 2>/dev/null; then
  pass "Stage103 source commit exists in local Git history"
  if git merge-base --is-ancestor "$BUILD_COMMIT" HEAD; then
    pass "Stage103 source commit is an ancestor of current HEAD"
  else
    fail "Stage103 source commit is not an ancestor of current HEAD"
  fi
  if git diff --quiet "$BUILD_COMMIT" HEAD -- driver/RTL88WiFi driver/rtw88-stable; then
    pass "driver source/build tree unchanged since Stage103 source commit"
  else
    fail "driver source/build tree changed since Stage103; this bundle's source provenance needs a fresh link"
    git diff --stat "$BUILD_COMMIT" HEAD -- driver/RTL88WiFi driver/rtw88-stable
  fi
else
  fail "Stage103 source commit unavailable in local Git history; source provenance unverified"
fi

echo "STAGE104_PASS_COUNT=$PASS"
echo "STAGE104_FAIL_COUNT=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  STATUS=PASS
else
  STATUS=FAIL_REVIEW_REQUIRED
fi
echo "STAGE104_RESULT=$STATUS"
echo "STAGE104_DETAIL_LOG=$LOG_REL"
echo "STAGE104_BUILD_SOURCE_COMMIT=$BUILD_COMMIT"
echo "STAGE104_INSTALL=NOT_RUN LOAD=NOT_RUN SIGNING=NOT_RUN HARDWARE_TEST=NOT_RUN OPENCORE_CHANGE=NONE"

{
  echo
  echo "========== STAGE104 NATIVE BINARY / DEPENDENCY AUDIT =========="
  echo "STAGE104_RESULT=$STATUS"
  echo "STAGE104_PASS_COUNT=$PASS"
  echo "STAGE104_FAIL_COUNT=$FAIL"
  echo "STAGE104_BUILD_SOURCE_COMMIT=$BUILD_COMMIT"
  echo "STAGE104_DETAIL_LOG=$LOG_REL"
  echo "STAGE104_AUDIT_RUN=AWAITING_LOCAL_MAC_EXECUTION"
  echo "STAGE104_INSTALL=NOT_RUN LOAD=NOT_RUN SIGNING=NOT_RUN HARDWARE_TEST=NOT_RUN OPENCORE_CHANGE=NONE"
  echo "STAGE104_NATIVE_ACTIVATION=BLOCKED_PENDING_RUNTIME_VALIDATION"
  echo "STAGE104_PR4_MERGE=BLOCKED"
  echo "==============================================================="
} >> Development/output.log

git add Development/output.log "$LOG_REL"
if ! git diff --cached --quiet; then
  git commit -m "Stage104: record native binary and dependency audit"
  if git push origin "$(git branch --show-current)"; then
    echo "STAGE104_LOG_UPLOAD=PUSHED"
  else
    echo "STAGE104_LOG_UPLOAD=PUSH_FAILED"
  fi
else
  echo "STAGE104_LOG_UPLOAD=NO_CHANGES"
fi

if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
