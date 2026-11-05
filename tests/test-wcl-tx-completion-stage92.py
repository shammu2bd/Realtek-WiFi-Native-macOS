#!/usr/bin/env python3
"""Stage92 source contract: 24H32 TX submit and completion ownership handoff."""
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
action_end = queues_cpp.index("UInt32 RTW88WCLSkywalkQueues::txCompletionAction", action_start)
action = queues_cpp[action_start:action_end]
for token in ("refCon != self", "ownsTXSubmissionQueue(queue)",
              "queuesAllocated()", "self->_txAdapter && packets && packetCount != 0",
              "RTW88WCLTxSubmissionBatch::submitPrefix"):
    assert token in action
assert "completeWithQueue" not in action
assert "registerEthernetInterface(" not in action
assert "addEventSource(" not in action
assert "self->_txCallbackGate.enterSubmission()" in action
assert "self->_txCallbackGate.leaveSubmission()" in action
assert action.index("self->_txCallbackGate.enterSubmission()") < action.index("ownsTXSubmissionQueue(queue)")

# Keep the exact 24H32 Skywalk service class through queue callback, adapter,
# Ethernet queue mapping and 802.11 QoS TID.
route_h = (KEXT / "RTW88WCLTXQueueArrayContract.hpp").read_text()
radio_h = (ROOT / "driver/RTL88WiFi/src/kext/RTW88IEEE80211.hpp").read_text()
radio_cpp = (ROOT / "driver/RTL88WiFi/src/kext/RTW88IEEE80211.cpp").read_text()
for token in ("kServiceClassBackground", "kServiceClassBestEffort",
              "kServiceClassVideo", "kServiceClassVoice",
              "routeForServiceClass", "kAccessCategoryBackground",
              "kAccessCategoryBestEffort", "kAccessCategoryVideo",
              "kAccessCategoryVoice"):
    assert token in route_h
assert "routeForServiceClass(" in action
assert "queue->getServiceClass()" in action
assert "submission.route" in action
assert "submission->route.accessCategory" in queues_cpp
assert "submission->route.tid" in queues_cpp
assert "submission->adapter->submitPacket(" in queues_cpp
assert "uint8_t accessCategory" in adapter_h
assert "uint8_t tid" in adapter_h
assert "accessCategory, tid" in adapter_cpp
assert "uint8_t accessCategory = 2" in radio_h
assert "uint8_t tid = 0" in radio_h
assert "skb_set_queue_mapping(skb, accessCategory);" in radio_cpp
assert "skb->priority = tid;" in radio_cpp
assert "qosc[0] = (uint8_t)(tid & IEEE80211_QOS_CTL_TID_MASK);" in radio_cpp
assert "accessCategory == IEEE80211_AC_BE" in radio_cpp
assert "tid == _baTid" in radio_cpp

# Confirm the selected IEEE80211_AC value actually selects the matching RTW88
# hardware ring instead of being discarded by the PCI TX queue mapper.
rtw_tx = (ROOT / "driver/rtw88-stable/drivers/net/wireless/realtek/rtw88/tx.c").read_text()
mac80211_h = (ROOT / "driver/RTL88WiFi/src/compat/net/mac80211.h").read_text()
for token in ("#define IEEE80211_AC_VO 0", "#define IEEE80211_AC_VI 1",
              "#define IEEE80211_AC_BE 2", "#define IEEE80211_AC_BK 3"):
    assert token in mac80211_h
assert "queue = ac_to_hwq[q_mapping];" in rtw_tx
assert "q_mapping = skb_get_queue_mapping(skb);" in rtw_tx
for token in ("[IEEE80211_AC_VO] = RTW_TX_QUEUE_VO",
              "[IEEE80211_AC_VI] = RTW_TX_QUEUE_VI",
              "[IEEE80211_AC_BE] = RTW_TX_QUEUE_BE",
              "[IEEE80211_AC_BK] = RTW_TX_QUEUE_BK",
              "pkt_info->qsel = skb->priority;"):
    assert token in rtw_tx

# Four independently scheduled AC queues use the production atomic state
# object for per-TID sequence spaces and one unique 48-bit CCMP PN allocator.
sequence_h = (ROOT / "driver/RTL88WiFi/src/kext/RTW88TxSequenceNumbers.hpp").read_text()
makefile = (ROOT / "driver/RTL88WiFi/Makefile").read_text()
assert makefile.count("$(KEXT_SRC)/RTW88TxSequenceNumbers.hpp") == 3
assert '#include "RTW88TxSequenceNumbers.hpp"' in radio_h
assert "RTW88TxSequenceNumbers _txSequenceNumbers;" in radio_h
assert "return _txSequenceNumbers.nextNonQoS();" in radio_cpp
assert "return _txSequenceNumbers.nextQoS(tid);" in radio_cpp
assert "return _txSequenceNumbers.currentQoS(tid);" in radio_cpp
assert "uint16_t _qos[kQoSTidCount] = {};" in sequence_h
assert "__atomic_fetch_add(&_qos[tid], 1, __ATOMIC_RELAXED)" in sequence_h
assert "__atomic_load_n(&_qos[tid], __ATOMIC_ACQUIRE)" in sequence_h
assert "bool nextCCMP(uint64_t *packetNumber)" in sequence_h
assert "__atomic_compare_exchange_n(&_ccmpPacketNumber" in sequence_h
assert "previous >= kCCMPPacketNumberMax" in sequence_h
assert "_txSequenceNumbers.nextCCMP(&packetNumber)" in radio_cpp
assert "_txSequenceNumbers.resetQoS();" in radio_cpp
assert "_txSequenceNumbers.resetCCMP();" in radio_cpp

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
assert submit.index("enterSubmission()") < submit.index("submitPacketEntered(packet, accessCategory, tid)")
assert "uint8_t accessCategory, uint8_t tid" in submit
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
assert "accessCategory, tid" in entered
assert "if (!ticket)" in entered
assert "static_cast<IOReturn>(0)" not in entered

completion_start = adapter_cpp.index("void RTW88WCLSkywalkTxAdapter::backendCompletion")
completion_end = adapter_cpp.index("uint32_t RTW88WCLSkywalkTxAdapter::drainCompletions", completion_start)
completion = adapter_cpp[completion_start:completion_end]
assert "__atomic_add_fetch(&self->_backendCompletionCallbacksInFlight" in completion
assert "TicketPool::complete(ticket, transmitted)" in completion
assert "if (TicketPool::complete(ticket, transmitted))" in completion
assert "__atomic_sub_fetch(&self->_backendCompletionCallbacksInFlight" in completion
assert "CompletionNotify notify = self->_completionNotifier;" in completion
assert "notify(notifyContext);" in completion
assert "completeWithQueue" not in completion
assert "packet->release()" not in completion
assert "release();" not in completion

# Deferred handoff is retryable. A failed/invalid sink must not finish the
# ticket or drop the retained packet/adapter references.
assert "using CompletionSink = bool (*)(IOSkywalkPacket *packet" in adapter_h
drain_start = adapter_cpp.index("uint32_t RTW88WCLSkywalkTxAdapter::drainCompletions")
drain_end = adapter_cpp.index("bool RTW88WCLSkywalkTxAdapter::hasOutstandingCompletions", drain_start)
drain = adapter_cpp[drain_start:drain_end]
assert "if (!packet || !sink(packet, transmitted, context))" in drain
assert "TicketPool::retry(ticket)" in drain
assert drain.index("TicketPool::retry(ticket)") < drain.index("TicketPool::finish(ticket)")
assert "break;" in drain
slots_h = (KEXT / "RTW88WCLTxCompletionSlots.hpp").read_text()
assert "static bool retry(Ticket *ticket)" in slots_h
assert "uint32_t completedCount() const" in slots_h
assert "kDraining" in slots_h and "kCompleted" in slots_h

# The gate closes submission admission before RTW88 stop and PCI/DMA fencing.
for token in ("enterSubmission()", "leaveSubmission()", "beginUnbind()",
              "canFinishUnbind()", "finishUnbind()"):
    assert token in gate_h
unbind_start = adapter_cpp.index("IOReturn RTW88WCLSkywalkTxAdapter::unbind()")
unbind_end = adapter_cpp.index("mbuf_t RTW88WCLSkywalkTxAdapter::copyPacketToMbuf", unbind_start)
unbind = adapter_cpp[unbind_start:unbind_end]
assert "quiesceSubmissions()" in unbind
assert "_tickets.hasOutstanding()" in unbind
assert "_backendCompletionCallbacksInFlight" in unbind
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
worker_stop_pos = controller_cpp.index("_txCompletionWorker->stop()", adapter_unbind_pos)
assert adapter_unbind_pos < worker_stop_pos < owner_detach_pos < queue_destroy_pos
assert queue_destroy_pos < queue_released_check_pos < queue_owner_release_pos
assert "RTW88WCLTxCompletionWorkQueue *_txCompletionWorker" in controller_h
assert "_txCompletionWorker->init(this, _workLoop, _txAdapter," in controller_cpp
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
owner_unbind_end = queues_cpp.index("/*\n * The Sequoia", owner_unbind_start)
owner_unbind = queues_cpp[owner_unbind_start:owner_unbind_end]
assert owner_unbind.index("_txCallbackGate.beginUnbind()") < owner_unbind.index("_txCallbackGate.canFinishUnbind()")
assert owner_unbind.index("_txCallbackGate.canFinishUnbind()") < owner_unbind.index("adapter->isUnbound()")
assert "_txCallbackGate.isUnbound()" in queues_cpp[queues_cpp.index("bool RTW88WCLSkywalkQueues::hasOutstandingResources"):queues_cpp.index("bool RTW88WCLSkywalkQueues::txSubmissionQueuesValid")]
destroy_start = queues_cpp.index("void RTW88WCLSkywalkQueues::destroyQueues()")
destroy_body = queues_cpp[destroy_start:]
assert "if (_txAdapter || !_txCallbackGate.isUnbound())" in destroy_body
assert "queue rollback deferred" in destroy_body
assert "_txCallbackGate.isUnbound()" in destroy_body
assert "bool RTW88WCLSkywalkQueues::resourcesReleased() const" in queues_cpp
assert "return !_allocated && _acquisitionJournal.isEmpty() &&" in queues_cpp
assert "_skywalkQueues->destroyQueues();" in controller_cpp
assert "_skywalkQueues->resourcesReleased()" in controller_cpp

# Stage92: exact completion action ABI and synchronous target queue handoff.
completion_sdk = (SDK / "IOSkywalkTxCompletionQueue.h").read_text()
packet_sdk = (SDK / "IOSkywalkPacket.h").read_text()
worker_h = (KEXT / "RTW88WCLTxCompletionWorkQueue.hpp").read_text()
worker_cpp = (KEXT / "RTW88WCLTxCompletionWorkQueue.cpp").read_text()
assert "static UInt32 txCompletionAction" in queues_h
assert "UInt32 RTW88WCLSkywalkQueues::txCompletionAction" in queues_cpp
assert "return 0;" in queues_cpp[queues_cpp.index("UInt32 RTW88WCLSkywalkQueues::txCompletionAction"):]
assert "using TxCompletionAction24H32 = UInt32 (*)" in queues_cpp
assert "reinterpret_cast<IOSkywalkTxCompletionQueueAction>" in queues_cpp
assert "UInt32 (*)(OSObject *, IOSkywalkTxCompletionQueue *, IOSkywalkPacket **" not in queues_cpp
assert "enqueuePackets( const IOSkywalkPacket ** packets, UInt32 packetCount, IOOptionBits options )" in completion_sdk
assert "virtual IOReturn completeWithQueue" in packet_sdk
assert "completePackets();" in completion_sdk
assert "const IOSkywalkPacket *batch[1] = { packet };" in worker_cpp
assert "_completionQueue->enqueuePackets(batch, 1, 0) ==" in worker_cpp
assert "kIOReturnSuccess" in worker_cpp
assert "completeWithQueue(queue, Tx, 0)" in worker_cpp
assert "setCompletionNotifier" in adapter_h
assert "clearCompletionNotifier" in adapter_h
assert "signalWorkAvailable()" in worker_cpp
assert "IOTimerEventSource::timerEventSource" in worker_cpp
assert "setTimeoutMS(kRetryDelayMilliseconds)" in worker_cpp
assert "readyCompletionCount() != 0" in worker_cpp
assert "_completionQueue->enqueuePackets" in worker_cpp
assert "drainCompletions(" in worker_cpp
assert "_retryTimer->cancelTimeout()" in worker_cpp
assert "_workLoop->removeEventSource(this)" in worker_cpp
assert "_workLoop->removeEventSource(_retryTimer)" in worker_cpp
assert "_txCompletionWorker->stop()" in controller_cpp
assert "_txCompletionWorker->release()" in controller_cpp
assert "_txCompletionWorker->init(this, _workLoop, _txAdapter" in controller_cpp
assert "_skywalkQueues->txCompletionQueue()" in controller_cpp
assert "registerEthernetInterface(" not in worker_cpp
assert "enable()" not in worker_cpp

# Native activation remains outside Stage92.
code = queues_cpp + controller_cpp + worker_cpp
code_without_comments = re.sub(r"/\*.*?\*/|//[^\n]*", "", code, flags=re.S)
assert "registerEthernetInterface(" not in code_without_comments
assert "completeWithQueue(" not in code_without_comments

print("PASS: target 24H32 TX action ABI is UInt32 plus IOSkywalkPacket * const *")
print("PASS: callback accepts only a bounded contiguous prefix")
print("PASS: rejected packets remain Skywalk-owned; accepted packets have retained completion tickets")
print("PASS: submission quiesce precedes radio/PCI teardown and queue rollback")
print("PASS: Stage92 TX completion worker is source-wired; RX delivery and native registration remain fenced")
