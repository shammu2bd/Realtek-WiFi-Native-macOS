# RTL88WiFi Native WCL / Skywalk — Master Stage History

**Coverage:** Stage 1 through Stage 88  
**History snapshot:** 2026-11-03  
**Target:** Intel Hackintosh, macOS Sequoia 15.8.1 (24H32), x86_64, PCIe RTL8821CE  
**Project baseline:** `RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source`

## Purpose and reading guide

This document is the chronological index of the work completed and audited across the earlier “Combine Kext Dependencies” conversations and the current GitHub development runs. It consolidates recovered Stage 1–19 notes, the Stage 20–62 development narrative, and the later Stage 63–88 checkpoints.

- **This file** is the durable stage-by-stage overview and current project checkpoint.
- [`Development/output.log`](./output.log) is the append-only run checkpoint log. Its older canonical content begins at Stage 23; this master file fills in the recovered earlier history and provides the complete index.
- [`Development/README.md`](./README.md) contains repository operating rules and selected stage run instructions.
- [`Development/Logs/`](./Logs/) contains the detailed timestamped reports, evidence parts, manifests and run artifacts. Stage-level summaries below do not replace those raw reports.

### Evidence labels and limitations

1. **Recovered artifact/history** means the summary was reconstructed from saved implementation status, patches, reports or stage packages from earlier conversations.
2. **Canonical GitHub record** means the checkpoint exists in `Development/output.log` or the stage narrative in `Development/README.md`.
3. **Retrospective grouping** means the available history records a range or a run family but does not preserve a distinct, independently verified description for every number. Those entries are explicitly marked; no missing work is invented.
4. A **PASS** on a read-only audit means that audit's stated checks passed. It does not mean the native driver is complete, safe to activate, installed, signed or hardware-tested.

## Current project state after Stage 88

**Status: IMPLEMENTATION NOT AUTHORIZED**

The last recorded milestone is **Stage 88 V1** (`run-20261102-205135-b4f4ddc49298`). It decoded the WMM service-class values and verified Apple QueueSet pointer-array lifetime behavior. The native source still does not contain the required four-queue pointer array or a native registration call. Four TX/RX callback ownership handoffs are still missing. The activation gate remains **BLOCKED**.

Important distinctions:

- A separate native target successfully compiled/linked in the Stage 29c-v5 / Stage 35 family, and Stage 43 also recorded a native build pass after a source correction. These are build milestones, not a functional driver validation.
- Stage 29d–29i established that the candidate was structurally inspectable but not package/load ready: the bundle was user-owned and unsigned, no valid Developer ID kext-signing identity was available, and EFI discovery was still unresolved.
- No completed evidence in this history shows the native kext installed or loaded, native Wi-Fi service working, or the RTL8821CE hardware operating through the new native path.
- OpenCore has not been changed by these later audits. Preserve the known-good legacy RTL88WiFi setup and existing everyday EFI.
- The end goal remains a standalone native RTL88WiFi.kext using the macOS Wi-Fi menu, without requiring `IO80211FamilyLegacy.kext` / `IOSkywalkFamily.kext` as bundled dependencies and without blocking `com.apple.iokit.IOSkywalkFamily` in OpenCore. AirportRTW migration is not the chosen solution.

## Stage-by-stage history

### Stages 1–19 — WCL foundation, packet adapters and Apple ABI evidence

| Stage | Work recorded | Result / boundary |
|---|---|---|
| **1 — Native WCL foundation** | Reconstructed from the pre-Stage2 `PRIVATE-WCL-IMPLEMENTATION-STATUS.md` baseline (the source document itself did not carry a formal “Stage 1” heading). Added the RTW88 radio bridge concept, serialized bounded WCL event queue, Sequoia 24H32 controller ABI shell, ABI-neutral PCI/MMIO/DMA backend owner, native-controller mbuf TX gate and bounded infrastructure-protocol request decoding. | Compile-only / fail-closed scaffolding. Not a native registered or running driver; not linked into the legacy kext; no IOKit personality, native link, load or hardware test. |
| **2 — TX terminal outcome and packet bounds** | Added an optional completion token to RTW88 `sk_buff`; introduced `outputPacketWithCompletion()`; used an atomic terminal-claim path to arbitrate hardware completion versus early free/purge/reset. Added overflow-safe single-buffer Skywalk packet/buffer range validation and Ethernet frame bounds. | Race and bounds tests were added. The Skywalk TX submit path deliberately still returns `kIOReturnNotReady`; it does not consume or complete a live Skywalk packet. |
| **3 — Registration ABI safety** | Compared public SDK and independent Sequoia private declarations for Ethernet registration. The declarations disagreed on return type; opaque RegistrationInfo and ExpansionData were kept opaque and no speculative layout/call was used. | Registration remained fenced. The later Stage 10 Apple call-site evidence resolves the return contract as `IOReturn`; Stage 3's conflicting header observation is historical, not the final ABI conclusion. |
| **4 — Bounded Skywalk TX adapter** | Added the Skywalk-to-RTW88 TX conversion seam and fixed 128-slot completion-ticket table. The adapter validates the packet, copies it into an RTW88 mbuf, and makes the RTW88 completion callback publish only a bounded result for deferred draining. | Compile-only adapter. No live queue registration or Skywalk completion API; TX submission remains not-ready. |
| **5 — Bounded RX staging** | Added a fixed 128-entry MPMC mbuf ring and workloop drain with bounded per-pass processing; stress-tested concurrent producers and exact-once staging. | RX staging only. No native Skywalk packet creation/refill, RX completion or interface publication. |
| **6 — Native RX packet conversion** | Added validated conversion from fragmented RTW88 mbuf chains into one-buffer IOSkywalkPacket objects, with packet length/status and memory-segment/range checks. | The sink rejected/recycled the packet at this point. No `enqueuePackets`, registration or BSD publication. |
| **7 — Controller-owned RX packet retention** | Added a bounded 128-entry native packet ring and teardown ordering for packets retained by the controller. | Ownership staging only, not an RX completion queue or network-delivery path. |
| **8 — Registration method-body collection** | Expanded the bounded evidence collector to capture complete registration method bodies and the Apple interface start path. | Host extraction checks passed; remaining exact symbol coverage led to Stage 9. |
| **9 — Forced registration symbols** | Forced collection of exact mangled registration symbols and inspected the suspected interface vtable slot. | Improved symbol coverage. The initial interpretation of slot `0xc00` was corrected in Stage 10. |
| **10 — 24H32 registration status contract** | Disassembly showed Apple interface start calling `registerInfraEthernetInterface`, wrapper flow into network registration, and success tested as `EAX == 0`. The suspected vtable slot `0xc00` was identified as `setInterfaceOFDMDesense`, not registration. | Registration return type established as `IOReturn`. Calls remained fenced pending queue, packet ownership and rollback evidence. |
| **11 — RegistrationInfo builder** | Added a persistent aligned 0x130-byte builder based on the audited initializer and confirmed writes at offsets 0x0c, 0x14, 0x24, 0x40 and the hardware MAC at 0x108. | Builder was not called from start and did not invoke registration. Queue, pool, callback and rollback contracts remained open. |
| **12 — Queue and pool ABI capture** | Collected exact method bodies for IOSkywalkPacketQueue, PacketBufferPool, QueueSet and LogicalLink. | Initial parser stopped after the first pass; Stage 12.1 repaired exact mangled-symbol handling and completed the collection. |
| **13 — Apple PCIe packet-pool ABI** | Inspected the target Apple PCIe packet-pool/provider-specific pool and memory-segment ABI. | Reference evidence only; no guessed provider-specific allocation or live pool use. |
| **14 — Generic Skywalk class evidence** | Broad target ABI collection: 49 vtables, 325 size records, 701 function bodies and eight class method lists. | Evidence collection completed; later stages audited semantics and ownership. |
| **15 — Packet accessor audit** | Correlated packet accessor implementations with the collected Skywalk class evidence. | Accessor evidence only; no activation authorization. |
| **16 — Packet size / offset semantic audit** | Compared actual packet and packet-buffer layouts with SDK expectations. | Review discrepancy recorded: IOSkywalkPacket actual 0x70 versus expected 0x78; IOSkywalkPacketBuffer 0x90 matched. The mismatch was not papered over. |
| **17 — Full method capture** | Captured 743/743 executable method bodies and recorded 19/19 ownership-fence items; 39 of 782 total symbols were non-code. | Collection completeness improved; manual ownership review was still required. |
| **18 — Ownership contract dossiers** | Produced six ownership-contract dossiers. | Marked `READY_FOR_MANUAL_REVIEW`, not sign-off and not permission to activate. |
| **19 — Ownership review checkpoint** | Consolidated the remaining manual queue, pool, packet and teardown questions from the Stage 18 dossiers. | Activation contracts remained open; this stage did not authorize queue registration. |

### Stages 20–35 — source correlation, datapath audits, packaging and native build

| Stage | Work recorded | Result / boundary |
|---|---|---|
| **20 — 24H32 queue contract review ledger** | Static correlation of Stage 14–17 ABI evidence with Stage 18–19 ownership dossiers. | Six activation contracts remained blocked; no source modification or queue activation. |
| **21 — Native source-to-ABI audit** | Inventoried WCL sources, start fences, registration/queue call sites and native bundle dependency state against the pinned build. | Read-only; manual callback/ownership correlation remained required. |
| **22 — Deep source lifecycle audit** | Captured numbered source contexts and hashes for controller/interface start-stop, registration/deregistration, TX/RX, packet tickets, pool/DMA prepare-complete and teardown. | Source excerpts supported review but did not prove runtime ownership. |
| **23 — Targeted datapath audit** | Targeted native datapath/source inspection. Canonical report: `stage23-targeted-datapath-audit.txt` (208,142 bytes). | `REVIEW_REQUIRED`; activation blocked; no source changes, build, install, load or OpenCore changes. |
| **24 — RTW88 callback / DMA audit** | Callback and DMA source audit. The repaired collector targeted 120 source files and reduced the report to 88,148 bytes after an earlier oversized report. | Audit/reporting refinement; not a driver activation milestone. |
| **25 — Source-complete TX / DMA audit** | Expanded TX and DMA source inspection. Canonical report: `stage25-source-complete-tx-dma-audit.txt` (267,943 bytes). | `REVIEW_REQUIRED`; activation blocked; no source changes or build/install/load. |
| **26 — Stage26 clean source baseline** | Established the clean Stage26 project tree used by the later native source audits and scripts. | Working source baseline; does not itself mean the native driver is integrated or loaded. |
| **27 — Source packaging repair** | Stage27a restored the source template `RTL88WiFi.kext/Contents/Info.plist` that had been excluded by a broad `*.kext` packaging filter, and recreated the source archive while excluding generated build folders. | Packaging correction only; it did not install or load the kext. |
| **28 — RTW88 skb terminal ownership** | Audited terminal completion/free ownership in the RTW88 skb lifecycle. Canonical report: `stage28-rtw88-skb-terminal-ownership-audit.txt` (345,819 bytes). | `REVIEW_REQUIRED`; activation blocked; source/build/install/load unchanged. |
| **29 — Native build, packaging and signing gates** | Stage29c-v5 completed native compile/link and bundle validation. Stage29d checked Mach-O structure, symbols, metadata and PCI personality. Stage29e resolved imports to BootKC providers but kmutil diagnostics still found bad ownership/signature. Stage29f confirmed user ownership and unsigned bundle. Stage29g found SIP enabled and no valid Developer ID kext-signing identity. Stage29h documented the separate internal-testing route. Stage29i performed read-only EFI discovery because no mounted EFI config had been found. | Build/link is not load-ready. Candidate remained unsigned/user-owned; no install/load and no OpenCore change. Stages 29a/29b are not separately described in the recovered summary. |
| **30 — RTW88 TX implementation trace** | Deep TX implementation trace. Canonical manifest: `stage30-rtw88-tx-implementation-manifest.txt`; 622,892 report bytes in two parts. | `REVIEW_REQUIRED`; activation blocked; no source modification or native install/load. |
| **31 — Full-tree TX contract tests** | Full-tree TX contract test evidence. Canonical manifest: `stage31-full-tree-tx-contract-tests-manifest.txt`; 875,366 report bytes in three parts. | `REVIEW_REQUIRED`; activation blocked. |
| **32 — Combined TX integration audit** | Combined TX integration audit. Canonical manifest: `stage32-combined-tx-integration-manifest.txt`; 1,997,087 report bytes in six parts. | `REVIEW_REQUIRED`; activation blocked. Report size was split into parts for repository upload. |
| **33–34 — Intermediate native-target refinement** | Recovered project timeline groups these with native-target source/compile/link and warning audits. No separate detailed stage summary was present in the consolidated notes available for this file. | Preserve their individual run artifacts if present; no separate functional validation claim is made here. |
| **35 — Native target build / warning audits** | Stage35r recorded `BUILD_EXIT=0`, successful native target compile/link and bundle validation, with 1,153 warnings. Stage35x2 later reported zero warnings in the targeted ABI warning groups. | Build milestone only. Not installed, loaded or hardware-tested. |

### Stages 36–50 — Apple registration, interface lifecycle and source call graph

| Stage | Work recorded | Result / boundary |
|---|---|---|
| **36–42 — Apple Skywalk / BSD lifecycle ABI series** | Recovered timeline groups these stages as read-only disassembly and source audits of Apple Skywalk registration, BSD interface, start/stop/free and related lifecycle behavior. | Grouped reconstruction: separate one-line scopes for 36–42 were not retained in the consolidated history. No activation claim. |
| **43 — BSD parameter forwarding correction** | Updated `RTW88WCLInfraInterface::initBSDInterfaceParameters` to forward to the verified 24H32 `IO80211InfraInterface` base implementation. | Native build PASS; source SHA recorded in the canonical log. No install/load/code-sign or OpenCore change. |
| **44 — BSD prepare/finalize ABI audit** | Inspected `IO80211InfraInterface::prepareBSDInterface`, inherited finalize path, vtables and exact method bodies; checked Stage43 source fingerprints. | Read-only audit; activation blocked. |
| **45 — BSD finalize cleanup slot** | Resolved inherited `IOSkywalkNetworkInterface::finalizeBSDInterface` cleanup target at vtable byte offset `0x858`; inspected neighboring slots and targets. | Read-only lifecycle evidence; no queue/datapath implementation. |
| **46 — Network deregistration / pool ownership** | Audited `deregisterNetworkInterface`, LogicalLink and PacketBufferPool ownership and teardown order. | Read-only; activation blocked. |
| **47 — LogicalLink / QueueSet teardown** | Audited LogicalLink deletion, QueueSet attach/detach and TX/RX queue teardown/pool-release order. | Read-only; registration and callback ownership still unimplemented. |
| **48 — Registration / queue construction / callback ABI** | Captured the 24H32 registration wrappers, QueueSet construction, packet-queue constructors and TX/RX callback-bearing methods. | ABI map only; no queue creation or callback activation in RTL88WiFi. |
| **49 — Source-to-ABI correlation** | Compared native RegistrationInfo, queue creation/order, pool ownership, callback wiring, TX/RX datapath and rollback source against Stage48 evidence. | Pattern matches treated as pointers, not proof of safe behavior; activation blocked. |
| **50 — Registration call graph / callback reachability** | V2 extracted exact native method bodies for controller/interface startup, RegistrationInfo preparation, `createQueues`, four queue callbacks and adapter handoffs; corrected the initial method-name mismatch and distinguished direct-body edges from transitive reachability. | Read-only source audit; missing runtime edges and rollback remained. |

### Stages 51–62 — controller, personality, factories, queue ABI and registration metadata

| Stage | Work recorded | Result / boundary |
|---|---|---|
| **51 — Controller/interface ownership lifecycle** | Audited controller and infrastructure-interface object creation, radio attachment, primary-interface publication references and start/stop/free ordering. | Lifecycle source audit only. |
| **52 — IOKit personality/provider contract** | Audited Info.plist personality keys, class/metaclass declarations, provider initialization, controller linkage and interface publication. | No native registration or hardware-test authorization. |
| **53 — IO80211 factory/vtable audit** | Audited 24H32 BootKC methods/vtables for IO80211 controller, Skywalk/infra interfaces, primary interface getter and Apple reference registration path. | Framework ABI evidence only. |
| **54 — Interface initializer/factory/lifecycle** | Resolved exact `IO80211SkywalkInterface::init(IOService*, ether_addr*)`, primary-interface getter, start/stop/free and Apple BCM reference factory/lifecycle methods. | Apple Broadcom path used as reference evidence only; no driver activation. |
| **55 — Native factory/registration reachability** | Correlated Stage54 methods with native controller/interface construction, attach, publication, registration and packet callback edges. | Source-to-ABI crosswalk; helper/API presence not taken as proof of execution. |
| **56 — RegistrationInfo and TX/RX callback integration** | Audited RegistrationInfo lifecycle, queue/pool creation, constructor callback arguments, TX completion sink, RX consumer sink and controller wiring. | No datapath enablement or hardware-test authorization. |
| **57 — Queue callback ABI and adapter handoff** | V2 compared 24H32 queue constructor/dispatch ABI and action signatures with native TX completion tickets and RX network sink wiring; verified predecessor artifacts. | ABI/callback crosswalk only; no queue registration implementation. |
| **58 — QueueSet/LogicalLink registration and ownership** | V2 traced registration, queue-type classification, QueueSet/LogicalLink metadata, queue ownership, dispatch slot and rollback. | Private ownership contracts remained incomplete. |
| **59 — Packet-queue virtual dispatch contract** | Audited packet-queue `getFreeSpace`, QueueSet indirect-dispatch callsite, SDK declarations and source registration reachability. | Dispatch target evidence only; native registration and TX/RX ownership remained open. |
| **60 — Itanium vtable address-point correction** | Corrected QueueSet vtable interpretation using the Itanium primary address point; resolved the call through `[vptr + 0x218]` against the corresponding `_ZTV` offset/index and concrete queue `performCommand` targets. | Corrected ABI interpretation; did not implement queue activation. |
| **61 — Queue descriptor / QueueSet classification** | Decoded the 16-byte queue descriptor (queue-kind code, capacity, pool pointer) and correlated four queue-kind IDs with QueueSet per-type arrays/counts. | Queue grouping evidence; registration and packet ownership remained open. |
| **62 — QueueSet / LogicalLink metadata** | Traced QueueSet control words and the separate LogicalLink initializer/caller transaction; kept opaque private structure sizes/layouts unresolved where not proven. | Metadata bounds/flow improved; native queue registration and TX/RX ownership remained open. |

### Stages 63–78 — four-queue readiness, callbacks and ownership evidence

| Stage | Work recorded | Result / boundary |
|---|---|---|
| **63 — Four-queue / registration arguments** | V2 audited native four-queue construction, RegistrationInfo preparation, callback arguments and Apple registration readiness. | Driver queue-pointer array and native registration call remained absent; activation blocked. |
| **64 — Four-queue callback/ownership dispatch** | Audited native TX/RX queue callback bodies and Apple `checkForWork` dispatch paths. | Callback ownership/completion handoffs not complete. |
| **65 — Apple callback dispatch targets** | Resolved Apple TX/RX callback dispatch helpers and TxSubmission virtual targets. | Reference-side dispatch evidence; native ownership bridge remained incomplete. |
| **66 — Queue callback registration / packet lifecycle** | Audited four `initWithPool` callback paths, PacketQueue base initialization dispatch and TX/RX packet lifecycle methods. | Separate reviewed source implementation still required. |
| **67 — Packet/pool vtable and recycle audit** | First run failed the post-audit artifact gate because `dispatch-edge-inventory.txt` was missing (audit summary itself reported 19/19 methods and vtable coverage). A subsequent run completed packet/pool vtable, recycle, completion and RX enqueue lifecycle inspection. | Initial failure preserved; rerun recorded. No source/build/install/load/OpenCore changes; packet ownership implementation not authorized. |
| **68 — Packet-buffer preparation / pool** | Audited packet-buffer vtable target, acquire/setPacket methods, pool allocation and packet preparation dispatch. | Buffer lifetime and hardware queue ownership still needed reviewed implementation. |
| **69 — Packet-buffer lifecycle / memory segment** | Audited packet-buffer prepare/complete, handle lookup/acquire, packet attachment, disposal and pool-release lifecycle. | ABI evidence only; native queue handoff remained open. |
| **70 — Corrected Itanium vtable address points** | Corrected Stage65–69 virtual target indexing using the primary Itanium `_ZTV + 0x10` address-point rule. | Corrected target mapping; no source implementation. |
| **71 — Callsite-aware vtable reconciliation** | V1 failed during the audit script. V2 distinguished object-vptr offsets from direct `_ZTV` base offsets and reconciled Stage64–69 targets. | V2 is the retained corrected audit; native registration/TX/RX ownership still open. |
| **72 — Callee contract / callback handoff** | Verified 12 reconciled Apple callee bodies and compared them with RTL88WiFi callback handoff source. | Missing TX/RX ownership handoffs identified; registration remained incomplete. |
| **73 — TX/RX ownership inventory** | Mapped native queue callbacks, TX/RX adapters, packet ownership and teardown dependencies. | Inventory only; no native queue registration or callback handoff implementation. |
| **74 — Registration/callback wiring** | Audited 24H32 RegistrationInfo boundary, queue constructors, callback wiring and teardown order from unchanged source. | Audit only; no Skywalk queue registration or activation. |
| **75 — Registration payload / queue arguments** | Inspected RegistrationInfo payload, native queue-array argument contract, registration call sites and rollback lifecycle. | Registration and callback handoffs still incomplete. |
| **76–78 — Registration/startup readiness checkpoints** | Recovered project timeline groups these between Stage75 payload review and Stage79 wrapper-flow review as additional registration/startup readiness gates. | Individual stage titles/scopes were not present in the canonical output.log snapshot used for this consolidation; retain the matching `Development/Logs/stage76` through `stage78` artifacts as the primary evidence if present. No independent completion or authorization is asserted here. |

### Stages 79–88 — final registration wrapper, WMM and readiness gates

| Stage | Work recorded | Result / boundary |
|---|---|---|
| **79 — Registration wrapper flow** | V2 re-audited native/Apple registration wrapper argument flow and call path. | Native driver registration call site still absent; source/build/install/load unchanged; activation blocked. |
| **80 — Queue typecode crosswalk** | V2 correlated queue typecodes with queue construction/registration evidence and Stage79. | Driver queue-pointer array and registration call remained absent. |
| **81 — Implementation contract** | V2 consolidated Stage79/80 evidence and implementation preconditions. | `IMPLEMENTATION_AUTHORIZED=NO`; activation blocked. |
| **82 — Registration wrapper ABI** | Revalidated wrapper argument flow from the 24H32 evidence. Two same-version runs are recorded; later run ID is `run-20261102-192209-4127dc7d4c59`. | ABI flow revalidated; no source/build/install/load/OpenCore change. |
| **83 — Private metadata bounds** | Classified accessed bounds of private registration metadata. | Formal structure sizes/layouts remained unresolved; no guessing. |
| **84 — Queue array / WMM gate** | V2 checked for a native queue-pointer array and registration call, along with WMM gating. | Neither queue-pointer array nor native registration call was found; activation blocked. |
| **85 — WMM predicate body** | Disassembled the WMM predicate and reviewed its acceptance rule. | Predicate body was decoded; final WMM table interpretation continued into Stage88. |
| **86 — Queue-array source inventory** | V1 produced false-positive candidates (including non-queue arrays/prototypes); V2 corrected the source inventory. | Corrected V2: queue-pointer array not found; native registration calls = 0. Earlier V1 candidate/call counts are superseded, not current facts. |
| **87 — Implementation readiness synthesis** | V1 was superseded by V2, which synthesized the Stage82–86 evidence chain. | `IMPLEMENTATION_AUTHORIZED=NO`; activation blocked; source/build/install/load/OpenCore unchanged. |
| **88 — WMM values / QueueSet pointer-array lifetime** | Decoded four WMM service-class values: `0x00100080`, `0x00000000`, `0x00380100`, `0x00400180`. Verified the predicate requires exactly one queue per class. Apple QueueSet initialization copies the caller's pointer array into internal storage and retains the queue objects; teardown clears back-references, releases queues and frees internal storage. | ABI contract is now better understood, but native source still has four queue factory calls without the required pointer array and has no registration call. Four TX/RX callback handoffs remain absent. `IMPLEMENTATION_AUTHORIZED=NO`; activation blocked. |

## Consolidated progress checklist

| Requirement | Current evidence |
|---|---|
| Sequoia 15.8.1 (24H32) native target can compile/link | **PASS at build milestones** (Stage29c-v5 / Stage35 family; Stage43 build after source correction). |
| Native binary package is signed and load-ready | **NOT PASS** — Stage29f found user ownership and no code signature; Stage29g found no valid kext-signing identity. |
| Apple registration wrapper ABI understood | **Substantially mapped** through Stages 10–11, 48–63, 79–83; private metadata/ownership still needs closure. |
| Four native Skywalk queue objects can be constructed | **Helpers exist**, but source lacks the required queue-pointer array passed as the registration argument. |
| Native interface registration is implemented | **NO** — Stage86 V2 / Stage88 confirm no native registration call. |
| TX submission and hardware completion handoffs are connected | **NO** — conversion/ticket helpers exist; full Skywalk queue callback ownership path is missing. |
| RX refill and network-delivery completion path is connected | **NO** — staging/conversion helpers exist; full native queue completion/refill/network handoff remains missing. |
| Stop/free rollback releases all registered queues, links and pools safely | **NOT CLOSED** — Apple teardown contracts have been audited, but the driver-side integrated lifecycle is not implemented/approved. |
| Native kext installed/loaded and RTL8821CE hardware tested | **NOT RUN / NOT VERIFIED**. |
| OpenCore block/config change | **NONE** in these audits; preserve the existing configuration and working legacy kext. |

## Implementation roadmap

The proposed next sequence is maintained in [RTL88WiFi-ROADMAP-STAGE89-101.md](./RTL88WiFi-ROADMAP-STAGE89-101.md). It starts with four-queue construction and registration-argument assembly (Stage 89), then packet/queue ownership, the four TX/RX handoffs, integrated registration/rollback, focused tests, clean build, isolated test boot and hardware validation. Reading the roadmap does not authorize registration, signing, installation, loading or OpenCore changes.

## Next engineering boundary

The next work should be a **separate implementation stage**, not another broad ABI inventory. Before any queue activation, implement and review in the native source:

1. The four queue objects plus a correctly ordered four-pointer array passed to the audited registration wrapper.
2. The four queue callback/handoff edges: TX submit, TX completion drain, RX refill and RX network delivery.
3. Exact queue/pool/packet ownership transfer and failure rollback for partial registration and stop/free.
4. Focused tests and a clean native build, followed by independent review of the candidate package/signing/test-boot route.

Keep all new work fail-closed until those contracts are implemented and reviewed. Do not install/load or change OpenCore merely because an ABI audit reports PASS.

## Provenance notes

- Stages 1–19 were reconstructed from saved status documents, patch packages and prior conversation artifacts. Stage 1 is an inferred chronological label for the foundational baseline, not a literal heading in its original source document.
- Stages 20–22 and 27/29 plus Stage44–62 are described in the existing Development README and related reports.
- Stages 23, 25, 28, 30–32 and 43–88 have canonical checkpoints in Development/output.log; reports and run folders are linked from those entries.
- Stages 33–34, 36–42 and 76–78 are grouped where the retained summary does not preserve an individual detailed scope. This file deliberately records those gaps.
- Stage versions matter: Stage50 V2, Stage57 V2, Stage58 V2, Stage62 V2, Stage63 V2, Stage71 V2, Stage79 V2, Stage80 V2, Stage81 V2, Stage84 V2, Stage86 V2, Stage87 V2 and Stage88 V1 are the relevant corrected/latest versions identified in the retained history. Earlier failed/superseded runs are noted where material.

---
**Master history checkpoint: 2026-11-03 — last completed recorded stage: 88.**
