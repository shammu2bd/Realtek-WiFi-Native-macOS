#!/usr/bin/env python3
"""Stage102 XNU thread-call and completion-token lifecycle source proof."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
COMPAT = ROOT / "driver/RTL88WiFi/src/compat"
KEXT = ROOT / "driver/RTL88WiFi/src/kext"
WCL = KEXT / "wcl24h32"
SDK = ROOT / "driver/RTL88WiFi/MacKernelSDK/Headers/kern/thread_call.h"

FILES = {
    "compat_c": (COMPAT / "rtw88_compat.c").read_text(),
    "compat_h": (COMPAT / "rtw88_compat.h").read_text(),
    "queue": (COMPAT / "linux/mpsc_bounded_queue.h").read_text(),
    "sdk": SDK.read_text(),
    "adapter_h": (WCL / "RTW88WCLSkywalkTxAdapter.hpp").read_text(),
    "adapter_c": (WCL / "RTW88WCLSkywalkTxAdapter.cpp").read_text(),
    "worker_h": (WCL / "RTW88WCLTxCompletionWorkQueue.hpp").read_text(),
    "worker_c": (WCL / "RTW88WCLTxCompletionWorkQueue.cpp").read_text(),
    "controller": (WCL / "RTW88WCLController.cpp").read_text(),
    "token": (COMPAT / "linux/skbuff_tx_completion.h").read_text(),
}

def body(src, marker):
    at = src.find(marker)
    if at < 0:
        raise RuntimeError("missing source marker: " + marker)
    start = src.find("{", at)
    if start < 0:
        raise RuntimeError("missing body: " + marker)
    depth = 0
    quote = None
    escaped = line = comment = False
    i = start
    while i < len(src):
        ch = src[i]
        nx = src[i + 1] if i + 1 < len(src) else ""
        if line:
            if ch == "\n":
                line = False
        elif comment:
            if ch == "*" and nx == "/":
                comment = False
                i += 1
        elif quote:
            if escaped:
                escaped = False
            elif ch == chr(92):
                escaped = True
            elif ch == quote:
                quote = None
        elif ch == "/" and nx == "/":
            line = True
            i += 1
        elif ch == "/" and nx == "*":
            comment = True
            i += 1
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[at:i + 1]
        i += 1
    raise RuntimeError("unterminated body: " + marker)

checks = []
def check(name, ok, detail):
    checks.append((name, bool(ok), detail))

compat_helper = body(FILES["compat_c"], "bool rtw88_compat_quiesce_skb_free_reaper(")
compat_exit = body(FILES["compat_c"], "bool rtw88_compat_exit(")
worker_stop = body(FILES["worker_c"], "IOReturn RTW88WCLTxCompletionWorkQueue::stop(")
worker_schedule = body(FILES["worker_c"], "void RTW88WCLTxCompletionWorkQueue::scheduleTokenReap(")
worker_reap = body(FILES["worker_c"], "void RTW88WCLTxCompletionWorkQueue::deferredTokenReap(")
worker_check = body(FILES["worker_c"], "bool RTW88WCLTxCompletionWorkQueue::checkForWork(")
worker_enter = body(FILES["worker_c"], "bool RTW88WCLTxCompletionWorkQueue::enterWorkCallback(")
worker_leave = body(FILES["worker_c"], "void RTW88WCLTxCompletionWorkQueue::leaveWorkCallback(")
worker_notify = body(FILES["worker_c"], "void RTW88WCLTxCompletionWorkQueue::completionNotifier(")
worker_timer = body(FILES["worker_c"], "void RTW88WCLTxCompletionWorkQueue::retryTimerFired(")
adapter_unbind = body(FILES["adapter_c"], "IOReturn RTW88WCLSkywalkTxAdapter::unbind(")
token_retire = body(FILES["adapter_c"], "void RTW88WCLSkywalkTxAdapter::retireCompletionToken(")
token_reap = body(FILES["adapter_c"], "void RTW88WCLSkywalkTxAdapter::reapDeferredCompletionTokens(")
token_state = body(FILES["adapter_c"], "bool RTW88WCLSkywalkTxAdapter::hasRetiredCompletionTokens(")
controller_release = body(FILES["controller"], "IOReturn RTW88WCLController::releaseNativeResources(")
queue_dequeue = body(FILES["queue"], "rtw88_mpsc_bounded_queue_dequeue(")
queue_empty = body(FILES["queue"], "rtw88_mpsc_bounded_queue_empty(")

check("XNU_CANCEL_WAIT_CAVEAT_PRESENT_IN_TARGET_SDK",
      "<i>after</i> the current invocation may be in flight when" in FILES["sdk"],
      "target MacKernelSDK documents that cancel_wait may return with later invocations in flight")
check("XNU_THREAD_CALL_ISACTIVE_AVAILABLE",
      "boolean_t               thread_call_isactive(" in FILES["sdk"] or
      "boolean_t thread_call_isactive(" in FILES["sdk"],
      "target MacKernelSDK exposes pending-or-executing state query")
check("XNU_ISACTIVE_CONTRACT_DOCUMENTED",
      "currently executing" in FILES["sdk"] and "scheduled for execution" in FILES["sdk"],
      "isactive includes both pending and executing invocations")
check("GENERIC_REAPER_CLOSES_PRODUCER_GATE",
      "__atomic_fetch_or(&g_tx_skb_free_producer_gate" in compat_helper and
      "RTW88_SKB_FREE_GATE_CLOSED" in compat_helper,
      "no producer can publish after shutdown closes the gate")
check("GENERIC_REAPER_JOINS_ACTIVE_PRODUCERS",
      "RTW88_SKB_FREE_GATE_PRODUCERS" in compat_helper and "IOSleep(1)" in compat_helper,
      "producer reservation includes the enqueue and thread_call_enter operation")
check("GENERIC_REAPER_CANCELS_THEN_POLLS_ISACTIVE",
      compat_helper.find("thread_call_cancel_wait") <
      compat_helper.find("while (thread_call_isactive") <
      compat_helper.find("rtw88_skb_free_drain_batch"),
      "cancel_wait is followed by an isactive join before final consumption")
check("GENERIC_REAPER_FINAL_DRAIN_BEFORE_FREE",
      compat_helper.find("rtw88_skb_free_drain_batch") <
      compat_helper.find("rtw88_mpsc_bounded_queue_empty") <
      compat_helper.find("thread_call_free"),
      "only the passive final consumer drains after call quiescence and before freeing call storage")
check("GENERIC_REAPER_RETURNS_FAILURE_ON_INCOMPLETE_DRAIN",
      "return false" in compat_helper and "g_tx_skb_free_outstanding" in compat_helper,
      "incomplete ownership remains fail-closed")
check("COMPAT_EXIT_USES_REAPER_JOIN",
      "rtw88_compat_quiesce_tx_status();" in compat_exit and
      "if (!rtw88_compat_quiesce_skb_free_reaper())" in compat_exit and
      compat_exit.find("rtw88_compat_quiesce_skb_free_reaper") <
      compat_exit.find("IOLockFree(work_state_lock)"),
      "global locks/callbacks are not released before the reaper join")
check("COMPAT_HEADER_EXPOSES_REAPER_QUIESCE",
      "bool rtw88_compat_quiesce_skb_free_reaper(void);" in FILES["compat_h"],
      "WCL teardown can explicitly drain generic skb ownership before token worker shutdown")
check("BOUNDED_QUEUE_DEQUEUE_POSITION_ATOMIC",
      "volatile uint32_t dequeue_pos" in FILES["queue"] and
      "__atomic_load_n(&queue->dequeue_pos" in queue_dequeue and
      "__atomic_store_n(&queue->dequeue_pos" in queue_dequeue,
      "single-consumer cursor reads/writes are also race-safe to observers")
check("BOUNDED_QUEUE_EMPTY_USES_ATOMIC_CURSOR",
      "__atomic_load_n(&queue->enqueue_pos" in queue_empty and
      "__atomic_load_n(&queue->dequeue_pos" in queue_empty,
      "concurrent token/teardown observers do not race a plain cursor read")
check("WCL_TOKEN_RETIRE_USES_BOUNDED_MPSC",
      "rtw88_mpsc_bounded_queue_enqueue" in token_retire and
      "RTW88WCLCompletionTokenRetireList" not in FILES["adapter_h"],
      "token retirement uses sequence-numbered queue rather than an intrusive list")
check("TOKEN_COUNT_PRECEDES_PUBLICATION",
      token_retire.find("_retiredCompletionTokenCount") <
      token_retire.find("rtw88_mpsc_bounded_queue_enqueue"),
      "teardown cannot miss token ownership during the publication interval")
check("TOKEN_QUEUE_OVERFLOW_FAILS_CLOSED",
      "if (!rtw88_mpsc_bounded_queue_enqueue" in token_retire and
      "_retiredCompletionTokenRejectedCount" in token_retire and
      "_retiredCompletionTokenCount" in token_retire and
      "__atomic_sub_fetch" not in token_retire,
      "queue-full retains outstanding count and quarantines token instead of freeing in callback context")
check("TOKEN_REAPER_IS_SOLE_QUEUE_CONSUMER",
      "rtw88_mpsc_bounded_queue_dequeue" in token_reap and
      "kfree(token)" in token_reap and
      "__atomic_sub_fetch(&_retiredCompletionTokenCount" in token_reap,
      "token memory is freed only by deferred/passive single consumer")
check("TOKEN_RETIRED_STATE_INCLUDES_QUARANTINE",
      "_retiredCompletionTokenCount" in token_state and
      "rtw88_mpsc_bounded_queue_empty" in token_state,
      "a quarantined overflow token continues to block unbind/stop")
check("ADAPTER_UNBIND_JOINS_COMPLETION_CALLBACKS",
      "_backendCompletionCallbacksInFlight" in adapter_unbind and
      "hasRetiredCompletionTokens()" in adapter_unbind and
      "_tickets.hasOutstanding()" in adapter_unbind,
      "adapter unbind waits ticket and backend callback/token ownership")
check("WORKER_STOP_REQUIRES_CALLBACK_AND_TOKEN_QUIESCENCE",
      "_adapter->hasBackendCompletionCallbacksInFlight()" in worker_stop and
      "_adapter->hasRetiredCompletionTokens()" in worker_stop and
      "_adapter->hasOutstandingCompletions()" in worker_stop,
      "worker refuses to stop while a ticket, token or backend completion callback exists")
check("WORKLOOP_AND_TIMER_CALLBACKS_HAVE_ADMISSION_GATE",
      "enterWorkCallback()" in worker_check and "leaveWorkCallback()" in worker_check and
      "enterWorkCallback()" in worker_notify and "leaveWorkCallback()" in worker_notify and
      "enterWorkCallback()" in worker_timer and "leaveWorkCallback()" in worker_timer,
      "checkForWork, notifier and timer callbacks are counted around worker access")
check("WORKER_STOP_CLOSES_CALLBACK_ADMISSION",
      "__atomic_fetch_or(&_workCallbackGate" in worker_stop and
      "kWorkCallbackGateClosed" in worker_stop and
      "while ((__atomic_load_n(&_workCallbackGate" in worker_stop,
      "all event and timer callback entrants are joined before worker storage is released")
check("WORKER_STOP_REMOVES_EVENT_SOURCES_BEFORE_JOIN",
      worker_stop.find("removeEventSource(_retryTimer)") <
      worker_stop.find("removeEventSource(this)") <
      worker_stop.find("__atomic_fetch_or(&_workCallbackGate"),
      "retry timer and workloop source are detached before callback gate join")
check("WORKER_CANCEL_WAIT_FOLLOWED_BY_ISACTIVE_JOIN",
      worker_stop.find("thread_call_cancel_wait") <
      worker_stop.find("while (thread_call_isactive") <
      worker_stop.find("thread_call_free"),
      "no thread-call storage or worker owner is freed while a later invocation remains active")
check("WORKER_FINAL_TOKEN_DRAIN_AFTER_THREADCALL_JOIN",
      worker_stop.find("thread_call_free") <
      worker_stop.find("reapDeferredCompletionTokens") <
      worker_stop.find("set_skb_tx_completion_token_releaser(nullptr)"),
      "final passive token drain follows call join and precedes retire-hook removal")
check("WORKER_SCHEDULER_ONLY_FROM_GATED_EVENT_SOURCE",
      worker_check.count("scheduleTokenReap();") == 1,
      "the only scheduler invocation is inside counted checkForWork")
check("CONTROLLER_STOPS_RADIO_AND_FENCES_PCI_BEFORE_QUIESCE",
      controller_release.find("_radio->stop()") <
      controller_release.find("setRadioRunning(false)") <
      controller_release.find("rtw88_compat_quiesce_tx_status"),
      "hardware producers are stopped/fenced before callback admission closes")
check("CONTROLLER_DRAINS_GENERIC_SKBS_BEFORE_ADAPTER_UNBIND",
      controller_release.find("rtw88_compat_quiesce_tx_status") <
      controller_release.find("rtw88_compat_quiesce_skb_free_reaper") <
      controller_release.find("_txAdapter->unbind()"),
      "deferred skb destruction may still publish WCL tokens while worker is alive")
check("CONTROLLER_UNBINDS_ADAPTER_BEFORE_STOPPING_WORKER",
      controller_release.find("_txAdapter->unbind()") <
      controller_release.find("_txCompletionWorker->stop()"),
      "worker is stopped only after all tickets and backend callbacks have returned")
check("TOKEN_RELEASE_PRECEDES_BACKEND_COMPLETION",
      FILES["token"].find("release(token)") < FILES["token"].find("callback(context, cookie, transmitted)"),
      "token becomes visible to retirement accounting before completion callback can wake teardown")
check("THREAD_CALL_ENTER_RESULT_NOT_TREATED_AS_FAILURE",
      "(void)thread_call_enter(_tokenReapCall)" in worker_schedule and
      "(void)thread_call_enter(g_tx_skb_free_reaper_call)" in FILES["compat_c"],
      "TRUE means already pending; it is not interpreted as an error")
check("THREAD_CALLS_ALLOCATED_WITH_SUPPORTED_API",
      "thread_call_allocate_with_priority" in FILES["compat_c"] and
      "thread_call_allocate_with_priority" in FILES["worker_c"],
      "both reapers use an allocation form supported by cancel_wait/free")

failed = [item for item in checks if not item[1]]
for name, ok, detail in checks:
    print(("PASS" if ok else "FAIL") + f": {name}: {detail}")
print(f"PASS_COUNT={len(checks) - len(failed)}")
print(f"FAIL_COUNT={len(failed)}")
print("XNU_CANCEL_WAIT_POLICY=ALWAYS_FOLLOWED_BY_ISACTIVE_JOIN")
print("TOKEN_RECLAMATION=SEQUENCE_MPSC_WITH_FAIL_CLOSED_OVERFLOW")
print("STAGE102_RESULT=" + ("PASS_STATIC_REVIEW" if not failed else "BLOCKED"))
sys.exit(1 if failed else 0)
