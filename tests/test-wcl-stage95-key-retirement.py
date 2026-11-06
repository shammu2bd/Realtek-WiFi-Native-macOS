#!/usr/bin/env python3
"""Stage95 read-only key-retirement audit for PCI rings and TXQ admission."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "driver/rtw88-stable/drivers/net/wireless/realtek/rtw88"
TX = (BASE / "tx.c").read_text()
TX_H = (BASE / "tx.h").read_text()
PCI = (BASE / "pci.c").read_text()
PCI_H = (BASE / "pci.h").read_text()
MAC80211 = (BASE / "mac80211.c").read_text()
HCI = (BASE / "hci.h").read_text()

def body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise RuntimeError(f"missing function signature: {signature}")
    opening = source.find("{", start)
    if opening < 0:
        raise RuntimeError(f"missing function body: {signature}")
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
    raise RuntimeError(f"unterminated function: {signature}")

def emit(kind: str, name: str, detail: str) -> None:
    print(f"{kind}: {name}: {detail}")

tx_map = body(TX, "enum rtw_tx_queue_type rtw_tx_queue_mapping(")
pci_sync = body(PCI, "static bool rtw_pci_flush_queues_sync(")
pci_write = body(PCI, "static int rtw_pci_tx_write(")
wake = body(MAC80211, "static void rtw_ops_wake_tx_queue(")
tx_work = body(TX, "void __rtw_tx_work(")
txq_push = body(TX, "static int rtw_txq_push_skb(")
set_key = body(MAC80211, "static int rtw_ops_set_key(")
hci_flush = body(HCI, "static inline bool rtw_hci_flush_all_queues_sync(")

passed = 0
blockers = 0

def check(name: str, condition: bool, detail: str) -> None:
    global passed
    if not condition:
        emit("AUDIT_ERROR", name, detail)
        raise SystemExit(2)
    passed += 1
    emit("PASS", name, detail)

# Establish that HI0 is a real TX ring, not a symbolic/unused queue.
hi0_mapping = ("is_broadcast_ether_addr(hdr->addr1) ||" in tx_map and
               "is_multicast_ether_addr(hdr->addr1)" in tx_map and
               "queue = RTW_TX_QUEUE_HI0;" in tx_map)
hi0_pci_ring = ("[RTW_TX_QUEUE_HI0]" in PCI and
                "RTK_PCI_TXBD_IDX_HI0Q" in PCI and
                "tx_rings[RTK_MAX_TX_QUEUE_NUM]" in PCI_H and
                "ring = &rtwpci->tx_rings[queue];" in pci_write)
check("HI0_IS_A_REAL_MULTICAST_PCI_RING", hi0_mapping and hi0_pci_ring,
      "broadcast/multicast data is mapped to HI0; PCI has a dedicated HI0 doorbell and ring")

# A key-retirement flush that excludes this live ring cannot prove GTK DMA retirement.
hi0_skipped = ("q == RTW_TX_QUEUE_HI0" in pci_sync)
if hi0_skipped:
    blockers += 1
    emit("BLOCKER", "HI0_NOT_DRAINED_BEFORE_CAM_CLEAR",
         "the all-queues PCI drain skips HI0 although multicast/broadcast data uses that ring; GTK CAM retirement can race pending descriptors")
else:
    check("HI0_INCLUDED_IN_SYNC_DRAIN", hi0_pci_ring and not hi0_skipped,
          "every live data ring is covered by the synchronous PCI drain")

# flush_work covers queued tx_work only; VO can run the same worker synchronously.
vo_sync = ("if (txq->ac == IEEE80211_AC_VO)" in wake and
           "__rtw_tx_work(rtwdev);" in wake and
           "queue_work(rtwdev->tx_wq, &rtwdev->tx_work);" in wake)
worker_writes_hci = ("rtw_txq_push(rtwdev, rtwtxq, frame_cnt);" in tx_work and
                     "rtw_hci_tx_write(rtwdev, &pkt_info, skb);" in txq_push)
key_flushes_work = "flush_work(&rtwdev->tx_work);" in set_key
if vo_sync and worker_writes_hci and key_flushes_work:
    blockers += 1
    emit("BLOCKER", "SYNCHRONOUS_VO_TXQ_BYPASSES_FLUSH_WORK",
         "wake_tx_queue invokes __rtw_tx_work inline for VO; flush_work waits only the queued work item and does not close this producer/admission path before ring polling")
else:
    check("TXQ_PRODUCER_QUIESCENCE", not (vo_sync and worker_writes_hci and key_flushes_work),
          "no synchronous TXQ producer bypasses key-retirement quiescence")

# A mutex is held by set_key while flush_work runs. The audited worker top-level
# and per-SKB functions do not directly acquire rtwdev->mutex; do not label this
# a proven deadlock without reviewing every lower HCI callback.
mutex_before_flush = (set_key.find("mutex_lock(&rtwdev->mutex)") >= 0 and
                      set_key.find("mutex_lock(&rtwdev->mutex)") < set_key.find("flush_work("))
worker_direct_mutex = ("mutex_lock(&rtwdev->mutex)" in tx_work or
                       "mutex_lock(&rtwdev->mutex)" in txq_push)
check("WORKER_MUTEX_DEADLOCK_NOT_PROVEN", mutex_before_flush and not worker_direct_mutex,
      "flush_work executes under rtwdev->mutex, but no direct mutex acquisition appears in the audited worker bodies; lower HCI call-chain/runtime proof remains open")

# The target PCI transport has the required callback, while missing transports fail closed.
check("PCI_HCI_SYNC_CALLBACK_REGISTERED",
      ".flush_queues_sync = rtw_pci_flush_queues_sync" in PCI,
      "the RTL8821CE PCI transport supplies a result-bearing flush callback")
check("MISSING_HCI_CALLBACK_FAILS_CLOSED",
      "if (!rtwdev->hci.ops->flush_queues_sync)" in hci_flush and
      "return false;" in hci_flush,
      "a transport without the synchronous callback cannot retire a CAM key")

# The CAM clear must remain after both lower-level drains.
check("CAM_CLEAR_AFTER_BOTH_DRAINS",
      "rtw_hci_flush_all_queues_sync(rtwdev, false)" in set_key and
      "rtw_mac_flush_all_queues_sync(rtwdev, false)" in set_key and
      set_key.find("if (!hci_drained || !mac_drained)") <
      set_key.find("rtw_sec_clear_cam(rtwdev, sec, key->hw_key_idx)") and
      "ret = -ETIMEDOUT" in set_key,
      "CAM clear remains fail-closed on PCI/HCI or firmware FIFO drain failure")

print(f"PASS_COUNT={passed}")
print(f"BLOCKER_COUNT={blockers}")
print("AUDIT_SCOPE=READ_ONLY_SOURCE_REVIEW")
print("DRIVER_SOURCE_MODIFIED=NO")
print("STAGE95_RESULT=" + ("BLOCKED" if blockers else "PASS_SOURCE_AUDIT_ONLY"))
print("NATIVE_ACTIVATION=BLOCKED")
sys.exit(0)
