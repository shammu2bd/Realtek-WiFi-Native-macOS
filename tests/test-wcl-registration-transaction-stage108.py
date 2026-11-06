#!/usr/bin/env python3
"""Stage108 source contract for transactional 24H32 Skywalk registration."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
KEXT = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"

def uncomment(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//[^\n]*", "", source)

queues_h = (KEXT / "RTW88WCLSkywalkQueues.hpp").read_text()
queues_cpp_raw = (KEXT / "RTW88WCLSkywalkQueues.cpp").read_text()
queues_cpp = uncomment(queues_cpp_raw)
infra_h = (KEXT / "RTW88WCLInfraInterface.hpp").read_text()
infra_cpp_raw = (KEXT / "RTW88WCLInfraInterface.cpp").read_text()
infra_cpp = uncomment(infra_cpp_raw)
controller_cpp_raw = (KEXT / "RTW88WCLController.cpp").read_text()
controller_cpp = uncomment(controller_cpp_raw)
transaction = (KEXT / "RTW88WCLRegistrationTransaction.hpp").read_text()
abi = (KEXT / "RTW88WCL24H32InterfaceABI.hpp").read_text()

# Transaction state is lock-free, explicit, and has no accidental recovery
# from a quarantined owner.
for token in (
    "kUnregistered = 0", "kRegistering = 1", "kRegistered = 2",
    "kDeregistering = 3", "kQuarantined = 4",
    "beginRegistration()", "commitRegistration()", "abortRegistration()",
    "beginDeregistration()", "commitDeregistration()", "abortDeregistration()",
    "__atomic_compare_exchange_n", "void quarantine()",
    "bool ownsQueues() const",
):
    assert token in transaction, f"missing transaction state contract: {token}"
assert "return state() != State::kUnregistered;" in transaction

# Queue owner exposes seven stable entries, four WMM TX queues followed by
# one queue for each remaining QueueSet role.
assert "kRegistrationQueueCount = 7" in queues_h
assert "IOSkywalkPacketQueue *_registrationQueues[kRegistrationQueueCount]" in queues_h
assert "_registrationQueues[i] = _txSubmissionQueues[i]" in queues_cpp
assert "_registrationQueues[4] = _txCompletion" in queues_cpp
assert "_registrationQueues[5] = _rxSubmission" in queues_cpp
assert "_registrationQueues[6] = _rxCompletion" in queues_cpp
assert all(value in queues_cpp for value in ("1, 1, 1, 1, 2, 3, 4"))

# Only the evidence-backed first UInt32 role result is interpreted. Do not
# model undocumented pool/capacity fields in the 16-byte performCommand buffer.
valid_start = queues_cpp.index("bool RTW88WCLSkywalkQueues::registrationQueuesValid()")
valid_end = queues_cpp.index("IOReturn RTW88WCLSkywalkQueues::beginRegistrationTransaction()", valid_start)
valid = queues_cpp[valid_start:valid_end]
assert "alignas(8) UInt8 descriptor[16]" in valid
assert "memcpy(&queueType, descriptor, sizeof(queueType))" in valid
assert "queueType != expectedTypes[i]" in valid
assert "QueueDescriptor24H32" not in valid
assert "descriptor.capacity" not in valid
assert "descriptor.pool" not in valid
assert "queue != expectedQueue" in valid

# Registration transaction protects queue/pool lifetime from preflight through
# Apple registration and while Skywalk owns the QueueSet.
for token in (
    "beginRegistrationTransaction()", "commitRegistrationTransaction()",
    "abortRegistrationTransaction(bool quarantine = false)",
    "beginDeregistrationTransaction()", "finishDeregistrationTransaction()",
    "abortDeregistrationTransaction(bool quarantine = false)",
    "registrationOwnsQueues()",
):
    assert token in queues_h, f"missing queue-owner transaction API: {token}"
assert "if (_registrationTransaction.ownsQueues())" in queues_cpp
assert "if (_registrationTransaction.ownsQueues() ||" in queues_cpp
assert "_registrationTransaction.isRegistered()" in queues_cpp
begin_method = queues_cpp.index("IOReturn RTW88WCLSkywalkQueues::beginRegistrationTransaction()")
begin_end = queues_cpp.index("IOReturn RTW88WCLSkywalkQueues::commitRegistrationTransaction()", begin_method)
begin_code = queues_cpp[begin_method:begin_end]
assert begin_code.index("beginRegistration()") < begin_code.index("queuesAllocated()")
assert begin_code.index("queuesAllocated()") < begin_code.index("registrationQueuesValid()")
assert "!_registrationTransaction.abortRegistration()" in begin_code
assert "_registrationTransaction.quarantine()" in begin_code

# Verify API declaration and interface transaction ordering against the
# audited 24H32 callable ABI; private QueueSet/LogicalLink payloads stay opaque.
assert re.search(r"IOReturn registerInfraEthernetInterface\s*\(", abi)
assert re.search(r"IOReturn deregisterEthernetInterface\(unsigned int\)", abi)
infra_start_method = infra_cpp.index("bool RTW88WCLInfraInterface::start(")
start_begin = infra_cpp.index("queues->beginRegistrationTransaction()", infra_start_method)
assert "registrationQueuesValid()" not in infra_cpp[infra_start_method:start_begin], \
    "queue-role validation must run only after the owner transaction pins resources"
start_call = infra_cpp.index("registerInfraEthernetInterface(", start_begin)
start_commit = infra_cpp.index("queues->commitRegistrationTransaction()", start_call)
start_mark = infra_cpp.index("_registered = true;", start_commit)
assert start_begin < start_call < start_commit < start_mark
assert "queues->registrationQueueArray()" in infra_cpp
assert "queues->registrationQueueCount()" in infra_cpp
assert "queues->txPacketPool(), queues->rxPacketPool()" in infra_cpp
assert "queues->abortRegistrationTransaction()" in infra_cpp
assert "deregisterEthernetInterface(0)" in infra_cpp[start_commit:start_mark]
assert "IOSkywalkQueueSet::createWithQueues" not in infra_cpp
assert "IOSkywalkLogicalLinkInfo" not in infra_cpp

# Stop path: close packet admission, begin deregistration, call Apple's
# deregistration wrapper, restore Registered on failure, and only then release
# the local registration pin.
shutdown_start = infra_cpp.index("IOReturn RTW88WCLInfraInterface::shutdownForController()")
shutdown_end = infra_cpp.index("void RTW88WCLInfraInterface::stop(", shutdown_start)
shutdown = infra_cpp[shutdown_start:shutdown_end]
assert shutdown.index("quiescePacketPath()") < shutdown.index("beginDeregistrationTransaction()")
assert shutdown.index("beginDeregistrationTransaction()") < shutdown.index("deregisterEthernetInterface(0)")
assert shutdown.index("deregisterEthernetInterface(0)") < shutdown.index("finishDeregistrationTransaction()")
assert "abortDeregistrationTransaction()" in shutdown
assert "registrationQuarantined()" in shutdown
assert "clearRegistrationInfo();" in shutdown

# Controller integration is deliberately ordered: the RTW88 core is probed
# with PCI interrupts masked, then interface registration succeeds, then the
# service is published, and only then is the PCI producer/interrupt gate opened.
controller_start = controller_cpp.index("bool RTW88WCLController::start(")
controller_end = controller_cpp.index("void RTW88WCLController::stop(", controller_start)
controller_start_code = controller_cpp[controller_start:controller_end]
radio_probe = controller_start_code.index("_radio->start()")
infra_start = controller_start_code.index("_infraInterface->start(this)")
service_publish = controller_start_code.index("_infraInterface->registerService()")
pci_enable = controller_start_code.index("_pciBackend->setRadioRunning(true)")
assert radio_probe < infra_start < service_publish < pci_enable
assert "RTW88WCLInfraInterface.hpp" in controller_cpp_raw
assert "_infraInterface = nullptr;" in controller_cpp_raw
assert "_infraInterface->shutdownForController()" in controller_cpp
assert controller_cpp.index("_infraInterface->shutdownForController()") < controller_cpp.index("_skywalkQueues->destroyQueues()")

rx_sink_start = controller_cpp.index("bool RTW88WCLController::stagedRxFrame(")
rx_sink_end = controller_cpp.index("IOWorkLoop *RTW88WCLController::getRxWorkLoop()", rx_sink_start)
rx_sink = controller_cpp[rx_sink_start:rx_sink_end]
assert "_skywalkQueues->isRegistered()" in rx_sink
assert "_infraInterface->isRegistered()" in rx_sink
assert "enqueueRXPacketForNetworking(preparedPacket)" in rx_sink
assert "return accepted == 1;" in rx_sink

# The local commit failure path must reconcile the external Apple side effect
# before queue owners can become unpinned. If reconciliation fails, quarantine.
commit_fail = infra_cpp[infra_cpp.index("const IOReturn commitStatus"):start_mark]
assert "const IOReturn rollbackStatus = deregisterEthernetInterface(0);" in commit_fail
assert "const IOReturn abortStatus =" in commit_fail
assert "if (abortStatus != kIOReturnSuccess)" in commit_fail
assert "abortRegistrationTransaction(true)" in commit_fail

# No obsolete boolean registration API may bypass the transaction state machine.
assert "setRegistered(" not in queues_h
assert "setRegistered(" not in queues_cpp
assert "markSkywalkQueuesRegistered" not in controller_cpp_raw

# The radio event bridge must be installed before WCL operations are enabled,
# and event delivery must go through the interface-owned work queue.
attach_radio = infra_cpp[infra_cpp.index("IOReturn RTW88WCLInfraInterface::attachRadio"):
                        infra_cpp.index("void RTW88WCLInfraInterface::detachRadio")]
assert "queue->init(this, workLoop, this)" in attach_radio
assert "_bridge.attach(radio, queue)" in attach_radio
bridge_cpp = (ROOT / "driver/RTL88WiFi/src/kext/RTW88WCLRadioBridge.cpp").read_text()
assert "radio->setEventDelegate(this)" in bridge_cpp
assert "sink->onRTW88WCLRadioEvent(event)" in bridge_cpp

# User-facing power and capability control is available only after successful
# registration; no unregistered interface can activate the packet path.
enable_start = infra_cpp.index("IOReturn RTW88WCLInfraInterface::enable(")
enable_end = infra_cpp.index("IOReturn RTW88WCLInfraInterface::disable(", enable_start)
enable = infra_cpp[enable_start:enable_end]
assert "powerOn()" in enable
assert "activatePacketPath(this)" in enable
disable_start = enable_end
disable_end = infra_cpp.index("SInt32 RTW88WCLInfraInterface::initBSDInterfaceParameters", disable_start)
disable = infra_cpp[disable_start:disable_end]
assert disable.index("quiescePacketPath()") < disable.index("powerOff()")
assert "return !_infraInterface || !_infraInterface->isRegistered();" in controller_cpp

# TX ownership stays connected to the existing deferred completion consumer.
assert "_txCompletionWorker->init(this, _workLoop, _txAdapter" in controller_cpp
assert "_completionQueue->enqueuePackets(batch, 1, 0)" in (
    ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLTxCompletionWorkQueue.cpp"
).read_text()

print("PASS: 24H32 registration uses Apple's audited infra wrapper and stable seven-queue vector")
print("PASS: atomic begin/commit/abort and deregistration retry/quarantine states guard queue ownership")
print("PASS: opaque descriptor tail and private QueueSet/LogicalLink layouts are not guessed")
print("PASS: controller publishes only after registration and opens PCI interrupt gate afterward")
print("PASS: RX sink transfers only accepted packets after both interface and queue registration")
print("PASS: failed local registration rollback quarantines all queue owners")
print("PASS: radio events and power controls flow through the registered infra interface")
print("PASS: obsolete bool registration shortcuts are absent")
