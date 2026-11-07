#!/bin/bash
# Stage164: temporary third-party KEXT symbol-provider audit for IO80211WorkQueue.
# No project source/build artifacts, install/load, AuxKC, or OpenCore changes.
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
EXPECTED_HEAD="3d02ef10e353bb80d032980ffe2e7d28b90fd7da"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE163_PATH="Development/Logs/stage163-workqueue-export-sdk-abi-20261107T055441Z.log"
STAGE163_SHA="d5f10cd40dd568907bc0712afeb0554383b033ac"
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
for c in curl gh python3 shasum nm plutil xcrun kmutil; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 6; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 7; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 8; }
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch"; exit 9; }

STAGE163_ACTUAL="$(gh api "repos/$REPO/contents/$STAGE163_PATH?ref=main" --jq '.sha')"
[[ "$STAGE163_ACTUAL" == "$STAGE163_SHA" ]] || { echo "ERROR: Stage163 report SHA mismatch"; exit 10; }

SDK="$(xcrun --sdk macosx --show-sdk-path)"
MKSDK="$ROOT/driver/RTL88WiFi/MacKernelSDK"
KMOD_SRC="$ROOT/driver/RTL88WiFi/src/kext/kmod_info.c"
BASE_INFO="$ROOT/driver/RTL88WiFi/RTL88WiFiNative.kext/Contents/Info.plist"
LIBKMOD="$MKSDK/Library/x86_64/libkmod.a"
for p in "$KMOD_SRC" "$BASE_INFO" "$LIBKMOD"; do
  [[ -r "$p" ]] || { echo "ERROR: missing required input $p"; exit 11; }
done
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BASE_INFO")"
[[ "$BUNDLE_ID" == "io.github.x1ren41l.RTL88WiFi" ]] || { echo "ERROR: unexpected probe bundle identity $BUNDLE_ID"; exit 12; }

WORK="$(mktemp -d "$TMPROOT/stage164-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage164-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
STATUS_BEFORE="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PROBE_KEXT="$WORK/RTL88WiFiNative.kext"
mkdir -p "$PROBE_KEXT/Contents/MacOS"
cp "$BASE_INFO" "$PROBE_KEXT/Contents/Info.plist"

cat > "$WORK/workqueue_symbol_probe.cpp" <<'CPP'
class IO80211WorkQueue;
extern "C" IO80211WorkQueue *stage164_workqueue_factory_probe(void)
    __asm__("__ZN16IO80211WorkQueue9workQueueEv");

extern "C" __attribute__((used, noinline))
IO80211WorkQueue *stage164_reference_workqueue_factory(void)
{
    return stage164_workqueue_factory_probe();
}
CPP

{
  echo "========== STAGE164 KMUTIL WORKQUEUE SYMBOL-PROVIDER AUDIT =========="
  echo "STAGE164_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
  echo "STAGE164_HEAD=$(git rev-parse HEAD)"
  echo "STAGE164_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
  echo "STAGE164_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
  echo "STAGE164_BOOTKC_SHA256=$BOOT_SHA"
  echo "STAGE164_STAGE163_REPORT_SHA=$STAGE163_ACTUAL"
  echo "STAGE164_SDK=$SDK"
  echo "STAGE164_BUNDLE_ID=$BUNDLE_ID"
  echo "STAGE164_SCOPE=TEMPORARY_KEXT_LINK_AND_KMUTIL_SYMBOL_PROVIDER_QUERY"
  echo "STAGE164_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE164_INSTALL=NOT_RUN LOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"

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
  echo "===== TEMPORARY KEXT LINK (NO SOURCE TARGET) ====="
  xcrun clang++ -arch x86_64 -static -nostdlib -Xlinker -kext \
    "$LIBKMOD" -Xlinker -undefined -Xlinker dynamic_lookup \
    -o "$PROBE_KEXT/Contents/MacOS/RTL88WiFiNative" \
    "$WORK/kmod_info.o" "$WORK/workqueue_symbol_probe.o"

  echo "TEMP_KEXT_LINK=PASS"
  echo "TEMP_KEXT_PATH=$PROBE_KEXT"
  echo "TEMP_KEXT_BINARY_SHA256=$(shasum -a 256 "$PROBE_KEXT/Contents/MacOS/RTL88WiFiNative" | awk '{print $1}')"

  echo
  echo "===== UNDEFINED FACTORY SYMBOL CHECK ====="
  nm -u "$PROBE_KEXT/Contents/MacOS/RTL88WiFiNative" > "$WORK/undefined.txt"
  if grep -F "__ZN16IO80211WorkQueue9workQueueEv" "$WORK/undefined.txt"; then
    echo "FACTORY_UNDEFINED_IMPORT=PASS"
  else
    echo "FACTORY_UNDEFINED_IMPORT=FAIL"
    exit 13
  fi

  echo
  echo "===== KMUTIL LIBRARY RESOLUTION ====="
  set +e
  kmutil libraries -p "$PROBE_KEXT" --all-symbols > "$WORK/kmutil-libraries.txt" 2>&1
  KMUTIL_RC=$?
  set -e
  cat "$WORK/kmutil-libraries.txt"
  echo "KMUTIL_LIBRARIES_EXIT=$KMUTIL_RC"
  echo "FACTORY_SYMBOL_MATCH_LINES=$(grep -Eic 'IO80211WorkQueue.*workQueue|workQueue.*IO80211WorkQueue|__ZN16IO80211WorkQueue9workQueueEv' "$WORK/kmutil-libraries.txt" || true)"
  if grep -Eiq 'IO80211WorkQueue.*workQueue|workQueue.*IO80211WorkQueue|__ZN16IO80211WorkQueue9workQueueEv' "$WORK/kmutil-libraries.txt"; then
    echo "KMUTIL_FACTORY_SYMBOL_LISTED=YES"
  else
    echo "KMUTIL_FACTORY_SYMBOL_LISTED=NO"
  fi
  if grep -Fq "com.apple.iokit.IO80211Family" "$WORK/kmutil-libraries.txt"; then
    echo "KMUTIL_IO80211FAMILY_PROVIDER_LISTED=YES"
  else
    echo "KMUTIL_IO80211FAMILY_PROVIDER_LISTED=NO"
  fi
  if [[ "$KMUTIL_RC" -eq 0 ]] && grep -Fq "com.apple.iokit.IO80211Family" "$WORK/kmutil-libraries.txt"; then
    echo "STAGE164_SYMBOL_PROVIDER_RESULT=PASS_PROVIDER_LIBRARY_PRESENT"
  else
    echo "STAGE164_SYMBOL_PROVIDER_RESULT=REVIEW_REQUIRED"
  fi

  echo
  echo "===== PROJECT PRESERVATION CHECK ====="
  STATUS_AFTER="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
  echo "PROJECT_STATUS_BEFORE_SHA=$STATUS_BEFORE"
  echo "PROJECT_STATUS_AFTER_SHA=$STATUS_AFTER"
  [[ "$STATUS_BEFORE" == "$STATUS_AFTER" ]] || { echo "PROJECT_WORKTREE_PRESERVATION=FAIL"; exit 14; }
  echo "PROJECT_WORKTREE_PRESERVATION=PASS"
  echo "STAGE164_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE164_INSTALL=NOT_RUN LOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
  echo "========== END STAGE164 =========="
} > "$REPORT" 2>&1

echo "===== STAGE164 SUMMARY ====="
grep -aE '^(STAGE164_|TEMP_KEXT_LINK=|FACTORY_UNDEFINED_IMPORT=|KMUTIL_LIBRARIES_EXIT=|KMUTIL_FACTORY_SYMBOL_LISTED=|KMUTIL_IO80211FAMILY_PROVIDER_LISTED=|STAGE164_SYMBOL_PROVIDER_RESULT=|PROJECT_WORKTREE_PRESERVATION=)' "$REPORT" || true

python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage164-kmutil-workqueue-symbol-provider-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage164: publish temporary kmutil IO80211WorkQueue symbol-provider audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
for attempt in range(1,4):
    with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
        json.dump(payload,f); f.flush()
        r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
    if r.returncode==0:
        try: actual=json.loads(r.stdout).get("content",{}).get("sha")
        except Exception: actual=None
        if actual==expected:
            print("STAGE164_UPLOAD_SHA="+actual)
            print("STAGE164_GITHUB_PATH="+dest)
            print("STAGE164_UPLOAD=PASS")
            break
    last=r.stderr.strip() or r.stdout.strip()
    check=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
    if check.returncode==0:
        try: actual=json.loads(check.stdout).get("sha")
        except Exception: actual=None
        if actual==expected:
            print("STAGE164_UPLOAD_SHA="+actual)
            print("STAGE164_GITHUB_PATH="+dest)
            print("STAGE164_UPLOAD=PASS_RECOVERED")
            break
        if actual:
            print("STAGE164_UPLOAD_CONFLICT="+str(actual))
            raise SystemExit(20)
    if attempt<3: time.sleep(attempt*3)
else:
    print("STAGE164_UPLOAD=FAILED")
    print(last)
    raise SystemExit(21)
PY
