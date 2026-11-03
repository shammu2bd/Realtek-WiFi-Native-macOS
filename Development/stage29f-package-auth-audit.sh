#!/bin/bash
set -u
REPO='shammu2bd/Realtek-WiFi-Native-macOS'
API="repos/$REPO/contents/Development/output.log"
NAME='RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source'
PROJECT=''
if [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$PWD"; fi
if [[ -z "$PROJECT" && -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$HOME/Downloads/$NAME"; fi
[[ -n "$PROJECT" ]] || { echo 'Cannot locate Stage26 project'; exit 2; }
BUNDLE="$PROJECT/driver/RTL88WiFi/build/out/RTL88WiFiNative.kext"
BIN="$BUNDLE/Contents/MacOS/RTL88WiFiNative"
STAGE="$PROJECT/build/stage29f-package-auth-audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { echo 'gh authentication required'; exit 2; }
gh api "$API" --jq '.content' | python3 -c 'import base64,sys;sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' > "$PROJECT/output.log" || exit 2
EXPECTED=$(grep '^BINARY_SHA256: ' "$PROJECT/output.log" | tail -1 | awk '{print $2}')
ACTUAL=$(shasum -a 256 "$BIN" | awk '{print $1}')
[[ -n "$EXPECTED" && "$ACTUAL" == "$EXPECTED" ]] || { echo 'Native binary hash mismatch'; exit 2; }
find "$BUNDLE" -exec stat -f '%u:%g %Sp %N' {} \; > "$STAGE/ownership.txt" 2>&1; OWN_RC=$?
codesign -d --verbose=4 "$BUNDLE" > "$STAGE/signature.txt" 2>&1; SIG_RC=$?
codesign --verify --deep --strict --verbose=4 "$BUNDLE" > "$STAGE/verify.txt" 2>&1; VERIFY_RC=$?
kmutil print-diagnostics -p "$BUNDLE" -D > "$STAGE/kmutil.txt" 2>&1; KM_RC=$?
python3 - "$STAGE" "$ACTUAL" "$EXPECTED" "$OWN_RC" "$SIG_RC" "$VERIFY_RC" "$KM_RC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); actual,expected=sys.argv[2:4]; own,sig,ver,km=map(int,sys.argv[4:8])
owner=(p/'ownership.txt').read_text(errors='replace')
signature=(p/'signature.txt').read_text(errors='replace')
verify=(p/'verify.txt').read_text(errors='replace')
diagnostic=(p/'kmutil.txt').read_text(errors='replace')
pairs=[line.split()[0] for line in owner.splitlines() if line.strip()]
root=bool(pairs) and all(x=='0:0' for x in pairs) and own==0
present=sig==0 and 'not signed at all' not in signature.lower()
verified=ver==0
has_owner_error='Invalid ownership' in diagnostic
has_sig_error='Authenticating extension failed' in diagnostic or 'Bad code signature' in diagnostic
print('STAGE29F — read-only ownership and code-signature audit')
print('BINARY_HASH_MATCH:', 'PASS' if actual==expected else 'FAIL')
print('ROOT_WHEEL_OWNERSHIP:', 'PASS' if root else 'REVIEW_REQUIRED')
print('SIGNATURE_METADATA_PRESENT:', 'YES' if present else 'NO')
print('CODESIGN_VERIFY:', 'PASS' if verified else 'FAIL')
print('KMUTIL_DIAGNOSTICS_EXIT:', km)
print('KMUTIL_OWNERSHIP_ERROR:', 'YES' if has_owner_error else 'NO')
print('KMUTIL_SIGNATURE_ERROR:', 'YES' if has_sig_error else 'NO')
print('--- ownership ---'); print(owner)
print('--- signature ---'); print(signature)
print('--- verify ---'); print(verify)
print('--- kmutil ---'); print(diagnostic)
overall=actual==expected and root and present and verified and km==0 and not has_owner_error and not has_sig_error
print('STAGE29F_PACKAGE_AUTH_AUDIT:', 'PASS' if overall else 'REVIEW_REQUIRED')
raise SystemExit(0 if overall else 1)
print('BUILD: NOT RUN'); print('SOURCE_FILES_MODIFIED: NONE'); print('INSTALL: NOT RUN'); print('LOAD: NOT RUN'); print('OPENCORE_CHANGE: NONE'); print('QUEUE_REGISTRATION: NOT ENABLED'); print('KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED')
PY
RC=$?
{ echo; echo '========== STAGE29F PACKAGE AUTH AUDIT =========='; echo "STAGE_DIR: $STAGE"; cat "$STAGE/ownership.txt"; cat "$STAGE/signature.txt"; cat "$STAGE/verify.txt"; cat "$STAGE/kmutil.txt"; echo "STAGE29F_ANALYSIS_EXIT: $RC"; echo 'BUILD: NOT RUN'; echo 'INSTALL: NOT RUN'; echo 'LOAD: NOT RUN'; echo 'OPENCORE_CHANGE: NONE'; echo 'QUEUE_REGISTRATION: NOT ENABLED'; echo 'KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED'; } >> "$PROJECT/output.log"
SHA=$(gh api "$API" --jq '.sha') || exit 2
python3 - "$PROJECT/output.log" "$SHA" "$STAGE/payload.json" <<'PY'
import base64,json,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
pathlib.Path(sys.argv[3]).write_text(json.dumps({'message':'Stage29f read-only package ownership and signature audit','content':base64.b64encode(data).decode(),'sha':sys.argv[2]}))
PY
gh api --method PUT "$API" --input "$STAGE/payload.json" > "$STAGE/response.json" || exit 2
PUT_SHA=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["content"]["sha"])' "$STAGE/response.json")
READ_SHA=$(gh api "$API" --jq '.sha') || exit 2
[[ -n "$PUT_SHA" && "$PUT_SHA" == "$READ_SHA" ]] || { echo 'GitHub read-back SHA mismatch'; exit 2; }
echo 'GITHUB_UPLOAD_STATUS: SUCCESS — verified Development/output.log'
exit "$RC"
