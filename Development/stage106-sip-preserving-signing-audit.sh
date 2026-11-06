#!/bin/bash
# Stage106 — SIP-preserving, no-paid-account kext-signing feasibility audit.
# READ ONLY with respect to security and driver state: does not sign, install, load,
# rebuild, change SIP, alter boot-args/NVRAM/OpenCore, or run hardware tests.
set -u
set -o pipefail

EXPECTED_BRANCH="work/stage91-tx-submission-callback-v1"
EXPECTED_BIN_SHA="5d63db951e4a5c0228d4d73e664ab8e9457fc1fe805cce23444fe022f04f2513"
BUNDLE="driver/RTL88WiFi/build/out/RTL88WiFiNative.kext"
BIN="$BUNDLE/Contents/MacOS/RTL88WiFiNative"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_REL="Development/Logs/stage106-sip-preserving-signing-feasibility-${STAMP}.log"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside repository"; exit 2; }
cd "$ROOT" || exit 2
[ "$(git branch --show-current)" = "$EXPECTED_BRANCH" ] || { echo "ERROR: wrong branch"; exit 2; }
if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree is not clean; commit or stash unrelated changes first."
  git status --short
  exit 2
fi
[ -d "$BUNDLE" ] && [ -f "$BIN" ] || { echo "ERROR: Stage103 native candidate missing"; exit 2; }

mkdir -p Development/Logs || exit 2
LOG="$ROOT/$LOG_REL"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stage106.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
exec > >(tee "$LOG") 2>&1

PASS=0; FAIL=0; WARN=0
pass(){ PASS=$((PASS+1)); echo "PASS: $*"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $*"; }
warn(){ WARN=$((WARN+1)); echo "WARN: $*"; }
capture(){ local n="$1"; shift; "$@" >"$TMP/$n.txt" 2>&1; local r=$?; echo "$r" >"$TMP/$n.rc"; echo "COMMAND_${n}_EXIT=$r"; return 0; }
rc(){ [ -f "$TMP/$1.rc" ] && cat "$TMP/$1.rc" || echo 999; }

echo "========== STAGE106 SIP-PRESERVING SIGNING FEASIBILITY =========="
echo "UTC_STAMP=$STAMP"
echo "BRANCH=$EXPECTED_BRANCH"
echo "HEAD=$(git rev-parse HEAD)"
echo "SCOPE=READ_ONLY_SIP_STATE_CERTIFICATE_IDENTITY_KEXT_SIGNING_OID_BUNDLE_SIGNATURE"
echo "BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE NVRAM_CHANGE=NONE"

for t in sw_vers uname csrutil security openssl codesign shasum git; do
  if command -v "$t" >/dev/null 2>&1; then pass "tool available: $t"; else fail "required tool missing: $t"; fi
done

OS="$(sw_vers -productVersion 2>/dev/null || echo UNKNOWN)"
BUILD="$(sw_vers -buildVersion 2>/dev/null || echo UNKNOWN)"
ARCH="$(uname -m 2>/dev/null || echo UNKNOWN)"
echo "HOST_PRODUCT_VERSION=$OS"
echo "HOST_BUILD_VERSION=$BUILD"
echo "HOST_ARCH=$ARCH"
if [ "$OS" = "15.8.1" ] && [ "$BUILD" = "24H32" ] && [ "$ARCH" = "x86_64" ]; then pass "pinned Sequoia 24H32 Intel host"; else fail "host differs from pinned Sequoia 24H32 Intel target"; fi

capture sip-status csrutil status
cat "$TMP/sip-status.txt"
if grep -Eqi 'System Integrity Protection status: enabled|System Integrity Protection is enabled' "$TMP/sip-status.txt"; then
  SIP_STATE=ENABLED; pass "SIP is enabled"
elif grep -Eqi 'System Integrity Protection status: disabled|System Integrity Protection is disabled' "$TMP/sip-status.txt"; then
  SIP_STATE=DISABLED; fail "SIP is disabled (Stage106 will not change it)"
else
  SIP_STATE=UNKNOWN; fail "could not establish SIP state"
fi
echo "STAGE106_SIP_STATE=$SIP_STATE"

BIN_SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
echo "STAGE106_BINARY_SHA256=$BIN_SHA"
if [ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ]; then pass "candidate binary matches Stage104/105 audited SHA"; else fail "candidate binary SHA differs from audited candidate"; fi

capture signing-identities security find-identity -v -p codesigning
# Do not publish certificate names, hashes, email addresses, or private-key metadata.
IDENTITY_COUNT="$(grep -Ec '^[[:space:]]*[0-9]+ valid identities? found$' "$TMP/signing-identities.txt" || true)"
echo "CODESIGNING_VALID_IDENTITY_SUMMARY=$(tail -n 1 "$TMP/signing-identities.txt" | sed -E 's/[0-9]+ valid identities? found/COUNT_RECORDED/')"
if grep -Eqi '0 valid identities found' "$TMP/signing-identities.txt"; then
  warn "no valid code-signing identities found in the current keychain search list"
else
  pass "code-signing identity inventory completed (names and hashes withheld)"
fi

# Inspect public certificates only. This searches the user's current keychain search list;
# it never exports or accesses private keys.
capture developer-id-certificates security find-certificate -a -c "Developer ID Application" -p
CERT_RC="$(rc developer-id-certificates)"
KEXT_OID="ABSENT_OR_NOT_DETECTED"
if [ "$CERT_RC" -eq 0 ] && grep -q 'BEGIN CERTIFICATE' "$TMP/developer-id-certificates.txt"; then
  capture cert-extensions sh -c 'openssl crl2pkcs7 -nocrl -certfile "$1" 2>/dev/null | openssl pkcs7 -print_certs -text -noout 2>/dev/null' sh "$TMP/developer-id-certificates.txt"
  if grep -Fq '1.2.840.113635.100.6.1.18' "$TMP/cert-extensions.txt"; then
    KEXT_OID=PRESENT
    pass "a Developer ID Application certificate with Apple's kext-signing extension OID is present"
  else
    warn "Developer ID Application certificate(s) found, but Apple's kext-signing OID 1.2.840.113635.100.6.1.18 was not detected"
  fi
else
  warn "no Developer ID Application certificate PEM was found in the current keychain search list"
fi
echo "STAGE106_KEXT_SIGNING_CERT_OID=$KEXT_OID"

capture codesign-verify codesign --verify --deep --strict "$BUNDLE"
if [ "$(rc codesign-verify)" -eq 0 ]; then
  SIGNATURE_STATE=VALID
  pass "candidate bundle signature verifies"
else
  SIGNATURE_STATE=UNSIGNED_OR_INVALID
  warn "candidate signature does not verify; expected for Stage103 unsigned artifact"
fi
echo "STAGE106_CANDIDATE_SIGNATURE_STATE=$SIGNATURE_STATE"

# This stage never signs. A matching identity/OID only establishes credential availability;
# it does not grant authorization to sign or imply runtime safety.
if [ "$SIP_STATE" = "ENABLED" ] && [ "$KEXT_OID" = "PRESENT" ] && [ "$SIGNATURE_STATE" = "VALID" ]; then
  FEASIBILITY="CREDENTIAL_AND_SIGNATURE_PRESENT_REVIEW_REQUIRED"
elif [ "$SIP_STATE" = "ENABLED" ]; then
  FEASIBILITY="BLOCKED_NO_VERIFIED_KEXT_SIGNING_PATH_WITH_CURRENT_KEYCHAIN"
else
  FEASIBILITY="BLOCKED_BY_USER_SECURITY_CONSTRAINTS_OR_UNKNOWN_SIP"
fi

echo
echo "========== STAGE106 SUMMARY =========="
echo "STAGE106_PASS_COUNT=$PASS"
echo "STAGE106_FAIL_COUNT=$FAIL"
echo "STAGE106_WARN_COUNT=$WARN"
echo "STAGE106_SIP_STATE=$SIP_STATE"
echo "STAGE106_KEXT_SIGNING_CERT_OID=$KEXT_OID"
echo "STAGE106_CANDIDATE_SIGNATURE_STATE=$SIGNATURE_STATE"
echo "STAGE106_SIGNING_FEASIBILITY=$FEASIBILITY"
echo "STAGE106_DETAIL_LOG=$LOG_REL"
echo "SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN SIP_CHANGE=NONE NVRAM_CHANGE=NONE OPENCORE_CHANGE=NONE HARDWARE_TEST=NOT_RUN"
echo "======================================"

{
 echo
 echo "========== STAGE106 SIP-PRESERVING SIGNING FEASIBILITY =========="
 echo "STAGE106_RESULT=$([ "$FAIL" -eq 0 ] && echo AUDIT_COMPLETE || echo REVIEW_REQUIRED)"
 echo "STAGE106_PASS_COUNT=$PASS"
 echo "STAGE106_FAIL_COUNT=$FAIL"
 echo "STAGE106_WARN_COUNT=$WARN"
 echo "STAGE106_SIP_STATE=$SIP_STATE"
 echo "STAGE106_KEXT_SIGNING_CERT_OID=$KEXT_OID"
 echo "STAGE106_CANDIDATE_SIGNATURE_STATE=$SIGNATURE_STATE"
 echo "STAGE106_SIGNING_FEASIBILITY=$FEASIBILITY"
 echo "STAGE106_DETAIL_LOG=$LOG_REL"
 echo "STAGE106_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN SIP_CHANGE=NONE NVRAM_CHANGE=NONE OPENCORE_CHANGE=NONE HARDWARE_TEST=NOT_RUN"
 echo "STAGE106_NATIVE_ACTIVATION=BLOCKED"
 echo "STAGE106_PR4_MERGE=BLOCKED"
 echo "==============================================================="
} >> Development/output.log

git add Development/output.log
git add -f "$LOG_REL"
git commit -m "Stage106: record SIP-preserving signing feasibility audit" || exit 3
git push origin "$EXPECTED_BRANCH" || { echo "STAGE106_LOG_UPLOAD=PUSH_FAILED"; exit 3; }
echo "STAGE106_LOG_UPLOAD=PUSHED"
[ "$FAIL" -eq 0 ]
