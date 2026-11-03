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
STAGE="$PROJECT/build/stage29g-signing-policy-preflight-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { echo 'GitHub CLI authentication is required'; exit 2; }
command -v security >/dev/null || { echo 'security command not found'; exit 2; }
gh api "$API" > "$STAGE/remote-log.json" || exit 2
python3 - "$STAGE/remote-log.json" "$PROJECT/output.log" <<'PY'
import base64,json,pathlib,sys
doc=json.loads(pathlib.Path(sys.argv[1]).read_text())
data=base64.b64decode(doc.get('content',''))
text=data.decode('utf-8',errors='replace')
required=['STAGE29F_ANALYSIS_EXIT: 1','code object is not signed at all','Invalid ownership (501:20)']
missing=[x for x in required if x not in text]
if missing: raise SystemExit('Remote log missing Stage29f evidence: '+', '.join(missing))
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
[[ $? -eq 0 ]] || { echo 'Remote log validation failed'; exit 2; }
[[ -f "$BIN" ]] || { echo 'Native executable missing'; exit 2; }
EXPECTED=$(grep '^BINARY_SHA256: ' "$PROJECT/output.log" | tail -1 | awk '{print $2}')
ACTUAL=$(shasum -a 256 "$BIN" | awk '{print $1}')
[[ -n "$EXPECTED" && "$ACTUAL" == "$EXPECTED" ]] || { echo 'Native binary hash mismatch'; exit 2; }
sw_vers > "$STAGE/sw-vers.txt" 2>&1
csrutil status > "$STAGE/csrutil-status.txt" 2>&1; CSR_RC=$?
security find-identity -v -p codesigning > "$STAGE/signing-identities.txt" 2>&1; ID_RC=$?
security find-certificate -a -c 'Developer ID Application' -p > "$STAGE/developer-id-certs.pem" 2> "$STAGE/find-certificates.err"; CERT_RC=$?
python3 - "$STAGE" "$ACTUAL" "$EXPECTED" "$CSR_RC" "$ID_RC" "$CERT_RC" > "$STAGE/stage29g-report.txt" 2>&1 <<'PY'
from pathlib import Path
import re, subprocess, sys
p=Path(sys.argv[1]); actual,expected=sys.argv[2:4]; csr_rc,id_rc,cert_rc=map(int,sys.argv[4:7])
csr=(p/'csrutil-status.txt').read_text(errors='replace')
identities=(p/'signing-identities.txt').read_text(errors='replace')
pem=(p/'developer-id-certs.pem').read_text(errors='replace')
blocks=re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',pem,re.S)
oid_count=0; cert_valid=0
for block in blocks:
    q=subprocess.run(['openssl','x509','-noout','-text'],input=block,text=True,capture_output=True)
    if q.returncode==0:
        cert_valid+=1
        if '1.2.840.113635.100.6.1.18' in q.stdout: oid_count+=1
valid_count_match=re.search(r'(\d+) valid identities found',identities)
valid_count=int(valid_count_match.group(1)) if valid_count_match else 0
dev_identities=[line for line in identities.splitlines() if 'Developer ID Application:' in line]
dev_id_count=len(dev_identities)
sip_disabled='system integrity protection status: disabled' in csr.lower()
sip_enabled='system integrity protection status: enabled' in csr.lower()
print('RTL88WiFi Stage29g — read-only signing-policy preflight')
print('BINARY_HASH_MATCH:', 'PASS' if actual==expected else 'FAIL')
print('CSRUTIL_EXIT:',csr_rc); print('SIP_STATUS:', 'DISABLED' if sip_disabled else ('ENABLED' if sip_enabled else 'UNKNOWN'))
print('CODESIGN_IDENTITY_QUERY_EXIT:',id_rc); print('VALID_CODESIGN_IDENTITIES:',valid_count)
print('DEVELOPER_ID_APPLICATION_IDENTITIES:',dev_id_count)
print('DEVELOPER_ID_CERTIFICATE_QUERY_EXIT:',cert_rc); print('DEVELOPER_ID_CERTIFICATES_PARSED:',cert_valid)
print('KEXT_SIGNING_OID_1.2.840.113635.100.6.1.18_CERT_COUNT:',oid_count)
print('IDENTITY_LIST_DETAILS: saved locally only; not copied into GitHub log')
print('CSRUTIL_STATUS_DETAILS:'); print(csr)
print('SIGNING_POLICY_INTERPRETATION:')
if oid_count and dev_id_count: print('A Developer ID identity and at least one kext-signing certificate extension were found; verify the identity/certificate pairing before any signing action.')
elif sip_disabled: print('SIP is disabled; Apple documents unsigned kexts for internal testing on test systems with SIP disabled. Do not infer this alone guarantees Sequoia/OpenCore acceptance.')
else: print('No kext-signing identity was confirmed and SIP is not confirmed disabled; obtain the appropriate signing policy before changing the candidate.')
print('STAGE29G_SIGNING_POLICY_PREFLIGHT: COMPLETE — NO SIGNING OR OWNERSHIP CHANGES MADE')
print('BUILD: NOT RUN'); print('SOURCE_FILES_MODIFIED: NONE'); print('INSTALL: NOT RUN'); print('LOAD: NOT RUN'); print('OPENCORE_CHANGE: NONE'); print('QUEUE_REGISTRATION: NOT ENABLED'); print('KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED')
PY
RC=$?
cat "$STAGE/stage29g-report.txt"
{
  echo
  echo '========== STAGE29G SIGNING POLICY PREFLIGHT =========='
  echo "STAGE_DIR: $STAGE"
  cat "$STAGE/sw-vers.txt"
  cat "$STAGE/csrutil-status.txt"
  cat "$STAGE/stage29g-report.txt"
  echo "STAGE29G_ANALYSIS_EXIT: $RC"
  echo 'INSTALL: NOT RUN'
  echo 'LOAD: NOT RUN'
  echo 'OPENCORE_CHANGE: NONE'
  echo 'QUEUE_REGISTRATION: NOT ENABLED'
  echo 'KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED'
} >> "$PROJECT/output.log"
SHA=$(gh api "$API" --jq '.sha') || exit 2
python3 - "$PROJECT/output.log" "$SHA" "$STAGE/payload.json" <<'PY'
import base64,json,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
pathlib.Path(sys.argv[3]).write_text(json.dumps({'message':'Stage29g read-only signing-policy preflight','content':base64.b64encode(data).decode(),'sha':sys.argv[2]}))
PY
gh api --method PUT "$API" --input "$STAGE/payload.json" > "$STAGE/response.json" || exit 2
PUT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["content"]["sha"])' "$STAGE/response.json")
READ=$(gh api "$API" --jq '.sha') || exit 2
[[ -n "$PUT" && "$PUT" == "$READ" ]] || { echo 'GitHub read-back SHA mismatch'; exit 2; }
echo 'GITHUB_UPLOAD_STATUS: SUCCESS — verified Development/output.log'
exit "$RC"
