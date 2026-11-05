#!/usr/bin/env python3
"""Source integration checks for the four-entry 24H32 TX queue array."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEXT = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"

hpp = (KEXT / "RTW88WCLSkywalkQueues.hpp").read_text()
cpp = (KEXT / "RTW88WCLSkywalkQueues.cpp").read_text()
sdk = (ROOT / "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h").read_text()
contract = (KEXT / "RTW88WCLTXQueueArrayContract.hpp").read_text()

assert "kTXSubmissionQueueCount = 4" in hpp
assert "_txSubmissionQueues[kTXSubmissionQueueCount]" in hpp
assert "txSubmissionQueues() const" in hpp
assert "txSubmissionQueuesValid() const" in hpp

# The target-backed overload carries options followed by the service class.
assert "IOSkywalkQueryFreeSpaceHandler24H32" in sdk
assert "IOSkywalkTxSubmissionQueueAction24H32" in sdk
assert "typedef IOReturn (*IOSkywalkTxSubmissionQueueAction)" in sdk
assert "const IOSkywalkPacket **" in sdk  # generic SDK ABI remains unchanged
assert "IOSkywalkPacket * const * packets" in sdk  # target-only 24H32 overload
assert "UInt32 serviceClass );" in sdk
assert "withPoolAndServiceClass(" not in cpp
assert "UInt32 RTW88WCLSkywalkQueues::txSubmissionAction(" in cpp
assert "IOSkywalkPacket * const *packets" in cpp
assert "RTW88WCLTxSubmissionBatch::submitPrefix<IOSkywalkPacket>" in cpp
assert "return accepted;" in cpp
assert "IOSkywalkTxSubmissionQueue::withPool(" in cpp
assert "this, nullptr," in cpp
assert "RTW88WCLTXQueueContract::kServiceClasses[i]" in cpp
assert "queue->getServiceClass()" in cpp
assert "kern_packet_svc_class_t getServiceClass() const;" in (ROOT / "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkPacketQueue.h").read_text()
assert "RTW88WCLTXQueueContract::validate" in cpp

# The role-1 array is owner-resident. Stage90 replaces the original
# manual reverse-index loop with a typed acquisition journal whose LIFO pop
# dispatches the matching queue slot and clears it immediately after release.
assert "RTW88WCLAcquisitionJournal::Journal _acquisitionJournal" in hpp
assert "while (_acquisitionJournal.popRollback(&resource))" in cpp
assert "releaseAcquiredResource(resource)" in cpp
release_start = cpp.index("void RTW88WCLSkywalkQueues::releaseAcquiredResource")
release_end = cpp.index("bool RTW88WCLSkywalkQueues::hasOutstandingResources", release_start)
release = cpp[release_start:release_end]
for token in (
    "Resource::kTXSubmission3",
    "Resource::kTXSubmission2",
    "Resource::kTXSubmission1",
    "Resource::kTXSubmission0",
    "_txSubmissionQueues[index] = nullptr;",
):
    assert token in release
assert "ownsTXSubmissionQueue(queue)" in cpp

# The exact WMM order is explicit and the portable contract rejects aliases.
for value in ("0x00100080U", "0x00000000U", "0x00380100U", "0x00400180U"):
    assert value in contract
assert "entries[i].identity == entries[j].identity" in contract
assert "entries[i].serviceClass != kServiceClasses[i]" in contract
assert "count != kRequiredCount" in contract

# Construction stays deliberately unregistered. TX submission returns the
# accepted prefix count; the not-yet-implemented completion/RX callbacks remain
# inert and return their legacy IOReturn success value.
assert "->registerEthernetInterface(" not in cpp and ".registerEthernetInterface(" not in cpp
assert "return static_cast<IOReturn>(0)" in cpp
print("PASS: four-entry target WMM queue array is fixed, ordered, validated, and journal-rollback compatible")
print("PASS: target TX action reports accepted prefix; native registration remains fenced")
