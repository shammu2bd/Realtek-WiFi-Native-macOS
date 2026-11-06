# Stage94 — shared radio TX synchronization and key retirement

Date: 2026-11-06  
Branch: `work/stage91-tx-submission-callback-v1`  
Final validated source head: `b667bfc4aac0f2ceacf8239a00e20551b45674df`

## Result

**Portable CI and read-only source integration audit: PASS.**

GitHub Actions run: [42150985888](https://github.com/shammu2bd/Realtek-WiFi-Native-macOS/actions/runs/42150985888)

- Radio admission gate: C++11 model compiled and passed three four-AC stress runs.
- Packed Block Ack state: C++11 concurrency model passed.
- Source integration audit: 39 checks passed; zero blockers.

## Production-source integration

- One atomic radio TX reader/writer gate now covers all four direct RTW88 submission functions and WMM packet entry.
- WPA G1/M1/M3 state changes run as writer transactions; the matching EAPOL reply uses an atomic writer-to-reader downgrade, with no admission gap.
- EAPOL protection is explicit per frame; the shared protect-next-frame flag is removed.
- PTK/GTK/station/target-BSS/channel-width/BA state updates are serialized against WMM TX. BA active+TID is one packed atomic snapshot.
- CCMP PN and QoS sequence allocators are not reset during rekey or station teardown.
- A timed-out PCI/FIFO drain refuses CAM clear. Key objects remain allocated; station free is also withheld until key retirement and RX-poll drain are confirmed.
- RTW88 stop and PCI/VIF removal run outside the radio writer, avoiding an RX/NAPI worker waiting on the writer while stop waits for that worker.

## Hardware key-retirement contract added

- PCI flush now returns success only when each relevant hardware read pointer reaches its software write pointer; timeout is reported.
- MAC flush returns success only when firmware reserved pages return to available-page counts for all mapped priority queues.
- HCI exposes a result-bearing synchronous flush callback; a missing callback fails closed.
- `DISABLE_KEY` flushes queued TX work and requires both HCI/PCI and MAC firmware drains before clearing the CAM slot. It uses the key's assigned CAM index rather than requiring another free slot.
- Rekey disables/drains the old CAM slot before using it for the replacement. If new-key programming fails, the old key is restored where possible; data TX remains closed on failure.

## Exact validation scope and remaining gates

The successful run used Ubuntu 26.04, GNU C++ 15.2.0 and Python 3.14.4. It did **not** compile the macOS kernel/IOKit driver or target Mach-O objects. A final atomic-power-load assertion was added and passed in the final run.

Not performed: full kext link, signing, installation, loading, target 24H32 runtime validation, fresh running-kernel disassembly, RTL8821CE hardware TX/RX or throughput testing.

Native queue registration/enabling, interface publication, radio start and PR merge remain blocked. PR #4 remains draft/unmerged.
