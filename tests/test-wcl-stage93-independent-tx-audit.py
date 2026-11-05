#!/usr/bin/env python3
"""Stage93 independent read-only TX completion, teardown, and radio-state audit."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
KEXT = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
RADIO_CPP = ROOT / "driver/RTL88WiFi/src/kext/RTW88IEEE80211.cpp"
RADIO_HPP = ROOT / "driver/RTL88WiFi/src/kext/RTW88IEEE80211.hpp"
SDK_WORKLOOP = ROOT / "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/IOWorkLoop.h"

def read(path):
    if not path.is_file():
        raise RuntimeError(f"required audit input missing: {path.relative_to(ROOT)}")
    return path.read_text()

def braced_function(source, signature):
    start = source.find(signature)
    if start < 0:
        raise RuntimeError(f"function not found: {signature}")
    opening = source.find("{", start)
    if opening < 0:
        raise RuntimeError(f"function body not found: {signature}")
    depth = 0
    quote = None
    escaped = False
    line_comment = False
    block_comment = False
    i = opening
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if line_comment:
            if ch == "\n":
                line_comment = False
        elif block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 1
        elif quote:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = None
        elif ch == "/" and nxt == "/":
            line_comment = True
            i += 1
        elif ch == "/" and nxt == "*":
            block_comment = True
            i += 1
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
        i += 1
    raise RuntimeError(f"unterminated function body: {signature}")

def line_number(source, token):
    pos = source.find(token)
    return source[:pos].count("\n") + 1 if pos >= 0 else 0

checks = []
blockers = []
unresolved = []

def ok(name, detail):
    checks.append((name, detail))
def block(name, detail):
    blockers.append((name, detail))
def open_item(name, detail):
    unresolved.append((name, detail))

try:
    worker_cpp = read(KEXT / "RTW88WCLTxCompletionWorkQueue.cpp")
    worker_hpp = read(KEXT / "RTW88WCLTxCompletionWorkQueue.hpp")
    adapter_cpp = read(KEXT / "RTW88WCLSkywalkTxAdapter.cpp")
    adapter_hpp = read(KEXT / "RTW88WCLSkywalkTxAdapter.hpp")
    slots_hpp = read(KEXT / "RTW88WCLTxCompletionSlots.hpp")
    controller_cpp = read(KEXT / "RTW88WCLController.cpp")
    queues_cpp = read(KEXT / "RTW88WCLSkywalkQueues.cpp")
    radio_cpp = read(RADIO_CPP)
    radio_hpp = read(RADIO_HPP)
    workloop_sdk = read(SDK_WORKLOOP)

    # Terminal callback: atomics + notifier only; packet completion is deferred.
    callback = braced_function(
        adapter_cpp, "void RTW88WCLSkywalkTxAdapter::backendCompletion")
    ordered = (
        callback.find("_backendCompletionCallbacksInFlight") <
        callback.find("TicketPool::complete(ticket, transmitted)") <
        callback.find("notify(notifyContext)") <
        callback.rfind("_backendCompletionCallbacksInFlight")
    )
    forbidden = ("enqueuePackets", "completeWithQueue", "packet->release()",
                 "mbuf_freem", "IOLog(", "IOLockLock(")
    if ordered and all(token not in callback for token in forbidden):
        ok("BACKEND_CALLBACK_CONTEXT",
           "callback-count bracket surrounds ticket publication and notifier; no direct Skywalk/packet release or blocking call found")
    else:
        block("BACKEND_CALLBACK_CONTEXT",
              "callback is not a bounded signal-only completion publisher")

    # Ticket ownership state transitions and retry behavior.
    transitions = (
        "kFree", "kReserved", "kSubmitted", "kCompleting", "kCompleted", "kDraining"
    )
    if all(token in slots_hpp for token in transitions) and \
       "compare_exchange_n(&ticket->state, &expected,\n                                           kCompleted" in slots_hpp and \
       "static void finish(Ticket *ticket)" in slots_hpp:
        ok("TICKET_STATE_MACHINE",
           "fixed ticket slots expose reserved/submitted/completing/completed/draining, retry and finish transitions")
    else:
        block("TICKET_STATE_MACHINE", "ticket lifecycle transition implementation changed or is incomplete")

    drain = braced_function(adapter_cpp, "uint32_t RTW88WCLSkywalkTxAdapter::drainCompletions")
    if ("TicketPool::retry(ticket)" in drain and
        drain.find("TicketPool::retry(ticket)") < drain.find("TicketPool::finish(ticket)") and
        "if (!packet || !sink(packet, transmitted, context))" in drain and
        "packet->release()" in drain):
        ok("RETRY_OWNERSHIP",
           "failed sink restores Completed and preserves packet/ticket; packet retain is released only after successful handoff")
    else:
        block("RETRY_OWNERSHIP", "failed completion handoff may lose packet/ticket ownership")

    # Worker owns the serialized queue consumer and retry timer.
    sink = braced_function(worker_cpp, "bool RTW88WCLTxCompletionWorkQueue::completionSink")
    work = braced_function(worker_cpp, "bool RTW88WCLTxCompletionWorkQueue::checkForWork")
    stop = braced_function(worker_cpp, "void RTW88WCLTxCompletionWorkQueue::stop")
    if ("enqueuePackets(batch, 1, 0)" in sink and
        "drainCompletions(" in work and
        "setTimeoutMS(kRetryDelayMilliseconds)" in work and
        "_adapter->retain()" in worker_cpp and
        "_completionQueue->retain()" in worker_cpp):
        ok("DEFERRED_WORKER",
           "one retained controller-workloop consumer performs synchronous completion handoff and timer retry")
    else:
        block("DEFERRED_WORKER", "completion worker wiring, retention, or retry scheduling is incomplete")

    stop_order = [
        "clearCompletionNotifier(this)", "cancelTimeout()",
        "removeEventSource(_retryTimer)", "removeEventSource(this)",
        "_completionQueue->release()", "_adapter->release()"
    ]
    stop_positions = [stop.find(token) for token in stop_order]
    if all(p >= 0 for p in stop_positions) and stop_positions == sorted(stop_positions):
        ok("WORKER_STOP_ORDER",
           "notifier clear, timer cancellation/removal, worker removal, then retained queue/adapter release")
    else:
        block("WORKER_STOP_ORDER", "worker teardown ordering is incomplete or reordered")

    if ("does not return until the work loop has acknowledged the removal" in workloop_sdk and
        "event source will be released before return" in workloop_sdk):
        ok("WORKLOOP_REMOVE_CONTRACT",
           "pinned IOWorkLoop header documents synchronous event-source removal acknowledgement")
    else:
        open_item("WORKLOOP_REMOVE_CONTRACT",
                  "the checked-in IOWorkLoop header did not expose the synchronous removal contract")

    # Controller ordering and callback lifetime barriers.
    teardown = braced_function(controller_cpp, "IOReturn RTW88WCLController::releaseNativeResources")
    order = [
        "_txAdapter->quiesceSubmissions()",
        "_radio->stop()",
        "_pciBackend->setRadioRunning(false)",
        "_txAdapter->unbind()",
        "_txCompletionWorker->stop()",
        "_skywalkQueues->unbindTXAdapter(_txAdapter)",
        "_skywalkQueues->destroyQueues()"
    ]
    positions = [teardown.find(token) for token in order]
    if all(p >= 0 for p in positions) and positions == sorted(positions):
        ok("CONTROLLER_TEARDOWN_ORDER",
           "submission admission closes before radio stop/PCI fence; adapter unbind precedes worker stop, owner detach, and queue rollback")
    else:
        block("CONTROLLER_TEARDOWN_ORDER", "controller teardown does not preserve the expected producer-to-consumer lifetime order")

    unbind = braced_function(adapter_cpp, "IOReturn RTW88WCLSkywalkTxAdapter::unbind")
    if ("_tickets.hasOutstanding()" in unbind and
        "_backendCompletionCallbacksInFlight" in unbind and
        "finishUnbind()" in unbind):
        ok("ADAPTER_UNBIND_BARRIER",
           "adapter unbind refuses to drop radio/pool while tickets or backend completion callbacks remain")
    else:
        block("ADAPTER_UNBIND_BARRIER", "adapter unbind lacks ticket/callback lifetime barriers")

    owner_unbind = braced_function(queues_cpp, "IOReturn RTW88WCLSkywalkQueues::unbindTXAdapter")
    if ("_txCallbackGate.beginUnbind()" in owner_unbind and
        "_txCallbackGate.canFinishUnbind()" in owner_unbind and
        "adapter->isUnbound()" in owner_unbind and
        "adapter->hasOutstandingCompletions()" in owner_unbind):
        ok("QUEUE_OWNER_DETACH_BARRIER",
           "queue-owner callback gate and adapter completion state must both be quiescent before detach")
    else:
        block("QUEUE_OWNER_DETACH_BARRIER", "queue owner can detach while callbacks or tickets remain")

    # Sequence/PN atomics are a partial solution, not whole-radio serialization.
    sequence_h = read(ROOT / "driver/RTL88WiFi/src/kext/RTW88TxSequenceNumbers.hpp")
    if ("__atomic_fetch_add(&_qos[tid]" in sequence_h and
        "__atomic_compare_exchange_n(&_ccmpPacketNumber" in sequence_h):
        ok("SEQUENCE_AND_PN_ALLOCATORS",
           "per-TID sequence allocation and 48-bit CCMP PN allocation use atomics")
    else:
        block("SEQUENCE_AND_PN_ALLOCATORS", "per-TID sequence or CCMP PN allocator is not atomic")

    tx = braced_function(radio_cpp, "bool RTW88IEEE80211::txDataFrame")
    install = braced_function(radio_cpp, "bool RTW88IEEE80211::installKey")
    clear_keys = braced_function(radio_cpp, "void RTW88IEEE80211::clearKeys")
    release_sta = braced_function(radio_cpp, "void RTW88IEEE80211::releaseSta")
    send_eapol = braced_function(radio_cpp, "bool RTW88IEEE80211::sendEAPOLKey")

    # Evidence for an unprotected shared mutable radio/key state.
    tx_locks = ("IOLockLock(", "IORecursiveLockLock(", "_gate->runAction(",
                "IOCommandGate::runAction(")
    tx_has_lock = any(token in tx for token in tx_locks)
    control_gate_runs = "_gate->runAction(" in radio_cpp or "IOCommandGate::runAction(" in radio_cpp
    lock_member_is_used = "IOLockLock(_lock)" in radio_cpp or "IOLockLock(_lock" in radio_cpp
    key_read = ("_ptkConf->keyidx" in tx and "info->control.hw_key = _ptkConf" in tx)
    key_freed = ("IOFree(*slot, sizeof(**slot))" in install and
                 "IOFree(_ptkConf, sizeof(*_ptkConf))" in clear_keys)
    key_slot_changed = ("*slot = key;" in install and "_ptkConf = nullptr;" in clear_keys)
    eapol_shared = ("_eapolTxProtect" in tx and
                    "_eapolTxProtect = (step == 5)" in send_eapol and
                    "_eapolTxProtect = false" in send_eapol)
    sta_lifetime = ("_sta" in tx and "_sta = nullptr;" in release_sta)
    ba_shared = ("_txBaActive" in tx and "_txBaActive = true;" in radio_cpp and
                 "_txBaActive = false;" in radio_cpp)

    shared_fields = all(("_" + name) in tx for name in
                        ("powered", "wpa2", "ptkConf", "targetBSS", "sta", "vif"))
    if (not tx_has_lock and not control_gate_runs and not lock_member_is_used and
        key_read and key_freed and key_slot_changed and eapol_shared and
        sta_lifetime and shared_fields):
        block(
            "RADIO_KEY_STATE_CONCURRENCY",
            "txDataFrame (RTW88IEEE80211.cpp:%d) reads _ptkConf/_wpa2/_eapolTxProtect/_sta/_vif/_targetBSS without a TX lock or command-gate action; installKey frees/replaces key objects, clearKeys frees _ptkConf, releaseSta clears/frees station state, and sendEAPOLKey toggles the shared protection flag. Four independent WMM queues must not be enabled until this state is serialized or safely snapshotted/refcounted."
            % line_number(radio_cpp, "bool RTW88IEEE80211::txDataFrame")
        )
    else:
        open_item(
            "RADIO_KEY_STATE_CONCURRENCY",
            "static pattern changed; manual review required. tx lock=%s, command-gate serialization=%s, key-read=%s, key-free=%s, EAPOL shared=%s"
            % (tx_has_lock, control_gate_runs, key_read, key_freed, eapol_shared)
        )

    if not tx_has_lock and not control_gate_runs and not lock_member_is_used and ba_shared:
        block(
            "RADIO_BA_STATE_CONCURRENCY",
            "txDataFrame reads _txBaActive/_baTid while BA response/DELBA paths mutate BA state; no common radio TX lock or gate action is visible in this source"
        )
    else:
        open_item("RADIO_BA_STATE_CONCURRENCY",
                  "BA-state synchronization pattern changed or requires manual confirmation")

    # Sequence reset can be atomic and still be semantically unsafe during TX.
    if ("_txSequenceNumbers.resetCCMP();" in clear_keys and
        "_txSequenceNumbers.resetCCMP();" in install and
        "_txSequenceNumbers.resetQoS();" in release_sta and
        "nextCCMP(&packetNumber)" in tx):
        block(
            "SEQUENCE_RESET_VS_INFLIGHT_TX",
            "atomic counters are reset during key/station teardown or key install; prove all transmitters are quiesced before reset, or serialize resets with nonce/sequence allocation"
        )
    else:
        open_item("SEQUENCE_RESET_VS_INFLIGHT_TX",
                  "sequence reset/allocation paths changed; re-review reset linearization")

    if ("_lock    = IOLockAlloc()" in radio_cpp and
        radio_cpp.count("IOLockLock(_lock)") == 0):
        open_item("UNUSED_RADIO_LOCK",
                  "radio allocates _lock but this source has no IOLockLock(_lock) use; establish intended locking contract before reusing it")

    # This audit deliberately cannot certify runtime TX or the target binary.
    open_item("TARGET_RUNTIME_AND_BINARY",
              "no kernel load, hardware TX/RX, or fresh 24H32 running-kernel disassembly was performed by this read-only source audit")

except Exception as exc:
    block("AUDIT_EXECUTION", str(exc))

print("RTL88WIFI STAGE93 INDEPENDENT TX COMPLETION / RADIO CONCURRENCY AUDIT")
print("SCOPE=READ_ONLY_SOURCE_AUDIT")
for name, detail in checks:
    print(f"PASS: {name}: {detail}")
for name, detail in blockers:
    print(f"BLOCKER: {name}: {detail}")
for name, detail in unresolved:
    print(f"OPEN: {name}: {detail}")
print(f"PASS_COUNT={len(checks)}")
print(f"BLOCKER_COUNT={len(blockers)}")
print(f"OPEN_COUNT={len(unresolved)}")
if blockers:
    print("STAGE93_RESULT=BLOCKED")
    print("NATIVE_ACTIVATION=BLOCKED")
    sys.exit(20)
if unresolved:
    print("STAGE93_RESULT=REVIEW_REQUIRED")
    print("NATIVE_ACTIVATION=BLOCKED")
    sys.exit(21)
print("STAGE93_RESULT=PASS")
print("NATIVE_ACTIVATION=STILL_BLOCKED_PENDING_RUNTIME_APPROVAL")
