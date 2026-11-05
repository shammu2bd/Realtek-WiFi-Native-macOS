# Stage91 WMM routing and completion retry fix

Date: 2026-11-06
Branch: `work/stage91-tx-submission-callback-v1`
Source baseline reviewed: `feba82c19a228a315309f7fa2e5fb926cbbe800e`
Implementation revision: `31c0d68988b5361900e6d21db6436cfa4e126377`
Target: macOS Sequoia 15.8.1 / 24H32 / x86_64

## Fix 1 — preserve WMM service class end-to-end

The four 24H32 Skywalk service-class values are explicitly named from the pinned SDK's `packet_svc_class_t`:
- Background: `PKT_SC_BK = 0x00100080`
- Best Effort: `PKT_SC_BE = 0x00000000`
- Interactive Video: `PKT_SC_VI = 0x00380100`
- Interactive Voice: `PKT_SC_VO = 0x00400180`

The route helper maps them to the compatibility layer's confirmed access-category values (VO=0, VI=1, BE=2, BK=3) and representative 802.11e TIDs (BK=1, BE=0, VI=5, VO=6).

The actual callback now reads `queue->getServiceClass()`, resolves a route, carries it through a bounded stack submission context, and forwards access category/TID through:
`txSubmissionAction -> submitTXPacket -> RTW88WCLSkywalkTxAdapter -> outputPacketWithCompletion -> txDataFrame`.

RTW88 now uses the supplied access category for `skb_set_queue_mapping`, the supplied TID for `skb->priority` and QoS Control, and only enables the existing BlockAck aggregation path for the matching Best-Effort TID. The pinned RTW88 PCI mapper turns those four AC values into the matching VO/VI/BE/BK hardware rings, and the TX descriptor qsel comes from the supplied TID. Packets no longer all collapse to Best Effort.

To make the four independently scheduled AC callbacks safe against sequence/nonce collisions, the radio uses the freestanding `RTW88TxSequenceNumbers` helper. It allocates QoS sequence numbers independently for TIDs 0–7, uses atomic allocation for the non-QoS sequence space, and allocates one unique 48-bit CCMP packet number through compare/exchange. It refuses to wrap and reuse a CCMP nonce.

## Fix 2 — make failed deferred completion handoffs retryable

The completion sink now returns `bool`.
- `true`: the sink confirms that the Skywalk completion queue accepted the packet and ownership handoff completed; the adapter may retire its ticket and drop its retains.
- `false`: the sink guarantees no handoff occurred; the adapter transitions the ticket from `Draining` back to `Completed`, preserves the packet and adapter retains, and stops that drain pass so it can retry later without spinning.

A new ticket-state regression test verifies that retry preserves packet identity and completion status and that the ticket remains outstanding until a later successful finish. The header documents that false must never be returned after transferring ownership.

## Regression coverage added

- Queue-array C++ test covers all four service-class to access-category/TID mappings plus unknown/null rejection.
- Completion-slot C++ test covers failed handoff, retry and final release.
- Stage91 source audit verifies the service-class callback source, the compatibility AC-to-RTW88-ring mapper, the QoS TID/qsel path, the atomic per-TID sequence helper and the retry-safe sink contract.
- New test 11, `tests/rtw88_tx_sequence_numbers_test.cpp`, stresses same-TID sequence allocation and CCMP packet-number uniqueness with eight concurrent producers.

## Verification still required on the target Mac

The updated 11-test runner must be rerun against this revision. The native compile-only validation must cover seven objects:
1. Six WCL objects from `rtl88wifi-wcl-controller-abi-check`.
2. `build/native/RTW88IEEE80211.o`, because the RTW88 frame-builder API was extended.

The previous 10/10 test PASS and six-object compile PASS predate these changes and do not validate this revision. The portable sequence-number stress test was also run in a local host shell; the complete 11-test repository runner and seven-object macOS compile still need to run on the user's Mac.

## Remaining Stage92 boundary

This patch fixes the completion-sink failure contract; it does **not** implement or activate the Stage92 Skywalk TX-completion queue consumer. The exact queue handoff ABI/lifecycle still needs its own source/ABI review and tests. Tickets therefore remain outstanding until a future validated deferred consumer calls `drainCompletions`. Queue registration, queue activation, radio start, full kext link, signing, installation, loading and hardware testing remain fenced.

## Decision

**Source changes committed; validation pending. PR #4 remains draft and unmerged. The validated Stage92 Skywalk completion consumer is still not implemented.
