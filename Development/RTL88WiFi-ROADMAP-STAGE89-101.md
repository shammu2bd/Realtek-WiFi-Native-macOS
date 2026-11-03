# RTL88WiFi Native WCL / Skywalk Implementation Roadmap

**Plan baseline:** Stage 88 V1  
**Roadmap created:** 2026-11-03  
**Target:** Intel Hackintosh, macOS Sequoia 15.8.1 (24H32), x86_64, PCIe RTL8821CE  
**Source baseline:** `RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source`  
**Planning status:** Proposed sequence; not authorization to activate or install the driver.

## 1. Objective

Complete the standalone native RTL88WiFi path while preserving the working legacy setup. The target is a native macOS Wi-Fi interface/menu, with the native driver using the audited Sequoia Skywalk/IO80211 contracts instead of bundling `IO80211FamilyLegacy.kext` / `IOSkywalkFamily.kext` and without an OpenCore block of `com.apple.iokit.IOSkywalkFamily`.

The preferred direction remains the RTL88WiFi WCL/OpenCore approach. This roadmap does not switch the project to AirportRTW.

## 2. Baseline facts carried forward from Stage 88

- The native target has compiled/linked in earlier build milestones (Stage29c-v5 / Stage35 family and Stage43). These are build results, not proof of a functioning or load-ready driver.
- Stage29f found the candidate bundle user-owned and unsigned. Stage29g found no valid Developer ID identity with the required kext-signing entitlement. The package is therefore not load-ready based on the recorded evidence.
- Stage88 decoded the WMM service-class values: `0x00100080`, `0x00000000`, `0x00380100`, `0x00400180`. The acceptance predicate requires exactly one queue for each class.
- Stage88 verified that Apple QueueSet initialization copies the supplied queue-pointer array into internal storage and retains the queue objects; teardown clears back-references, releases queues and frees internal storage.
- The native source still lacks the required queue-pointer array and a native registration call.
- Four key callback handoffs remain incomplete: TX submission, TX completion, RX refill and RX network delivery.
- Driver-side integrated rollback/stop/free has not been signed off. The native kext has not been verified installed, loaded or working with the RTL8821CE.
- Preserve the known-good legacy kext and everyday EFI. The roadmap must not cause an unreviewed OpenCore, SIP, NVRAM, ownership or security-policy change.

## 3. Execution principles

1. **One stage, one evidence-backed result.** Each stage must produce a report, source fingerprints, tests/build output where applicable, a clear PASS/FAIL/REVIEW_REQUIRED result, and an update to `Development/output.log`.
2. **Do not confuse audit PASS with driver readiness.** A static audit or host test can pass while the live driver remains unsafe or incomplete.
3. **Fail closed.** Until all callback, packet/pool ownership and rollback conditions are proven, native registration/start must remain unreachable or explicitly disabled.
4. **No speculative private ABI.** Use the exact 24H32 method signatures and argument contracts already collected; keep opaque private metadata opaque unless a verified initializer/callee contract proves a field.
5. **Protect the current working system.** Do not overwrite, rename, replace or remove the known-good legacy kext or everyday EFI. Use a separate test copy/EFI for any later load testing.
6. **No automatic security weakening.** Do not change SIP, NVRAM, OpenCore, signing, bundle ownership or kext installation as a side effect of an implementation stage. Each such action requires a separate reviewed and explicitly authorized test step.
7. **Keep local run artifacts in the source project's** `run log/<stage>/<run>/` **folder** and upload reports to `Development/Logs/<stage>/<run>/`. Do not create `run-xxx` folders directly in Downloads.

## 4. Roadmap and exit criteria

The stage numbers below are proposed next-stage numbers. A stage is not complete until its exit criteria are demonstrated on the target source tree and recorded in GitHub.

| Stage | Focus | Main work | Exit criteria |
|---|---|---|---|
| **89** | Four-queue construction and registration-argument assembly | Revalidate the Stage80–88 queue typecode/WMM crosswalk against the current source. Construct exactly four queue objects, associate one with each audited WMM service-class value, and build a stable four-pointer array in the audited order. Keep the array alive across the registration call. Add assertions and a small test for count, uniqueness, order and array lifetime. | Tests prove exactly one queue per class and correct pointer-array lifetime. No speculative fields or sizes. Do not make the live registration call yet unless Stage90–94 contracts are already proven; the start path remains fail-closed. |
| **90** | Queue, pool and registration transaction ownership | Define a single explicit ownership ledger for each queue, QueueSet, LogicalLink, packet pool and registration object. Implement staged acquisition, commit, reverse-order rollback and idempotent stop/free behavior. Record which side owns each object before and after every API call, including partial failures. | Fault-injection tests cover failure after each acquisition/constructor step and prove no leak, double release, stale back-reference or use-after-free. |
| **91** | TX submission callback | Connect the audited Skywalk TX submission callback to the RTW88 TX adapter. Validate packet/pool/segment bounds and metadata before handoff. Specify exactly when the Skywalk packet is consumed, retained or rejected; preserve bounded/non-blocking behavior required by the callback context. | Tests cover success, queue-full/not-ready, malformed packet, DMA/map failure and teardown races. Every input packet has exactly one terminal ownership outcome. |
| **92** | TX completion callback and ticket drain | Connect RTW88 hardware terminal status to the Skywalk TX completion path. Reuse the bounded ticket/completion design where appropriate, but match the Stage57–72 callback ABI and packet ownership rules exactly. Keep interrupt/producer callbacks limited to the permitted bounded handoff; perform APIs that may sleep only in the verified deferred context. | Tests cover hardware success/error, early free, reset/purge, duplicate/racing completion, ticket exhaustion and stop. Exactly one completion or release wins for every packet. |
| **93** | RX refill callback | Implement the RX submission/refill callback using the verified RX pool and packet preparation contract. Define how a packet moves from pool acquisition through DMA/device ownership and back to the refill pool. | Tests cover pool exhaustion, preparation/DMA failure, queue stop, partial refill and packet reuse. No buffer is reused while the device or network stack owns it. |
| **94** | RX completion and network delivery | Connect completed hardware RX frames to validated Skywalk packet metadata and the audited RX completion/network enqueue path. Define accepted-versus-rejected ownership transfer and recycle behavior. | Tests cover valid/invalid frame lengths, fragmented input, pool/segment bounds, enqueue success/failure and teardown races. Each packet is delivered once or recycled once. |
| **95** | Integrated native registration and lifecycle | Only after Stages89–94 pass: connect queue creation, pointer-array registration, interface start, callback activation, stop, deregistration and rollback into one ordered transaction. Keep the driver fail-closed if any queue or callback is missing. | Source call graph proves registration is reachable only after all four queues and callbacks are ready. Start/stop/failure tests prove reverse-order cleanup and safe repeat start/stop. |
| **96** | Focused tests and fault-injection campaign | Run host tests for queue-class cardinality/order, packet bounds, TX completion races, RX ownership, pool exhaustion, partial registration failures, queue shutdown and concurrent teardown. Add regression tests for the corrected Stage67/71/86 false-positive/failure cases where relevant. | All defined tests pass repeatedly; sanitizing/debug checks show no duplicate ownership, leak, stale pointer or unbounded queue growth. Preserve full output and test seeds. |
| **97** | Clean native build and integrated ABI audit | Build the separate native target from a clean source tree using the confirmed Xcode 16.4 toolchain/SDK settings. Run symbol/dependency, metaclass/personality, callback signature, ABI, bundle metadata and warning checks. Verify source and executable fingerprints and confirm no accidental legacy target coupling. | Build and bundle checks pass with no unexplained ABI warnings/errors. Dependency audit confirms the intended native linkage. No installation, loading or OpenCore changes. |
| **98** | Package, signing and isolated test-boot readiness | Reassess the candidate bundle's ownership, code signature, entitlements, metadata, kext policy and the current available testing route. Prepare a separate test EFI/configuration and rollback instructions, leaving the everyday EFI and legacy kext untouched. | A reviewed test plan identifies exactly which EFI and bundle will be used, how to recover, and how the normal system is preserved. No SIP/NVRAM/OpenCore/security changes occur automatically. |
| **99** | Controlled native kext load test | Only after Stage98 is reviewed and explicitly authorized, test the candidate on the isolated test environment. Collect boot, Kernel Management, IOKit matching, attach/start and panic/crash logs. Confirm the native bundle is the one actually loaded. | Native service matches and starts without panic, unresolved dependencies or unexpected legacy-family blocking. Failure triggers rollback; do not continue to radio tests if attach/start is not clean. |
| **100** | RTL8821CE functional and stability validation | Test native interface appearance in the macOS Wi-Fi menu, scan, association, authentication, DHCP/DNS, internet traffic, disconnect/reconnect, sustained TX/RX, 2.4/5 GHz where supported, sleep/wake and reboot. Record PHY rate, channel width, throughput, packet loss, latency and logs separately. | Repeatable connection and stable bidirectional traffic, no kernel panic, leaks or stuck queues, and documented results across reconnect/sleep/wake/reboot cycles. Do not treat a reported link rate as measured throughput. |
| **101** | Security restoration and release decision | Restore any temporary test-only security configuration according to the reviewed rollback plan. Compare final native package/source hashes to tested artifacts, archive the complete evidence, and decide whether the native path is ready for wider use. | Test environment is returned to the agreed security state; known-good legacy configuration remains recoverable; release decision is supported by reproducible logs and hashes. |

## 5. Mandatory gates

These gates control whether the project may move to the next risk level. A stage-level PASS cannot bypass them.

### Gate A — Implementation completeness (before live registration)

Required: Stage89 queue-array correctness; Stage90 ownership/rollback; Stage91 TX submit; Stage92 TX completion; Stage93 RX refill; Stage94 RX delivery. All four queue callbacks must be connected and their ownership semantics reviewed.

**Failure action:** keep native registration/start disabled. Do not enable a partially wired queue set.

### Gate B — Integrated lifecycle (before package/load preparation)

Required: Stage95 call graph and start/stop/rollback tests; Stage96 test campaign; Stage97 clean native build and ABI/dependency audit.

**Failure action:** fix source and repeat the affected tests. No install/load.

### Gate C — Test environment (before kext load)

Required: Stage98 reviewed bundle, signature/testing policy, isolated EFI and recovery plan. The candidate must be identified by exact hash. The working legacy kext and everyday EFI must remain untouched.

**Failure action:** no kext load and no everyday-boot configuration change.

### Gate D — Hardware validation (before considering release)

Required: Stage99 clean native load/attach/start, then Stage100 repeated functional/stability evidence, then Stage101 security restoration and artifact verification.

**Failure action:** rollback to the known-good legacy configuration and keep the native candidate classified as test-only.

## 6. What must remain unchanged during implementation

- The everyday OpenCore EFI and existing working legacy RTL88WiFi configuration.
- The currently working network path, unless an explicitly isolated test boot is underway.
- The user's requirement to keep the solution on RTL88WiFi rather than migrating to AirportRTW.
- The goal of not requiring bundled legacy Skywalk/IO80211 kext dependencies or an OpenCore block of `IOSkywalkFamily`.
- The rule that no install/load/hardware test occurs simply because a source audit or compile succeeds.

## 7. Definition of done

The project is complete only when all of the following are evidenced:

1. The native kext builds cleanly and its final package identity/hash is known.
2. Native registration, all four TX/RX handoffs, packet/pool ownership and full teardown/rollback are implemented and tested.
3. The candidate loads in the isolated test environment without panic or dependency/ownership failures.
4. RTL8821CE appears as a native macOS Wi-Fi interface and repeatedly scans, connects and transfers data in both directions.
5. Reconnect, sleep/wake and reboot tests remain stable.
6. The security state is restored as planned and the known-good legacy configuration remains available.

Until these criteria are met, status remains **WORK IN PROGRESS — NOT RELEASE READY**.

## 8. Reporting template for every future stage

Each future stage should append a compact entry to `Development/output.log` containing:

- Stage number, version and unique run ID.
- Scope and exact source baseline SHA-256.
- Source files changed (or `NONE`).
- Tests/build commands and their exit results.
- Report paths and blob SHA-256 values.
- Ownership/rollback findings.
- Explicit `INSTALL`, `LOAD`, `SIGNING` and `OPENCORE_CHANGE` status.
- Stage result: `PASS`, `FAIL` or `REVIEW_REQUIRED`.
- Remaining blockers and next-stage prerequisite.

**Roadmap checkpoint:** 2026-11-03 — proposed next stage: **Stage 89 (Four-queue construction and registration-argument assembly)**.  
**Current authorization:** `IMPLEMENTATION_AUTHORIZED=NO`; this roadmap itself does not authorize source activation, signing, installation, loading or OpenCore changes.
