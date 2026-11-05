#!/usr/bin/env python3
"""Stage90 source integration checks for journaled queue/pool ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
KEXT = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
hpp = (KEXT / "RTW88WCLSkywalkQueues.hpp").read_text()
cpp = (KEXT / "RTW88WCLSkywalkQueues.cpp").read_text()
journal = (KEXT / "RTW88WCLAcquisitionJournal.hpp").read_text()

assert '#include "RTW88WCLAcquisitionJournal.hpp"' in hpp
assert "RTW88WCLAcquisitionJournal::Journal _acquisitionJournal" in hpp
assert "if (!_acquisitionJournal.begin())" in cpp

# Every successful pool/queue factory is recorded immediately afterwards.
acquire_pairs = (
    ('IOSkywalkPacketBufferPool::withName(\n        "RTL88WiFi-WCL-TX"', "Resource::kTXPool"),
    ('IOSkywalkPacketBufferPool::withName(\n        "RTL88WiFi-WCL-RX"', "Resource::kRXPool"),
    ("IOSkywalkTxSubmissionQueue::withPool(", "txSubmissionResource(i, &resource)"),
    ("IOSkywalkTxCompletionQueue::withPool(", "Resource::kTXCompletion"),
    ("IOSkywalkRxSubmissionQueue::withPool(", "Resource::kRXSubmission"),
    ("IOSkywalkRxCompletionQueue::withPool(", "Resource::kRXCompletion"),
)
for factory, token in acquire_pairs:
    position = cpp.index(factory)
    record_position = cpp.index(token, position)
    assert record_position > position

assert "if (!txSubmissionQueuesValid() || !_acquisitionJournal.commit())" in cpp
assert cpp.index("_acquisitionJournal.commit()") < cpp.index("_allocated = true;")
assert "return (_acquisitionJournal.isCommitted() && queuesAllocated())" in cpp

# Rollback is a journal pop loop, not an independent guessed release order.
destroy_start = cpp.index("void RTW88WCLSkywalkQueues::destroyQueues()")
destroy_end = cpp.index("void RTW88WCLSkywalkQueues::releaseAcquiredResource", destroy_start)
destroy = cpp[destroy_start:destroy_end]
assert "beginRollback()" in destroy
assert "while (_acquisitionJournal.popRollback(&resource))" in destroy
assert "releaseAcquiredResource(resource)" in destroy
assert "finishRollback()" in destroy
assert "hasOutstandingResources()" in destroy

release_start = cpp.index("void RTW88WCLSkywalkQueues::releaseAcquiredResource")
release_end = cpp.index("bool RTW88WCLSkywalkQueues::txSubmissionQueuesValid", release_start)
release = cpp[release_start:release_end]
reverse_tokens = (
    "Resource::kRXCompletion",
    "Resource::kRXSubmission",
    "Resource::kTXCompletion",
    "Resource::kTXSubmission3",
    "Resource::kTXSubmission2",
    "Resource::kTXSubmission1",
    "Resource::kTXSubmission0",
    "Resource::kRXPool",
    "Resource::kTXPool",
)
positions = [release.index(token) for token in reverse_tokens]
assert positions == sorted(positions)
assert "void RTW88WCLSkywalkQueues::free()" in cpp
free_start = cpp.index("void RTW88WCLSkywalkQueues::free()")
free_body = cpp[free_start:]
assert "quarantining owner and retaining resources" in free_body
assert "super::free();" in free_body
assert free_body.index("quarantining owner") < free_body.index("super::free();")

# The portable transaction contract requires the exact nine acquisitions,
# ordered records, full commit, and reverse rollback.
for token in (
    "Resource::kTXPool", "Resource::kRXPool",
    "Resource::kTXSubmission0", "Resource::kTXSubmission1",
    "Resource::kTXSubmission2", "Resource::kTXSubmission3",
    "Resource::kTXCompletion", "Resource::kRXSubmission",
    "Resource::kRXCompletion",
):
    assert token in journal
assert "resource != kAcquisitionOrder[_count]" in journal
assert "_phase = Phase::kCommitted" in journal
assert "_entries[--_count]" in journal
assert "_phase = Phase::kIdle" in journal

# Stage90 remains an acquisition/rollback step only. No live registration,
# queue enabling, packet consumption, or event-source attachment is allowed.
code_without_comments = re.sub(r"/\\*.*?\\*/|//[^\\n]*", "", cpp, flags=re.S)
assert "registerEthernetInterface(" not in code_without_comments
assert "addEventSource(" not in code_without_comments
assert "return static_cast<UInt32>(0)" in cpp
assert "return static_cast<IOReturn>(0)" in cpp

print("PASS: all nine queue/pool acquisitions are journaled and committed only when complete")
print("PASS: partial and committed teardown pop resources in reverse order")
print("PASS: registration and packet callbacks remain fail-closed")
