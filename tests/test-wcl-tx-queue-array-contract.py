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
assert "UInt32 serviceClass );" in sdk
assert "withPoolAndServiceClass(" not in cpp
assert "IOSkywalkTxSubmissionQueue::withPool(" in cpp
assert "this, nullptr," in cpp
assert "RTW88WCLTXQueueContract::kServiceClasses[i]" in cpp
assert "queue->getServiceClass()" in cpp
assert "kern_packet_svc_class_t getServiceClass() const;" in (ROOT / "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkPacketQueue.h").read_text()
assert "RTW88WCLTXQueueContract::validate" in cpp

# The actual role-1 array is a fixed member; all acquired queues are released
# in reverse index order and cleared after release.
assert "for (UInt32 i = kTXSubmissionQueueCount; i > 0; --i)" in cpp
assert "_txSubmissionQueues[i - 1] = nullptr;" in cpp
assert "ownsTXSubmissionQueue(queue)" in cpp

# The exact WMM order is explicit and the portable contract rejects aliases.
for value in ("0x00100080U", "0x00000000U", "0x00380100U", "0x00400180U"):
    assert value in contract
assert "entries[i].identity == entries[j].identity" in contract
assert "entries[i].serviceClass != kServiceClasses[i]" in contract
assert "count != kRequiredCount" in contract

# Construction stays deliberately unregistered and callbacks remain fail-closed.
assert "->registerEthernetInterface(" not in cpp and ".registerEthernetInterface(" not in cpp
assert "return static_cast<IOReturn>(0)" in cpp
print("PASS: four-entry target WMM queue array is fixed, ordered, validated, and reverse-released")
print("PASS: construction remains unregistered and callback packet acceptance remains fail-closed")
