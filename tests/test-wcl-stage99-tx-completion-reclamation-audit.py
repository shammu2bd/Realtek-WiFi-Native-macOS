#!/usr/bin/env python3
"""Stage99 TX completion callback lock and deferred token-reclamation audit."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
COMPAT = ROOT / "driver/RTL88WiFi/src/compat"
KEXT = ROOT / "driver/RTL88WiFi/src/kext"
WCL = KEXT / "wcl24h32"
RTW = ROOT / "driver/rtw88-stable/drivers/net/wireless/realtek/rtw88"

TOKEN_H = (COMPAT / "linux/skbuff_tx_completion.h").read_text()
SKBUFF_H = (COMPAT / "linux/skbuff.h").read_text()
RADIO_CPP = (KEXT / "RTW88IEEE80211.cpp").read_text()
COMPAT_C = (COMPAT / "rtw88_compat.c").read_text()
PCI_C = (RTW / "pci.c").read_text()
TX_C = (RTW / "tx.c").read_text()
ADAPTER_CPP = (WCL / "RTW88WCLSkywalkTxAdapter.cpp").read_text()
ADAPTER_HPP = (WCL / "RTW88WCLSkywalkTxAdapter.hpp").read_text()
WORKER_CPP = (WCL / "RTW88WCLTxCompletionWorkQueue.cpp").read_text()
WORKER_HPP = (WCL / "RTW88WCLTxCompletionWorkQueue.hpp").read_text()
CONTROLLER_CPP = (WCL / "RTW88WCLController.cpp").read_text()
RETIRE_LIST = (WCL / "RTW88WCLCompletionTokenRetireList.hpp").read_text()


def body(src, marker):
    at = src.find(marker)
    if at < 0:
        raise RuntimeError("missing source marker: " + marker)
    start = src.find("{", at)
    if start < 0:
        raise RuntimeError("missing body for: " + marker)
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
    raise RuntimeError("unterminated source body: " + marker)


checks = []


def check(name, ok, detail):
    checks.append((name, bool(ok), detail))


token_dispatch = body(TOKEN_H, "rtw88_skb_tx_completion_dispatch(")
radio_release = body(RADIO_CPP, "static void rtw88_release_skb_tx_completion_token(")
backend_completion = body(ADAPTER_CPP, "void RTW88WCLSkywalkTxAdapter::backendCompletion(")
retire = body(ADAPTER_CPP, "void RTW88WCLSkywalkTxAdapter::retireCompletionToken(")
reap = body(ADAPTER_CPP, "void RTW88WCLSkywalkTxAdapter::reapDeferredCompletionTokens(")
adapter_unbind = body(ADAPTER_CPP, "IOReturn RTW88WCLSkywalkTxAdapter::unbind(")
adapter_free = body(ADAPTER_CPP, "void RTW88WCLSkywalkTxAdapter::free(")
bridge = body(ADAPTER_CPP, 'extern "C" void rtw88_wcl_defer_skb_tx_completion_token(')
worker_init = body(WORKER_CPP, "bool RTW88WCLTxCompletionWorkQueue::init(")
worker_stop = body(WORKER_CPP, "IOReturn RTW88WCLTxCompletionWorkQueue::stop(")
schedule = body(WORKER_CPP, "void RTW88WCLTxCompletionWorkQueue::scheduleTokenReap(")
thread_call_reap = body(WORKER_CPP, "void RTW88WCLTxCompletionWorkQueue::deferredTokenReap(")
worker_check = body(WORKER_CPP, "bool RTW88WCLTxCompletionWorkQueue::checkForWork(")
worker_free = body(WORKER_CPP, "void RTW88WCLTxCompletionWorkQueue::free(")
controller_release = body(CONTROLLER_CPP, "IOReturn RTW88WCLController::releaseNativeResources(")
compat_status = body(COMPAT_C, "void ieee80211_tx_status_irqsafe(")
compat_tx_status = body(RADIO_CPP, "void RTW88IEEE80211::compat_tx_status(")
pci_thread = body(PCI_C, "static irqreturn_t rtw_pci_interrupt_threadfn(")
pci_tx_isr = body(PCI_C, "static void rtw_pci_tx_isr(")
tx_report = body(TX_C, "void rtw_tx_report_handle(")
native_tx_status = body(RADIO_CPP, "void RTW88IEEE80211::txStatus(")

check("TOKEN_HAS_INTRUSIVE_RETIRED_LINK",
      "struct rtw88_skb_tx_completion_token *deferred_next;" in TOKEN_H and
      "RTW88WCLCompletionTokenRetireList<rtw88_skb_tx_completion_token>" in ADAPTER_HPP,
      "token embeds the link consumed by the adapter's MPSC retire stack")

check("TOKEN_RETIRED_BEFORE_BACKEND_CALLBACK",
      token_dispatch.find("if (release)") < token_dispatch.find("release(token)") <
      token_dispatch.find("if (callback)") < token_dispatch.find("callback(context, cookie, transmitted)"),
      "report copies callback inputs, queues token retirement, then calls backend completion")

check("IRQ_CONTEXT_RELEASE_HOOK_DOES_NOT_FREE",
      "rtw88_wcl_defer_skb_tx_completion_token(completion->context, token)" in radio_release and
      "kfree(" not in radio_release and "IOFree(" not in radio_release,
      "release hook performs only the adapter's bounded deferred-retirement publication")

check("LOCK_FREE_MPSC_RETIRE_STACK",
      "node->deferred_next = head;" in RETIRE_LIST and
      "__atomic_compare_exchange_n" in RETIRE_LIST and
      "__atomic_exchange_n" in RETIRE_LIST and
      "IOLock" not in RETIRE_LIST and "spin_lock" not in RETIRE_LIST and
      "kfree(" not in RETIRE_LIST and "IOFree(" not in RETIRE_LIST,
      "completion producers use atomic intrusive push; one consumer detaches a whole list")

check("RETIRE_PUBLICATION_COUNTER_PRECEDES_PUSH",
      retire.find("__atomic_add_fetch(&_retiredCompletionTokenCount") <
      retire.find("_retiredCompletionTokens.push(token)") and
      "kfree(" not in retire and "IOFree(" not in retire,
      "teardown sees a token in the publication window and the producer never frees it")

check("POTENTIALLY_BLOCKING_FREE_ONLY_IN_REAPER",
      reap.find("_retiredCompletionTokens.takeAll()") <
      reap.find("token->deferred_next") < reap.find("kfree(token)") <
      reap.find("__atomic_sub_fetch(&_retiredCompletionTokenCount"),
      "deferred consumer saves the next link, frees token storage, then drops outstanding count")

check("C_BRIDGE_RETURNS_TOKEN_TO_OWNING_ADAPTER",
      "adapter->retireCompletionToken(" in bridge and
      "completion->context" in radio_release,
      "token's retained adapter context receives the retirement node")

check("UNBIND_WAITS_TICKETS_CALLBACKS_AND_RETIRED_TOKENS",
      "_tickets.hasOutstanding()" in adapter_unbind and
      "_backendCompletionCallbacksInFlight" in adapter_unbind and
      "hasRetiredCompletionTokens()" in adapter_unbind,
      "adapter cannot release radio/pool until ticket callbacks and token reclamation drain")

check("ADAPTER_FREE_FAILS_CLOSED_ON_RETIRED_TOKENS",
      "hasRetiredCompletionTokens()" in adapter_free,
      "adapter free quarantines rather than destroying a live retire list")

check("WORKER_ALLOCATES_KERNEL_PRIORITY_REAPER",
      "thread_call_allocate_with_priority" in worker_init and
      "THREAD_CALL_PRIORITY_KERNEL" in worker_init and
      "_tokenReapCall" in WORKER_HPP,
      "one native XNU thread-call runs deferred kfree in kernel thread context")

check("WORKLOOP_SCHEDULES_REAPER_WITH_RESIGNAL_HANDSHAKE",
      "_adapter->hasReapableCompletionTokens()" in schedule and
      "kTokenReapScheduled" in schedule and "kTokenReapResignal" in schedule and
      "thread_call_enter(_tokenReapCall)" in schedule and
      "scheduleTokenReap();" in worker_check,
      "workloop coalesces reaper requests and records a signal that races an active drain")

check("THREADCALL_DRAINS_ONLY_ON_DEFERRED_PATH",
      "_adapter->reapDeferredCompletionTokens();" in thread_call_reap and
      "thread_call_enter(" not in thread_call_reap and
      "kTokenReapResignal" in thread_call_reap and
      "kfree(" not in thread_call_reap and "IOFree(" not in thread_call_reap,
      "reaper callback drains the adapter list and never re-enqueues itself")

check("WORKER_STOP_CANCELS_REAPER_BEFORE_RELEASING_OWNERS",
      worker_stop.find("_workLoop->removeEventSource(this)") <
      worker_stop.find("thread_call_cancel_wait(_tokenReapCall)") <
      worker_stop.find("thread_call_free(_tokenReapCall)") <
      worker_stop.find("_completionQueue->release()") <
      worker_stop.find("_adapter->release()"),
      "event source is removed, pending reaper is joined/freed, then adapter and queue refs drop")

check("WORKER_STOP_REQUIRES_EMPTY_TICKET_AND_TOKEN_OWNERSHIP",
      "_adapter->hasOutstandingCompletions()" in worker_stop and
      "_adapter->hasRetiredCompletionTokens()" in worker_stop,
      "worker refuses to stop while any ticket or token still owns callback state")

check("CONTROLLER_CHECKS_WORKER_STOP_BEFORE_RELEASE",
      controller_release.find("_txAdapter->unbind()") <
      controller_release.find("_txCompletionWorker->stop()") <
      controller_release.find("_txCompletionWorker->release()") and
      "if (workerStopStatus != kIOReturnSuccess)" in controller_release,
      "controller retains worker/queue owners if deferred token cleanup has not finished")

check("PCI_TX_STATUS_CALLBACK_IS_SYNCHRONOUS_UNDER_IRQ_LOCK",
      pci_thread.find("spin_lock_bh(&rtwpci->irq_lock)") <
      pci_thread.find("rtw_pci_tx_isr(") <
      pci_thread.find("spin_unlock_bh(&rtwpci->irq_lock)") and
      "ieee80211_tx_status_irqsafe(hw, skb)" in pci_tx_isr and
      "g_hw_cbs->tx_status(ctx, skb)" in compat_status and
      "self->txStatus(skb)" in compat_tx_status and
      "rtw88_skb_tx_completion_report(&skb->tx_completion, transmitted)" in native_tx_status,
      "normal PCI report path invokes the native callback before irq_lock release")

check("FIRMWARE_TX_REPORT_CALLBACK_IS_SYNCHRONOUS_UNDER_REPORT_LOCK",
      tx_report.find("spin_lock_irqsave(&tx_report->q_lock") <
      tx_report.find("rtw_tx_report_tx_status(rtwdev, cur") <
      tx_report.find("spin_unlock_irqrestore(&tx_report->q_lock"),
      "firmware CCX report path also calls tx status while holding tx_report q_lock")

check("TOKEN_RELEASE_PRECEDES_TICKET_COMPLETION_SIGNAL",
      token_dispatch.find("release(token)") < token_dispatch.find("callback(context, cookie, transmitted)") and
      backend_completion.find("TicketPool::complete(ticket, transmitted)") <
      backend_completion.find("notify(notifyContext);") and
      "kfree(" not in backend_completion and "IOFree(" not in backend_completion,
      "token is counted as retired before the ticket can wake the drain/teardown path")

check("SKBUFF_FREE_REPORT_IS_EXACTLY_ONCE",
      "rtw88_skb_tx_completion_report(&skb->tx_completion, false)" in SKBUFF_H and
      "rtw88_skb_tx_completion_claim" in TOKEN_H and
      "__atomic_exchange_n(&completion->token" in TOKEN_H,
      "both TX status and early skb free claim a single independently allocated token")

failed = [entry for entry in checks if not entry[1]]
for name, ok, detail in checks:
    print(("PASS" if ok else "FAIL") + f": {name}: {detail}")
print(f"PASS_COUNT={len(checks) - len(failed)}")
print(f"FAIL_COUNT={len(failed)}")
print("CALLBACK_SCOPE=PCI_IRQ_LOCK_AND_FIRMWARE_TX_REPORT_LOCK_ARE_HELD_AT_STATUS_CALLBACK")
print("RECLAMATION_SCOPE=IOFree_MOVED_TO_KERNEL_PRIORITY_THREAD_CALL")
print("RUNTIME_LOCK_PROOF=NOT_PROVEN_BY_STATIC_SOURCE_AUDIT")
print("STAGE99_RESULT=" + ("PASS_STATIC_AUDIT_WITH_RUNTIME_REVIEW_OPEN" if not failed else "BLOCKED"))
sys.exit(1 if failed else 0)
