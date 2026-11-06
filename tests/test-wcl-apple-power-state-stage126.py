#!/usr/bin/env python3
"""Stage126 source baseline pins; read-only checks before Apple disassembly."""
import hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
PINS={
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.cpp":"253f8f6136788f8e8a063811172c9ed8eb1a906e",
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.hpp":"aab83ca0e963f85c4fd455ac82cfe50bf8fb6e54",
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":"7621f15b25d94e882c3a89cc6d90f980bdde6dcc",
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":"f27344296e669defa0b46e0721ff4098d2a0e73c",
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":"0e155ec7dda26701bf962bb1442d6a54be0becb2",
}
def blob_sha(data):
    return hashlib.sha1(f"blob {len(data)}\\0".encode()+data).hexdigest()
for rel,expected in PINS.items():
    actual=blob_sha((ROOT/rel).read_bytes())
    ok=actual==expected
    print(f"STAGE126_SOURCE_PIN_{Path(rel).name.upper().replace('.','_')}={'PASS' if ok else 'FAIL'}")
    if not ok: raise SystemExit(f"source pin mismatch: {rel} expected={expected} actual={actual}")
infra=(ROOT/"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp").read_text()
controller=(ROOT/"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.cpp").read_text()
abi=(ROOT/"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp").read_text()
def body(source,start,end):
    return source[source.index(start):source.index(end,source.index(start))]
enable=body(infra,"IOReturn RTW88WCLInfraInterface::enable(","IOReturn RTW88WCLInfraInterface::disable(")
disable=body(infra,"IOReturn RTW88WCLInfraInterface::disable(","SInt32 RTW88WCLInfraInterface::initBSDInterfaceParameters(")
getpower=body(controller,"IOReturn RTW88WCLController::getPOWER(","IOReturn RTW88WCLController::setPOWER(")
setpower=body(controller,"IOReturn RTW88WCLController::setPOWER(","IOReturn RTW88WCLController::getCOUNTRY_CODE(")
assert "_bridge.powerOn()" in enable and "_controller->activatePacketPath(this)" in enable
assert "_controller->quiescePacketPath()" in disable and "_bridge.powerOff()" in disable
assert "_infraInterface->isInterfaceEnabled()" in getpower
assert "_infraInterface->enable(0)" in setpower and "_infraInterface->disable(0)" in setpower
assert "setInterfaceEnable(bool)" in abi and "isInterfaceEnabled()" in abi
print("STAGE126_EXISTING_DRIVER_POWER_PATH=PINNED_AND_CONFIRMED")
print("STAGE126_APPLE_POWER_SEMANTICS=REQUIRES_TARGET_DISASSEMBLY")
