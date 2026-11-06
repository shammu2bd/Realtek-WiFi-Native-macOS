#!/bin/bash
# Stage122: read-only observation of Stage121 native controller/interface state.
# The only writes are this report and Git evidence publication on this branch.
set -u
set -o pipefail

EXPECTED_BRANCH="work/stage122-primary-interface-runtime-diagnostics"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

if [ "$(git branch --show-current)" != "$EXPECTED_BRANCH" ]; then
  echo "ERROR: run Stage122 on $EXPECTED_BRANCH"
  exit 2
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree is not clean; preserve or resolve local changes first"
  git status --short
  exit 2
fi

mkdir -p Development/Logs
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="Development/Logs/stage122-readonly-runtime-diagnostics-$STAMP.log"
SOURCE_COMMIT="$(git rev-parse HEAD)"
exec > >(tee "$LOG") 2>&1

echo "========== STAGE122 READ-ONLY RUNTIME DIAGNOSTICS =========="
echo "STAGE122_SOURCE_COMMIT=$SOURCE_COMMIT"
echo "STAGE122_TARGET=macOS_15.8.1_24H32_x86_64"
echo "STAGE122_DEVICE=RTL8821CE_PCIe_10EC:C821"
echo "STAGE122_SCOPE=OBSERVE_CURRENT_NATIVE_CONTROLLER_AND_INTERFACE_STATE"
echo "STAGE122_MODE=READ_ONLY_NO_DRIVER_ACTIVATION"
echo "STAGE122_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE"
echo "STAGE122_INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN REBOOT=NOT_RUN"
echo

echo "----- 0. Static read-only contract and shell syntax -----"
if python3 tests/test-stage122-readonly-runtime-diagnostics.py; then
  echo "STAGE122_STATIC_CONTRACT=PASS"
else
  echo "STAGE122_STATIC_CONTRACT=FAIL"
  exit 1
fi
echo

echo "----- 1. Host identity -----"
sw_vers 2>&1
echo "SW_VERS_EXIT=$?"
uname -a 2>&1
echo "UNAME_EXIT=$?"
sysctl -n kern.osversion 2>&1
echo "KERN_OSVERSION_EXIT=$?"
uname -m 2>&1
echo "ARCH_EXIT=$?"
echo

echo "----- 2. Loaded-kext visibility -----"
KMUTIL_OUTPUT="$(kmutil showloaded 2>&1)"
KMUTIL_EXIT=$?
echo "KMUTIL_SHOWLOADED_EXIT=$KMUTIL_EXIT"
printf '%s\n' "$KMUTIL_OUTPUT" | grep -Ei 'io\.github\.x1ren41l\.RTL88WiFi|RTL88WiFiNative|RtWlan|AirportRTW' || true
if printf '%s\n' "$KMUTIL_OUTPUT" | grep -Eiq 'io\.github\.x1ren41l\.RTL88WiFi|RTL88WiFiNative'; then
  NATIVE_KEXT_STATE="LOADED"
else
  NATIVE_KEXT_STATE="NOT_VISIBLE"
fi
echo "STAGE122_NATIVE_KEXT_STATE=$NATIVE_KEXT_STATE"
echo

echo "----- 3. Native controller I/O Registry record -----"
CONTROLLER_IOREG="$(ioreg -p IOService -l -w0 -c RTW88WCLController 2>&1)"
CONTROLLER_IOREG_EXIT=$?
printf '%s\n' "$CONTROLLER_IOREG"
echo "CONTROLLER_IOREG_EXIT=$CONTROLLER_IOREG_EXIT"
if printf '%s\n' "$CONTROLLER_IOREG" | grep -q 'RTW88WCLController'; then
  CONTROLLER_IOREG_STATE="FOUND"
else
  CONTROLLER_IOREG_STATE="NOT_FOUND"
fi
echo "STAGE122_CONTROLLER_IOREG=$CONTROLLER_IOREG_STATE"
echo

echo "----- 4. Native infra-interface I/O Registry record -----"
INTERFACE_IOREG="$(ioreg -p IOService -l -w0 -c RTW88WCLInfraInterface 2>&1)"
INTERFACE_IOREG_EXIT=$?
printf '%s\n' "$INTERFACE_IOREG"
echo "INTERFACE_IOREG_EXIT=$INTERFACE_IOREG_EXIT"
if printf '%s\n' "$INTERFACE_IOREG" | grep -q 'RTW88WCLInfraInterface'; then
  INTERFACE_IOREG_STATE="FOUND"
else
  INTERFACE_IOREG_STATE="NOT_FOUND"
fi
echo "STAGE122_INTERFACE_IOREG=$INTERFACE_IOREG_STATE"
echo

echo "----- 5. RTL8821CE PCI provider evidence -----"
PCI_OUTPUT="$(ioreg -p IOService -l -w0 2>&1 | grep -i -B 6 -A 16 -E 'pci10ec,c821|device-id.*21c80000|vendor-id.*ec100000')"
PCI_EXIT=$?
printf '%s\n' "$PCI_OUTPUT"
echo "PCI_FILTER_EXIT=$PCI_EXIT"
if printf '%s\n' "$PCI_OUTPUT" | grep -Eiq 'pci10ec,c821|device-id.*21c80000'; then
  PCI_STATE="FOUND"
else
  PCI_STATE="NOT_FOUND"
fi
echo "STAGE122_RTL8821CE_PCI=$PCI_STATE"
echo

echo "----- 6. Stage121 controller/interface stage properties -----"
# ControllerStage is attached to the PCI provider; InfraInterfaceStage is
# attached to the controller. Search the complete read-only service tree.
STAGE_PROPERTIES="$(ioreg -p IOService -l -w0 2>&1 | grep -i -E -B 3 -A 4 'RTW88WCLControllerStage|RTW88WCLInfraInterfaceStage|RTW88WCLInfraInterfaceStopped')"
STAGE_PROPERTIES_EXIT=$?
printf '%s\n' "$STAGE_PROPERTIES"
echo "STAGE_PROPERTY_FILTER_EXIT=$STAGE_PROPERTIES_EXIT"
if printf '%s\n' "$STAGE_PROPERTIES" | grep -q 'RTW88WCLControllerStage'; then
  CONTROLLER_PUBLISHED_STATE="PROPERTY_FOUND"
else
  CONTROLLER_PUBLISHED_STATE="NOT_OBSERVED"
fi
if printf '%s\n' "$STAGE_PROPERTIES" | grep -q 'RTW88WCLInfraInterfaceStage'; then
  REGISTRATION_PROPERTY_STATE="PROPERTY_FOUND"
else
  REGISTRATION_PROPERTY_STATE="NOT_OBSERVED"
fi
echo "STAGE122_CONTROLLER_PUBLICATION_PROPERTY=$CONTROLLER_PUBLISHED_STATE"
echo "STAGE122_INTERFACE_REGISTRATION_PROPERTY=$REGISTRATION_PROPERTY_STATE"
echo

echo "----- 7. Recent driver runtime log evidence (last 24 hours) -----"
DRIVER_LOG="$(log show --last 24h --style compact --info --predicate 'eventMessage CONTAINS[c] "rtl88wifi-wcl"' 2>&1)"
DRIVER_LOG_EXIT=$?
printf '%s\n' "$DRIVER_LOG" | tail -n 180
echo "DRIVER_LOG_QUERY_EXIT=$DRIVER_LOG_EXIT"
ATTACH_SUCCESS=0
ATTACH_FAILURE=0
DETACH_SUCCESS=0
DETACH_FAILURE=0
REGISTRATION_SUCCESS=0
REGISTRATION_FAILURE=0
if printf '%s\n' "$DRIVER_LOG" | grep -Fq 'Apple primary Skywalk interface attached and getter-verified'; then ATTACH_SUCCESS=1; fi
if printf '%s\n' "$DRIVER_LOG" | grep -Eiq 'attachInterface rejected|without publishing this primary interface|could not become controller primary|already owns a different primary'; then ATTACH_FAILURE=1; fi
if printf '%s\n' "$DRIVER_LOG" | grep -Fq 'Apple primary Skywalk interface detached and getter-verified'; then DETACH_SUCCESS=1; fi
if printf '%s\n' "$DRIVER_LOG" | grep -Fq 'Apple detachInterface did not clear the primary pointer'; then DETACH_FAILURE=1; fi
if printf '%s\n' "$DRIVER_LOG" | grep -Fq 'native 24H32 infrastructure interface registered'; then REGISTRATION_SUCCESS=1; fi
if printf '%s\n' "$DRIVER_LOG" | grep -Eiq 'registerInfraEthernetInterface failed|registration transaction commit failed'; then REGISTRATION_FAILURE=1; fi

if [ "$ATTACH_SUCCESS" -eq 1 ] && [ "$ATTACH_FAILURE" -eq 1 ]; then
  ATTACH_STATE="MIXED_MARKERS_REVIEW"
elif [ "$ATTACH_SUCCESS" -eq 1 ]; then
  ATTACH_STATE="VERIFIED"
elif [ "$ATTACH_FAILURE" -eq 1 ]; then
  ATTACH_STATE="FAILURE_MARKER_OBSERVED"
else
  ATTACH_STATE="NOT_OBSERVED"
fi
if [ "$DETACH_SUCCESS" -eq 1 ] && [ "$DETACH_FAILURE" -eq 1 ]; then
  DETACH_STATE="MIXED_MARKERS_REVIEW"
elif [ "$DETACH_SUCCESS" -eq 1 ]; then
  DETACH_STATE="VERIFIED"
elif [ "$DETACH_FAILURE" -eq 1 ]; then
  DETACH_STATE="FAILURE_MARKER_OBSERVED"
else
  DETACH_STATE="NOT_OBSERVED"
fi
if [ "$REGISTRATION_SUCCESS" -eq 1 ] && [ "$REGISTRATION_FAILURE" -eq 1 ]; then
  REGISTRATION_LOG_STATE="MIXED_MARKERS_REVIEW"
elif [ "$REGISTRATION_SUCCESS" -eq 1 ]; then
  REGISTRATION_LOG_STATE="SUCCESS_MARKER_OBSERVED"
elif [ "$REGISTRATION_FAILURE" -eq 1 ]; then
  REGISTRATION_LOG_STATE="FAILURE_MARKER_OBSERVED"
else
  REGISTRATION_LOG_STATE="NOT_OBSERVED"
fi
if printf '%s\n' "$DRIVER_LOG" | grep -Fq 'native 24H32 infrastructure interface published'; then
  PUBLISHED_LOG_STATE="SUCCESS_MARKER_OBSERVED"
else
  PUBLISHED_LOG_STATE="NOT_OBSERVED"
fi
echo "STAGE122_PRIMARY_INTERFACE_GETTER_VERIFIED=$ATTACH_STATE"
echo "STAGE122_PRIMARY_INTERFACE_DETACH_VERIFIED=$DETACH_STATE"
echo "STAGE122_SKYWALK_REGISTRATION=$REGISTRATION_LOG_STATE"
echo "STAGE122_CONTROLLER_FINAL_PUBLICATION=$PUBLISHED_LOG_STATE"
echo

echo "----- 8. Current network hardware ports -----"
NETWORK_PORTS="$(networksetup -listallhardwareports 2>&1)"
NETWORK_PORTS_EXIT=$?
printf '%s\n' "$NETWORK_PORTS"
echo "NETWORK_PORTS_EXIT=$NETWORK_PORTS_EXIT"
echo

echo "----- 9. Current BSD network interfaces -----"
IFCONFIG_OUTPUT="$(ifconfig -a 2>&1)"
IFCONFIG_EXIT=$?
printf '%s\n' "$IFCONFIG_OUTPUT"
echo "IFCONFIG_EXIT=$IFCONFIG_EXIT"
echo

echo "----- 10. AirPort system-profiler view -----"
AIRPORT_OUTPUT="$(system_profiler SPAirPortDataType 2>&1)"
AIRPORT_EXIT=$?
printf '%s\n' "$AIRPORT_OUTPUT"
echo "AIRPORT_SYSTEM_PROFILER_EXIT=$AIRPORT_EXIT"
echo

echo "----- 11. Runtime interpretation -----"
if [ "$ATTACH_STATE" = "FAILURE_MARKER_OBSERVED" ] || [ "$ATTACH_STATE" = "MIXED_MARKERS_REVIEW" ] || \
   [ "$REGISTRATION_LOG_STATE" = "FAILURE_MARKER_OBSERVED" ] || [ "$REGISTRATION_LOG_STATE" = "MIXED_MARKERS_REVIEW" ] || \
   [ "$DETACH_STATE" = "FAILURE_MARKER_OBSERVED" ] || [ "$DETACH_STATE" = "MIXED_MARKERS_REVIEW" ]; then
  RUNTIME_INTERPRETATION="FAILURE_OR_CONFLICT_MARKERS_OBSERVED"
elif [ "$NATIVE_KEXT_STATE" = "LOADED" ] && \
     [ "$CONTROLLER_IOREG_STATE" = "FOUND" ] && \
     [ "$INTERFACE_IOREG_STATE" = "FOUND" ] && \
     [ "$CONTROLLER_PUBLISHED_STATE" = "PROPERTY_FOUND" ] && \
     [ "$REGISTRATION_PROPERTY_STATE" = "PROPERTY_FOUND" ] && \
     [ "$ATTACH_STATE" = "VERIFIED" ] && \
     [ "$REGISTRATION_LOG_STATE" = "SUCCESS_MARKER_OBSERVED" ] && \
     [ "$PUBLISHED_LOG_STATE" = "SUCCESS_MARKER_OBSERVED" ]; then
  RUNTIME_INTERPRETATION="ATTACHMENT_AND_REGISTRATION_OBSERVED"
else
  RUNTIME_INTERPRETATION="INCOMPLETE_OR_NOT_OBSERVED"
fi
echo "STAGE122_RUNTIME_INTERPRETATION=$RUNTIME_INTERPRETATION"
echo "STAGE122_DIAGNOSTIC_COLLECTION=COMPLETE"
echo "STAGE122_PRIMARY_INTERFACE_GETTER_VERIFIED=$ATTACH_STATE"
echo "STAGE122_DETACH_GETTER_VERIFIED=$DETACH_STATE"
echo "STAGE122_NATIVE_KEXT_STATE=$NATIVE_KEXT_STATE"
echo "STAGE122_CONTROLLER_IOREG=$CONTROLLER_IOREG_STATE"
echo "STAGE122_INTERFACE_IOREG=$INTERFACE_IOREG_STATE"
echo "STAGE122_RTL8821CE_PCI=$PCI_STATE"
echo "STAGE122_CONTROLLER_PUBLICATION_PROPERTY=$CONTROLLER_PUBLISHED_STATE"
echo "STAGE122_INTERFACE_REGISTRATION_PROPERTY=$REGISTRATION_PROPERTY_STATE"
echo "STAGE122_SKYWALK_REGISTRATION=$REGISTRATION_LOG_STATE"
echo "STAGE122_CONTROLLER_FINAL_PUBLICATION=$PUBLISHED_LOG_STATE"
echo "STAGE122_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE"
echo "STAGE122_INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN REBOOT=NOT_RUN"
echo "STAGE122_DETAIL_LOG=$LOG"
echo "============================================================"
 
# Publish only this report and its canonical checkpoint; no source or system
# configuration files are touched. From here, publication failures are fatal.
set -e
git add -f "$LOG"
git -c core.whitespace=-trailing-space diff --cached --check
git commit -m "Stage122: publish read-only native interface runtime diagnostics"

git fetch origin "$EXPECTED_BRANCH"
git rebase FETCH_HEAD

cat >> Development/output.log <<EOF

========== STAGE122 READ-ONLY RUNTIME DIAGNOSTICS ==========
STAGE122_DIAGNOSTIC_COLLECTION=COMPLETE
STAGE122_RUNTIME_INTERPRETATION=$RUNTIME_INTERPRETATION
STAGE122_PRIMARY_INTERFACE_GETTER_VERIFIED=$ATTACH_STATE
STAGE122_DETACH_GETTER_VERIFIED=$DETACH_STATE
STAGE122_NATIVE_KEXT_STATE=$NATIVE_KEXT_STATE
STAGE122_CONTROLLER_IOREG=$CONTROLLER_IOREG_STATE
STAGE122_INTERFACE_IOREG=$INTERFACE_IOREG_STATE
STAGE122_RTL8821CE_PCI=$PCI_STATE
STAGE122_SKYWALK_REGISTRATION=$REGISTRATION_LOG_STATE
STAGE122_CONTROLLER_FINAL_PUBLICATION=$PUBLISHED_LOG_STATE
STAGE122_DETAIL_LOG=$LOG
STAGE122_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE
STAGE122_INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN REBOOT=NOT_RUN
============================================================
EOF

git add -f Development/output.log
git -c core.whitespace=-trailing-space diff --cached --check
git commit -m "Stage122: publish canonical runtime diagnostic checkpoint"
git push origin "HEAD:$EXPECTED_BRANCH"

git fetch origin "$EXPECTED_BRANCH"
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse FETCH_HEAD)"
if [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
  echo "ERROR: pushed Stage122 HEAD does not match fetched remote HEAD"
  exit 3
fi
git show "FETCH_HEAD:$LOG" >/dev/null
git show "FETCH_HEAD:Development/output.log" | grep -F "$LOG" >/dev/null

echo "STAGE122_UPLOAD=PASS"
echo "STAGE122_BRANCH=$EXPECTED_BRANCH"
echo "STAGE122_DETAIL_LOG=$LOG"
echo "STAGE122_REMOTE_HEAD=$REMOTE_HEAD"
