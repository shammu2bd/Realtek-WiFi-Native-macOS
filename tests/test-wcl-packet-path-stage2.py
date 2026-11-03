#!/usr/bin/env python3
"""Host tests and source audit for stage-2 packet bounds/TX completion hooks."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "driver/RTL88WiFi"
KEXT = DRIVER / "src/kext"

compiler = shutil.which("clang++") or shutil.which("c++")
assert compiler, "clang++ or c++ is required for the host C++ checks"

for source in ("rtw88_skb_tx_completion_test.cpp", "wcl_packet_span_test.cpp"):
    with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage2-") as tmp:
        binary = Path(tmp) / source.removesuffix(".cpp")
        command = [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pthread",
                   str(ROOT / "tests" / source), "-o", str(binary)]
        subprocess.run(command, check=True, cwd=ROOT)
        subprocess.run([str(binary)], check=True, cwd=ROOT)

skbuff = (DRIVER / "src/compat/linux/skbuff.h").read_text()
backend_h = (KEXT / "RTW88IEEE80211.hpp").read_text()
backend_cpp = (KEXT / "RTW88IEEE80211.cpp").read_text()
queue_cpp = (KEXT / "wcl24h32/RTW88WCLSkywalkQueues.cpp").read_text()
span_h = (KEXT / "wcl24h32/RTW88WCLPacketSpanValidation.hpp").read_text()
view_h = (KEXT / "wcl24h32/RTW88WCLPacketView.hpp").read_text()

assert "rtw88_skb_tx_completion_report(&skb->tx_completion, false)" in skbuff
assert "rtw88_skb_tx_completion_report(&skb->tx_completion, transmitted)" in backend_cpp
assert "outputPacketWithCompletion" in backend_h and "outputPacketWithCompletion" in backend_cpp
assert "rtw88_skb_tx_completion_bind(&skb->tx_completion" in backend_cpp
completion_h = (DRIVER / "src/compat/linux/skbuff_tx_completion.h").read_text()
assert "__atomic_exchange_n" in completion_h
assert "rtw88_skb_tx_completion_claim" in completion_h
assert "rtw88_skb_tx_completion_dispatch" in completion_h
assert "struct rtw88_skb_tx_completion_token *token" in completion_h
assert "RTW88WCLResolveEthernetTxPacket" in queue_cpp
assert "return kIOReturnNotReady;" in queue_cpp
assert "RTW88WCLRangeFits" in span_h
assert "offset <= extent" in span_h and "length <= (extent - offset)" in span_h
assert "getMemorySegmentOffset" in view_h and "getVirtualAddress" in view_h
assert "getPacketBufferCount() != 1" in view_h

print("PASS: detached TX token survives skb reclamation; exactly-once completion/drop")
print("PASS: overflow-safe Skywalk span and Ethernet length validation")
print("PASS: queue callback validates descriptors and remains fail-closed")
