#!/usr/bin/env python3
"""Stage100 TX-status skb ownership, deferred free, and teardown audit."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
COMPAT = ROOT / "driver/RTL88WiFi/src/compat"
KEXT = ROOT / "driver/RTL88WiFi/src/kext"
STACK = (COMPAT / "linux/mpsc_retire_stack.h").read_text()
SKBUFF = (COMPAT / "linux/skbuff.h").read_text()
COMPAT_C = (COMPAT / "rtw88_compat.c").read_text()
COMPAT_H = (COMPAT / "rtw88_compat.h").read_text()
RADIO = (KEXT / "RTW88IEEE80211.cpp").read_text()
PCI_CPP = (KEXT / "RTW88PCIDevice.cpp").read_text()
PCI_HPP = (KEXT / "RTW88PCIDevice.hpp").read_text()
WCL_BACKEND = (KEXT / "wcl24h32/RTW88WCLPCIBackend.cpp").read_text()

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

defer = body(COMPAT_C, "bool rtw88_defer_skb_free(")
drain = body(COMPAT_C, "static void rtw88_skb_free_drain_batch(")
reaper = body(COMPAT_C, "static void rtw88_skb_free_reaper_fn(")
init = body(COMPAT_C, "int rtw88_compat_init(")
exit_ = body(COMPAT_C, "void rtw88_compat_exit(")
fallback = body(COMPAT_C, "void ieee80211_tx_status_irqsafe(")
callback = body(RADIO, "void RTW88IEEE80211::compat_tx_status(")
tx_status = body(RADIO, "void RTW88IEEE80211::txStatus(")
pci_start = body(PCI_CPP, "bool RTW88PCIDevice::start(")
pci_teardown = body(PCI_CPP, "void RTW88PCIDevice::teardown(")

check("MPSC_STACK_ATOMIC_PUSH_AND_DETACH",
      "__atomic_compare_exchange_n" in STACK and "__atomic_exchange_n" in STACK and
      "IOLock" not in STACK and "kfree" not in STACK,
      "intrusive MPSC operations do not allocate, lock, or reclaim")
check("SKBUFF_EMBEDS_RETIRE_NODE",
      '#include "mpsc_retire_stack.h"' in SKBUFF and
      "struct rtw88_mpsc_retire_node deferred_free_node;" in SKBUFF,
      "each skb carries its own allocation-free retire node")
check("HEADER_EXPORTS_DEFERRED_OWNERSHIP_API",
      "bool rtw88_defer_skb_free(struct sk_buff *skb);" in COMPAT_H,
      "shared C/C++ ownership-transfer API is declared")
check("PRODUCER_FAILS_CLOSED_WITHOUT_SYNC_FREE",
      "RTW88_SKB_FREE_GATE_CLOSED" in defer and
      "__atomic_compare_exchange_n" in defer and "g_tx_skb_free_rejected" in defer and
      "return false" in defer and "kfree_skb(" not in defer and
      "IOLog(" not in defer and "IOLock" not in defer,
      "closed runtime quarantines skb rather than falling back to IOFree")
check("PRODUCER_DOES_ATOMIC_PUSH_AND_THREADCALL_SIGNAL",
      "rtw88_mpsc_retire_stack_push" in defer and
      "thread_call_enter(g_tx_skb_free_reaper_call)" in defer and
      "RTW88_SKB_FREE_REAPER_RESIGNAL" in defer and
      "IOFree(" not in defer and "kfree(" not in defer,
      "producer boundary performs only atomics, intrusive publication and signal")
check("DEFERRED_CONSUMER_IS_ONLY_REAPER_KFREE",
      "rtw88_mpsc_retire_stack_take_all" in drain and
      "kfree_skb(skb)" in drain and
      "__atomic_sub_fetch(&g_tx_skb_free_outstanding" in drain,
      "detached consumer performs the final skb reclaim")
check("REAPER_SINGLE_FLIGHT_RESIGNAL",
      "RTW88_SKB_FREE_REAPER_RESIGNAL" in reaper and
      "__atomic_compare_exchange_n" in reaper and
      "rtw88_skb_free_drain_batch();" in reaper,
      "enqueue racing an active reaper is observed by the state handshake")
check("INIT_CREATES_REAPER_BEFORE_ADMISSION",
      "thread_call_allocate_with_priority" in init and
      "THREAD_CALL_PRIORITY_KERNEL" in init and
      init.find("g_tx_skb_free_reaper_call = thread_call_allocate_with_priority") <
      init.find("g_tx_skb_free_producer_gate, 0U"),
      "TX skb free admission opens only after kernel-priority reaper allocation")
check("INIT_ROLLBACK_RELEASES_PARTIAL_REAPER",
      "thread_call_free(g_tx_skb_free_reaper_call)" in init and
      "destroy_workqueue(g_datapath_wq)" in init,
      "failed initialization unwinds the partially allocated compat runtime")
check("EXIT_CLOSES_AND_DRAINS_AFTER_PRODUCERS_STOP",
      exit_.find("destroy_workqueue(g_datapath_wq)") < exit_.find("RTW88_SKB_FREE_GATE_CLOSED") <
      exit_.find("RTW88_SKB_FREE_GATE_PRODUCERS") < exit_.find("thread_call_cancel_wait") <
      exit_.find("rtw88_skb_free_drain_batch") < exit_.find("thread_call_free"),
      "teardown closes producers, joins reaper, drains final batch, then frees call")
check("EXIT_RETAINS_RUNTIME_ON_DRAIN_FAILURE",
      "deferred TX skb reaper did not drain" in exit_ and
      "retaining compat runtime" in exit_ and
      exit_.find("return;") < exit_.find("if (work_state_lock)"),
      "runtime is retained when deferred ownership cannot be proven empty")
check("TX_STATUS_CALLBACK_TRANSFERS_SKB",
      "self->txStatus(skb)" in callback and "rtw88_defer_skb_free(skb)" in callback and
      "kfree_skb(" not in callback and "IOFree(" not in callback,
      "callback returns skb ownership to generic compat reaper")
check("MISSING_CALLBACK_FALLBACK_IS_DEFERRED",
      "rtw88_defer_skb_free(skb)" in fallback and "kfree_skb(skb)" not in fallback,
      "missing status callback cannot free synchronously under driver lock")
check("TX_STATUS_CALLBACK_HAS_NO_DIAGNOSTIC_IO",
      "rtw88_skb_tx_completion_report(&skb->tx_completion, transmitted)" in tx_status and
      "IOLog(" not in tx_status and "rtw88_candidate_log(" not in tx_status and
      "kfree_skb(" not in tx_status,
      "one-shot completion remains; frame parsing and IOLog are removed from locked path")
check("LEGACY_RUNTIME_INIT_FAILURE_IS_CHECKED",
      "const int compatStatus = rtw88_compat_init();" in pci_start and
      "if (compatStatus != 0)" in pci_start and "_compatInitialized = true;" in pci_start and
      "bool                    _compatInitialized = false;" in PCI_HPP,
      "legacy start cannot proceed without the required compat reaper")
check("LEGACY_EXIT_GUARDED_BY_INIT_FLAG",
      "if (_compatInitialized)" in pci_teardown and
      "_compatInitialized = false;" in pci_teardown,
      "legacy teardown exits only the runtime it initialized")
check("WCL_RUNTIME_INIT_ALREADY_CHECKED",
      "const int compatStatus = rtw88_compat_init();" in WCL_BACKEND and
      "if (compatStatus != 0)" in WCL_BACKEND and
      "rtw88_compat_exit();" in WCL_BACKEND,
      "native WCL preserves its checked compat runtime lifecycle")

failed = [c for c in checks if not c[1]]
for name, ok, detail in checks:
    print(("PASS" if ok else "FAIL") + f": {name}: {detail}")
print(f"PASS_COUNT={len(checks) - len(failed)}")
print(f"FAIL_COUNT={len(failed)}")
print("CALLBACK_FREE=DEFERRED_XNU_KERNEL_THREAD_CALL")
print("TX_STATUS_DIAGNOSTICS=OMITTED_FROM_LOCKED_CALLBACK")
print("TEARDOWN=PRODUCER_QUIESCENCE_REAPER_JOIN_AND_DRAIN")
print("TARGET_XNU_RUNTIME_LOCK_ORDER=OPEN")
print("STAGE100_RESULT=" + ("PASS_STATIC_WITH_TARGET_COMPILE_PENDING" if not failed else "BLOCKED"))
sys.exit(1 if failed else 0)
