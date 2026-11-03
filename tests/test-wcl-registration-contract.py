#!/usr/bin/env python3
"""Guard the private 24H32 Skywalk registration ABI until it is proven."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
KEXT = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
ABI = KEXT / "RTW88WCL24H32InterfaceABI.hpp"
abi = ABI.read_text()
sdk_dir = ROOT / "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk"
sdk_net = (sdk_dir / "IOSkywalkNetworkInterface.h").read_text()
sdk_eth = (sdk_dir / "IOSkywalkEthernetInterface.h").read_text()

# The public SDK deliberately leaves both RegistrationInfo types opaque.
assert re.search(r"struct RegistrationInfo\s*;", sdk_net)
assert re.search(r"struct RegistrationInfo\s*;", sdk_eth)
assert re.search(r"struct RegistrationInfo\s*;", abi)
assert not re.search(r"struct RegistrationInfo\s*\{", abi), \
    "Do not guess the private RegistrationInfo payload layout"

# Keep the framework-owned expansion allocations opaque as well. The visible
# public SDK ExpansionData is not evidence of the private 24H32 allocation size.
assert abi.count("struct ExpansionData;") == 2
assert not re.search(r"struct ExpansionData\s*\{", abi)
assert "ExpansionData *mExpansionData;" in abi
assert "ExpansionData *mExpansionData2;" in abi

# The complete 24H32 target bodies and Apple caller now resolve these as
# non-virtual IOReturn entry points. Keep RegistrationInfo opaque and check the
# declarations without allowing a vtable extension.
assert re.search(r"IOReturn registerEthernetInterface\s*\(", sdk_eth)
assert re.search(r"IOReturn registerNetworkInterface\s*\(", sdk_net)
for declaration in (
    r"bool initRegistrationInfo\(RegistrationInfo \*, unsigned int, size_t\)",
    r"IOReturn registerEthernetInterface\(RegistrationInfo const \*, IOSkywalkPacketQueue \*\*,",
    r"IOReturn deregisterEthernetInterface\(unsigned int\)",
    r"IOReturn registerNetworkInterface\(RegistrationInfo const \*, IOSkywalkPacketQueue \*\*,",
    r"IOReturn deregisterNetworkInterface\(unsigned int\)",
    r"IOReturn registerInfraEthernetInterface\(",
):
    assert re.search(declaration, abi, re.S), \
        f"Missing verified callable ABI declaration: {declaration}"

controller = (KEXT / "RTW88WCLController.cpp").read_text()
infra = (KEXT / "RTW88WCLInfraInterface.cpp").read_text()
queues = (KEXT / "RTW88WCLSkywalkQueues.cpp").read_text()
native_cpp = "\n".join(path.read_text() for path in KEXT.glob("*.cpp"))
makefile = (ROOT / "driver/RTL88WiFi/Makefile").read_text()

assert "refusing publication until Skywalk datapath is ready" in controller
assert "goto fail;" in controller
assert "return false;" in infra[infra.index("bool RTW88WCLInfraInterface::start("):infra.index("void RTW88WCLInfraInterface::stop(")]
assert "return kIOReturnUnsupported;" in infra[infra.index("SInt32 RTW88WCLInfraInterface::initBSDInterfaceParameters"):]
assert "not registered" in queues.lower()
for api in ("initRegistrationInfo", "registerEthernetInterface",
            "deregisterEthernetInterface", "registerNetworkInterface",
            "deregisterNetworkInterface"):
    assert not re.search(rf"->\s*{api}\s*\(", native_cpp), \
        f"Unverified private registration call found: {api}"
assert not re.search(r"sizeof\s*\(\s*(?:IOSkywalkNetworkInterface::|IOSkywalkEthernetInterface::)?RegistrationInfo", native_cpp)
assert "WCL24H32_SKYWALK_QUEUES_OBJ" in makefile
link_objs = makefile.split("AIRPORT_ALL_OBJS :=", 1)[1].split("\n", 1)[0]
assert "WCL24H32_" not in link_objs, "Native WCL objects must remain out of legacy kext link"

print("PASS: registration payloads/expansion blocks remain opaque; disputed APIs are fenced; native service publication stays disabled")
