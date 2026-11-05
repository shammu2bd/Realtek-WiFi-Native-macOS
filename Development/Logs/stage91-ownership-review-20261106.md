# Stage91 TX packet ownership and teardown review

Date: 2026-11-06
Branch: `work/stage91-tx-submission-callback-v1`
Reviewed commit: `feba82c19a228a315309f7fa2e5fb926cbbe800e`
Target: macOS Sequoia 15.8.1 / 24H32 / x86_64
Review type: static source/control-flow review; no source code changed by this review.

## Decision

**CONDITIONAL PASS for Stage91's bounded submission and retained-ticket ownership path. NOT APPROVED for queue activation, merge, or end-to-end TX completion.**

The 10 host/source tests and six-object native compile-only validation are PASS, but they do not exercise a registered Skywalk queue, a live packet, the deferred completion handoff, or the RTL8821CE hardware.

## Ownership path — findings

1. The TX callback validates the Skywalk packet and copies the Ethernet bytes into a nonblocking mbuf before retaining the original packet. Invalid packets and copy failures return without taking the Skywalk packet.
2. On the accepted path, the adapter retains the packet and reserves a fixed-capacity completion ticket. If ticket reservation fails, it releases the packet retain and frees the copied mbuf.
3. The adapter takes a matching per-ticket retain before invoking `outputPacketWithCompletion`. The RTW88 output path consumes the mbuf on every visible early-reject and frame-build path. A failed lower-level TX submission produces a terminal false callback; the adapter intentionally still reports the Skywalk packet as accepted because the ticket now carries the later completion result.
4. The RTW88 completion token is separately allocated; `alloc_skb` zero-initializes the skb structure; the token uses an atomic exchange to allow one terminal reporter. The local PCI TX ISR reports successful status for ordinary packets and routes request-status packets through the firmware-report path. skb free/purge paths report failure. The compat callback calls the WCL backend completion hook before freeing the skb.
5. The WCL backend completion hook only atomically marks the ticket complete. It does not call Skywalk, release OSObjects, allocate memory, or block. Packet and adapter releases are deferred to the completion-drain side.
6. The owner and adapter admission gates protect callback pointer-load windows. Teardown closes TX admission, stops RTW88, fences the PCI/DMA backend, refuses adapter unbind while tickets remain, detaches the queue-owner callback context only after quiescence, and delays queue/pool rollback until the owner is detached.

Relevant reviewed source:
- `RTW88WCLSkywalkTxAdapter.cpp` — blob `c9726b49bf1d6f2ec8fb3932f2a39ad23f006124`
- `RTW88WCLSkywalkTxAdapter.hpp` — blob `53b9029f577fba9a3f921583811fafc87595b7c9`
- `RTW88WCLSkywalkQueues.cpp` — blob `c13868cd44f18dda1ce7413c3e65b83f93006750`
- `RTW88IEEE80211.cpp` — blob `08ffe447a751fa38d55295298cd1ca7d0500f974`
- `skbuff_tx_completion.h` — blob `7d8e4dca677ce70b0c8c57e2168772a76accc448`
- RTW88 PCI `pci.c` — blob `018167fa93006b270606cb39b1d06348057ad6e0`

## Blocking findings

### A. Four WMM submission queues do not preserve their service class

`txSubmissionAction` checks which queue invoked the callback, but then calls `submitPrefix` with only the adapter as context. `submitTXPacket` forwards only the packet to `submitPacket`; the selected queue/service class is lost. Downstream, `RTW88IEEE80211::txDataFrame` sets `skb_set_queue_mapping(skb, IEEE80211_AC_BE)`, `skb->priority = 0`, and the QoS TID from `_baTid`. Thus packets arriving on Background, Video, or Voice queues are currently transmitted through the Best-Effort mapping. The four queue objects exist, but four-class TX scheduling is not implemented. Preserve and validate the service-class/AC/TID mapping end-to-end before claiming WMM queue support.

### B. Stage92 completion sink cannot report handoff failure

The adapter's `CompletionSink` type returns `void`. `drainCompletions` therefore calls the sink and unconditionally finishes the ticket, releases the packet retain, and releases the per-ticket adapter retain. If a future Skywalk completion-queue handoff can fail, the sink cannot tell the adapter to keep/retry/quarantine that packet. Stage92 must prove the exact 24H32 completion API's no-fail/ownership contract, or make the sink report success/failure and preserve the ticket and packet retain on failure. A packet must not be retired merely because a sink callback returned.

### C. No completion consumer exists in Stage91

No Stage91 path schedules or invokes `drainCompletions`. Completed tickets remain outstanding until a later stage drains them; consequently `unbind` correctly returns busy and the controller retains/quarantines owners rather than freeing live state. This is safe fail-closed behavior, but means Stage91 cannot complete teardown after accepting TX packets and is not activation-ready.

## Required next work

1. Resolve WMM service-class propagation from the queue callback through the RTW88 hardware queue and QoS TID.
2. Verify the exact 24H32 TX completion queue handoff semantics and give the drain path a safe failure policy.
3. Add tests for service-class preservation, sink failure/retry, and completion-versus-stop races.
4. Implement and test the Stage92 deferred completion consumer; keep queue registration and radio start fenced until its ownership contract is reviewed.
5. Re-run all 10 Stage91 tests and the six-object compile after any source changes, then repeat independent review.

## Safety boundary

No queue registration/enable, BSD interface publication, radio start, full kext link, signing, installation, loading, hardware test, or OpenCore/SIP/NVRAM change was performed or authorized by this review. PR #4 remains draft and must not be merged on the current evidence.
