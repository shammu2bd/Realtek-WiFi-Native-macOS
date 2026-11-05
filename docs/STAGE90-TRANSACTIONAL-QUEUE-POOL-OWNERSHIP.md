# Stage90 — transactional Skywalk queue and pool ownership

## Scope of this increment

Stage90 introduces a fixed-capacity acquisition journal for the native 24H32 queue owner. It makes the queue/pool acquisition prefix explicit, commits only after all nine resources exist and the four TX service classes validate, and rolls back successful acquisitions in strict reverse order.

The nine journal entries are:

1. TX packet pool
2. RX packet pool
3. TX submission queue 0
4. TX submission queue 1
5. TX submission queue 2
6. TX submission queue 3
7. TX completion queue
8. RX submission queue
9. RX completion queue

The journal records an entry only after its factory returns a non-null object. It rejects out-of-order/duplicate records, cannot commit an incomplete prefix, and exposes only LIFO rollback. The queue owner releases the matching OSObject for each popped entry. The empty journal makes repeated destroyQueues() teardown harmless. If journal state or live pointers disagree, teardown logs the invariant failure and free() quarantines the owner rather than destroying an object that may still be referenced by a queue callback.

## Fault-injection coverage

tests/wcl_resource_acquisition_journal_test.cpp simulates failure at every acquisition point, including the first and last. It verifies that only prior successful resources are rolled back and that the rollback order is exactly reversed. It also checks incomplete commit, double commit, duplicate/out-of-order records, invalid TX queue indices, and repeated teardown.

tests/test-wcl-resource-transaction.py checks that the live queue owner records every pool/queue acquisition, commits only after queue-array validation, and dispatches rollback entries through the resource release switch.

Run the combined validation on the target Mac from the Stage90 Git checkout:

```bash
bash tools/run-stage90-transaction-tests.sh
```

The runner writes a timestamped full report under Development/Logs/, appends a concise summary to Development/output.log, then commits and pushes both log files to the dedicated Stage90 branch. It refuses to push when run from another branch.

## Registration and activation boundary

This increment does not call registerEthernetInterface(), enable queue event sources, publish a BSD interface, or consume/complete packets. The existing native interface start() remains fail-closed. The 24H32 RegistrationInfo builder remains a prepared-but-unused helper until the exact registration, ring ownership, deregistration and rollback ABI paths are fully correlated.

The transaction journal introduced here covers only the queue/pool objects owned by RTW88WCLSkywalkQueues. Controller-level PCI/DMA/radio teardown keeps its existing dependency-aware quiesce order; it is not replaced with a simplistic reverse-acquisition loop. Do not infer from these host tests that the kernel factories or rollback paths have been executed in a running kernel.

No complete kext link, code signing, installation, loading, hardware testing, or OpenCore/SIP/NVRAM modification is part of Stage90 source work.