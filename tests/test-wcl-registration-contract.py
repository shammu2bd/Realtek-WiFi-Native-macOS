#!/usr/bin/env python3
"""Guard opaque 24H32 registration ABI and Stage108 transaction wiring."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
KEXT = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
ABI = KEXT / "RTW88WCL24H32InterfaceABI.hpp"
abi = ABI.read_text()
sdk_dir = ROOT / "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk"
sdk_net = (sdk_dir / "IOSkywalkNetworkInterface.h").read_text()
sdk_eth = (sdk_dir / "IOSkywalkEthernetInterface.h").read_text()

# Public/private registration and expansion payloads remain opaque.
assert re.search(r"struct RegistrationInfo\s*;", sdk_net)
assert re.search(r"struct RegistrationInfo\s*;", sdk_eth)
assert re.search(r"struct RegistrationInfo\s*;", abi)
assert not re.search(r"struct RegistrationInfo\s*\{", abi)
assert abi.count("struct ExpansionData;") == 2
assert not re.search(r"struct ExpansionData\s*\{", abi)
assert "ExpansionData *mExpansionData;" in abi
assert "ExpansionData *mExpansionData2;" in abi

# Keep only the 24H32 target-callable declarations whose return and argument
# contracts were established from target bodies/callers.
for declaration in (
    r"bool initRegistrationInfo\(RegistrationInfo \*, unsigned int, size_t\)",
    r"IOReturn registerEthernetInterface\(RegistrationInfo const \*, IOSkywalkPacketQueue \*\*,",
    r"IOReturn deregisterEthernetInterface\(unsigned int\)",
    r"IOReturn registerNetworkInterface\(RegistrationInfo const \*, IOSkywalkPacketQueue \*\*,",
    r"IOReturn deregisterNetworkInterface\(unsigned int\)",
    r"IOReturn registerInfraEthernetInterface\(",
):
    assert re.search(declaration, abi, re.S), f"missing verified ABI declaration: {declaration}"

controller = (KEXT / "RTW88WCLController.cpp").read_text()
infra = (KEXT / "RTW88WCLInfraInterface.cpp").read_text()
queues = (KEXT / "RTW88WCLSkywalkQueues.cpp").read_text()
queues_h = (KEXT / "RTW88WCLSkywalkQueues.hpp").read_text()
native_cpp = "\n".join(path.read_text() for path in KEXT.glob("*.cpp"))
makefile = (ROOT / "driver/RTL88WiFi/Makefile").read_text()

# The interface invokes Apple's verified infra wrapper, never a guessed
# direct QueueSet/LogicalLink constructor or registration overload.
assert "initRegistrationInfo(info, 1, sizeof(_registrationInfo.bytes))" in infra
assert "registerInfraEthernetInterface(" in infra
assert "deregisterEthernetInterface(0)" in infra
assert "queues->registrationQueueArray()" in infra
assert "queues->registrationQueueCount()" in infra
assert "queues->txPacketPool(), queues->rxPacketPool()" in infra
assert "IOSkywalkQueueSet::createWithQueues" not in native_cpp
assert "IOSkywalkLogicalLinkInfo" not in native_cpp
assert not re.search(r"sizeof\s*\(\s*(?:IOSkywalkNetworkInterface::|IOSkywalkEthernetInterface::)?RegistrationInfo", native_cpp)
assert not re.search(r"(?:->|\.)\s*registerEthernetInterface\s*\(", native_cpp)

# The queue owner pins resources through active, in-flight and quarantined
# transactions, and only inspects the known role-code word from the 16-byte
# performCommand result.
assert "RTW88WCLRegistrationTransaction::Transaction _registrationTransaction" in queues_h
assert "_registrationTransaction.ownsQueues()" in queues
assert "alignas(8) UInt8 descriptor[16]" in queues
assert "memcpy(&queueType, descriptor, sizeof(queueType))" in queues
assert "descriptor.capacity" not in queues
assert "descriptor.pool" not in queues

# Controller integration probes the RTW88 core with the PCI interrupt
# gate still closed, then registers/publishes the infra service, and only then
# opens the PCI producer path. Teardown deregisters before queue destruction.
controller_code = re.sub(r"/\*.*?\*/|//[^\n]*", "", controller, flags=re.S)
controller_start = controller_code.index("bool RTW88WCLController::start(")
controller_end = controller_code.index("void RTW88WCLController::stop(", controller_start)
controller_start_code = controller_code[controller_start:controller_end]
radio_probe = controller_start_code.index("_radio->start()")
infra_start = controller_start_code.index("_infraInterface->start(this)")
service_publish = controller_start_code.index("_infraInterface->registerService()")
pci_enable = controller_start_code.index("_pciBackend->setRadioRunning(true)")
assert radio_probe < infra_start < service_publish < pci_enable
assert "_infraInterface->shutdownForController()" in controller_code
release_start = controller_code.index("IOReturn RTW88WCLController::releaseNativeResources()")
release_end = controller_code.index("void RTW88WCLController::free()", release_start)
release_code = controller_code[release_start:release_end]
assert release_code.index("_infraInterface->shutdownForController()") < release_code.index("_skywalkQueues->destroyQueues()")
assert "return static_cast<UInt32>(0)" in queues

link_objs = makefile.split("AIRPORT_ALL_OBJS :=", 1)[1].split("\n", 1)[0]
assert "WCL24H32_" not in link_objs, "Native WCL objects must remain out of legacy kext link"

print("PASS: registration payloads/expansion blocks remain opaque and target ABI declarations are pinned")
print("PASS: native interface uses Apple's 24H32 registration/deregistration wrapper transactionally")
print("PASS: QueueSet/LogicalLink private layouts are not constructed by driver code")
print("PASS: native interface/radio activation remains fenced until datapath stages pass")
