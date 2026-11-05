# Host validation

## Stage-specific host test artifacts

Stage 89's four-entry TX submission queue contract has a portable C++ test and
a source-integration audit. Run them from the repository root:

```sh
c++ -std=c++17 -Wall -Wextra -Werror -O2 tests/wcl_tx_submission_queue_array_test.cpp -o /tmp/wcl-tx-submission-queue-array-test
/tmp/wcl-tx-submission-queue-array-test
python3 tests/test-wcl-tx-queue-array-contract.py
python3 tests/test-wcl-skywalk-queues.py
```

These tests validate pointer-array cardinality, non-null entries, pairwise
uniqueness, exact WMM class ordering, and source-side reverse release. They
do not establish kernel factory linkage, object retention by a live QueueSet,
registration safety, or RTL8821CE hardware behavior. See
docs/24H32-TX-SUBMISSION-FACTORY-ABI.md for the target symbol crosswalk.


The Stage 18 synthetic regression result is retained in [results/STAGE18-HOST-TEST-RESULTS.txt](results/STAGE18-HOST-TEST-RESULTS.txt). It is a host-side fixture result, not a target-Mac evidence dossier and not permission to activate the native datapath.

These ten suites exercise the actual driver functions with host substitutes
for kernel/hardware services, using ASan/UBSan. They cover firmware bounds,
HT/VHT peer capabilities, station lifetime, diagnostic buffers, WPA2
handshake/GTK rekeys, protected RX and A-MSDU filtering, and scan SSID/TIM
handling, and (1.0.2) multi-BSS mesh join selection/fallback and noise
reporting (`test-join-policy.py`), bounded connected-scan policy
(`test-roam-scan-policy.py`), plus the join-report tool (`test-join-report.py`,
which uses fake `ioreg`/`ifconfig`) the Private Wi-Fi address request
(`test-private-mac.py`) and uplink Block Ack recovery (`test-ba-recovery.py`). Timer lifecycle checks inspect source ordering rather than execute
IOKit. The separate `wcl-event-ring-test.cpp` exercises the allocation-free
WCL event ring (FIFO order, wrap-around, capacity, replacement and eviction)
without IOKit. `test-wcl-packet-path-stage2.py` exercises exactly-once TX
terminal-outcome callbacks, concurrent completion/free races and overflow-safe
Skywalk single-buffer span checks. These tests do not establish kernel load,
queue registration, or hardware behavior. The Stage 3 registration-contract
check also ensures that the target's private registration payloads and
expansion blocks remain opaque until their exact 24H32 layout and callable ABI
are confirmed.

Run from the repository root on macOS with Xcode Command Line Tools:

```sh
c++ -std=c++17 -Wall -Wextra -Werror -O2 tests/wcl-event-ring-test.cpp -o /tmp/wcl-event-ring-test
/tmp/wcl-event-ring-test
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
python3 tests/test-wcl-packet-path-stage2.py
python3 tests/test-wcl-registration-contract.py
```

Build the complete driver with `make -C driver/RTL88WiFi rtl88wifi`.

Stage 4 adds `test-wcl-tx-adapter-stage4.py`, which stress-tests the bounded
128-ticket RTW88 completion handoff with concurrent completion producers and a
single deferred consumer. The native adapter copies the validated Skywalk
single-buffer Ethernet payload into a non-blocking mbuf and submits it through
`RTW88IEEE80211::outputPacketWithCompletion()`. It does not call Skywalk APIs
from the RTW88 completion callback. The TX submission callback remains
fail-closed until the exact 24H32 completion-queue handoff and registration
contract are verified.

Stage 10 verifies the 24H32 registration entry-point declarations and the
zero-success `IOReturn` return convention while keeping every call fenced.
Stage 11 validates the aligned `0x130`-byte opaque `RegistrationInfo` storage
and the exact Apple caller-side writes after `initRegistrationInfo()`:

```sh
python3 tests/test-wcl-registration-info-stage11.py
python3 tests/test-wcl-registration-abi-stage10.py
```

Neither stage enables registration or establishes runtime Skywalk operation.
See `docs/24H32-SKYWALK-REGISTRATION-INFO-STAGE11.md` for the ABI evidence,
validation scope, and remaining queue/pool/ownership blockers.

Stage 8 focused registration ABI evidence extractor:

```sh
python3 tests/test-wcl-registration-abi-extractor-stage8.py
```

On the target Sequoia 24H32 Mac, append complete registration and caller
function disassemblies to the canonical `Development/output.log` with:

```sh
make wcl-abi-audit-24h32 2>&1 | tee -a ../../Development/output.log
```


Stage 12 adds a two-pass, read-only 24H32 kcabi evidence collector. The first
pass obtains method lists for `IOSkywalkPacketQueue`,
`IOSkywalkPacketBufferPool`, `IOSkywalkQueueSet`, and
`IOSkywalkLogicalLink`; the second pass requests their complete function bodies
while retaining the Stage 8-10 registration targets. The parser accepts exact
mangled symbol tokens in method rows and has an `INDEX.txt` fallback. Its test is:

```sh
python3 tests/test-wcl-queue-pool-ref-stage12.py
bash -n tools/collect-sequoia-abi-24H32-stage12.sh
```

Run the actual collector only on macOS Sequoia 15.8.1 / Darwin 24H32 x86_64:

```sh
tools/collect-sequoia-abi-24H32-stage12.sh build/sequoia-abi-24H32-stage12 2>&1 | tee Development/output.log
```

This stage gathers queue/pool lifecycle evidence only. It does not implement or
enable queue registration, ownership transfer, BSD publication, RX delivery,
or TX completion. See
`docs/24H32-SKYWALK-QUEUE-POOL-ABI-STAGE12.md`.


Stage 14 completed on macOS 15.8.1 / 24H32 / x86_64. The target run collected
49 vtables, 325 size records and 701 function bodies with zero missing in both
kcabi passes; all eight generic queue/pool/segment/packet class method lists
were found. The Stage 14 archive was uploaded to the GitHub repository root.

Stage 15 adds a read-only audit of the packet, buffer, pool, memory-segment and
network-packet accessors already used by `RTW88WCLPacketView.hpp` and the RX
adapter. It demangles the exact Stage 14 class-member symbols and requires a
matching disassembly reference for each required call. Host regression test:

```sh
python3 tests/test-skywalk-packet-access-stage15.py
```

Run the actual target-archive audit on the Sequoia 24H32 x86_64 Mac:

```sh
python3 tools/audit-skywalk-packet-access-stage15.py \
  --archive build/sequoia-abi-24H32-stage14/RTL88WiFi-Sequoia-24H32-stage14-generic-skywalk-segment-packet-kcabi.tar.gz \
  --out build/sequoia-abi-24H32-stage15
```

Stage 15 does not alter Kext code or enable packet callbacks. A host fixture
PASS validates the audit tool only; the Stage 15 target run must independently
report every accessor with a matching disassembly body before proceeding to
semantic review or packet-path changes. See
`docs/24H32-SKYWALK-PACKET-ACCESS-ABI-STAGE15.md`.
