#!/bin/bash
# Stage110: read-only signing identity and exact USB EFI parity audit.
# No signing, install/load, mount, EFI write, SIP/NVRAM change or hardware test.
set -euo pipefail
BRANCH="work/stage91-tx-submission-callback-v1"
BASE="0cf25c1155019a0c689ecafc767dff39aefb5479"
BIN_SHA="409137db0772c6f5326af89f9f6dc699f8f18a13eb9025bc194b58e5bb92cd0a"
NATIVE_ID="io.github.x1ren41l.RTL88WiFi"
SCRIPT="Development/stage110-signing-efi-audit.sh"
PINFILE="Development/Allowlist/stage110-signing-efi-audit.gitblob"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
[[ "$(git branch --show-current)" == "$BRANCH" ]] || { echo "ERROR: wrong branch"; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "ERROR: working tree not clean"; git status --short; exit 2; }
git cat-file -e "$BASE^{commit}"
git merge-base --is-ancestor "$BASE" HEAD
PIN="$(awk 'NR==1 {print $1}' "$PINFILE")"
ACTUAL="$(git hash-object "$SCRIPT")"
[[ -n "$PIN" && "$PIN" == "$ACTUAL" ]] || { echo "ERROR: runner blob hash mismatch"; exit 2; }
for t in security openssl python3 plutil csrutil git; do command -v "$t" >/dev/null || { echo "ERROR: missing $t"; exit 2; }; done
OS="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: wrong target $OS ($BUILD) $ARCH"; exit 2; }

mkdir -p Development/Logs
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="Development/Logs/stage110-signing-efi-audit-$STAMP.log"
TMPBASE="$(printenv TMPDIR || echo /tmp)"; [[ -d "$TMPBASE" && -w "$TMPBASE" ]] || TMPBASE=/tmp
TMP="$(mktemp -d "$TMPBASE/stage110.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
exec 3>&1 4>&2
exec > >(tee "$LOG") 2>&1
PASS=0; FAIL=0; WARN=0
pass(){ PASS=$((PASS+1)); echo "PASS: $*"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $*"; }
warn(){ WARN=$((WARN+1)); echo "WARN: $*"; }

echo "========== STAGE110 SIGNING IDENTITY / USB EFI AUDIT =========="
echo "UTC_STAMP=$STAMP"
echo "BRANCH=$BRANCH"
echo "HEAD=$(git rev-parse HEAD)"
echo "STAGE109_COMMIT=$BASE"
echo "RUNNER_GIT_BLOB_SHA=$ACTUAL"
echo "TARGET=$OS ($BUILD) $ARCH"
echo "SCOPE=READ_ONLY_KEXT_SIGNING_IDENTITY_OID_AND_EFI_PARITY"
echo "SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN EFI_WRITE=NONE MOUNT=NOT_RUN SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN"
pass "runner Git blob hash matches allowlist"
pass "host matches Sequoia 24H32 x86_64"

# Keychain read-only inventory. No private key is exported or used.
security find-identity -v -p codesigning >"$TMP/ids" 2>&1
cat "$TMP/ids"
security find-certificate -a -p >"$TMP/certs.pem" 2>"$TMP/certs.err"
python3 - "$TMP/ids" "$TMP/certs.pem" >"$TMP/signing.txt" <<'PY'
import re,subprocess,sys
from pathlib import Path
ids={}
for line in Path(sys.argv[1]).read_text(errors="replace").splitlines():
 m=re.match(r'^\s*\d+\)\s+([0-9a-fA-F]{40})\s+"([^"]+)"\s*line)
 if m and "Developer ID" in m.group(2): ids[m.group(1).upper()]=m.group(2)
certs=re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',Path(sys.argv[2]).read_text(errors="replace"),re.S)
rows=[]
for pem in certs:
 fp=subprocess.run(["/usr/bin/openssl","x509","-noout","-fingerprint","-sha1"],input=pem,text=True,capture_output=True)
 m=re.search(r'Fingerprint=([0-9a-fA-F:]+)',fp.stdout)
 if fp.returncode or not m: continue
 sha=m.group(1).replace(":","").upper()
 if sha not in ids: continue
 info=subprocess.run(["/usr/bin/openssl","x509","-noout","-text"],input=pem,text=True,capture_output=True)
 rows.append((ids[sha],sha,"1.2.840.113635.100.6.1.18" in info.stdout))
print(f"VALID_DEVELOPER_ID_IDENTITIES={len(ids)}")
print(f"MATCHED_DEVELOPER_ID_CERTIFICATES={len(rows)}")
print(f"KEXT_SIGNING_OID_IDENTITIES={sum(1 for x in rows if x[2])}")
for name,sha,oid in rows: print(f"IDENTITY={name} SHA1={sha} KEXT_OID={'PRESENT' if oid else 'ABSENT'}")
PY
cat "$TMP/signing.txt"
DEV="$(sed -n 's/^VALID_DEVELOPER_ID_IDENTITIES=//p' "$TMP/signing.txt")"
OID="$(sed -n 's/^KEXT_SIGNING_OID_IDENTITIES=//p' "$TMP/signing.txt")"
SIGNER=UNKNOWN
if [[ "$OID" -gt 0 ]]; then SIGNER=KEXT_SIGNING_IDENTITY_FOUND; pass "kext-signing OID matched to valid Developer ID identity"
elif [[ "$DEV" -gt 0 ]]; then SIGNER=DEVELOPER_ID_WITHOUT_KEXT_OID; warn "Developer ID exists, but kext-signing extension was not found"
else SIGNER=NO_VALID_DEVELOPER_ID_IDENTITY; warn "no valid Developer ID identity with private key found"
fi
echo "STAGE110_SIGNING_IDENTITY_STATE=$SIGNER"
echo "STAGE110_KEXT_SIGNING_OID_IDENTITY_COUNT=$OID"

csrutil status >"$TMP/sip" 2>&1 || true
cat "$TMP/sip"
if grep -Eqi 'status: enabled|is enabled' "$TMP/sip"; then SIP=ENABLED; pass "SIP enabled"; else SIP=NOT_CONFIRMED; warn "SIP state not confirmed"; fi
echo "STAGE110_SIP_STATE=$SIP"

# Only inspect the already-mounted USB EFI. Never mount or write it.
CONFIG="$(printenv OPENCORE_CONFIG || echo /Volumes/EFI/EFI/OC/config.plist)"
echo "STAGE110_EFI_CONFIG_PATH=$CONFIG"
EFI=NOT_ASSESSED; NC=UNKNOWN; NE=UNKNOWN; LC=UNKNOWN; HM=UNKNOWN; BLOCK=UNKNOWN; SB=UNKNOWN; VAULT=UNKNOWN
if [[ -f "$CONFIG" ]]; then
  plutil -lint "$CONFIG"
  python3 - "$CONFIG" "$BIN_SHA" "$NATIVE_ID" >"$TMP/efi.txt" <<'PY'
import hashlib,plistlib,sys
from pathlib import Path
cfgpath=Path(sys.argv[1]).resolve(); expected=sys.argv[2]; bid=sys.argv[3].lower()
with cfgpath.open("rb") as f: cfg=plistlib.load(f)
oc=cfgpath.parent; native=[]; collision=[]
for i,e in enumerate(cfg.get("Kernel",{}).get("Add",[]) or []):
 bp=str(e.get("BundlePath","")); exe=str(e.get("ExecutablePath",""))
 if not bp: continue
 p=Path(bp); choices=[(oc/p).resolve()]
 if len(p.parts)==1: choices.append((oc/"Kexts"/p).resolve())
 bundle=next((x for x in choices if x.is_dir()),choices[0])
 ident=""
 ip=bundle/"Contents"/"Info.plist"
 if ip.is_file():
  try:
   with ip.open("rb") as f: ident=str(plistlib.load(f).get("CFBundleIdentifier","")).lower()
  except Exception: ident="PLIST_READ_ERROR"
 if Path(bp).name=="RTL88WiFiNative.kext" and Path(exe).name=="RTL88WiFiNative":
  binary=(bundle/exe).resolve(); digest=hashlib.sha256(binary.read_bytes()).hexdigest() if binary.is_file() else "MISSING"
  native.append((i,bool(e.get("Enabled",False)),bp,ident,digest))
 elif ident==bid: collision.append((i,bool(e.get("Enabled",False)),bp,ident))
for x in native: print("NATIVE_ENTRY="+str(x))
for x in collision: print("BUNDLE_ID_COLLISION="+str(x))
blocked=any(bool(x.get("Enabled",False)) and x.get("BundleIdentifier")=="com.apple.iokit.IOSkywalkFamily" for x in cfg.get("Kernel",{}).get("Block",[]) or [])
sec=cfg.get("Misc",{}).get("Security",{})
print("EFI_NATIVE_COUNT="+str(len(native)))
print("EFI_NATIVE_ENABLED="+str(sum(int(x[1]) for x in native)))
print("EFI_LEGACY_COLLISIONS="+str(len(collision)))
print("EFI_HASH_MATCH="+str(bool(native) and all(x[4]==expected for x in native)))
print("EFI_IOSKYWALK_BLOCK="+str(blocked))
print("EFI_SECURE_BOOT_MODEL="+str(sec.get("SecureBootModel","UNKNOWN")))
print("EFI_VAULT="+str(sec.get("Vault","UNKNOWN")))
PY
  cat "$TMP/efi.txt"
  EFI=PARSED
  NC="$(sed -n 's/^EFI_NATIVE_COUNT=//p' "$TMP/efi.txt")"
  NE="$(sed -n 's/^EFI_NATIVE_ENABLED=//p' "$TMP/efi.txt")"
  LC="$(sed -n 's/^EFI_LEGACY_COLLISIONS=//p' "$TMP/efi.txt")"
  HM="$(sed -n 's/^EFI_HASH_MATCH=//p' "$TMP/efi.txt")"
  BLOCK="$(sed -n 's/^EFI_IOSKYWALK_BLOCK=//p' "$TMP/efi.txt")"
  SB="$(sed -n 's/^EFI_SECURE_BOOT_MODEL=//p' "$TMP/efi.txt")"
  VAULT="$(sed -n 's/^EFI_VAULT=//p' "$TMP/efi.txt")"
  [[ "$NC" == 1 && "$NE" == 1 ]] && pass "exactly one enabled native EFI entry" || warn "native EFI entry missing/disabled/duplicated"
  [[ "$LC" == 0 ]] && pass "no legacy/native bundle ID collision" || fail "legacy/native bundle ID collision"
  [[ "$HM" == True ]] && pass "EFI executable hash matches Stage108" || warn "EFI executable does not match Stage108"
  [[ "$BLOCK" == False ]] && pass "IOSkywalkFamily is not blocked" || fail "IOSkywalkFamily is blocked"
else
  warn "USB EFI config not mounted/readable; no mount attempted"
fi
echo "STAGE110_EFI_CONFIG_RESULT=$EFI"
echo "STAGE110_EFI_NATIVE_COUNT=$NC"
echo "STAGE110_EFI_NATIVE_ENABLED_COUNT=$NE"
echo "STAGE110_EFI_LEGACY_COLLISIONS=$LC"
echo "STAGE110_EFI_HASH_MATCH=$HM"
echo "STAGE110_EFI_IOSKYWALK_BLOCK=$BLOCK"
echo "STAGE110_EFI_SECURE_BOOT_MODEL=$SB"
echo "STAGE110_EFI_VAULT=$VAULT"

LOAD=BLOCKED_UNSIGNED
[[ "$SIGNER" == KEXT_SIGNING_IDENTITY_FOUND ]] && LOAD=IDENTITY_FOUND_NO_SIGN_OR_LOAD_AUTHORIZATION
EFI_STATE=BLOCKED_EFI_NOT_ASSESSED
if [[ "$EFI" == PARSED ]]; then
  if [[ "$LC" != 0 || "$BLOCK" != False ]]; then EFI_STATE=BLOCKED_EFI_CONFLICT
  elif [[ "$NC" == 1 && "$NE" == 1 && "$HM" == True ]]; then EFI_STATE=PARITY_AUDIT_PASS_ONLY_NO_ACTIVATION
  else EFI_STATE=BLOCKED_EFI_PARITY
  fi
fi
[[ "$FAIL" -eq 0 ]] && RESULT=AUDIT_COMPLETE || RESULT=REVIEW_REQUIRED
echo "========== STAGE110 SUMMARY =========="
echo "STAGE110_PASS_COUNT=$PASS"
echo "STAGE110_FAIL_COUNT=$FAIL"
echo "STAGE110_WARN_COUNT=$WARN"
echo "STAGE110_RESULT=$RESULT"
echo "STAGE110_SIGNING_IDENTITY_STATE=$SIGNER"
echo "STAGE110_KEXT_SIGNING_OID_IDENTITY_COUNT=$OID"
echo "STAGE110_SIP_STATE=$SIP"
echo "STAGE110_EFI_CONFIG_RESULT=$EFI"
echo "STAGE110_EFI_NATIVE_COUNT=$NC"
echo "STAGE110_EFI_NATIVE_ENABLED_COUNT=$NE"
echo "STAGE110_EFI_LEGACY_COLLISIONS=$LC"
echo "STAGE110_EFI_HASH_MATCH=$HM"
echo "STAGE110_EFI_IOSKYWALK_BLOCK=$BLOCK"
echo "STAGE110_EFI_SECURE_BOOT_MODEL=$SB"
echo "STAGE110_EFI_VAULT=$VAULT"
echo "STAGE110_LOAD_READINESS=$LOAD"
echo "STAGE110_EFI_READINESS=$EFI_STATE"
echo "STAGE110_DETAIL_LOG=$LOG"
echo "SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN EFI_WRITE=NONE MOUNT=NOT_RUN SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN"
echo "STAGE110_NATIVE_ACTIVATION=NOT_AUTHORIZED"
echo "STAGE110_PR4_MERGE=BLOCKED"
{
  echo
  echo "========== STAGE110 SIGNING IDENTITY / USB EFI AUDIT =========="
  echo "STAGE110_RESULT=$RESULT"
  echo "STAGE110_PASS_COUNT=$PASS"
  echo "STAGE110_FAIL_COUNT=$FAIL"
  echo "STAGE110_WARN_COUNT=$WARN"
  echo "STAGE110_SIGNING_IDENTITY_STATE=$SIGNER"
  echo "STAGE110_KEXT_SIGNING_OID_IDENTITY_COUNT=$OID"
  echo "STAGE110_SIP_STATE=$SIP"
  echo "STAGE110_EFI_CONFIG_RESULT=$EFI"
  echo "STAGE110_EFI_NATIVE_COUNT=$NC"
  echo "STAGE110_EFI_NATIVE_ENABLED_COUNT=$NE"
  echo "STAGE110_EFI_LEGACY_COLLISIONS=$LC"
  echo "STAGE110_EFI_HASH_MATCH=$HM"
  echo "STAGE110_EFI_IOSKYWALK_BLOCK=$BLOCK"
  echo "STAGE110_EFI_SECURE_BOOT_MODEL=$SB"
  echo "STAGE110_EFI_VAULT=$VAULT"
  echo "STAGE110_LOAD_READINESS=$LOAD"
  echo "STAGE110_EFI_READINESS=$EFI_STATE"
  echo "STAGE110_DETAIL_LOG=$LOG"
  echo "SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN EFI_WRITE=NONE MOUNT=NOT_RUN SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN"
  echo "STAGE110_NATIVE_ACTIVATION=NOT_AUTHORIZED"
  echo "STAGE110_PR4_MERGE=BLOCKED"
  echo "==============================================================="
} >> Development/output.log
exec 1>&3 2>&4
git add Development/output.log
git add -f "$LOG"
git diff --cached --check
git commit -m "Stage110: record signing identity and USB EFI audit"
git push origin "$BRANCH"
echo "STAGE110_LOG_UPLOAD=PUSHED"
echo "Stage110 finished: $RESULT; $LOG"
[[ "$FAIL" -eq 0 ]]
,$line)
 if m and "Developer ID" in m.group(2): ids[m.group(1).upper()]=m.group(2)
certs=re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',Path(sys.argv[2]).read_text(errors="replace"),re.S)
rows=[]
for pem in certs:
 fp=subprocess.run(["/usr/bin/openssl","x509","-noout","-fingerprint","-sha1"],input=pem,text=True,capture_output=True)
 m=re.search(r'Fingerprint=([0-9a-fA-F:]+)',fp.stdout)
 if fp.returncode or not m: continue
 sha=m.group(1).replace(":","").upper()
 if sha not in ids: continue
 info=subprocess.run(["/usr/bin/openssl","x509","-noout","-text"],input=pem,text=True,capture_output=True)
 rows.append((ids[sha],sha,"1.2.840.113635.100.6.1.18" in info.stdout))
print(f"VALID_DEVELOPER_ID_IDENTITIES={len(ids)}")
print(f"MATCHED_DEVELOPER_ID_CERTIFICATES={len(rows)}")
print(f"KEXT_SIGNING_OID_IDENTITIES={sum(1 for x in rows if x[2])}")
for name,sha,oid in rows: print(f"IDENTITY={name} SHA1={sha} KEXT_OID={'PRESENT' if oid else 'ABSENT'}")
PY
cat "$TMP/signing.txt"
DEV="$(sed -n 's/^VALID_DEVELOPER_ID_IDENTITIES=//p' "$TMP/signing.txt")"
OID="$(sed -n 's/^KEXT_SIGNING_OID_IDENTITIES=//p' "$TMP/signing.txt")"
SIGNER=UNKNOWN
if [[ "$OID" -gt 0 ]]; then SIGNER=KEXT_SIGNING_IDENTITY_FOUND; pass "kext-signing OID matched to valid Developer ID identity"
elif [[ "$DEV" -gt 0 ]]; then SIGNER=DEVELOPER_ID_WITHOUT_KEXT_OID; warn "Developer ID exists, but kext-signing extension was not found"
else SIGNER=NO_VALID_DEVELOPER_ID_IDENTITY; warn "no valid Developer ID identity with private key found"
fi
echo "STAGE110_SIGNING_IDENTITY_STATE=$SIGNER"
echo "STAGE110_KEXT_SIGNING_OID_IDENTITY_COUNT=$OID"

csrutil status >"$TMP/sip" 2>&1 || true
cat "$TMP/sip"
if grep -Eqi 'status: enabled|is enabled' "$TMP/sip"; then SIP=ENABLED; pass "SIP enabled"; else SIP=NOT_CONFIRMED; warn "SIP state not confirmed"; fi
echo "STAGE110_SIP_STATE=$SIP"

# Only inspect the already-mounted USB EFI. Never mount or write it.
CONFIG="$(printenv OPENCORE_CONFIG || echo /Volumes/EFI/EFI/OC/config.plist)"
echo "STAGE110_EFI_CONFIG_PATH=$CONFIG"
EFI=NOT_ASSESSED; NC=UNKNOWN; NE=UNKNOWN; LC=UNKNOWN; HM=UNKNOWN; BLOCK=UNKNOWN; SB=UNKNOWN; VAULT=UNKNOWN
if [[ -f "$CONFIG" ]]; then
  plutil -lint "$CONFIG"
  python3 - "$CONFIG" "$BIN_SHA" "$NATIVE_ID" >"$TMP/efi.txt" <<'PY'
import hashlib,plistlib,sys
from pathlib import Path
cfgpath=Path(sys.argv[1]).resolve(); expected=sys.argv[2]; bid=sys.argv[3].lower()
with cfgpath.open("rb") as f: cfg=plistlib.load(f)
oc=cfgpath.parent; native=[]; collision=[]
for i,e in enumerate(cfg.get("Kernel",{}).get("Add",[]) or []):
 bp=str(e.get("BundlePath","")); exe=str(e.get("ExecutablePath",""))
 if not bp: continue
 p=Path(bp); choices=[(oc/p).resolve()]
 if len(p.parts)==1: choices.append((oc/"Kexts"/p).resolve())
 bundle=next((x for x in choices if x.is_dir()),choices[0])
 ident=""
 ip=bundle/"Contents"/"Info.plist"
 if ip.is_file():
  try:
   with ip.open("rb") as f: ident=str(plistlib.load(f).get("CFBundleIdentifier","")).lower()
  except Exception: ident="PLIST_READ_ERROR"
 if Path(bp).name=="RTL88WiFiNative.kext" and Path(exe).name=="RTL88WiFiNative":
  binary=(bundle/exe).resolve(); digest=hashlib.sha256(binary.read_bytes()).hexdigest() if binary.is_file() else "MISSING"
  native.append((i,bool(e.get("Enabled",False)),bp,ident,digest))
 elif ident==bid: collision.append((i,bool(e.get("Enabled",False)),bp,ident))
for x in native: print("NATIVE_ENTRY="+str(x))
for x in collision: print("BUNDLE_ID_COLLISION="+str(x))
blocked=any(bool(x.get("Enabled",False)) and x.get("BundleIdentifier")=="com.apple.iokit.IOSkywalkFamily" for x in cfg.get("Kernel",{}).get("Block",[]) or [])
sec=cfg.get("Misc",{}).get("Security",{})
print("EFI_NATIVE_COUNT="+str(len(native)))
print("EFI_NATIVE_ENABLED="+str(sum(int(x[1]) for x in native)))
print("EFI_LEGACY_COLLISIONS="+str(len(collision)))
print("EFI_HASH_MATCH="+str(bool(native) and all(x[4]==expected for x in native)))
print("EFI_IOSKYWALK_BLOCK="+str(blocked))
print("EFI_SECURE_BOOT_MODEL="+str(sec.get("SecureBootModel","UNKNOWN")))
print("EFI_VAULT="+str(sec.get("Vault","UNKNOWN")))
PY
  cat "$TMP/efi.txt"
  EFI=PARSED
  NC="$(sed -n 's/^EFI_NATIVE_COUNT=//p' "$TMP/efi.txt")"
  NE="$(sed -n 's/^EFI_NATIVE_ENABLED=//p' "$TMP/efi.txt")"
  LC="$(sed -n 's/^EFI_LEGACY_COLLISIONS=//p' "$TMP/efi.txt")"
  HM="$(sed -n 's/^EFI_HASH_MATCH=//p' "$TMP/efi.txt")"
  BLOCK="$(sed -n 's/^EFI_IOSKYWALK_BLOCK=//p' "$TMP/efi.txt")"
  SB="$(sed -n 's/^EFI_SECURE_BOOT_MODEL=//p' "$TMP/efi.txt")"
  VAULT="$(sed -n 's/^EFI_VAULT=//p' "$TMP/efi.txt")"
  [[ "$NC" == 1 && "$NE" == 1 ]] && pass "exactly one enabled native EFI entry" || warn "native EFI entry missing/disabled/duplicated"
  [[ "$LC" == 0 ]] && pass "no legacy/native bundle ID collision" || fail "legacy/native bundle ID collision"
  [[ "$HM" == True ]] && pass "EFI executable hash matches Stage108" || warn "EFI executable does not match Stage108"
  [[ "$BLOCK" == False ]] && pass "IOSkywalkFamily is not blocked" || fail "IOSkywalkFamily is blocked"
else
  warn "USB EFI config not mounted/readable; no mount attempted"
fi
echo "STAGE110_EFI_CONFIG_RESULT=$EFI"
echo "STAGE110_EFI_NATIVE_COUNT=$NC"
echo "STAGE110_EFI_NATIVE_ENABLED_COUNT=$NE"
echo "STAGE110_EFI_LEGACY_COLLISIONS=$LC"
echo "STAGE110_EFI_HASH_MATCH=$HM"
echo "STAGE110_EFI_IOSKYWALK_BLOCK=$BLOCK"
echo "STAGE110_EFI_SECURE_BOOT_MODEL=$SB"
echo "STAGE110_EFI_VAULT=$VAULT"

LOAD=BLOCKED_UNSIGNED
[[ "$SIGNER" == KEXT_SIGNING_IDENTITY_FOUND ]] && LOAD=IDENTITY_FOUND_NO_SIGN_OR_LOAD_AUTHORIZATION
EFI_STATE=BLOCKED_EFI_NOT_ASSESSED
if [[ "$EFI" == PARSED ]]; then
  if [[ "$LC" != 0 || "$BLOCK" != False ]]; then EFI_STATE=BLOCKED_EFI_CONFLICT
  elif [[ "$NC" == 1 && "$NE" == 1 && "$HM" == True ]]; then EFI_STATE=PARITY_AUDIT_PASS_ONLY_NO_ACTIVATION
  else EFI_STATE=BLOCKED_EFI_PARITY
  fi
fi
[[ "$FAIL" -eq 0 ]] && RESULT=AUDIT_COMPLETE || RESULT=REVIEW_REQUIRED
echo "========== STAGE110 SUMMARY =========="
echo "STAGE110_PASS_COUNT=$PASS"
echo "STAGE110_FAIL_COUNT=$FAIL"
echo "STAGE110_WARN_COUNT=$WARN"
echo "STAGE110_RESULT=$RESULT"
echo "STAGE110_SIGNING_IDENTITY_STATE=$SIGNER"
echo "STAGE110_KEXT_SIGNING_OID_IDENTITY_COUNT=$OID"
echo "STAGE110_SIP_STATE=$SIP"
echo "STAGE110_EFI_CONFIG_RESULT=$EFI"
echo "STAGE110_EFI_NATIVE_COUNT=$NC"
echo "STAGE110_EFI_NATIVE_ENABLED_COUNT=$NE"
echo "STAGE110_EFI_LEGACY_COLLISIONS=$LC"
echo "STAGE110_EFI_HASH_MATCH=$HM"
echo "STAGE110_EFI_IOSKYWALK_BLOCK=$BLOCK"
echo "STAGE110_EFI_SECURE_BOOT_MODEL=$SB"
echo "STAGE110_EFI_VAULT=$VAULT"
echo "STAGE110_LOAD_READINESS=$LOAD"
echo "STAGE110_EFI_READINESS=$EFI_STATE"
echo "STAGE110_DETAIL_LOG=$LOG"
echo "SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN EFI_WRITE=NONE MOUNT=NOT_RUN SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN"
echo "STAGE110_NATIVE_ACTIVATION=NOT_AUTHORIZED"
echo "STAGE110_PR4_MERGE=BLOCKED"
{
  echo
  echo "========== STAGE110 SIGNING IDENTITY / USB EFI AUDIT =========="
  echo "STAGE110_RESULT=$RESULT"
  echo "STAGE110_PASS_COUNT=$PASS"
  echo "STAGE110_FAIL_COUNT=$FAIL"
  echo "STAGE110_WARN_COUNT=$WARN"
  echo "STAGE110_SIGNING_IDENTITY_STATE=$SIGNER"
  echo "STAGE110_KEXT_SIGNING_OID_IDENTITY_COUNT=$OID"
  echo "STAGE110_SIP_STATE=$SIP"
  echo "STAGE110_EFI_CONFIG_RESULT=$EFI"
  echo "STAGE110_EFI_NATIVE_COUNT=$NC"
  echo "STAGE110_EFI_NATIVE_ENABLED_COUNT=$NE"
  echo "STAGE110_EFI_LEGACY_COLLISIONS=$LC"
  echo "STAGE110_EFI_HASH_MATCH=$HM"
  echo "STAGE110_EFI_IOSKYWALK_BLOCK=$BLOCK"
  echo "STAGE110_EFI_SECURE_BOOT_MODEL=$SB"
  echo "STAGE110_EFI_VAULT=$VAULT"
  echo "STAGE110_LOAD_READINESS=$LOAD"
  echo "STAGE110_EFI_READINESS=$EFI_STATE"
  echo "STAGE110_DETAIL_LOG=$LOG"
  echo "SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN EFI_WRITE=NONE MOUNT=NOT_RUN SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN"
  echo "STAGE110_NATIVE_ACTIVATION=NOT_AUTHORIZED"
  echo "STAGE110_PR4_MERGE=BLOCKED"
  echo "==============================================================="
} >> Development/output.log
exec 1>&3 2>&4
git add Development/output.log
git add -f "$LOG"
git diff --cached --check
git commit -m "Stage110: record signing identity and USB EFI audit"
git push origin "$BRANCH"
echo "STAGE110_LOG_UPLOAD=PUSHED"
echo "Stage110 finished: $RESULT; $LOG"
[[ "$FAIL" -eq 0 ]]
