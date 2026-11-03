# Stage 13 — Apple PCIe Skywalk pool/resource ABI reference

## Why this stage follows Stage 12.1

The uploaded Stage 12 archive was inspected directly from the GitHub repository.
The 24H32 evidence confirms the generic ownership chain:

- `IOSkywalkPacketQueue::initWithPool` retains its packet pool and optional
  refcon. Its `initialize` path derives queue identity, checks the queue into
  the pool, and tracks initialization. Its `finalize` path pairs the lifecycle
  and checks the queue out when the final initialization reference ends.
- `IOSkywalkQueueSet::initWithQueues` links and retains the queues it accepts.
  `free` clears each queue's back-pointer and releases the queue references.
- `IOSkywalkLogicalLink::initWithQueueSet` links and retains the supplied
  QueueSets. `free` clears their back-pointers and releases them.
- The queue-array overload of
  `IOSkywalkNetworkInterface::registerNetworkInterface` creates its own
  QueueSet and LogicalLink. It uses QueueSet flags `3`, or `0xb` when the
  supplied queue group passes Apple's WMM capability test. It seeds the
  0xa0-byte `LogicalLinkInfo_s` from an internal template and changes its first
  word to `1`; it then calls the logical-link overload and releases its local
  QueueSet/LogicalLink references. Driver code should pass queues and pools to
  the infra registration entry point, not manually construct or double-free
  these intermediate objects.
- `IOSkywalkPacketBufferPool::release` has a deferred last-release cleanup
  sequence; `free` cancels its reporting thread call, releases packet and
  memory-segment resources, releases owned OS objects, frees its lock, and
  finally calls the base free path.

The remaining unknown is how Apple's PCIe Skywalk provider constructs its
packet-pool subclass and configures the per-pool options, queue parameters,
callback/refcon and DMA/mapper interactions. Stage 13 therefore expands the
exact method bodies for:

- `AppleBCMWLANPCIeSkywalk`
- `AppleBCMWLANPCIeSkywalkPacketPool`

It also retains the Stage 12 generic queue/pool class methods and the Stage
8–10 registration targets. Apple BCM hardware-specific PCIe ring, mapper and
completion logic is evidence only; it is **not** copied into the RTW88 backend.

## Run on the target Mac

Run from the extracted Stage 13 project root:

```sh
python3 tests/test-wcl-pcie-pool-ref-stage13.py
bash -n tools/collect-sequoia-abi-24H32-stage13.sh

tools/collect-sequoia-abi-24H32-stage13.sh \
  build/sequoia-abi-24H32-stage13 2>&1 | tee output.log
```

Upload the resulting archive to the GitHub repository root with the exact name
`RTL88WiFi-Sequoia-24H32-stage13-apple-skywalk-pool-kcabi.tar.gz`; keep the
single project-root `output.log` for the run log.

## Safety boundary

This stage is ABI evidence collection only. It changes no Kext source and does
not instantiate a pool or queue, invoke a private registration API, publish a
BSD interface, activate TX/RX, or start the radio. Do not install or load an
experimental Kext from this stage. The working legacy Kext and OpenCore
configuration remain the test fallback.
