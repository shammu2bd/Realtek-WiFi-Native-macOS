#!/usr/bin/env python3
"""Source audit for the staged, unregistered 24H32 Skywalk queue owner."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEXT = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"

hpp = (KEXT / "RTW88WCLSkywalkQueues.hpp").read_text()
cpp = (KEXT / "RTW88WCLSkywalkQueues.cpp").read_text()
controller_h = (KEXT / "RTW88WCLController.hpp").read_text()
controller_cpp = (KEXT / "RTW88WCLController.cpp").read_text()
makefile = (ROOT / "driver/RTL88WiFi/Makefile").read_text()
rx_queue_sdk = (ROOT / "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkRxSubmissionQueue.h").read_text()

for queue, member in (
    ("IOSkywalkTxSubmissionQueue", "_txSubmissionQueues"),
    ("IOSkywalkTxCompletionQueue", "_txCompletion"),
    ("IOSkywalkRxSubmissionQueue", "_rxSubmission"),
    ("IOSkywalkRxCompletionQueue", "_rxCompletion"),
):
    assert queue in hpp, f"missing queue type: {queue}"
    assert member in hpp, f"missing owned member: {member}"

assert "kTXSubmissionQueueCount = 4" in hpp
assert "_txSubmissionQueues[kTXSubmissionQueueCount]" in hpp
assert "txSubmissionQueuesValid() const" in hpp
assert "kQueueCapacity = 128" in hpp
assert "kTxBufferSize = 2048" in hpp
assert "kRxBufferSize = 4096" in hpp
assert "maxBuffersPerPacket = 1" in cpp
assert "memorySegmentSize = kQueueCapacity * kTxBufferSize" in cpp
assert "rxOptions.memorySegmentSize = kQueueCapacity * kRxBufferSize" in cpp
assert "RTW88WCLTXQueueArrayContract.hpp" in cpp
assert "RTW88WCLTXQueueContract::validate" in cpp
assert "queue->getServiceClass()" in cpp
assert "ownsTXSubmissionQueue(queue)" in cpp
assert "for (UInt32 i = kTXSubmissionQueueCount; i > 0; --i)" in cpp
assert "static_cast<UInt32>(RTW88WCLTXQueueContract::kServiceClasses[i])" in cpp
assert "kIOSkywalkPacketTypeNetwork" in cpp
assert "RTL88WiFi-WCL-TX" in cpp and "RTL88WiFi-WCL-RX" in cpp

# No callbacks may pretend packets have been consumed or completed yet.
for action in ("txSubmissionAction", "txCompletionAction", "rxSubmissionAction", "rxCompletionAction"):
    start = cpp.index(f"IOReturn RTW88WCLSkywalkQueues::{action}(")
    end = cpp.find("\n}\n", start)
    body = cpp[start:end]
    expected_zero = "return static_cast<UInt32>(0)" if action == "txSubmissionAction" else "return static_cast<IOReturn>(0)"
    assert expected_zero in body, f"{action} must report zero accepted/completed packets"
    assert "completeWithQueue" not in body and "mbuf_freem" not in body

assert "not registered" in cpp.lower()
assert "->registerEthernetInterface(" not in cpp and ".registerEthernetInterface(" not in cpp
assert "addEventSource" not in cpp
assert "RTW88WCLSkywalkQueues *_skywalkQueues" in controller_h
assert "_skywalkQueues->createQueues()" in controller_cpp
assert "_skywalkQueues->destroyQueues()" in controller_cpp
assert controller_cpp.index("_skywalkQueues->destroyQueues()") < controller_cpp.index("unbindRadioBackend()")
assert "WCL24H32_SKYWALK_QUEUES_OBJ" in makefile
assert "withPool( IOSkywalkPacketBufferPool * pool, UInt32 capacity, UInt32 queueId, OSObject * owner, IOSkywalkQueryFreeSpaceHandler handler, IOSkywalkTxSubmissionQueueAction action, void * refCon, IOOptionBits options, UInt32 serviceClass );" in (ROOT / "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h").read_text()
assert "WCL24H32_SKYWALK_QUEUES_OBJ" not in makefile.split("AIRPORT_ALL_OBJS :=", 1)[1].split("\n", 1)[0]
assert "virtual bool initWithPool( IOSkywalkPacketBufferPool * pool, UInt32 capacity, UInt32 queueId, kern_packet_svc_class_t serviceClass, OSObject * owner, IOSkywalkRxSubmissionQueueAction action, void * refCon, IOOptionBits options );" in rx_queue_sdk

print("PASS: four Skywalk queue objects and pools are owned with rollback; callbacks remain fail-closed and unregistered")
