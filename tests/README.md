# Host validation

These ten suites exercise the actual driver functions with host substitutes
for kernel/hardware services, using ASan/UBSan. They cover firmware bounds,
HT/VHT peer capabilities, station lifetime, diagnostic buffers, WPA2
handshake/GTK rekeys, protected RX and A-MSDU filtering, and scan SSID/TIM
handling, and (1.0.2) multi-BSS mesh join selection/fallback and noise
reporting (`test-join-policy.py`), bounded connected-scan policy
(`test-roam-scan-policy.py`), plus the join-report tool (`test-join-report.py`,
which uses fake `ioreg`/`ifconfig`) the Private Wi-Fi address request
(`test-private-mac.py`) and uplink Block Ack recovery (`test-ba-recovery.py`). Timer lifecycle checks inspect source ordering rather than execute
IOKit. They do not establish kernel load or hardware behavior.

Run from the repository root on macOS with Xcode Command Line Tools:

```sh
python3 tests/test-focused.py
python3 tests/test-group-key.py
python3 tests/test-handshake.py
python3 tests/test-rx-filter.py
python3 tests/test-scan-ssid.py
python3 tests/test-join-policy.py
python3 tests/test-join-report.py
python3 tests/test-private-mac.py
python3 tests/test-ba-recovery.py
python3 tests/test-roam-scan-policy.py
```

Build the complete driver with `make -C driver/RTL88WiFi rtl88wifi`.
