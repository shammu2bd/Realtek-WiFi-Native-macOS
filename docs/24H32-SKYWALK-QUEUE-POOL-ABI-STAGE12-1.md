# Stage 12.1 — Queue/pool ABI collector repair

The first Stage 12 run stopped after pass 1. The collector found the expected
method-list file but its parser accepted only numbered `address + mangled
symbol` rows. The actual target `IOSkywalkPacketQueue.methods.txt` did not
contain any row in that narrow form, so no pass-2 archive was generated.

This repair makes the collector handle exact Itanium symbol tokens embedded
anywhere in a method-list row and uses only exact class-owned mangled symbols
from `INDEX.txt` as a fallback. It does not demangle or invent private method
signatures. If both sources lack exact symbols, the helper reports the file
size and a bounded preview, while the shell collector preserves the temporary
pass data for a follow-up forensic check.

## Checks on the development host

```sh
python3 tests/test-wcl-queue-pool-ref-stage12.py
bash -n tools/collect-sequoia-abi-24H32-stage12.sh
```

The target Mac must rerun the complete two-pass collector. Success requires
all four classes to yield exact symbol lists, pass 2 to complete, an archive
to be created, and no nonzero exit status. The earlier 374-function pass-1
result alone is not a completed queue/pool audit.

No driver source, registration call, queue/pool creation, ownership transfer,
BSD publication, RX delivery, or TX completion is enabled by this repair.
