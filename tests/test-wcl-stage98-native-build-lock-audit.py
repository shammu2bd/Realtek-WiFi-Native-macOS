#!/usr/bin/env python3
"""Stage98 native object-graph and PCI/TX callback source audit."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MAKE = (ROOT / "driver/RTL88WiFi/Makefile").read_text()
BASE = ROOT / "driver/rtw88-stable/drivers/net/wireless/realtek/rtw88"
TX = (BASE / "tx.c").read_text()
PCI = (BASE / "pci.c").read_text()
COMPAT = (ROOT / "driver/RTL88WiFi/src/compat/rtw88_compat.c").read_text()
NATIVE = (ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.cpp").read_text()
WORKER = (ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLTxCompletionWorkQueue.cpp").read_text()
IEEE = (ROOT / "driver/RTL88WiFi/src/kext/RTW88IEEE80211.cpp").read_text()

def block(src, marker):
    at = src.find(marker)
    if at < 0:
        raise RuntimeError("missing source marker: " + marker)
    start = src.find("{", at)
    depth = 0
    quote = None
    esc = line = comment = False
    for i in range(start, len(src)):
        ch = src[i]
        nx = src[i + 1] if i + 1 < len(src) else ""
        if line:
            if ch == "\n": line = False
        elif comment:
            if ch == "*" and nx == "/": comment = False
        elif quote:
            if esc: esc = False
            elif ch == chr(92): esc = True
            elif ch == quote: quote = None
        elif ch == "/" and nx == "/": line = True
        elif ch == "/" and nx == "*": comment = True
        elif ch in ("'", '"'): quote = ch
        elif ch == "{": depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0: return src[at:i + 1]
    raise RuntimeError("unterminated source block: " + marker)

def variable(name):
    m = re.search(r"^" + re.escape(name) + r"\s*:=\s*(.*(?:\\\n.*)*)", MAKE, re.M)
    return m.group(1).replace("\\\n", " ") if m else ""

checks = []
def check(name, ok, detail):
    checks.append((name, bool(ok), detail))

native_objs = variable("NATIVE_ALL_OBJS")
compile_target = re.search(r"^native-compile-only:\s*(.+)$", MAKE, re.M)
check("NATIVE_LINK_OBJECT_GRAPH_INCLUDES_TX_COMPLETION_WORKER",
      "$(WCL24H32_TX_COMPLETION_WORK_OBJ)" in native_objs and
      "new RTW88WCLTxCompletionWorkQueue" in NATIVE and
      "RTW88WCLTxCompletionWorkQueue.cpp" in MAKE,
      "native controller constructs the worker and its implementation object is in NATIVE_ALL_OBJS")
check("COMPILE_ONLY_TARGET_COVERS_COMPLETE_NATIVE_OBJECT_GRAPH",
      bool(compile_target) and "$(NATIVE_ALL_OBJS)" in compile_target.group(1),
      "native-compile-only depends on all native objects, not the linked kext")
check("COMPILE_ONLY_TARGET_HAS_NO_LINK_OR_BUNDLE_RECIPE",
      bool(compile_target) and "native-compile-only: $(NATIVE_ALL_OBJS)" in MAKE and
      "NATIVE_COMPILE_ONLY=PASS" in MAKE and
      "NATIVE LD" not in MAKE[MAKE.find("native-compile-only:"):MAKE.find("native-compile-only:")+350],
      "compile-only target ends after object compilation and does not invoke native link/bundle assembly")
check("NATIVE_CORE_DEPFILES_TRACKED",
      "$(NATIVE_CORE_OBJS:.o=.d)" in MAKE,
      "native core object dependency files are included for correct incremental rebuilds")
check("COMPLETION_WORKER_IS_ACTUALLY_USED",
      "_txCompletionWorker = new RTW88WCLTxCompletionWorkQueue" in NATIVE and
      "_txCompletionWorker->init(" in NATIVE and
      "enqueuePackets(batch, 1, 0)" in WORKER,
      "controller owns and initializes the worker that calls the 24H32 completion queue")
wake_stub = block(COMPAT, "void ieee80211_wake_queue(")
check("MACOS_WAKE_QUEUE_SHIM_IS_NOOP",
      not re.search(r"\b(if|while|for|return|[A-Za-z_]\w*\s*\()", wake_stub.split("{",1)[1].rsplit("}",1)[0]),
      "the current macOS compatibility wake_queue shim does not re-enter the TXQ callback")
worker = block(TX, "void __rtw_tx_work(")
push = block(TX, "static int rtw_txq_push_skb(")
check("TXQ_LOCK_COVERS_HCI_SUBMISSION",
      worker.find("spin_lock_bh(&rtwdev->txq_lock)") < worker.find("rtw_txq_push(") <
      worker.find("spin_unlock_bh(&rtwdev->txq_lock)") and "rtw_hci_tx_write" in push,
      "TXQ worker retains txq_lock while the HCI write path submits descriptors")
pci_write = block(PCI, "static int rtw_pci_tx_write_data(")
check("PCI_SUBMISSION_ACQUIRES_IRQ_LOCK",
      "spin_lock_bh(&rtwpci->irq_lock)" in pci_write and
      "spin_unlock_bh(&rtwpci->irq_lock)" in pci_write,
      "PCI HCI submission takes irq_lock while TXQ worker is still in its critical section")
isr = block(PCI, "static irqreturn_t rtw_pci_interrupt_threadfn(")
tx_isr = block(PCI, "static void rtw_pci_tx_isr(")
compat_status = block(COMPAT, "void ieee80211_tx_status_irqsafe(")
tx_status = block(IEEE, "void RTW88IEEE80211::txStatus(")
check("PCI_COMPLETION_CALLBACK_RUNS_UNDER_IRQ_LOCK",
      isr.find("spin_lock_bh(&rtwpci->irq_lock)") < isr.find("rtw_pci_tx_isr(") <
      isr.find("spin_unlock_bh(&rtwpci->irq_lock)") and
      "ieee80211_tx_status_irqsafe(hw, skb)" in tx_isr and
      "g_hw_cbs->tx_status(ctx, skb)" in compat_status and
      "rtw88_skb_tx_completion_report(&skb->tx_completion, transmitted)" in tx_status,
      "PCI completion reaches native txStatus synchronously under irq_lock; terminal reporter's internal lock behavior remains to be audited")

failed = [x for x in checks if not x[1]]
for name, ok, detail in checks:
    print(("PASS" if ok else "FAIL") + f": {name}: {detail}")
print(f"PASS_COUNT={len(checks)-len(failed)}")
print(f"FAIL_COUNT={len(failed)}")
print("LOCK_ORDER_RESULT=REVIEW_REQUIRED_CALLBACK_REPORTER_INTERNALS_AND_TARGET_RUNTIME")
print("BUILD_RESULT=COMPILE_ONLY_TARGET_ADDED_NOT_RUN_ON_TARGET_MAC")
print("STAGE98_RESULT=" + ("PASS_STATIC_AUDIT_WITH_OPEN_RUNTIME_REVIEW" if not failed else "BLOCKED"))
sys.exit(1 if failed else 0)
