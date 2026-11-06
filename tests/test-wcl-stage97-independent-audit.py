#!/usr/bin/env python3
"""Stage97 independent CAM bounds and TXQ lock-order source audit."""
from pathlib import Path
import sys

BASE = Path("driver/rtw88-stable/drivers/net/wireless/realtek/rtw88")
SEC = (BASE / "sec.c").read_text()
SEC_H = (BASE / "sec.h").read_text()
MAC80211 = (BASE / "mac80211.c").read_text()
TX = (BASE / "tx.c").read_text()
MAIN_H = (BASE / "main.h").read_text()
PCI = (BASE / "pci.c").read_text()

def body(src, sig):
    a = src.find(sig)
    if a < 0:
        raise RuntimeError("missing " + sig)
    o = src.find("{", a)
    depth = 0
    quote = None
    escaped = line = block = False
    i = o
    while i < len(src):
        ch = src[i]
        nx = src[i + 1] if i + 1 < len(src) else ""
        if line:
            if ch == "\n": line = False
        elif block:
            if ch == "*" and nx == "/": block = False; i += 1
        elif quote:
            if escaped: escaped = False
            elif ch == "\\\\": escaped = True
            elif ch == quote: quote = None
        elif ch == "/" and nx == "/": line = True; i += 1
        elif ch == "/" and nx == "*": block = True; i += 1
        elif ch in ("'", '"'): quote = ch
        elif ch == "{": depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0: return src[a:i + 1]
        i += 1
    raise RuntimeError("unterminated " + sig)

checks = []
def check(n, ok, why): checks.append((n, bool(ok), why))

free_cam = body(SEC, "int rtw_sec_get_free_cam(")
write_cam = body(SEC, "void rtw_sec_write_cam(")
clear_cam = body(SEC, "void rtw_sec_clear_cam(")
set_key = body(MAC80211, "static int rtw_ops_set_key(")
worker = body(TX, "void __rtw_tx_work(")
quiesce = body(TX, "void rtw_txq_quiesce(")
resume = body(TX, "void rtw_txq_resume(")
wake = body(MAC80211, "static void rtw_ops_wake_tx_queue(")
pci_drain = body(PCI, "static bool rtw_pci_flush_queues_sync(")

check("CAM_SLOT_COUNT_IS_32", "#define RTW_MAX_SEC_CAM_NUM" in (BASE / "main.h").read_text() and
      "total_cam_num = 32" in (BASE / "main.c").read_text(),
      "CAM storage capacity and runtime count agree at 32 entries")
check("FULL_ALLOCATOR_RETURNS_SENTINEL", "find_first_zero_bit(sec->cam_map, RTW_MAX_SEC_CAM_NUM)" in free_cam,
      "allocator can return slot-count sentinel when all entries are occupied")
check("SET_KEY_REJECTS_EQUAL_TO_COUNT",
      "hw_key_idx >= sec->total_cam_num" in set_key and
      "hw_key_idx >= RTW_MAX_SEC_CAM_NUM" in set_key and
      "cmd == DISABLE_KEY ? -EINVAL : -ENOSPC" in set_key,
      "SET_KEY/DISABLE_KEY reject the first invalid index before CAM access")
check("CAM_WRITE_HAS_DEFENSIVE_BOUNDS",
      "hw_key_idx >= RTW_MAX_SEC_CAM_NUM" in write_cam and
      "hw_key_idx >= sec->total_cam_num" in write_cam and
      write_cam.find("return;") < write_cam.find("cam = &sec->cam_table[hw_key_idx]"),
      "low-level CAM writer guards array access independently")
check("CAM_CLEAR_HAS_DEFENSIVE_BOUNDS",
      "hw_key_idx >= RTW_MAX_SEC_CAM_NUM" in clear_cam and
      "hw_key_idx >= sec->total_cam_num" in clear_cam and
      clear_cam.find("return;") < clear_cam.find("cam = &sec->cam_table[hw_key_idx]"),
      "low-level CAM clearer guards array access independently")
check("INLINE_VO_AND_QUEUED_WORK_SHARE_GATE",
      "if (txq->ac == IEEE80211_AC_VO)\n\t\t__rtw_tx_work(rtwdev);" in wake and
      "queue_work(rtwdev->tx_wq, &rtwdev->tx_work);" in wake and
      "if (rtwdev->txq_quiescing)" in worker,
      "both VO inline and deferred worker paths observe the same quiescence gate")
check("QUIESCE_SERIALIZES_ACTIVE_WORKER",
      quiesce.find("spin_lock_bh(&rtwdev->txq_lock)") <
      quiesce.find("rtwdev->txq_quiescing = true") <
      quiesce.find("spin_unlock_bh(&rtwdev->txq_lock)") <
      quiesce.find("flush_work(&rtwdev->tx_work)"),
      "lock acquisition waits for an active worker before queued-work flush")
check("RESUME_REKICKS_RETAINED_TXQS",
      resume.find("rtwdev->txq_quiescing = false") <
      resume.find("flush_work(&rtwdev->tx_work)") <
      resume.find("queue_work(rtwdev->tx_wq, &rtwdev->tx_work)"),
      "resume joins an early-return worker then guarantees a deferred re-kick")
check("HI0_INCLUDED_IN_SYNC_PCI_DRAIN",
      "q == RTW_TX_QUEUE_BCN || q == RTW_TX_QUEUE_H2C" in pci_drain and
      "q == RTW_TX_QUEUE_HI0" not in pci_drain and
      "__pci_flush_queue_sync(rtwdev, q)" in pci_drain,
      "multicast/broadcast HI0 ring is polled before key retirement")

failed = [x for x in checks if not x[1]]
for n, ok, why in checks:
    print(("PASS" if ok else "FAIL") + f": {n}: {why}")
print(f"PASS_COUNT={len(checks)-len(failed)}")
print(f"FAIL_COUNT={len(failed)}")
print("AUDIT_SCOPE=STATIC_SOURCE_REVIEW; LOCK_ORDER_RUNTIME_NOT_PROVEN")
print("STAGE97_RESULT=" + ("PASS_STATIC_AUDIT_WITH_OPEN_RUNTIME_REVIEW" if not failed else "BLOCKED"))
sys.exit(1 if failed else 0)
