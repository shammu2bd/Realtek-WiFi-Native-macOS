#!/bin/bash
# Stage165: retry the IO80211WorkQueue symbol-provider query with an explicit
# kmutil repository containing the temporary KEXT bundle.
# No project source/build outputs, install/load, AuxKC, or OpenCore changes.
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
EXPECTED_HEAD="3d02ef10e353bb80d032980ffe2e7d28b90fd7da"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE163_PATH="Development/Logs/stage163-workqueue-export-sdk-abi-20261107T055441Z.log"
STAGE163_SHA="d5f10cd40dd568907bc0712afeb0554383b033ac"
STAGE164_PATH="Development/Logs/stage164-kmutil-workqueue-symbol-provider-20261107T060242Z.log"
STAGE164_SHA="314ac400f81e698c2dfa3c216efd86d3f1e3765b"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
[[ -n "$TMPROOT" ]] || TMPROOT="/tmp"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside project checkout"; exit 2; }
cd "$ROOT"

[[ "$(git rev-parse HEAD)" == "$EXPECTED_HEAD" ]] || { echo "ERROR: source HEAD mismatch"; exit 3; }
[[ "$(git remote get-url origin 2>/dev/null || true)" == *"Realtek-WiFi-Native-macOS"* ]] || { echo "ERROR: unexpected origin"; exit 4; }
OS="$(sw_vers -productVersion)"
BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || {
  echo "ERROR: target mismatch $OS $BUILD $ARCH"; exit 5;
}
for c in curl gh python3 shasum nm plutil xcrun kmutil file lipo; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 6; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 7; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 8; }
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch"; exit 9; }

STAGE163_ACTUAL="$(gh api "repos/$REPO/contents/$STAGE163_PATH?ref=main" --jq '.sha')"
[[ "$STAGE163_ACTUAL" == "$STAGE163_SHA" ]] || { echo "ERROR: Stage163 report SHA mismatch"; exit 10; }
STAGE164_ACTUAL="$(gh api "repos/$REPO/contents/$STAGE164_PATH?ref=main" --jq '.sha')"
[[ "$STAGE164_ACTUAL" == "$STAGE164_SHA" ]] || { echo "ERROR: Stage164 report SHA mismatch"; exit 10; }

SDK="$(xcrun --sdk macosx --show-sdk-path)"
MKSDK="$ROOT/driver/RTL88WiFi/MacKernelSDK"
KMOD_SRC="$ROOT/driver/RTL88WiFi/src/kext/kmod_info.c"
BASE_INFO="$ROOT/driver/RTL88WiFi/RTL88WiFi.kext/Contents/Info.plist"
PLIST_GENERATOR="$ROOT/tools/generate-sequoia-native-plist.py"
CONTROLLER_HEADER="$ROOT/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.hpp"
LIBKMOD="$MKSDK/Library/x86_64/libkmod.a"
for p in "$KMOD_SRC" "$BASE_INFO" "$LIBKMOD" "$PLIST_GENERATOR" "$CONTROLLER_HEADER"; do
  [[ -r "$p" ]] || { echo "ERROR: missing required input $p"; exit 11; }
done
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BASE_INFO")"
[[ "$BUNDLE_ID" == "io.github.x1ren41l.RTL88WiFi" ]] || { echo "ERROR: unexpected probe bundle identity $BUNDLE_ID"; exit 12; }

WORK="$(mktemp -d "$TMPROOT/stage165-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage165-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
STATUS_BEFORE="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPOSITORY="$WORK/repository"
PROBE_KEXT="$REPOSITORY/RTL88WiFiNative.kext"
mkdir -p "$PROBE_KEXT/Contents/MacOS"
python3 "$PLIST_GENERATOR" --base-plist "$BASE_INFO" --controller-header "$CONTROLLER_HEADER" --output "$PROBE_KEXT/Contents/Info.plist" > "$WORK/plist-generator.txt"

cat > "$WORK/workqueue_symbol_probe.cpp" <<'CPP'
class IO80211WorkQueue;
extern "C" IO80211WorkQueue *stage165_workqueue_factory_probe(void)
    __asm__("__ZN16IO80211WorkQueue9workQueueEv");

extern "C" __attribute__((used, noinline))
IO80211WorkQueue *stage165_reference_workqueue_factory(void)
{
    return stage165_workqueue_factory_probe();
}
CPP

{
  echo "========== STAGE165 KMUTIL EXPLICIT-REPOSITORY SYMBOL-PROVIDER AUDIT =========="
  echo "STAGE165_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
  echo "STAGE165_HEAD=$(git rev-parse HEAD)"
  echo "STAGE165_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
  echo "STAGE165_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
  echo "STAGE165_BOOTKC_SHA256=$BOOT_SHA"
  echo "STAGE165_STAGE163_REPORT_SHA=$STAGE163_ACTUAL"
  echo "STAGE165_STAGE164_REPORT_SHA=$STAGE164_ACTUAL"
  echo "STAGE165_SDK=$SDK"
  echo "STAGE165_BUNDLE_ID=$BUNDLE_ID"
  echo "STAGE165_SCOPE=TEMPORARY_KEXT_LINK_AND_KMUTIL_REPOSITORY_DISCOVERY"
  echo "STAGE165_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE165_INSTALL=NOT_RUN LOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"

  echo
  echo "===== NATIVE PROBE PLIST VALIDATION ====="
  cat "$WORK/plist-generator.txt"
  plutil -lint "$PROBE_KEXT/Contents/Info.plist"
  PLIST_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PROBE_KEXT/Contents/Info.plist")"
  [[ "$PLIST_EXECUTABLE" == "RTL88WiFiNative" ]] || { echo "PROBE_PLIST_EXECUTABLE=FAIL"; exit 13; }
  echo "PROBE_PLIST_LINT=PASS"
  echo "PROBE_PLIST_EXECUTABLE=$PLIST_EXECUTABLE"
  echo "PROBE_KEXT_REPOSITORY=$REPOSITORY"
  echo "PROBE_KEXT_BUNDLE=$PROBE_KEXT"
  echo "PROBE_KEXT_BUNDLE_LAYOUT=PASS"

  echo
  echo "===== KMOD INFO COMPILE ====="
  xcrun clang -fno-exceptions -fno-rtti -fno-stack-protector -mkernel \
    -arch x86_64 -mmacosx-version-min=13.0 -isysroot "$SDK" \
    -I"$MKSDK/Headers" -I"$SDK/System/Library/Frameworks/Kernel.framework/Headers" \
    -DRTW88_AIRPORT_KMOD=1 -c "$KMOD_SRC" -o "$WORK/kmod_info.o"

  echo
  echo "===== FACTORY PROBE COMPILE ====="
  xcrun clang++ -fno-exceptions -fno-rtti -fno-stack-protector -mkernel \
    -arch x86_64 -mmacosx-version-min=13.0 -isysroot "$SDK" \
    -I"$MKSDK/Headers" -I"$SDK/System/Library/Frameworks/Kernel.framework/Headers" \
    -fapple-kext -std=c++17 -DKERNEL -D__IO80211_TARGET=__MAC_15_2 \
    -c "$WORK/workqueue_symbol_probe.cpp" -o "$WORK/workqueue_symbol_probe.o"

  echo
  echo "===== TEMPORARY KEXT LINK ====="
  xcrun clang++ -arch x86_64 -static -nostdlib -Xlinker -kext \
    "$LIBKMOD" -Xlinker -undefined -Xlinker dynamic_lookup \
    -o "$PROBE_KEXT/Contents/MacOS/RTL88WiFiNative" \
    "$WORK/kmod_info.o" "$WORK/workqueue_symbol_probe.o"
  [[ -s "$PROBE_KEXT/Contents/MacOS/RTL88WiFiNative" && -x "$PROBE_KEXT/Contents/MacOS/RTL88WiFiNative" ]] || {
    echo "TEMP_KEXT_EXECUTABLE=FAIL"; exit 14;
  }
  echo "TEMP_KEXT_LINK=PASS"
  echo "TEMP_KEXT_EXECUTABLE=PASS"
  echo "TEMP_KEXT_BINARY_SHA256=$(shasum -a 256 "$PROBE_KEXT/Contents/MacOS/RTL88WiFiNative" | awk '{print $1}')"
  file "$PROBE_KEXT/Contents/MacOS/RTL88WiFiNative"
  lipo -archs "$PROBE_KEXT/Contents/MacOS/RTL88WiFiNative"

  echo
  echo "===== UNDEFINED FACTORY SYMBOL CHECK ====="
  nm -u "$PROBE_KEXT/Contents/MacOS/RTL88WiFiNative" > "$WORK/undefined.txt"
  if grep -F "__ZN16IO80211WorkQueue9workQueueEv" "$WORK/undefined.txt"; then
    echo "FACTORY_UNDEFINED_IMPORT=PASS"
  else
    echo "FACTORY_UNDEFINED_IMPORT=FAIL"
    exit 15
  fi

  echo
  echo "===== KMUTIL LIBRARIES: EXPLICIT REPOSITORY + BUNDLE PATH ====="
  echo "KMUTIL_COMMAND=kmutil libraries -r <temporary-repository> -p <temporary-kext-bundle> --all-symbols"
  set +e
  kmutil libraries -r "$REPOSITORY" -p "$PROBE_KEXT" --all-symbols > "$WORK/kmutil-all-symbols.txt" 2>&1
  KMUTIL_ALL_RC=$?
  set -e
  cat "$WORK/kmutil-all-symbols.txt"
  echo "KMUTIL_ALL_SYMBOLS_EXIT=$KMUTIL_ALL_RC"
  if grep -Eiq 'IO80211WorkQueue.*workQueue|workQueue.*IO80211WorkQueue|__ZN16IO80211WorkQueue9workQueueEv' "$WORK/kmutil-all-symbols.txt"; then
    echo "KMUTIL_ALL_FACTORY_SYMBOL_LISTED=YES"
  else
    echo "KMUTIL_ALL_FACTORY_SYMBOL_LISTED=NO"
  fi

  echo
  echo "===== KMUTIL LIBRARIES: UNIQUE PROVIDER LIST ====="
  set +e
  kmutil libraries -r "$REPOSITORY" -p "$PROBE_KEXT" --onedef-symbols > "$WORK/kmutil-onedef-symbols.txt" 2>&1
  KMUTIL_ONEDEF_RC=$?
  set -e
  cat "$WORK/kmutil-onedef-symbols.txt"
  echo "KMUTIL_ONEDEF_SYMBOLS_EXIT=$KMUTIL_ONEDEF_RC"
  if grep -Fq "__ZN16IO80211WorkQueue9workQueueEv" "$WORK/kmutil-onedef-symbols.txt"; then
    echo "KMUTIL_ONEDEF_FACTORY_SYMBOL_LISTED=YES"
  else
    echo "KMUTIL_ONEDEF_FACTORY_SYMBOL_LISTED=NO"
  fi
  if grep -Fq "com.apple.iokit.IO80211Family" "$WORK/kmutil-onedef-symbols.txt"; then
    echo "KMUTIL_ONEDEF_IO80211FAMILY_PROVIDER_LISTED=YES"
  else
    echo "KMUTIL_ONEDEF_IO80211FAMILY_PROVIDER_LISTED=NO"
  fi
  echo "===== UNIQUE-PROVIDER SYMBOL CONTEXT ====="
  grep -F -C 3 "__ZN16IO80211WorkQueue9workQueueEv" "$WORK/kmutil-onedef-symbols.txt" || true

  if [[ "$KMUTIL_ALL_RC" -eq 0 && "$KMUTIL_ONEDEF_RC" -eq 0 ]] &&
     grep -Fq "__ZN16IO80211WorkQueue9workQueueEv" "$WORK/kmutil-onedef-symbols.txt" &&
     grep -Fq "com.apple.iokit.IO80211Family" "$WORK/kmutil-onedef-symbols.txt"; then
    echo "STAGE165_SYMBOL_PROVIDER_RESULT=PASS_UNIQUE_FACTORY_PROVIDER_REPORTED"
  else
    echo "STAGE165_SYMBOL_PROVIDER_RESULT=REVIEW_REQUIRED"
  fi

  echo
  echo "===== PROJECT PRESERVATION CHECK ====="
  STATUS_AFTER="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
  echo "PROJECT_STATUS_BEFORE_SHA=$STATUS_BEFORE"
  echo "PROJECT_STATUS_AFTER_SHA=$STATUS_AFTER"
  [[ "$STATUS_BEFORE" == "$STATUS_AFTER" ]] || { echo "PROJECT_WORKTREE_PRESERVATION=FAIL"; exit 16; }
  echo "PROJECT_WORKTREE_PRESERVATION=PASS"
  echo "STAGE165_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE165_INSTALL=NOT_RUN LOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
  echo "========== END STAGE165 =========="
} > "$REPORT" 2>&1

echo "===== STAGE165 SUMMARY ====="
grep -aE '^(STAGE165_|PROBE_PLIST_LINT=|PROBE_PLIST_EXECUTABLE=|TEMP_KEXT_LINK=|TEMP_KEXT_EXECUTABLE=|FACTORY_UNDEFINED_IMPORT=|KMUTIL_ALL_SYMBOLS_EXIT=|KMUTIL_ALL_FACTORY_SYMBOL_LISTED=|KMUTIL_ONEDEF_SYMBOLS_EXIT=|KMUTIL_ONEDEF_FACTORY_SYMBOL_LISTED=|KMUTIL_ONEDEF_IO80211FAMILY_PROVIDER_LISTED=|STAGE165_SYMBOL_PROVIDER_RESULT=|PROJECT_WORKTREE_PRESERVATION=)' "$REPORT" || true

python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage165-kmutil-repository-bundle-discovery-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage165: publish kmutil explicit-repository symbol-provider audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
    with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
        json.dump(payload,f); f.flush()
        r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
    if r.returncode==0:
        try: actual=json.loads(r.stdout).get("content",{}).get("sha")
        except Exception: actual=None
        if actual==expected:
            verify=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main","--jq",".sha"],capture_output=True,text=True)
            if verify.returncode==0 and verify.stdout.strip()==expected:
                print("STAGE165_UPLOAD_SHA="+actual)
                print("STAGE165_GITHUB_PATH="+dest)
                print("STAGE165_UPLOAD=PASS_VERIFIED")
                break
    last=r.stderr.strip() or r.stdout.strip()
    check=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main","--jq",".sha"],capture_output=True,text=True)
    if check.returncode==0 and check.stdout.strip()==expected:
        print("STAGE165_UPLOAD_SHA="+expected)
        print("STAGE165_GITHUB_PATH="+dest)
        print("STAGE165_UPLOAD=PASS_RECOVERED")
        break
    if check.returncode==0 and check.stdout.strip():
        print("STAGE165_UPLOAD_CONFLICT="+check.stdout.strip())
        raise SystemExit(20)
    if attempt<3: time.sleep(attempt*3)
else:
    print("STAGE165_UPLOAD=FAILED")
    print(last)
    raise SystemExit(21)
PY
