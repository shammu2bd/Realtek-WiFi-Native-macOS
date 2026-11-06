#!/usr/bin/env python3
"""Stage96 read-only regression audit for HI0 drain and shared TXQ quiescence."""
from pathlib import Path
import sys

BASE = Path("driver/rtw88-stable/drivers/net/wireless/realtek/rtw88")
MAIN_H = (BASE / "main.h").read_text()
MAIN_C = (BASE / "main.c").read_text()
TX_H = (BASE / "tx.h").read_text()
TX = (BASE / "tx.c").read_text()
PCI = (BASE / "pci.c").read_text()
MAC80211 = (BASE / "mac80211.c").read_text()
HCI = (BASE / "hci.h").read_text()

def body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise RuntimeError(f"missing function signature: {signature}")
    opening = source.find("{", start)
    depth = 0
    quote = None
    escaped = line_comment = block_comment = False
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
            elif ch == "\\\\":
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
    raise RuntimeError(f"unterminated function: {signature}")

checks = []
def check(name: str, ok: bool, detail: str) -> None:
    checks.append((name, ok, detail))

pci_sync = body(PCI, "static bool rtw_pci_flush_queues_sync(")
pci_wait = body(PCI, "static bool __pci_flush_queue_sync(")
pci_hw_rp = body(PCI, "static u32 __pci_get_hw_tx_ring_rp(")
tx_map = body(TX, "enum rtw_tx_queue_type rtw_tx_queue_mapping(")
tx_work = body(TX, "void __rtw_tx_work(")
quiesce = body(TX, "void rtw_txq_quiesce(")
resume = body(TX, "void rtw_txq_resume(")
wake = body(MAC80211, "static void rtw_ops_wake_tx_queue(")
set_key = body(MAC80211, "static int rtw_ops_set_key(")

# HI0 is the real multicast/broadcast data ring and has a valid hardware RP.
check("HI0_MULTICAST_MAPPING", "queue = RTW_TX_QUEUE_HI0;" in tx_map and
      "is_multicast_ether_addr(hdr->addr1)" in tx_map,
      "multicast/broadcast frames map to HI0")
check("HI0_HAS_PCI_DOORBELL",
      "[RTW_TX_QUEUE_HI0]" in PCI and "RTK_PCI_TXBD_IDX_HI0Q" in PCI and
      "rtw_pci_tx_queue_idx_addr[pci_q]" in pci_hw_rp and
      "__pci_get_hw_tx_ring_rp(rtwdev, pci_q)" in pci_wait,
      "HI0 ring index maps to its PCI hardware consumer-pointer register")
check("HI0_INCLUDED_IN_SYNC_DRAIN",
      "q == RTW_TX_QUEUE_BCN || q == RTW_TX_QUEUE_H2C" in pci_sync and
      "q == RTW_TX_QUEUE_HI0" not in pci_sync and
      "__pci_flush_queue_sync(rtwdev, q)" in pci_sync,
      "only BCN/H2C are excluded; HI0 is polled by the all-queue drain")

# Both inline VO and queued worker enter the same locked worker body.
check("BOTH_TXQ_DISPATCH_PATHS_SHARE_WORKER",
      "if (txq->ac == IEEE80211_AC_VO)\n\t\t__rtw_tx_work(rtwdev);" in wake and
      "queue_work(rtwdev->tx_wq, &rtwdev->tx_work);" in wake and
      "__rtw_tx_work(rtwdev);" in TX,
      "VO inline and queued work both pass through __rtw_tx_work")
check("TXQ_GATE_IS_LOCK_PROTECTED",
      "spinlock_t txq_lock;\n\tbool txq_quiescing;" in MAIN_H and
      "rtwdev->txq_quiescing = false;" in MAIN_C,
      "quiescence state is explicitly initialized and protected by txq_lock")
check("WORKER_CHECKS_GATE_BEFORE_DEQUEUE_OR_HCI",
      tx_work.find("spin_lock_bh(&rtwdev->txq_lock)") <
      tx_work.find("if (rtwdev->txq_quiescing)") <
      tx_work.find("list_for_each_entry_safe") <
      tx_work.find("rtw_hci_tx_kick_off"),
      "worker exits under shared lock before dequeuing or kicking hardware when closed")
check("QUIESCE_CLOSES_GATE_THEN_JOINS_QUEUED_WORK",
      quiesce.find("spin_lock_bh(&rtwdev->txq_lock)") <
      quiesce.find("rtwdev->txq_quiescing = true") <
      quiesce.find("spin_unlock_bh(&rtwdev->txq_lock)") <
      quiesce.find("flush_work(&rtwdev->tx_work)"),
      "lock acquisition joins any active inline worker; flush_work joins queued worker")
check("SET_KEY_QUIESCES_BEFORE_HARDWARE_DRAIN",
      set_key.find("rtw_txq_quiesce(rtwdev)") <
      set_key.find("rtw_hci_flush_all_queues_sync") <
      set_key.find("rtw_mac_flush_all_queues_sync") <
      set_key.find("rtw_sec_clear_cam"),
      "no CAM clear is attempted before TXQ close and both hardware drains")
check("RESUME_REJOINS_WORKER_BEFORE_REKICK",
      resume.find("rtwdev->txq_quiescing = false") <
      resume.find("flush_work(&rtwdev->tx_work)") <
      resume.find("queue_work(rtwdev->tx_wq, &rtwdev->tx_work)"),
      "resume joins a worker that may have observed the closed gate before guaranteed re-kick")
check("SET_KEY_RESUMES_ON_SUCCESS_AND_TIMEOUT",
      "rtw_txq_resume(rtwdev);" in set_key and
      set_key.find("rtw_txq_resume(rtwdev);") > set_key.find("rtw_sec_clear_cam"),
      "TXQ admission is reopened after either successful CAM clear or fail-closed timeout")
check("CAM_CLEAR_REQUIRES_BOTH_DRAINS",
      "if (!hci_drained || !mac_drained)" in set_key and
      set_key.find("if (!hci_drained || !mac_drained)") <
      set_key.find("rtw_sec_clear_cam"),
      "CAM is retained when PCI/HCI or MAC firmware FIFO drain fails")
check("MISSING_HCI_CALLBACK_FAILS_CLOSED",
      "if (!rtwdev->hci.ops->flush_queues_sync)" in HCI and
      "return false;" in HCI,
      "transport without synchronous drain cannot retire a key")

failed = [x for x in checks if not x[1]]
for name, ok, detail in checks:
    print(("PASS" if ok else "FAIL") + f": {name}: {detail}")
print(f"PASS_COUNT={len(checks)-len(failed)}")
print(f"FAIL_COUNT={len(failed)}")
print("AUDIT_SCOPE=STATIC_SOURCE_REGRESSION_ONLY")
print("NATIVE_ACTIVATION=BLOCKED")
print("STAGE96_RESULT=" + ("PASS_SOURCE_AUDIT_ONLY" if not failed else "BLOCKED"))
sys.exit(1 if failed else 0)
