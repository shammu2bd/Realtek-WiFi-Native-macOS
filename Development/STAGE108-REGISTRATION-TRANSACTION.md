# Stage108 — 24H32 Skywalk registration transaction

**Target:** macOS Sequoia 15.8.1 (24H32), x86_64, PCIe RTL8821CE  
**Scope:** registration ownership, commit/abort, deregistration retry and queue/pool lifetime  
**Status:** source implementation published; target-Mac test/build pending

## 1. Registration ABI used

The native infra interface retains an aligned, persistent 0x130-byte opaque `RegistrationInfo` buffer. It calls Apple's target-specific `IO80211InfraInterface::registerInfraEthernetInterface()` wrapper with:

- the initialized opaque `RegistrationInfo`,
- a stable owner-resident seven-entry `IOSkywalkPacketQueue *` array,
- the seven-entry count,
- the TX packet pool,
- the RX packet pool.

The wrapper is used instead of constructing private `IOSkywalkQueueSet`, `IOSkywalkLogicalLink` or their private information structures in driver code. The target ABI evidence records the helper as an `IOReturn` API (zero means success).

The seven entries are four distinct WMM TX submission queues, then TX completion, RX submission and RX completion. Queue roles are checked using the first `UInt32` role code in the target's 16-byte `performCommand(0x10000)` output. The remaining descriptor bytes are kept opaque; no private pool/capacity fields are inferred from them.

## 2. Queue-owner transaction

`RTW88WCLRegistrationTransaction::Transaction` provides these atomic states:

| State | Meaning | Queue/pool release permitted? |
|---|---|---:|
| Unregistered | No external Skywalk registration owns the vector | Yes, subject to other owners |
| Registering | Preflight or Apple registration call in progress | No |
| Registered | Apple registration succeeded and local commit completed | No |
| Deregistering | Apple deregistration call in progress | No |
| Quarantined | External ownership could not be reconciled safely | No |

The state is acquired before checking the registration vector. This pins the queue/pool owner across both preflight and the Apple registration call.

## 3. Start/commit/rollback sequence

1. The interface completes Apple's infra-interface base start.
2. The RTW88 radio bridge is attached and a valid unicast hardware MAC is read.
3. `initRegistrationInfo(option=1, size=0x130)` initializes the opaque storage; only the caller-side writes supported by the 24H32 evidence are applied.
4. The queue owner enters `Registering` before validating the seven queues.
5. `registerInfraEthernetInterface()` is called with the stable vector and both pools.
6. Apple failure aborts to `Unregistered`. If the local state transition cannot be reconciled, the queue owner is quarantined.
7. Only Apple success permits local `commitRegistrationTransaction()`.
8. If local commit unexpectedly fails, the driver calls Apple's `deregisterEthernetInterface(0)` to undo registration. Failed rollback quarantines the owner. The interface does not claim registration.

## 4. Stop/deregistration sequence

1. The packet path is quiesced before touching the Skywalk registration.
2. The queue owner transitions `Registered -> Deregistering`.
3. Apple's `deregisterEthernetInterface(0)` is invoked.
4. If Apple reports failure, the local state returns to `Registered` so a later stop can retry. If that transition cannot be proven, the owner is quarantined.
5. Only successful Apple deregistration permits `Deregistering -> Unregistered`.
6. The interface then clears `RegistrationInfo`, detaches its radio bridge, and stops the Apple infra base.
7. The controller detaches/releases the interface before destroying the seven queues and two pools.

The quarantine state is terminal for the lifetime of that queue-owner object. `destroyQueues()` and `hasOutstandingResources()` treat every non-unregistered state as an owner that must be retained.

## 5. Controller ordering

The controller probes/starts the RTW88 core to obtain the eFuse MAC while its PCI interrupt/radio producer gate remains closed. It then creates, starts and registers the infra interface. Only after the interface service has been registered does it call `_pciBackend->setRadioRunning(true)`.

Teardown stops the RTW88 producer, closes the PCI path, drains deferred callbacks, stops RX/TX adapters, deregisters and detaches the infra interface, then destroys queues/pools. This source ordering is covered by Stage108 contract checks; it is not runtime proof of the private Apple framework's behavior.

## 6. Validation and limits

Stage108 runner executes:

- the C++ atomic state-machine test,
- Stage108 transaction and registration source-contract checks,
- the RegistrationInfo opaque-layout/write-preservation test,
- the TX queue-array and resource-transaction regression tests,
- the unsigned native 24H32 kext link and bundle validation.

The runner does not sign, install, load or hardware-test the kext. It does not change OpenCore, EFI, SIP or NVRAM.

**Important:** Stage108 implements the registration transaction and integrates it into the controller's existing startup path. It does not prove that the private 24H32 registration helper succeeds on hardware, nor that scan, RX, TX, association, link-state reporting, or teardown are stable in a live kernel. The existing RX/TX callback ownership, hardware DMA, radio operation and full runtime validation remain separate gates. Do not use the Stage108 bundle as a working Wi-Fi driver based solely on a successful compile or source test.

PR #4 remains draft/open/unmerged.