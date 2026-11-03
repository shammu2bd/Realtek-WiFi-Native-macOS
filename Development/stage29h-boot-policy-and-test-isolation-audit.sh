#!/bin/bash
set -u
REPO='shammu2bd/Realtek-WiFi-Native-macOS'
API="repos/$REPO/contents/Development/output.log"
NAME='RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source'
PROJECT=''
if [[ -n "${PROJECT_DIR:-}" ]]; then
  if [[ -f "$PROJECT_DIR/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$PROJECT_DIR"; fi
  if [[ -z "$PROJECT" && -f "$PROJECT_DIR/Makefile" && -d "$PROJECT_DIR/src/kext" ]]; then PROJECT="$(cd "$PROJECT_DIR/../.." && pwd -P)"; fi
fi
if [[ -z "$PROJECT" && -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$PWD"; fi
if [[ -z "$PROJECT" && -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$HOME/Downloads/$NAME"; fi
[[ -n "$PROJECT" ]] || { echo 'Cannot locate Stage26 project; set PROJECT_DIR to its root.'; exit 2; }
DRIVER="$PROJECT/driver/RTL88WiFi"
NATIVE="$DRIVER/build/out/RTL88WiFiNative.kext"
LEGACY="$DRIVER/RTL88WiFi.kext"
LOG="$PROJECT/output.log"
STAGE="$PROJECT/build/stage29h-boot-policy-audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE" || exit 2
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { echo 'GitHub CLI authentication required'; exit 2; }
gh api "$API" > "$STAGE/remote-log.json" || exit 2
python3 - "$STAGE/remote-log.json" "$LOG" <<'PY'
import base64,json,pathlib,sys
doc=json.loads(pathlib.Path(sys.argv[1]).read_text())
data=base64.b64decode(doc.get('content',''))
t=data.decode('utf-8',errors='replace')
needed=['NATIVE_ACTUAL_BUILD: PASS','STAGE29D_STATIC_AUDIT: PASS','STAGE29G_PREFLIGHT: COMPLETE']
missing=[x for x in needed if x not in t]
if missing: raise SystemExit('Canonical log lacks required milestones: '+', '.join(missing))
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
[[ $? -eq 0 ]] || { echo 'Canonical log validation failed'; exit 2; }
OS_VERSION=$(sw_vers -productVersion 2>&1)
OS_BUILD=$(sw_vers -buildVersion 2>&1)
ARCH=$(uname -m)
MODEL=$(sysctl -n hw.model 2>&1)
CSR=$(csrutil status 2>&1); CSR_RC=$?
NVRAM_CSR=$(nvram csr-active-config 2>&1); NVRAM_CSR_RC=$?
NVRAM_ARGS=$(nvram boot-args 2>&1); NVRAM_ARGS_RC=$?
KERN_ARGS=$(sysctl -n kern.bootargs 2>&1); KERN_ARGS_RC=$?
command -v kmutil >/dev/null 2>&1 && kmutil showloaded -b io.github.x1ren41l.RTL88WiFi > "$STAGE/current-bundle-loaded.txt" 2>&1; LOADED_RC=$?
find /Volumes -maxdepth 5 -type f -path '*/EFI/OC/config.plist' -print 2>/dev/null > "$STAGE/oc-config-paths.txt"
if [[ -f /EFI/OC/config.plist ]]; then echo /EFI/OC/config.plist >> "$STAGE/oc-config-paths.txt"; fi
if [[ -f "$DRIVER/Info.plist" ]]; then :; fi
python3 - "$STAGE" "$NATIVE" "$LEGACY" "$OS_VERSION" "$OS_BUILD" "$ARCH" "$MODEL" "$CSR" "$CSR_RC" "$NVRAM_CSR" "$NVRAM_CSR_RC" "$NVRAM_ARGS" "$NVRAM_ARGS_RC" "$KERN_ARGS" "$KERN_ARGS_RC" "$LOADED_RC" <<'PY'
from pathlib import Path
import plistlib,sys,re,hashlib
p=Path(sys.argv[1]); native=Path(sys.argv[2]); legacy=Path(sys.argv[3])
osv,build,arch,model,csr,csr_rc,nvcsr,nvcsr_rc,nvargs,nvargs_rc,kargs,kargs_rc,loaded_rc=sys.argv[4:]
def plist(path):
 try: return plistlib.loads((path/'Contents/Info.plist').read_bytes())
 except Exception: return {}
def val(x):
 if isinstance(x,bytes): return x.hex()
 return str(x) if x is not None else '<unset>'
n=plist(native); l=plist(legacy)
report=[]
report.append('RTL88WiFi Stage29h — read-only boot-policy and test-isolation audit')
report.append('HOST: macOS {} / {} / {} / {}'.format(osv,build,arch,model))
report.append('CSRUTIL_STATUS: {}'.format(csr.strip().replace('\n',' | ')))
report.append('CSRUTIL_EXIT: '+csr_rc)
report.append('NVRAM_CSR_ACTIVE_CONFIG: {}'.format(nvcsr.strip().replace('\n',' | ')))
report.append('NVRAM_CSR_QUERY_EXIT: '+nvcsr_rc)
report.append('NVRAM_BOOT_ARGS: {}'.format(nvargs.strip().replace('\n',' | ')))
report.append('NVRAM_BOOT_ARGS_QUERY_EXIT: '+nvargs_rc)
report.append('KERNEL_BOOT_ARGS: {}'.format(kargs.strip().replace('\n',' | ')))
report.append('KERNEL_BOOT_ARGS_QUERY_EXIT: '+kargs_rc)
report.append('CURRENT_TARGET_BUNDLE_LOAD_QUERY_EXIT: '+loaded_rc)
report.append('CURRENT_TARGET_BUNDLE_LOAD_QUERY:')
loaded=(p/'current-bundle-loaded.txt').read_text(errors='replace') if (p/'current-bundle-loaded.txt').exists() else 'kmutil showloaded unavailable or no matching bundle'
report.extend('  '+x for x in loaded.splitlines()[:80])
report.append('')
report.append('=== INSTALLED-TREE CANDIDATES ===')
paths=(p/'oc-config-paths.txt').read_text(errors='replace').splitlines()
report.append('OPENCORE_CONFIG_COUNT: {}'.format(len(paths)))
for cfg in paths:
 try:
  data=plistlib.loads(Path(cfg).read_bytes())
  guid='7C436110-AB2A-4BBB-A880-FE41995C9F82'
  add=data.get('NVRAM',{}).get('Add',{}).get(guid,{})
  delete=data.get('NVRAM',{}).get('Delete',{}).get(guid,[])
  report.append('OPENCORE_CONFIG: '+cfg)
  report.append('  CONFIG_SHA256: '+hashlib.sha256(Path(cfg).read_bytes()).hexdigest())
  report.append('  NVRAM.Add csr-active-config: '+val(add.get('csr-active-config')))
  report.append('  NVRAM.Add boot-args: '+val(add.get('boot-args')))
  report.append('  NVRAM.Delete csr-active-config: '+('YES' if 'csr-active-config' in delete else 'NO'))
 except Exception as e: report.append('OPENCORE_CONFIG_PARSE_ERROR: {}: {}'.format(cfg,e))
if not paths: report.append('No mounted EFI/OC/config.plist found; no OpenCore file was read.')
report.append('')
report.append('=== LEGACY / NATIVE BUNDLE IDENTITY ===')
report.append('LEGACY_BUNDLE_ID: '+str(l.get('CFBundleIdentifier','<missing>')))
report.append('NATIVE_BUNDLE_ID: '+str(n.get('CFBundleIdentifier','<missing>')))
same=bool(l.get('CFBundleIdentifier')) and l.get('CFBundleIdentifier')==n.get('CFBundleIdentifier')
report.append('BUNDLE_IDENTIFIER_COLLISION: '+('YES — mutually exclusive test install required' if same else 'NO'))
report.append('LEGACY_BUNDLE_PRESENT_IN_SOURCE_TREE: '+('YES' if legacy.exists() else 'NO'))
report.append('NATIVE_BUNDLE_PRESENT: '+('YES' if native.exists() else 'NO'))
report.append('')
report.append('=== INTERPRETATION ===')
if 'enabled' in csr.lower(): report.append('SIP currently ENABLED. The approved internal-testing route has not yet been activated.')
elif 'disabled' in csr.lower(): report.append('SIP currently DISABLED. Do not assume this alone makes the kext loadable; check kmutil diagnostics and root:wheel install staging.')
else: report.append('SIP status could not be parsed; do not change security settings until clarified.')
report.append('kext-dev-mode=1 is obsolete and must not be added.')
report.append('No OpenCore configuration, NVRAM variable, SIP setting, filesystem ownership, bundle, or installed kext was changed.')
report.append('STAGE29H: READ_ONLY_AUDIT_COMPLETE')
report.append('NEXT: Build a separate test boot entry/config only after reviewing the detected OpenCore state. Preserve the daily EFI config and working legacy kext.')
report.append('BUILD: NOT RUN'); report.append('INSTALL: NOT RUN'); report.append('LOAD: NOT RUN'); report.append('OPENCORE_CHANGE: NONE'); report.append('KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED')
(p/'stage29h-report.txt').write_text('\n'.join(report)+'\n',encoding='utf-8')
print('\n'.join(report))
PY
RC=$?
{ echo; echo '========== STAGE29H BOOT POLICY / TEST ISOLATION AUDIT =========='; echo "STAGE_DIR: $STAGE"; cat "$STAGE/stage29h-report.txt" 2>/dev/null || true; echo "STAGE29H_ANALYSIS_EXIT: $RC"; echo 'INSTALL: NOT RUN'; echo 'LOAD: NOT RUN'; echo 'OPENCORE_CHANGE: NONE'; echo 'KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED'; } >> "$LOG"
SHA=$(gh api "$API" --jq '.sha') || exit 2
python3 - "$LOG" "$SHA" "$STAGE/payload.json" <<'PY'
import base64,json,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
pathlib.Path(sys.argv[3]).write_text(json.dumps({'message':'Stage29h read-only boot policy and test isolation audit','content':base64.b64encode(data).decode(),'sha':sys.argv[2]}))
PY
gh api --method PUT "$API" --input "$STAGE/payload.json" > "$STAGE/response.json" || exit 2
PUT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["content"]["sha"])' "$STAGE/response.json")
READ=$(gh api "$API" --jq '.sha') || exit 2
[[ -n "$PUT" && "$PUT" == "$READ" ]] || { echo 'GitHub read-back SHA mismatch'; exit 2; }
echo 'GITHUB_UPLOAD_STATUS: SUCCESS — verified Development/output.log'
exit "$RC"
