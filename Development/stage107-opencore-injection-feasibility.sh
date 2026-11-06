#!/bin/bash
# Stage107 — read-only OpenCore boot-injection feasibility audit.
# No mount/unmount, config writes, SIP/NVRAM changes, signing, install, load, or rebuild.
set -u
set -o pipefail
EXPECTED_BRANCH="work/stage91-tx-submission-callback-v1"
EXPECTED_BIN_SHA="5d63db951e4a5c0228d4d73e664ab8e9457fc1fe805cce23444fe022f04f2513"
NATIVE_BUNDLE_ID="io.github.x1ren41l.RTL88WiFi"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_REL="Development/Logs/stage107-opencore-injection-feasibility-${STAMP}.log"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside repository"; exit 2; }
cd "$ROOT" || exit 2
[ "$(git branch --show-current)" = "$EXPECTED_BRANCH" ] || { echo "ERROR: wrong branch"; exit 2; }
if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree is not clean; preserve/commit existing changes first."
  git status --short
  exit 2
fi
BUNDLE="driver/RTL88WiFi/build/out/RTL88WiFiNative.kext"
BIN="$BUNDLE/Contents/MacOS/RTL88WiFiNative"
PLIST="$BUNDLE/Contents/Info.plist"
[ -f "$BIN" ] && [ -f "$PLIST" ] || { echo "ERROR: Stage103 candidate bundle missing"; exit 2; }
mkdir -p Development/Logs || exit 2
LOG="$ROOT/$LOG_REL"
TMP_BASE="${TMPDIR:-/tmp}"
[ -d "$TMP_BASE" ] && [ -w "$TMP_BASE" ] || TMP_BASE="/tmp"
TMP="$(mktemp -d "$TMP_BASE/stage107.XXXXXX")" || { echo "ERROR: unable to create Stage107 temporary directory"; exit 2; }
trap 'rm -rf "$TMP"' EXIT
exec 3>&1 4>&2
exec > >(tee "$LOG") 2>&1
PASS=0; FAIL=0; WARN=0
pass(){ PASS=$((PASS+1)); echo "PASS: $*"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $*"; }
warn(){ WARN=$((WARN+1)); echo "WARN: $*"; }
capture(){ local n="$1"; shift; "$@" >"$TMP/$n.txt" 2>&1; local r=$?; echo "$r" >"$TMP/$n.rc"; echo "COMMAND_${n}_EXIT=$r"; return 0; }
rc(){ [ -f "$TMP/$1.rc" ] && cat "$TMP/$1.rc" || echo 999; }

echo "========== STAGE107 OPENCORE INJECTION FEASIBILITY =========="
echo "UTC_STAMP=$STAMP"
echo "BRANCH=$EXPECTED_BRANCH"
echo "HEAD=$(git rev-parse HEAD)"
echo "SCOPE=READ_ONLY_HOST_SECURITY_OPENCORE_CONFIG_KERNEL_ADD_BLOCK_DEPENDENCY_ORDER_VAULT"
echo "BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN SIP_CHANGE=NONE NVRAM_CHANGE=NONE EFI_WRITE=NONE HARDWARE_TEST=NOT_RUN"

for t in sw_vers uname csrutil nvram sysctl kmutil plutil python3 shasum git; do
  if command -v "$t" >/dev/null 2>&1; then pass "tool available: $t"; else fail "required audit tool missing: $t"; fi
done
OS="$(sw_vers -productVersion 2>/dev/null || echo UNKNOWN)"
BUILD="$(sw_vers -buildVersion 2>/dev/null || echo UNKNOWN)"
ARCH="$(uname -m 2>/dev/null || echo UNKNOWN)"
echo "HOST_PRODUCT_VERSION=$OS"
echo "HOST_BUILD_VERSION=$BUILD"
echo "HOST_ARCH=$ARCH"
if [ "$OS" = "15.8.1" ] && [ "$BUILD" = "24H32" ] && [ "$ARCH" = "x86_64" ]; then pass "host matches Sequoia 15.8.1 build 24H32 x86_64"; else fail "host differs from pinned target"; fi

capture sip-status csrutil status
cat "$TMP/sip-status.txt"
if grep -Eqi 'System Integrity Protection status: enabled|System Integrity Protection is enabled' "$TMP/sip-status.txt"; then SIP_STATE=ENABLED; pass "SIP is enabled"; else SIP_STATE=NOT_CONFIRMED_ENABLED; fail "SIP is not confirmed enabled"; fi
BIN_SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
echo "STAGE107_CANDIDATE_BINARY_SHA256=$BIN_SHA"
if [ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ]; then pass "candidate matches Stage104/105 audited binary"; else fail "candidate hash differs"; fi

OC_VERSION="$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version 2>/dev/null | sed 's/.*:opencore-version[[:space:]]*//' | head -1)"
[ -n "$OC_VERSION" ] && echo "BOOTED_OPENCORE_VERSION=$OC_VERSION" || { echo "BOOTED_OPENCORE_VERSION=NOT_EXPOSED"; warn "OpenCore version not exposed through NVRAM"; }
BOOTARGS="$(sysctl -n kern.bootargs 2>/dev/null || true)"
SECURITY_ARGS="$(printf '%s\n' "$BOOTARGS" | tr ' ' '\n' | grep -Ei '^(amfi|cs_enforcement_disable|amfi_get_out_of_my_way|amfi_allow_any_signature|kext-dev-mode|rootless|csr-active-config)' || true)"
if [ -n "$SECURITY_ARGS" ]; then
  echo "SECURITY_RELEVANT_BOOT_ARGS_BEGIN"; printf '%s\n' "$SECURITY_ARGS"; echo "SECURITY_RELEVANT_BOOT_ARGS_END"
  if printf '%s\n' "$SECURITY_ARGS" | grep -Eqi '^(amfi=0x0|amfi_get_out_of_my_way=1|-amfi_get_out_of_my_way=1|cs_enforcement_disable=1|amfi_allow_any_signature=1)'; then
    warn "security-weakening AMFI/code-signing boot argument detected"
  else pass "no recognized AMFI/code-signing bypass boot argument detected"; fi
else echo "SECURITY_RELEVANT_BOOT_ARGS=NONE_DETECTED"; pass "no recognized AMFI/code-signing bypass boot argument detected"; fi

CONFIG_PATH="${OPENCORE_CONFIG:-}"
if [ -n "$CONFIG_PATH" ]; then
  if [ ! -f "$CONFIG_PATH" ]; then echo "ERROR: OPENCORE_CONFIG path is not readable"; exit 2; fi
  CONFIG_SOURCE=EXPLICIT_READ_ONLY_PATH
else
  CONFIG_LIST="$TMP/config-candidates.txt"
  python3 - <<'PY' > "$CONFIG_LIST"
from pathlib import Path
for p in sorted(Path("/Volumes").glob("*/EFI/OC/config.plist")):
    if p.is_file(): print(str(p))
PY
  COUNT="$(wc -l < "$CONFIG_LIST" | tr -d ' ')"
  if [ "$COUNT" -eq 1 ]; then CONFIG_PATH="$(cat "$CONFIG_LIST")"; CONFIG_SOURCE=UNIQUE_MOUNTED_EFI_CONFIG
  elif [ "$COUNT" -eq 0 ]; then CONFIG_PATH=""; CONFIG_SOURCE=NOT_FOUND
  else CONFIG_PATH=""; CONFIG_SOURCE=AMBIGUOUS_MULTIPLE_CONFIGS; fi
fi
echo "OPENCORE_CONFIG_SOURCE=$CONFIG_SOURCE"
[ -n "$CONFIG_PATH" ] && echo "OPENCORE_CONFIG_PATH=$CONFIG_PATH" || echo "OPENCORE_CONFIG_PATH=NOT_SELECTED"

CONFIG_RESULT=NOT_ASSESSED
APPLE_SECURE_BOOT=UNKNOWN
VAULT=UNKNOWN
NATIVE_ENTRY=UNKNOWN
SKYWALK_BLOCK=UNKNOWN
LEGACY_ENTRIES=UNKNOWN
SIP_CONFIG_VALUE=UNKNOWN

if [ -n "$CONFIG_PATH" ]; then
  if plutil -lint "$CONFIG_PATH"; then pass "selected OpenCore config.plist passes plutil"; else fail "OpenCore config.plist is invalid"; fi
  if python3 - "$CONFIG_PATH" "$BUNDLE" "$NATIVE_BUNDLE_ID" > "$TMP/config-inspection.txt" <<'PY'
import plistlib,sys
from pathlib import Path
cfg_path=Path(sys.argv[1]).expanduser().resolve()
native_bundle=Path(sys.argv[2]).resolve()
native_id=sys.argv[3]
with cfg_path.open("rb") as f: cfg=plistlib.load(f)
ocdir=cfg_path.parent
misc=cfg.get("Misc",{}).get("Security",{})
secure=misc.get("SecureBootModel","<MISSING>")
vault=misc.get("Vault","<MISSING>")
print("CONFIG_PARSE=PASS")
print("OC_SECURE_BOOT_MODEL="+str(secure))
print("OC_VAULT="+str(vault))
print("APPLE_SECURE_BOOT_POLICY="+("DISABLED_IN_CONFIG" if secure=="Disabled" else "ENABLED_OR_UNRECOGNIZED_VALUE"))
guid="7C436110-AB2A-4BBB-A880-FE41995C9F82"
nvadd=cfg.get("NVRAM",{}).get("Add",{}).get(guid,{})
csr=nvadd.get("csr-active-config")
if isinstance(csr,bytes): csrval=csr.hex()
elif isinstance(csr,str): csrval=csr
else: csrval="NOT_SET_IN_NVRAM_ADD"
print("CONFIG_CSR_ACTIVE_CONFIG="+csrval)
nvdelete=cfg.get("NVRAM",{}).get("Delete",{}).get(guid,[])
print("CONFIG_CSR_ACTIVE_CONFIG_DELETE="+str("csr-active-config" in nvdelete))
add=cfg.get("Kernel",{}).get("Add",[])
legacy=[]; sky=[]; famlegacy=[]; native=[]
print("KERNEL_ADD_COUNT="+str(len(add)))
for i,e in enumerate(add):
    bp=str(e.get("BundlePath","")); enabled=bool(e.get("Enabled",False))
    arch=str(e.get("Arch","")); exe=str(e.get("ExecutablePath","")); pp=str(e.get("PlistPath",""))
    ident=""; version=""
    ip=ocdir/bp/"Contents/Info.plist"
    if bp and ip.is_file():
        try:
            with ip.open("rb") as f: item=plistlib.load(f)
            ident=str(item.get("CFBundleIdentifier","")); version=str(item.get("CFBundleVersion",""))
        except Exception: ident="PLIST_READ_ERROR"
    if "RTL88" in bp.upper() or "REALTEK" in bp.upper() or ident.lower()==native_id.lower():
        print(f"KERNEL_ADD[{i}]=enabled:{enabled};arch:{arch};bundle:{bp};id:{ident};version:{version};executable:{exe};plist:{pp}")
    if ident.lower()==native_id.lower(): native.append((i,enabled,bp))
    if ("RTL88" in bp.upper() or "REALTEK" in bp.upper()) and "NATIVE" not in bp.upper(): legacy.append((i,enabled,bp,ident))
    if ident=="com.apple.iokit.IOSkywalkFamily" or "IOSkywalkFamily.kext" in bp: sky.append((i,enabled,bp,ident))
    if "IO80211FamilyLegacy" in bp or ident.endswith("IO80211FamilyLegacy"): famlegacy.append((i,enabled,bp,ident))
print("NATIVE_KERNEL_ADD_ENTRY="+("FOUND" if native else "ABSENT"))
print("NATIVE_KERNEL_ADD_ENABLED="+str(any(x[1] for x in native)))
print("LEGACY_REALTEK_KERNEL_ADD_ENTRIES="+str(len(legacy)))
for x in legacy: print("LEGACY_REALTEK_ENTRY="+repr(x))
print("INJECTED_IOSKYWALK_FAMILY_ENTRIES="+str(len(sky)))
for x in sky: print("INJECTED_IOSKYWALK_ENTRY="+repr(x))
print("INJECTED_IO80211FAMILYLEGACY_ENTRIES="+str(len(famlegacy)))
for x in famlegacy: print("INJECTED_IO80211FAMILYLEGACY_ENTRY="+repr(x))
block=cfg.get("Kernel",{}).get("Block",[])
blocked=[]
for i,e in enumerate(block):
    ident=str(e.get("BundleIdentifier","")); en=bool(e.get("Enabled",False))
    if ident in ("com.apple.iokit.IOSkywalkFamily","com.apple.iokit.IO80211Family") or "RTL88" in ident.upper():
        blocked.append((i,en,ident))
print("RELEVANT_KERNEL_BLOCK_ENTRIES="+str(len(blocked)))
for x in blocked: print("KERNEL_BLOCK_ENTRY="+repr(x))
print("IOSKYWALK_BLOCK_ENABLED="+str(any(x[1] and x[2]=="com.apple.iokit.IOSkywalkFamily" for x in blocked)))
force=cfg.get("Kernel",{}).get("Force",[])
for i,e in enumerate(force):
    ident=str(e.get("Identifier",""))
    if "IO80211" in ident or "IOSkywalk" in ident or "RTL88" in ident.upper():
        print("RELEVANT_KERNEL_FORCE_ENTRY="+str(i)+";enabled:"+str(e.get("Enabled",False))+";identifier:"+ident)
quirks=cfg.get("Kernel",{}).get("Quirks",{})
print("KERNEL_QUIRK_DISABLE_LINKEDIT_JETTISON="+str(quirks.get("DisableLinkeditJettison","<MISSING>")))
print("NATIVE_BUNDLE_PRESENT_AT_REPO_PATH="+str(native_bundle.is_dir()))
with (native_bundle/"Contents/Info.plist").open("rb") as f: np=plistlib.load(f)
libs=np.get("OSBundleLibraries",{})
print("NATIVE_BUNDLE_ID="+str(np.get("CFBundleIdentifier","")))
print("NATIVE_OSBUNDLE_LIBRARIES="+",".join(sorted(libs.keys())))
print("NATIVE_REQUIRES_IOSKY_FAMILY="+str("com.apple.iokit.IOSkywalkFamily" in libs))
print("NATIVE_REQUIRES_LEGACY_80211="+str("com.apple.iokit.IO80211FamilyLegacy" in libs))
PY
  then
    cat "$TMP/config-inspection.txt"
    CONFIG_RESULT=PARSED
    APPLE_SECURE_BOOT="$(sed -n 's/^OC_SECURE_BOOT_MODEL=//p' "$TMP/config-inspection.txt" | head -1)"
    VAULT="$(sed -n 's/^OC_VAULT=//p' "$TMP/config-inspection.txt" | head -1)"
    NATIVE_ENTRY="$(sed -n 's/^NATIVE_KERNEL_ADD_ENTRY=//p' "$TMP/config-inspection.txt" | head -1)"
    SKYWALK_BLOCK="$(sed -n 's/^IOSKYWALK_BLOCK_ENABLED=//p' "$TMP/config-inspection.txt" | head -1)"
    LEGACY_ENTRIES="$(sed -n 's/^LEGACY_REALTEK_KERNEL_ADD_ENTRIES=//p' "$TMP/config-inspection.txt" | head -1)"
    SIP_CONFIG_VALUE="$(sed -n 's/^CONFIG_CSR_ACTIVE_CONFIG=//p' "$TMP/config-inspection.txt" | head -1)"
    pass "OpenCore config parsed read-only"
    if [ "$APPLE_SECURE_BOOT" = "Disabled" ]; then pass "SecureBootModel Disabled; this avoids the documented Apple Secure Boot unsigned-kext restriction"; else warn "SecureBootModel is not Disabled; OpenCore docs state unsigned kexts cannot be used under Apple Secure Boot"; fi
    if [ "$SKYWALK_BLOCK" = "True" ]; then fail "Kernel->Block actively blocks IOSkywalkFamily required by native candidate"; else pass "no enabled IOSkywalkFamily block detected"; fi
    if [ "$VAULT" = "Optional" ]; then pass "OpenCore Vault is Optional"; elif [ "$VAULT" = "Secure" ]; then warn "OpenCore Vault=Secure; EFI changes require a valid updated vault"; else warn "Vault policy missing or unrecognized"; fi
    if grep -q '^NATIVE_KERNEL_ADD_ENTRY=FOUND$' "$TMP/config-inspection.txt"; then warn "native candidate already appears in Kernel->Add; verify exact active config provenance"; else pass "native candidate not yet in Kernel->Add"; fi
    if [ "$LEGACY_ENTRIES" != "0" ]; then warn "existing Realtek/RTL88 entry may conflict; compare identifiers and order before replacing anything"; else pass "no RTL88-named legacy entry detected"; fi
  else CONFIG_RESULT=PARSE_FAILED; fail "could not parse selected OpenCore config or native Info.plist"; fi
else
  if [ "$CONFIG_SOURCE" = "NOT_FOUND" ]; then warn "no mounted EFI config found; mount the intended EFI manually, then rerun"; else warn "multiple mounted EFI configs found; rerun with OPENCORE_CONFIG set to the active boot config"; fi
fi

capture loaded-kexts kmutil showloaded
if [ "$(rc loaded-kexts)" -eq 0 ]; then
  grep -Ei 'RTL88|Realtek|IO80211FamilyLegacy|IOSkywalkFamily' "$TMP/loaded-kexts.txt" || echo "NO_MATCHING_REALTEK_OR_LEGACY_SKYWALK_KEXTS_REPORTED"
  pass "loaded-kext inventory completed (matching lines only)"
else warn "kmutil showloaded unavailable"; fi

if [ "$CONFIG_RESULT" != "PARSED" ]; then
  FEASIBILITY=NOT_ASSESSED_CONFIG_NOT_AVAILABLE
elif [ "$SIP_STATE" != "ENABLED" ]; then
  FEASIBILITY=BLOCKED_USER_REQUIRES_SIP_ENABLED
elif [ "$SKYWALK_BLOCK" = "True" ]; then
  FEASIBILITY=BLOCKED_IOSKYWALK_DEPENDENCY_IS_BLOCKED
elif [ "$APPLE_SECURE_BOOT" != "Disabled" ]; then
  FEASIBILITY=BLOCKED_OR_REVIEW_REQUIRED_APPLE_SECURE_BOOT_MODEL
elif [ "$VAULT" = "Secure" ]; then
  FEASIBILITY=REQUIRES_VALID_UPDATED_OPENCORE_VAULT
else
  FEASIBILITY=BOOT_INJECTION_CONFIGURATION_POSSIBLE_BUT_UNSIGNED_KEXT_ACCEPTANCE_NOT_PROVEN
fi

echo
echo "========== STAGE107 SUMMARY =========="
echo "STAGE107_PASS_COUNT=$PASS"
echo "STAGE107_FAIL_COUNT=$FAIL"
echo "STAGE107_WARN_COUNT=$WARN"
echo "STAGE107_SIP_STATE=$SIP_STATE"
echo "STAGE107_OPENCORE_CONFIG_RESULT=$CONFIG_RESULT"
echo "STAGE107_SECURE_BOOT_MODEL=$APPLE_SECURE_BOOT"
echo "STAGE107_VAULT_POLICY=$VAULT"
echo "STAGE107_NATIVE_KERNEL_ADD_ENTRY=$NATIVE_ENTRY"
echo "STAGE107_IOSKYWALK_BLOCK_ENABLED=$SKYWALK_BLOCK"
echo "STAGE107_LEGACY_REALTEK_ENTRIES=$LEGACY_ENTRIES"
echo "STAGE107_CONFIG_CSR_ACTIVE_CONFIG=$SIP_CONFIG_VALUE"
echo "STAGE107_INJECTION_FEASIBILITY=$FEASIBILITY"
echo "STAGE107_DETAIL_LOG=$LOG_REL"
echo "BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN SIP_CHANGE=NONE NVRAM_CHANGE=NONE EFI_WRITE=NONE HARDWARE_TEST=NOT_RUN"
echo "======================================"
{
 echo
 echo "========== STAGE107 OPENCORE INJECTION FEASIBILITY =========="
 if [ "$FAIL" -gt 0 ]; then
  STAGE107_RESULT=REVIEW_REQUIRED
elif [ "$CONFIG_RESULT" != "PARSED" ]; then
  STAGE107_RESULT=PARTIAL_CONFIG_NOT_ASSESSED
else
  STAGE107_RESULT=AUDIT_COMPLETE
fi
 echo "STAGE107_RESULT=$STAGE107_RESULT"
 echo "STAGE107_PASS_COUNT=$PASS"
 echo "STAGE107_FAIL_COUNT=$FAIL"
 echo "STAGE107_WARN_COUNT=$WARN"
 echo "STAGE107_SIP_STATE=$SIP_STATE"
 echo "STAGE107_OPENCORE_CONFIG_RESULT=$CONFIG_RESULT"
 echo "STAGE107_SECURE_BOOT_MODEL=$APPLE_SECURE_BOOT"
 echo "STAGE107_VAULT_POLICY=$VAULT"
 echo "STAGE107_NATIVE_KERNEL_ADD_ENTRY=$NATIVE_ENTRY"
 echo "STAGE107_IOSKYWALK_BLOCK_ENABLED=$SKYWALK_BLOCK"
 echo "STAGE107_LEGACY_REALTEK_ENTRIES=$LEGACY_ENTRIES"
 echo "STAGE107_CONFIG_CSR_ACTIVE_CONFIG=$SIP_CONFIG_VALUE"
 echo "STAGE107_INJECTION_FEASIBILITY=$FEASIBILITY"
 echo "STAGE107_DETAIL_LOG=$LOG_REL"
 echo "STAGE107_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN SIP_CHANGE=NONE NVRAM_CHANGE=NONE EFI_WRITE=NONE HARDWARE_TEST=NOT_RUN"
 echo "STAGE107_NATIVE_ACTIVATION=BLOCKED_PENDING_REVIEW"
 echo "STAGE107_PR4_MERGE=BLOCKED"
 echo "==============================================================="
} >> Development/output.log

exec 1>&3 2>&4
git add Development/output.log
git add -f "$LOG_REL"
git commit -m "Stage107: record read-only OpenCore injection feasibility audit" || exit 3
git push origin "$EXPECTED_BRANCH" || { echo "STAGE107_LOG_UPLOAD=PUSH_FAILED" >&3; exit 3; }
echo "STAGE107_LOG_UPLOAD=PUSHED" >&3
[ "$FAIL" -eq 0 ]
