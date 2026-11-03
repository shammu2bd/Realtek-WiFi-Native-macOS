#!/bin/bash
# Stage 35V — unaligned-safe TX descriptor checksum access.
# Applies one guarded helper-only patch, tests it on deliberately unaligned
# buffers, rebuilds rtl88wifi-native, and rolls back the source patch on failure.
# No signing, install, load, OpenCore modification, or hardware test.
set -Eeuo pipefail

echo "STAGE35V_SCRIPT_VERSION=1"
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW88="$SOURCE_ROOT/driver/rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35V-$RUN"
REPORT="$OUT/report.txt"
DRYRUN="$OUT/native-dry-run.txt"
BUILDLOG="$OUT/native-build.log"
UPLOAD_ERROR="$OUT/upload-error.txt"
DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
mkdir -p "$OUT"
ROLLBACK_ACTIVE=0
FW_BACKUP_ACTIVE=0
trap 'rc=$?; if [[ "$FW_BACKUP_ACTIVE" == 1 ]]; then restore_fw_generated || true; fi; if [[ "$ROLLBACK_ACTIVE" == 1 ]]; then rollback_source || true; fi; echo "STAGE35V_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 make xcrun split shasum tar file lipo plutil grep awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" && -d "$SRC/RTL88WiFiNative.kext" && -f "$SRC/scripts/gen_fw_blobs.py" ]] || { echo "ERROR: Stage26 native build inputs missing"; exit 3; }
[[ -f "$RTW88/tx.h" && -f "$SRC/src/compat/linux/bitfield.h" ]] || { echo "ERROR: TX descriptor or bitfield helper source missing"; exit 4; }
[[ -d "$DEVELOPER_DIR" ]] || { echo "ERROR: Xcode 16.4 Developer directory missing"; exit 5; }
export DEVELOPER_DIR
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
[[ -d "$SDKROOT" ]] || { echo "ERROR: SDKROOT invalid"; exit 6; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 7; }

TXH="$RTW88/tx.h"
BACK="$OUT/backups"
mkdir -p "$BACK"
cp -p "$TXH" "$BACK/tx.h"
SOURCE_BEFORE="$(shasum -a 256 "$TXH" | awk '{print $1}')"
BUILDLOG_DISPLAY="$BUILDLOG"
[[ -n "$BUILDLOG_DISPLAY" ]] || BUILDLOG_DISPLAY="NOT_FOUND"

python3 - "$TXH" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old="""static inline
void fill_txdesc_checksum_common(u8 *txdesc, size_t words)
{
\t__le16 chksum = 0;
\t__le16 *data = (__le16 *)(txdesc);
\tstruct rtw_tx_desc *tx_desc = (struct rtw_tx_desc *)txdesc;

\tle32p_replace_bits(&tx_desc->w7, 0, RTW_TX_DESC_W7_TXDESC_CHECKSUM);

\twhile (words--)
\t\tchksum ^= *data++;

\tle32p_replace_bits(&tx_desc->w7, __le16_to_cpu(chksum),
\t\t\t   RTW_TX_DESC_W7_TXDESC_CHECKSUM);
}"""
if s.count(old)!=1:
    raise SystemExit("PATCH_PREFLIGHT=BLOCKED: common checksum helper did not match exactly once")
print("PATCH_PREFLIGHT=PASS")
print("COMMON_CHECKSUM_HELPER_MATCHES=1")
print("PATCH_SCOPE=common TX checksum helper only")
PY
grep -q 'static inline void le32p_replace_bits' "$SRC/src/compat/linux/bitfield.h" || {
  echo "ERROR: expected le32p_replace_bits helper definition missing"
  exit 8
}

{
  echo "========== STAGE 35V: UNALIGNED-SAFE TX CHECKSUM PATCH + TEST + BUILD =========="
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "source_root=$SOURCE_ROOT"
  echo "target=rtl88wifi-native"
  echo "predecessor=Stage35U run-20261102-015008"
  echo "predecessor_warning=address-of-packed-member in tx.h lines 125 and 130"
  echo "audit_finding=alloc_skb initializes skb->data from kmalloc; skb_reserve can then move data by caller-provided headroom"
  echo "patch_policy=use aligned local __le32 and __le16 objects plus memcpy for byte-buffer access"
  echo "sdkroot=$SDKROOT"
  echo
  echo "--- Source before patch ---"
  echo "tx.h sha256=$SOURCE_BEFORE"
  echo
  echo "--- Relevant original code ---"
  nl -ba "$TXH" | sed -n '112,145p'
  echo
} > "$REPORT"

rollback_source() {
  if [[ "$ROLLBACK_ACTIVE" == 1 ]]; then
    cp -p "$BACK/tx.h" "$TXH"
    ROLLBACK_ACTIVE=0
    echo "SOURCE_PATCH_ROLLBACK=COMPLETED" >> "$REPORT"
  fi
}
restore_fw_generated() {
  if [[ "$FW_BACKUP_ACTIVE" == 1 ]]; then
    if [[ "$FW_ORIG_PRESENT" == 1 ]]; then cp -p "$FW_BACKUP" "$FW_GENERATED"; else rm -f "$FW_GENERATED"; fi
    FW_BACKUP_ACTIVE=0
  fi
}

python3 - "$TXH" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old="""static inline
void fill_txdesc_checksum_common(u8 *txdesc, size_t words)
{
\t__le16 chksum = 0;
\t__le16 *data = (__le16 *)(txdesc);
\tstruct rtw_tx_desc *tx_desc = (struct rtw_tx_desc *)txdesc;

\tle32p_replace_bits(&tx_desc->w7, 0, RTW_TX_DESC_W7_TXDESC_CHECKSUM);

\twhile (words--)
\t\tchksum ^= *data++;

\tle32p_replace_bits(&tx_desc->w7, __le16_to_cpu(chksum),
\t\t\t   RTW_TX_DESC_W7_TXDESC_CHECKSUM);
}"""
new="""static inline
void fill_txdesc_checksum_common(u8 *txdesc, size_t words)
{
\t__le16 chksum = 0;
\tu8 *checksum_ptr = txdesc + (7 * sizeof(__le32));
\t__le32 checksum_word;

\tmemcpy(&checksum_word, checksum_ptr, sizeof(checksum_word));
\tle32p_replace_bits(&checksum_word, 0, RTW_TX_DESC_W7_TXDESC_CHECKSUM);
\tmemcpy(checksum_ptr, &checksum_word, sizeof(checksum_word));

\twhile (words--) {
\t\t__le16 data;
\t\tmemcpy(&data, txdesc, sizeof(data));
\t\tchksum ^= data;
\t\ttxdesc += sizeof(data);
\t}

\tmemcpy(&checksum_word, checksum_ptr, sizeof(checksum_word));
\tle32p_replace_bits(&checksum_word, __le16_to_cpu(chksum),
\t\t\t   RTW_TX_DESC_W7_TXDESC_CHECKSUM);
\tmemcpy(checksum_ptr, &checksum_word, sizeof(checksum_word));
}"""
if s.count(old)!=1:
    raise SystemExit("PATCH_FAILED: expected helper text not unique")
p.write_text(s.replace(old,new,1))
print("PATCH_APPLIED=YES")
print("PACKED_MEMBER_ADDRESS_OPERATIONS_REMAINING_IN_HELPER=NO")
print("UNALIGNED_TYPED_HALFWORD_DEREFERENCES_REMAINING_IN_HELPER=NO")
PY
ROLLBACK_ACTIVE=1

python3 - "$TXH" "$OUT/checksum_alignment_test.c" <<'PY'
import pathlib,sys
src=pathlib.Path(sys.argv[1]).read_text()
out=pathlib.Path(sys.argv[2])
needle="static inline\nvoid fill_txdesc_checksum_common("
start=src.find(needle)
if start<0 or src.find(needle,start+1)>=0:
    raise SystemExit("TEST_HARNESS_FAILED: patched helper marker not unique")
brace=src.find("{",start)
depth=0; end=None
for i in range(brace,len(src)):
    if src[i]=="{": depth+=1
    elif src[i]=="}":
        depth-=1
        if depth==0:
            end=i+1; break
if end is None: raise SystemExit("TEST_HARNESS_FAILED: helper braces not balanced")
helper=src[start:end]
pre=r"""
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint16_t __le16;
typedef uint32_t __le32;
#define RTW_TX_DESC_W7_TXDESC_CHECKSUM 0x0000ffffU
#define __le16_to_cpu(x) (x)
static inline void u32p_replace_bits(u32 *p, u32 value, u32 mask) {
    unsigned int shift = (unsigned int)__builtin_ctz(mask);
    *p = (*p & ~mask) | ((value << shift) & mask);
}
static inline void le32p_replace_bits(__le32 *p, u32 value, u32 mask) {
    u32 tmp = (u32)*p;
    u32p_replace_bits(&tmp, value, mask);
    *p = (__le32)tmp;
}
"""
post=r"""
static uint16_t reference_checksum(uint8_t *data, size_t words) {
    uint16_t sum = 0;
    data[28] = 0;
    data[29] = 0;
    for (size_t i=0; i<words; ++i) {
        uint16_t value = (uint16_t)data[2*i] | ((uint16_t)data[2*i+1] << 8);
        sum ^= value;
    }
    data[28] = (uint8_t)(sum & 0xff);
    data[29] = (uint8_t)(sum >> 8);
    return sum;
}
int main(void) {
    static const size_t word_counts[] = {16, 20, 24, 32, 40};
    unsigned int cases = 0;
    for (size_t offset=0; offset<16; ++offset) {
        for (size_t wi=0; wi<sizeof(word_counts)/sizeof(word_counts[0]); ++wi) {
            uint8_t actual_storage[192], expected_storage[192], once_storage[192];
            for (size_t i=0; i<sizeof(actual_storage); ++i)
                actual_storage[i]=(uint8_t)((i*37U + offset*19U + wi*11U + 0x5dU) & 0xffU);
            memcpy(expected_storage, actual_storage, sizeof(actual_storage));
            uint8_t *actual=actual_storage+offset;
            uint8_t *expected=expected_storage+offset;
            size_t words=word_counts[wi];
            uint8_t high0=actual[30], high1=actual[31];
            reference_checksum(expected, words);
            fill_txdesc_checksum_common(actual, words);
            if (memcmp(actual, expected, words*2)!=0) {
                fprintf(stderr,"FAIL offset=%zu words=%zu checksum/data mismatch\n",offset,words);
                return 1;
            }
            if (actual[30]!=high0 || actual[31]!=high1) {
                fprintf(stderr,"FAIL offset=%zu words=%zu W7 high half changed\n",offset,words);
                return 2;
            }
            memcpy(once_storage, actual_storage, sizeof(actual_storage));
            fill_txdesc_checksum_common(actual, words);
            if (memcmp(actual_storage, once_storage, sizeof(actual_storage))!=0) {
                fprintf(stderr,"FAIL offset=%zu words=%zu non-idempotent result\n",offset,words);
                return 3;
            }
            ++cases;
        }
    }
    printf("CHECKSUM_ALIGNMENT_TEST=PASS\n");
    printf("ALIGNMENT_OFFSETS_TESTED=16\n");
    printf("WORD_COUNTS_TESTED=5\n");
    printf("TOTAL_CASES=%u\n",cases);
    printf("HIGH_HALFWORD_PRESERVED=YES\n");
    printf("REPEATED_CALL_IDEMPOTENT=YES\n");
    return 0;
}
"""
out.write_text(pre+helper+"\n"+post)
PY
xcrun clang -std=c11 -Wall -Wextra -Werror "$OUT/checksum_alignment_test.c" -o "$OUT/checksum_alignment_test"
"$OUT/checksum_alignment_test" >> "$REPORT"
echo "CHECKSUM_ALIGNMENT_TEST_EXIT=0" >> "$REPORT"

(cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -n -B -f Makefile rtl88wifi-native) > "$DRYRUN" 2>&1
python3 - "$DRYRUN" "$SRC" <<'PY' >> "$REPORT"
import pathlib,re,shlex,sys
p,src=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
issues=[]; compiler=[]; generator=0; rsync=0
for n,line in enumerate(p.read_text(errors="replace").splitlines(),1):
    t=line.strip()
    if not t: continue
    if t.startswith("xcrun clang ") or t.startswith("xcrun clang++ "):
        if re.search(r"\b(sudo|kextload|kmutil|bless|systemextensionsctl)\b|/Library/Extensions|EFI/OC|OpenCore",t,re.I):
            issues.append("FORBIDDEN_DESTINATION_OR_TOOL line %d"%n)
        compiler.append(t); continue
    try: argv=shlex.split(t,posix=True)
    except ValueError:
        issues.append("UNPARSEABLE_RECIPE line %d"%n); continue
    if not argv: continue
    exe=pathlib.PurePath(argv[0]).name
    if exe=="mkdir" and len(argv)==3 and argv[1]=="-p" and argv[2].startswith(str(src)+"/build/"):
        continue
    if exe=="echo": continue
    if exe=="python3" and argv==["python3",str(src/"scripts/gen_fw_blobs.py"),str(src/"firmware"),str(src/"src/compat/fw_blobs.c")]:
        generator+=1; continue
    if exe=="rsync" and argv==["rsync","-a","--exclude=MacOS",str(src)+"/RTL88WiFiNative.kext/",str(src)+"/build/out/RTL88WiFiNative.kext/"]:
        rsync+=1; continue
    issues.append("UNEXPECTED_RECIPE line %d: %s"%(n,t[:280]))
compiles=sum(bool(re.search(r"\s-c\s",x)) for x in compiler)
links=sum(bool("-static" in x and "-nostdlib" in x and "-Xlinker -kext" in x) for x in compiler)
for x in issues: print("DRYRUN_BLOCKER="+x)
ok=not issues and compiles>=30 and links==1 and generator==1 and rsync==1
print("DRYRUN_COMPILER_COMMANDS=%d"%len(compiler))
print("DRYRUN_COMPILE_COMMANDS=%d"%compiles)
print("DRYRUN_KEXT_LINK_COMMANDS=%d"%links)
print("DRYRUN_FIRMWARE_GENERATOR_COMMANDS=%d"%generator)
print("DRYRUN_KEXT_TEMPLATE_RSYNC_COMMANDS=%d"%rsync)
print("DRYRUN_PREFLIGHT="+("PASS" if ok else "BLOCKED"))
if not ok: raise SystemExit(9)
PY

FW_GENERATED="$SRC/src/compat/fw_blobs.c"
FW_BACKUP="$BACK/fw_blobs.c"
FW_ORIG_PRESENT=0
if [[ -f "$FW_GENERATED" ]]; then cp -p "$FW_GENERATED" "$FW_BACKUP"; FW_ORIG_PRESENT=1; fi
FW_BACKUP_ACTIVE=1
trap 'rc=$?; if [[ "$FW_BACKUP_ACTIVE" == 1 ]]; then restore_fw_generated || true; fi; if [[ "$ROLLBACK_ACTIVE" == 1 ]]; then rollback_source || true; fi; echo "STAGE35V_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

set +e
(cd "$SRC" && env -u MAKEFLAGS -u MFLAGS -u MAKEFILES make -B -f Makefile rtl88wifi-native) > "$BUILDLOG" 2>&1
BUILD_RC=$?
set -e
restore_fw_generated

{
  echo
  echo "--- Native build results ---"
  echo "NATIVE_BUILD_EXIT=$BUILD_RC"
  echo "NATIVE_BUILD_LOG_BYTES=$(wc -c < "$BUILDLOG" | tr -d ' ')"
  echo "NATIVE_BUILD_LOG_LINES=$(wc -l < "$BUILDLOG" | tr -d ' ')"
  echo "COMPILE_ERROR_LINES=$(grep -Ec '(^|: )(fatal error:|error:)' "$BUILDLOG" || true)"
  echo "WARNING_LINES=$(grep -Ec 'warning:' "$BUILDLOG" || true)"
  echo "PACKED_MEMBER_WARNING_LINES=$(grep -Ec 'address-of-packed-member' "$BUILDLOG" || true)"
  echo "CONDITIONAL_UNINITIALIZED_WARNING_LINES=$(grep -Ec 'conditional-uninitialized' "$BUILDLOG" || true)"
  echo "OFFSETOF_WARNING_LINES=$(grep -Ec 'invalid offsetof' "$BUILDLOG" || true)"
  echo
  echo "--- Remaining packed-member warning matches ---"
  grep -n 'address-of-packed-member' "$BUILDLOG" | head -80 || true
  echo
  echo "--- Build tail ---"
  tail -100 "$BUILDLOG"
} >> "$REPORT"

KEXT="$SRC/build/out/RTL88WiFiNative.kext"
ARTIFACT=""
ARTIFACT_REMOTE=""
ARTIFACT_BLOB="NONE"
ARTIFACT_SHA=""
ARTIFACT_BYTES=0
if [[ "$BUILD_RC" -eq 0 && -f "$KEXT/Contents/MacOS/RTL88WiFiNative" && -f "$KEXT/Contents/Info.plist" ]]; then
  set +e
  FILE_INFO="$(file "$KEXT/Contents/MacOS/RTL88WiFiNative" 2>&1)"; FILE_RC=$?
  LIPO_INFO="$(lipo -info "$KEXT/Contents/MacOS/RTL88WiFiNative" 2>&1)"; LIPO_RC=$?
  PLIST_INFO="$(plutil -lint "$KEXT/Contents/Info.plist" 2>&1)"; PLIST_RC=$?
  set -e
  {
    echo "KEXT_EXECUTABLE_FILE_RC=$FILE_RC"
    echo "KEXT_EXECUTABLE_FILE=$FILE_INFO"
    echo "KEXT_LIPO_INFO_RC=$LIPO_RC"
    echo "KEXT_ARCHITECTURES=$LIPO_INFO"
    echo "KEXT_PLUTIL_LINT_RC=$PLIST_RC"
    echo "KEXT_INFO_PLIST_VALIDATION=$PLIST_INFO"
  } >> "$REPORT"
  if [[ "$FILE_RC" -ne 0 || "$LIPO_RC" -ne 0 || "$PLIST_RC" -ne 0 || "$FILE_INFO" != *"x86_64"* || "$LIPO_INFO" != *"x86_64"* || "$PLIST_INFO" != *"OK"* ]]; then
    echo "BUILD_VALIDATION=FAIL" >> "$REPORT"
    BUILD_RC=98
  else
    echo "BUILD_VALIDATION=PASS" >> "$REPORT"
  fi
fi
if [[ "$BUILD_RC" -eq 0 && ( ! -f "$KEXT/Contents/MacOS/RTL88WiFiNative" || ! -f "$KEXT/Contents/Info.plist" ) ]]; then
  echo "BUILD_VALIDATION=FAIL_MISSING_KEXT_FILES" >> "$REPORT"
  BUILD_RC=97
fi

if [[ "$BUILD_RC" -eq 0 ]]; then
  ARTIFACT="$OUT/RTL88WiFiNative-$RUN.tar.gz"
  tar -czf "$ARTIFACT" -C "$SRC/build/out" RTL88WiFiNative.kext
  ARTIFACT_BYTES="$(wc -c < "$ARTIFACT" | tr -d ' ')"
  ARTIFACT_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
  echo "KEXT_ARCHIVE_BYTES=$ARTIFACT_BYTES" >> "$REPORT"
  echo "KEXT_ARCHIVE_SHA256=$ARTIFACT_SHA" >> "$REPORT"
  ROLLBACK_ACTIVE=0
  echo "SOURCE_PATCH_PERSISTED=YES" >> "$REPORT"
else
  rollback_source
  echo "SOURCE_PATCH_PERSISTED=NO" >> "$REPORT"
fi

SOURCE_AFTER="$(shasum -a 256 "$TXH" | awk '{print $1}')"
{
  echo
  echo "--- Final source and safety status ---"
  echo "TXH_SHA256_BEFORE=$SOURCE_BEFORE"
  echo "TXH_SHA256_AFTER=$SOURCE_AFTER"
  echo "GENERATED_FW_SOURCE_RESTORED=YES"
  echo "SOURCE_PATCH_ROLLED_BACK=$([[ "$BUILD_RC" -eq 0 ]] && echo NO || echo YES)"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "CODESIGN=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
  echo "HARDWARE_TEST=NOT_RUN"
  echo "========== END STAGE 35V =========="
} >> "$REPORT"

upload_file() {
  local f="$1" path="$2" msg="$3" payload="$4" response="$5" old put got
  old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
  python3 - "$f" "$old" "$msg" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,sha,msg,dest=sys.argv[1:]
v={"message":msg,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha: v["sha"]=sha
pathlib.Path(dest).write_text(json.dumps(v))
PY2
  if ! gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" >"$response" 2>"$UPLOAD_ERROR"; then
    echo "UPLOAD_FAILED_PATH=$path" >>"$UPLOAD_ERROR"; return 1
  fi
  put="$(python3 - "$response" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); s=(v.get("content") or {}).get("sha")
if not s: raise SystemExit("Missing returned blob SHA")
print(s)
PY2
)"
  got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
  [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >>"$UPLOAD_ERROR"; return 1; }
  UPLOAD_SHA="$got"
}

if [[ -n "$ARTIFACT" ]]; then
  ARTIFACT_REMOTE="Development/Artifacts/stage35v/RTL88WiFiNative-$RUN.tar.gz"
  upload_file "$ARTIFACT" "$ARTIFACT_REMOTE" "Add Stage35V native Kext artifact $RUN" "$OUT/artifact-upload.json" "$OUT/artifact-upload-response.json"
  ARTIFACT_BLOB="$UPLOAD_SHA"
  echo "KEXT_ARCHIVE_GITHUB_PATH=$ARTIFACT_REMOTE" >> "$REPORT"
  echo "KEXT_ARCHIVE_GITHUB_BLOB=$ARTIFACT_BLOB" >> "$REPORT"
fi

mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"
MANIFEST="$OUT/manifest.txt"
ARTIFACT_PATH="$ARTIFACT_REMOTE"; [[ -n "$ARTIFACT_PATH" ]] || ARTIFACT_PATH="NONE"
ARTIFACT_SHA_VALUE="$ARTIFACT_SHA"; [[ -n "$ARTIFACT_SHA_VALUE" ]] || ARTIFACT_SHA_VALUE="NONE"
printf 'STAGE: 35V\nRUN: %s\nTARGET: rtl88wifi-native\nBUILD_EXIT: %s\nPATCH_SCOPE: unaligned-safe common TX checksum helper\nARTIFACT_PATH: %s\nARTIFACT_BLOB: %s\nARTIFACT_SHA256: %s\nARTIFACT_BYTES: %s\n' "$RUN" "$BUILD_RC" "$ARTIFACT_PATH" "$ARTIFACT_BLOB" "$ARTIFACT_SHA_VALUE" "$ARTIFACT_BYTES" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage35v/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage35V build report $RUN/$name" "$OUT/log-upload.json" "$OUT/log-upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35v/$RUN/manifest.txt" "Add Stage35V manifest $RUN" "$OUT/manifest-upload.json" "$OUT/manifest-upload-response.json"

echo "STAGE35V_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35V_RUN=$RUN"
echo "STAGE35V_BUILD_EXIT=$BUILD_RC"
echo "STAGE35V_PATCH_PERSISTED=$([[ "$BUILD_RC" -eq 0 ]] && echo YES || echo NO)"
echo "STAGE35V_REPORT_PARTS=$COUNT"
echo "STAGE35V_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35v/$RUN"
trap - ERR
exit "$BUILD_RC"
