#!/usr/bin/env python3
"""Stage 10 guardrails for the 24H32 registration callable ABI."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tarfile
import io

ROOT = Path(__file__).resolve().parents[1]
ABI = (ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp").read_text()
AUDIT = ROOT / "tools/audit-skywalk-registration-24H32.py"
CONTROLLER = (ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.cpp").read_text()
QUEUES = (ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp").read_text()
INFRA = (ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp").read_text()

# Registration entry points are non-virtual. Adding them must not alter any
# private class vtable; the existing static sizeof assertions remain present.
for signature in (
    r"IOReturn registerNetworkInterface\(RegistrationInfo const \*, IOSkywalkPacketQueue \*\*,",
    r"IOReturn registerNetworkInterface\(RegistrationInfo const \*, IOSkywalkLogicalLink \*,",
    r"IOReturn deregisterNetworkInterface\(unsigned int\)",
    r"bool initRegistrationInfo\(RegistrationInfo \*, unsigned int, size_t\)",
    r"IOReturn registerEthernetInterface\(RegistrationInfo const \*, IOSkywalkPacketQueue \*\*,",
    r"IOReturn registerEthernetInterface\(RegistrationInfo const \*, IOSkywalkLogicalLink \*,",
    r"IOReturn deregisterEthernetInterface\(unsigned int\)",
    r"IOReturn registerInfraEthernetInterface\(\s*IOSkywalkEthernetInterface::RegistrationInfo \*,",
):
    assert re.search(signature, ABI, re.S), f"missing ABI declaration: {signature}"
assert "static_assert(sizeof(IOSkywalkNetworkInterface) == 0xd0" in ABI
assert "static_assert(sizeof(IOSkywalkEthernetInterface) == 0x110" in ABI
assert "static_assert(sizeof(IO80211InfraInterface) == 0x120" in ABI

# ABI resolution is not authorization to register queues or publish a service.
def strip_comments(source):
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//[^\n]*", "", source)

controller_code = strip_comments(CONTROLLER)
queue_code = strip_comments(QUEUES)
assert not re.search(r"(?:->|\.)\s*registerEthernetInterface\s*\(", controller_code)
assert not re.search(r"(?:->|\.)\s*registerEthernetInterface\s*\(", queue_code)
assert not re.search(r"(?:->|\.)\s*registerInfraEthernetInterface\s*\(", controller_code)
assert "return false;" in INFRA[INFRA.find("bool RTW88WCLInfraInterface::start"):INFRA.find("void RTW88WCLInfraInterface::stop")]

with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage10-") as tmp:
    archive = Path(tmp) / "contract.tar.gz"
    members = {
        "24H32/IO80211InfraInterface.vtable.txt": (
            "384\t0xc00\t__ZN21IO80211InfraInterface23setInterfaceOFDMDesenseE18apple80211_channelx\n"
        ),
        "24H32/asm/ZN21IO80211InfraInterface30registerInfraEthernetInterface.asm.txt": (
            "# __ZN21IO80211InfraInterface30registerInfraEthernetInterface\n"
            "call 0x2 ; __ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j\n"
            "mov r14d, eax\nmov eax, r14d\nret\n"
        ),
        "24H32/asm/ZN28AppleBCMWLANSkywalkInterface5startEP16AppleBCMWLANCore.asm.txt": (
            "# __ZN28AppleBCMWLANSkywalkInterface5startEP16AppleBCMWLANCore\n"
            "call 0x1 ; __ZN21IO80211InfraInterface30registerInfraEthernetInterfaceEPN26IOSkywalkEthernetInterface16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_\n"
            "test r12d, r12d\nsete r15b\nje 0x4\n"
        ),
        "24H32/asm/ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j.asm.txt": (
            "# __ZN26IOSkywalkEthernetInterface25registerEthernetInterface\n"
            "call 0x3 ; __ZN25IOSkywalkNetworkInterface24registerNetworkInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j\n"
        ),
    }
    with tarfile.open(archive, "w:gz") as tf:
        for name, value in members.items():
            data = value.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
    report = subprocess.run(
        [sys.executable, str(AUDIT), str(archive), "--full-registration-asm", "--stdout"],
        text=True, capture_output=True, check=True,
    ).stdout
    assert "setInterfaceOFDMDesense" in report
    assert "not the registration entry point" in report
    assert "calls registerInfraEthernetInterface directly" in report
    assert "IOReturn status in EAX" in report

print("PASS: exact 24H32 registration methods are declared as non-virtual IOReturn APIs")
print("PASS: no registration/publication call is enabled in the controller or queue owner")
print("PASS: 0xc00 is correctly identified as setInterfaceOFDMDesense")
print("PASS: Apple start's direct registration call confirms zero-success IOReturn semantics")
