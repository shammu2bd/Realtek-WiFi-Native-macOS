#!/usr/bin/env python3
"""Stage91 source contract: 24H32 TX submit ABI, bounded prefix and ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
KEXT = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
SDK = ROOT / "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk"

adapter_h = (KEXT / "RTW88WCLSkywalkTxAdapter.hpp").read_text()
adapter_cpp = (KEXT / "RTW88WCLSkywalkTxAdapter.cpp").read_text()
queues_h = (KEXT / "RTW88WCLSkywalkQueues.hpp").read_text()
queues_cpp = (KEXT / "RTW88WCLSkywalkQueues.cpp").read_text()
controller_h = (KEXT / "RTW88WCLController.hpp").read_text()
controller_cpp = (KEXT / "RTW88WCLController.cpp").read_text()
batch_h = (KEXT / "RTW88WCLTxSubmissionBatch.hpp").read_text()
gate_h = (KEXT / "RTW88WCLTxSubmissionGate.hpp").read_text()
tx_sdk = (SDK / "IOSkywalkTxSubmissionQueue.h").read_text()

# Exact target 24H32 action ABI: UInt32 accepted-packet count, read-only
# pointer slots. The older generic SDK typedef remains separately declared.
assert re.search(
    r"typedef UInt32\s*\(\*IOSkywalkTxSubmissionQueueAction24H32\)\s*\("
    r"\s*OSObject\s*\*\s*owner,\s*"
    r"IOSkywalkTxSubmissionQueue\s*\*\s*queue,\s*"
    r"IOSkywalkPacket\s*\*\s*const\s*\*\s*packets,\s*"
    r"UInt32\s+packetCount,\s*void\s*\*\s*refCon",
    tx_sdk,
)
assert "const IOSkywalkPacket **" in tx_sdk  # generic SDK declaration retained
assert "IOSkywalkPacket * const * packets" in tx_sdk  # target overload declaration

# Four queue callbacks are wired to one owner-bound adapter. Prefix processing
# is deliberately bounded and returns only the number actually accepted.
assert "IOSkywalkPacket * const *packets" in queues_h
assert "static UInt32 txSubmissionAction" in queues_h
assert "static int submitTXPacket(void *context, void *packet)" in queues_h
assert "RTW88WCLTxSubmissionBatch::submitPrefix<IOSkywalkPacket>" in queues_cpp
action_start = queues_cpp.index("UInt32 RTW88WCLSkywalkQueues::txSubmissionAction")
action_end = queues_cpp.index("IOReturn RTW88WCLSkywalkQueues::txCompletionAction", action_start)
action = queues_cpp[action_start:action_end]
for token in ("refCon != self", "ownsTXSubmissionQueue(queue)",
              "queuesAllocated()", "!self->_txAdapter", "packetCount == 0",
              "RTW88WCLTxSubmissionBatch::submitPrefix"):
    assert token in action
assert "completeWithQueue" not in action
assert "registerEthernetInterface(" not in action
assert "addEventSource(" not in action
assert "self->_txCallbackGate.enterSubmission()" in action
assert "self->_txCallbackGate.leaveSubmission()" in action
assert action.index("self->_txCallbackGate.enterSubmission()") < action.index("ownsTXSubmissionQueue(queue)")

assert "kMaximumPacketsPerCallback = 16" in batch_h
assert "if (!packets || packetCount == 0 || !submit)" in batch_h
assert "if (!packet || submit(context, static_cast<void *>(packet)) != 0)" in batch_h
assert "break;" in batch_h
assert "return accepted;" in batch_h

# Adapter calls are gated against teardown, validate/copy before retaining,
# and retain only after a completion slot has been reserved.
submit_start = adapter_cpp.index("IOReturn RTW88WCLSkywalkTxAdapter::submitPacket(")
submit_end = adapter_cpp.index("IOReturn RTW88WCLSkywalkTxAdapter::submitPacketEntered", submit_start)
submit = adapter_cpp[submit_start:submit_end]
assert "enterSubmission()" in submit and "leaveSubmission()" in submit
assert submit.index("enterSubmission()") < submit.index("submitPacketEntered(packet)")
assert "retain();" in submit and "release();" in submit

entered_start = adapter_cpp.index("IOReturn RTW88WCLSkywalkTxAdapter::submitPacketEntered")
entered_end = adapter_cpp.index("void RTW88WCLSkywalkTxAdapter::backendCompletion", entered_start)
entered = adapter_cpp[entered_start:entered_end]
for token in (
    "RTW88WCLResolveEthernetTxPacket(packet, _txPool, &view)",
    "copyPacketToMbuf(view.bytes, view.length)",
    "packet->retain()",
    "_tickets.reserve(packet)",
    "packet->release()",
    "mbuf_freem(mbuf)",
    "outputPacketWithCompletion(",
    "return kIOReturnSuccess;",
):
    assert token in entered
assert entered.index("RTW88WCLResolveEthernetTxPacket") < entered.index("packet->retain()")
assert entered.index("_tickets.reserve(packet)") < entered.index("outputPacketWithCompletion(")
assert "if (!ticket)" in entered
assert "static_cast<IOReturn>(0)" not in entered

completion_start = adapter_cpp.index("void RTW88WCLSkywalkTxAdapter::backendCompletion")
completion_end = adapter_cpp.index("uint32_t RTW88WCLSkywalkTxAdapter::drainCompletions", completion_start)
completion = adapter_cpp[completion_start:completion_end]
assert "TicketPool::complete(ticket, transmitted)" in completion
assert "completeWithQueue" not in completion
assert "packet->release()" not in completion
assert "release();" not in completion

# The gate closes submission admission before RTW88 stop and PCI/DMA fencing.
for token in ("enterSubmission()", "leaveSubmission()", "beginUnbind()",
              "canFinishUnbind()", "finishUnbind()"):
    assert token in gate_h
unbind_start = adapter_cpp.index("IOReturn RTW88WCLSkywalkTxAdapter::unbind()")
unbind_end = adapter_cpp.index("mbuf_t RTW88WCLSkywalkTxAdapter::copyPacketToMbuf", unbind_start)
unbind = adapter_cpp[unbind_start:unbind_end]
assert "quiesceSubmissions()" in unbind
assert "_tickets.hasOutstanding()" in unbind
assert "_radio = nullptr;" in unbind and "_txPool = nullptr;" in unbind
assert "finishUnbind()" in unbind

bind_pos = controller_cpp.index("_txAdapter->bind(_radio, _skywalkQueues->txPacketPool())")
owner_bind_pos = controller_cpp.index("_skywalkQueues->bindTXAdapter(_txAdapter)")
assert bind_pos < owner_bind_pos
quiesce_pos = controller_cpp.index("_txAdapter->quiesceSubmissions()")
radio_stop_pos = controller_cpp.index("_radio->stop();")
pci_fence_pos = controller_cpp.index("_pciBackend->setRadioRunning(false)")
adapter_unbind_pos = controller_cpp.index("_txAdapter->unbind()")
owner_detach_pos = controller_cpp.index("_skywalkQueues->unbindTXAdapter(_txAdapter)")
queue_destroy_pos = controller_cpp.index("_skywalkQueues->destroyQueues()")
queue_released_check_pos = controller_cpp.index("_skywalkQueues->resourcesReleased()", queue_destroy_pos)
queue_owner_release_pos = controller_cpp.index("_skywalkQueues->release()", queue_destroy_pos)
assert quiesce_pos < radio_stop_pos < pci_fence_pos < adapter_unbind_pos
assert adapter_unbind_pos < owner_detach_pos < queue_destroy_pos
assert queue_destroy_pos < queue_released_check_pos < queue_owner_release_pos
assert "bool _txAdapterBoundToQueues = false;" in controller_h

# Queue owner cannot be rolled back underneath the retained adapter context.
assert "if (!adapter->isBoundToPool(_txPool))" in queues_cpp
assert "_txCallbackGate.beginBind()" in queues_cpp
assert "_txCallbackGate.finishBind()" in queues_cpp
assert "_txCallbackGate.beginUnbind()" in queues_cpp
assert "_txCallbackGate.canFinishUnbind()" in queues_cpp
assert "_txCallbackGate.finishUnbind()" in queues_cpp
assert "if (!adapter->isUnbound() || adapter->hasOutstandingCompletions())" in queues_cpp
owner_unbind_start = queues_cpp.index("IOReturn RTW88WCLSkywalkQueues::unbindTXAdapter")
owner_unbind_end = queues_cpp.index("/*\\n * The Sequoia", owner_unbind_start)
owner_unbind = queues_cpp[owner_unbind_start:owner_unbind_end]
assert owner_unbind.index("_txCallbackGate.beginUnbind()") < owner_unbind.index("_txCallbackGate.canFinishUnbind()")
assert owner_unbind.index("_txCallbackGate.canFinishUnbind()") < owner_unbind.index("adapter->isUnbound()")
assert "_txCallbackGate.isUnbound()" in queues_cpp[queues_cpp.index("bool RTW88WCLSkywalkQueues::hasOutstandingResources"):queues_cpp.index("bool RTW88WCLSkywalkQueues::txSubmissionQueuesValid")]
destroy_start = queues_cpp.index("void RTW88WCLSkywalkQueues::destroyQueues()")
destroy_body = queues_cpp[destroy_start:]
assert "if (_txAdapter)" in destroy_body
assert "queue rollback deferred" in destroy_body
assert "_txCallbackGate.isUnbound()" in destroy_body
assert "bool RTW88WCLSkywalkQueues::resourcesReleased() const" in queues_cpp
assert "return !_allocated && _acquisitionJournal.isEmpty() &&" in queues_cpp
assert "_skywalkQueues->destroyQueues();" in controller_cpp
assert "_skywalkQueues->resourcesReleased()" in controller_cpp

# Native activation remains outside Stage91.
code = queues_cpp + controller_cpp
code_without_comments = re.sub(r"/\*.*?\*/|//[^\n]*", "", code, flags=re.S)
assert "registerEthernetInterface(" not in code_without_comments
assert "completeWithQueue(" not in code_without_comments

print("PASS: target 24H32 TX action ABI is UInt32 plus IOSkywalkPacket * const *")
print("PASS: callback accepts only a bounded contiguous prefix")
print("PASS: rejected packets remain Skywalk-owned; accepted packets have retained completion tickets")
print("PASS: submission quiesce precedes radio/PCI teardown and queue rollback")
print("PASS: TX completion, RX callbacks and native registration remain fenced for later stages")
