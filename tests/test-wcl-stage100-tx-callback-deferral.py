#!/usr/bin/env python3
"""Stage100/101 TX skb deferred ownership and teardown source audit."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
COMPAT = ROOT / "driver/RTL88WiFi/src/compat"
KEXT = ROOT / "driver/RTL88WiFi/src/kext"
QUEUE = (COMPAT / "linux/mpsc_bounded_queue.h").read_text()
SKBUFF = (COMPAT / "linux/skbuff.h").read_text()
COMPAT_C = (COMPAT / "rtw88_compat.c").read_text()
COMPAT_H = (COMPAT / "rtw88_compat.h").read_text()
RADIO = (KEXT / "RTW88IEEE80211.cpp").read_text()
LEGACY_CPP = (KEXT / "RTW88PCIDevice.cpp").read_text()
LEGACY_HPP = (KEXT / "RTW88PCIDevice.hpp").read_text()
WCL_CPP = (KEXT / "wcl24h32/RTW88WCLPCIBackend.cpp").read_text()
WCL_HPP = (KEXT / "wcl24h32/RTW88WCLPCIBackend.hpp").read_text()
WCL_CONTROLLER = (KEXT / "wcl24h32/RTW88WCLController.cpp").read_text()

def body(src, marker):
    at = src.find(marker)
    if at < 0: raise RuntimeError("missing source marker: " + marker)
    start = src.find("{", at)
    depth = 0
    quote = None
    escaped = line = comment = False
    i = start
    while i < len(src):
        ch = src[i]
        nx = src[i + 1] if i + 1 < len(src) else ""
        if line:
            if ch == "\n": line = False
        elif comment:
            if ch == "*" and nx == "/": comment = False; i += 1
        elif quote:
            if escaped: escaped = False
            elif ch == chr(92): escaped = True
            elif ch == quote: quote = None
        elif ch == "/" and nx == "/": line = True; i += 1
        elif ch == "/" and nx == "*": comment = True; i += 1
        elif ch in ("'", '"'): quote = ch
        elif ch == "{": depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0: return src[at:i + 1]
        i += 1
    raise RuntimeError("unterminated source body: " + marker)

checks = []
def check(name, ok, detail): checks.append((name, bool(ok), detail))

enqueue = body(QUEUE, "rtw88_mpsc_bounded_queue_enqueue(")
dequeue = body(QUEUE, "rtw88_mpsc_bounded_queue_dequeue(")
drain = body(COMPAT_C, "static void rtw88_skb_free_drain_batch(")
producer = body(COMPAT_C, "bool rtw88_defer_skb_free(")
exit_ = body(COMPAT_C, "bool rtw88_compat_exit(")
reaper = body(COMPAT_C, "static void rtw88_skb_free_reaper_fn(")
fallback = body(COMPAT_C, "void ieee80211_tx_status_irqsafe(")
callback = body(RADIO, "void RTW88IEEE80211::compat_tx_status(")
tx_status = body(RADIO, "void RTW88IEEE80211::txStatus(")
legacy_stop = body(LEGACY_CPP, "void RTW88PCIDevice::stop(")
legacy_free = body(LEGACY_CPP, "void RTW88PCIDevice::free(")
legacy_teardown = body(LEGACY_CPP, "bool RTW88PCIDevice::teardown(")
wcl_close = body(WCL_CPP, "IOReturn RTW88WCLPCIBackend::close(")
wcl_resources = body(WCL_CPP, "bool RTW88WCLPCIBackend::closeResources(")
wcl_free = body(WCL_CPP, "void RTW88WCLPCIBackend::free(")
controller_release = body(WCL_CONTROLLER, "IOReturn RTW88WCLController::releaseNativeResources(")
controller_free = body(WCL_CONTROLLER, "void RTW88WCLController::free(")

check("BOUNDED_POWER_OF_TWO_RING",
      "RTW88_MPSC_QUEUE_CAPACITY 2048U" in QUEUE and
      "(RTW88_MPSC_QUEUE_CAPACITY - 1U)" in QUEUE,
      "fixed 2048-slot queue bounds memory and wrap mask is power-of-two")
check("SEQUENCE_GENERATIONS_REPLACE_ABA_STACK",
      "volatile uint32_t sequence" in QUEUE and
      "__atomic_load_n(&slot->sequence" in enqueue and
      "__atomic_store_n(&slot->sequence" in enqueue and
      "rtw88_mpsc_retire_stack" not in QUEUE,
      "per-slot generations replace reclaimable head pointers")
check("PRODUCER_RESERVATION_IS_ATOMIC",
      "__atomic_compare_exchange_n(&queue->enqueue_pos" in enqueue,
      "concurrent producers reserve unique queue positions")
check("PRODUCER_RELEASE_PUBLICATION",
      "slot->value = value" in enqueue and "__ATOMIC_RELEASE" in enqueue,
      "consumer cannot observe a slot before pointer publication")
check("QUEUE_FULL_IS_EXPLICIT",
      "difference < 0" in enqueue and "return false" in enqueue,
      "full queue is rejected without overwriting a live slot")
check("CONSUMER_ACQUIRES_AND_RECYCLES_GENERATION",
      "__ATOMIC_ACQUIRE" in dequeue and
      "position + RTW88_MPSC_QUEUE_CAPACITY" in dequeue and
      "queue->dequeue_pos = position + 1U" in dequeue,
      "single consumer advances slot generation before reuse")
check("SKBUFF_HAS_NO_INTRUSIVE_STACK_NODE",
      "deferred_free_node" not in SKBUFF and "mpsc_retire_stack" not in SKBUFF,
      "skb lifetime is no longer coupled to a reclaimed stack link")
check("REAPER_DRAINS_BOUNDED_QUEUE",
      "rtw88_mpsc_bounded_queue_dequeue" in drain and
      "kfree_skb(skb)" in drain and "rtw88_mpsc_retire_stack" not in drain,
      "sole deferred consumer reclaims dequeued skbs")
check("PRODUCER_ACCOUNTING_PRECEDES_PUBLICATION",
      producer.find("g_tx_skb_free_outstanding") < producer.find("rtw88_mpsc_bounded_queue_enqueue") and
      "if (!rtw88_mpsc_bounded_queue_enqueue" in producer,
      "outstanding count is visible before consumer can pop")
check("QUEUE_FULL_ROLLS_BACK_OUTSTANDING",
      producer.find("if (!rtw88_mpsc_bounded_queue_enqueue") <
      producer.find("__atomic_sub_fetch(&g_tx_skb_free_outstanding"),
      "full queue rolls back outstanding before quarantine")
check("PRODUCER_NEVER_FREES_OR_LOGS",
      "kfree_skb(" not in producer and "IOFree(" not in producer and
      "IOLog(" not in producer and "return false" in producer,
      "closed/full paths do not perform synchronous IOFree")
check("REAPER_WAKEUP_HANDSHAKE_RETAINED",
      "RTW88_SKB_FREE_REAPER_RESIGNAL" in reaper and
      "__atomic_compare_exchange_n" in reaper and
      "rtw88_skb_free_drain_batch();" in reaper,
      "producer arriving during drain cannot lose its wakeup")
check("EXIT_RETURNS_FAILURE_IF_QUEUE_NOT_DRAINED",
      "bool rtw88_compat_exit(void)" in COMPAT_C and
      "rtw88_mpsc_bounded_queue_empty" in exit_ and
      "return false" in exit_ and "return true" in exit_,
      "cleanup result is explicit to resource owners")
check("COMPAT_HEADER_EXPOSES_BOOL_EXIT",
      "bool rtw88_compat_exit(void);" in COMPAT_H,
      "callers must check teardown completion")
check("TX_STATUS_CALLBACK_TRANSFERS_SKB",
      "self->txStatus(skb)" in callback and
      "rtw88_defer_skb_free(skb)" in callback and
      "kfree_skb(" not in callback,
      "TX callback only publishes completion and transfers skb ownership")
check("TX_STATUS_HAS_NO_LOCKED_DIAGNOSTIC_IO",
      "rtw88_skb_tx_completion_report(&skb->tx_completion, transmitted)" in tx_status and
      "IOLog(" not in tx_status and "rtw88_candidate_log(" not in tx_status,
      "one-shot completion remains while synchronous logging stays removed")
check("MISSING_CALLBACK_FALLBACK_IS_DEFERRED",
      "rtw88_defer_skb_free(skb)" in fallback and "kfree_skb(skb)" not in fallback,
      "fallback also avoids synchronous free")
check("LEGACY_STOP_PROPAGATES_TEARDOWN_FAILURE",
      "if (!teardown())" in legacy_stop and
      legacy_stop.find("return;") < legacy_stop.find("super::stop(provider)"),
      "legacy superclass stop is withheld when compat exit fails")
check("LEGACY_TEARDOWN_RETAINS_MMIO_AND_PCI",
      "if (!rtw88_compat_exit())" in legacy_teardown and
      "return false" in legacy_teardown and
      legacy_teardown.find("return false") < legacy_teardown.find("_mmioMap->release()"),
      "legacy device does not release PCI/MMIO/DMA after failed reaper drain")
check("LEGACY_FREE_QUARANTINES_OWNER",
      "if (_compatInitialized || _teardownQuarantined)" in legacy_free and
      legacy_free.find("return;") < legacy_free.find("super::free()"),
      "legacy object stays alive while compat runtime is retained")
check("WCL_CLOSE_PROPAGATES_TEARDOWN_FAILURE",
      "if (!closeResources())" in wcl_close and "return kIOReturnBusy" in wcl_close,
      "WCL close returns busy instead of success on failed compat exit")
check("WCL_BACKEND_RETAINS_DMA_AND_LEASE",
      "if (!rtw88_compat_exit())" in wcl_resources and
      "return false" in wcl_resources and
      wcl_resources.find("return false") < wcl_resources.find("releaseDMAEntries()") and
      wcl_resources.find("return false") < wcl_resources.find("clearCompatLease()"),
      "WCL PCI/DMA owner remains retained on failed compat drain")
check("WCL_FREE_QUARANTINES_BACKEND",
      "if (!closeResources())" in wcl_free and
      wcl_free.find("return;") < wcl_free.find("super::free()"),
      "WCL backend is not destroyed after failed deferred drain")
check("CONTROLLER_RETAINS_CHILD_ON_CLOSE_FAILURE",
      "if (closeStatus != kIOReturnSuccess)" in controller_release and
      "return closeStatus" in controller_release,
      "controller keeps backend and workloop owned")
check("CONTROLLER_FREE_ALREADY_QUARANTINES",
      "if (cleanupStatus != kIOReturnSuccess)" in controller_free and
      "return;" in controller_free and "super::free()" in controller_free,
      "controller free path preserves parent lifetime on child failure")


callback_enter = body(COMPAT_C, "static bool rtw88_tx_status_callback_enter(")
callback_quiesce = body(COMPAT_C, "void rtw88_compat_quiesce_tx_status(")
status_dispatch = body(COMPAT_C, "void ieee80211_tx_status_irqsafe(")

check("FULL_TX_STATUS_CALLBACK_HAS_ADMISSION_GATE",
      "g_tx_status_callback_gate" in callback_enter and
      "RTW88_TX_STATUS_GATE_CLOSED" in callback_enter and
      "__atomic_compare_exchange_n" in callback_enter,
      "callback lifetime is counted before entering radio completion code")
check("QUIESCE_CLOSES_GATE_AND_JOINS_ACTIVE_CALLBACKS",
      "__atomic_fetch_or(&g_tx_status_callback_gate" in callback_quiesce and
      "RTW88_TX_STATUS_GATE_CLOSED" in callback_quiesce and
      "RTW88_TX_STATUS_GATE_ACTIVE" in callback_quiesce and
      "IOSleep(1)" in callback_quiesce,
      "teardown waits until the entire synchronous status callback has returned")
check("STATUS_DISPATCH_GATE_COVERS_COMPLETION_AND_SKB_ENQUEUE",
      "rtw88_tx_status_callback_enter()" in status_dispatch and
      status_dispatch.find("rtw88_tx_status_callback_enter()") <
      status_dispatch.find("g_hw_cbs->tx_status") <
      status_dispatch.find("rtw88_tx_status_callback_leave()"),
      "the lease spans completion publication and final skb enqueue")
check("COMPAT_EXIT_QUIESCES_CALLBACK_BEFORE_REAPER_DRAIN",
      "rtw88_compat_quiesce_tx_status();" in exit_ and
      exit_.find("rtw88_compat_quiesce_tx_status();") <
      exit_.find("thread_call_cancel_wait"),
      "no in-flight callback can enqueue after final thread-call join")
check("LEGACY_RADIO_RELEASE_FOLLOWS_CALLBACK_QUIESCE",
      "rtw88_compat_quiesce_tx_status();" in legacy_teardown and
      legacy_teardown.find("rtw88_compat_quiesce_tx_status();") <
      legacy_teardown.find("_ieee80211->release()"),
      "legacy radio object stays alive until all status callbacks return")
check("WCL_COMPLETION_WORKER_RELEASE_FOLLOWS_CALLBACK_QUIESCE",
      "rtw88_compat_quiesce_tx_status();" in controller_release and
      controller_release.find("rtw88_compat_quiesce_tx_status();") <
      controller_release.find("_txCompletionWorker->stop()"),
      "WCL token reaper/worker remains alive until the enclosing callback exits")

failed = [c for c in checks if not c[1]]
for name, ok, detail in checks:
    print(("PASS" if ok else "FAIL") + f": {name}: {detail}")
print(f"PASS_COUNT={len(checks) - len(failed)}")
print(f"FAIL_COUNT={len(failed)}")
print("MPSC_QUEUE=BOUNDED_SEQUENCE_NUMBERED_2048_SLOTS")
print("TEARDOWN_FAILURE=PROPAGATED_TO_LEGACY_AND_WCL_OWNERS")
print("RUNTIME_XNU_SCHEDULING_PROOF=OPEN")
print("STAGE101_RESULT=" + ("PASS_STATIC_WITH_TARGET_COMPILE_PENDING" if not failed else "BLOCKED"))
sys.exit(1 if failed else 0)
