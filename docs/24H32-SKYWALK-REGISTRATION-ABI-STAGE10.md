# Sequoia 24H32 Skywalk registration ABI — Stage 10

Stage 10 records what the new full-function audit proves and corrects one bad
interpretation in the Stage 9 report. It does **not** turn on interface
registration or packet delivery.

## Confirmed callable signatures

The 24H32 method symbols and full function bodies agree with the public SDK's
`IOReturn` return types:

- `IOSkywalkNetworkInterface::registerNetworkInterface(RegistrationInfo const*, IOSkywalkPacketQueue**, unsigned int, IOSkywalkPacketBufferPool*, IOSkywalkPacketBufferPool*, unsigned int)`
- The logical-link overload of `registerNetworkInterface`, plus
  `deregisterNetworkInterface(unsigned int)`.
- Both `IOSkywalkEthernetInterface::registerEthernetInterface` overloads and
  `deregisterEthernetInterface(unsigned int)`.
- `IOSkywalkEthernetInterface::initRegistrationInfo(RegistrationInfo*,
  unsigned int, size_t)` retains the SDK's `bool` result.
- `IO80211InfraInterface::registerInfraEthernetInterface(
  IOSkywalkEthernetInterface::RegistrationInfo*, IOSkywalkPacketQueue**,
  unsigned int, IOSkywalkPacketBufferPool*, IOSkywalkPacketBufferPool*)`.

The registration methods are ordinary non-virtual methods. They are declared
in the private ABI shim without adding vtable entries. The opaque registration
payloads and expansion-data allocations are still not defined locally.

## Return-value evidence

`AppleBCMWLANSkywalkInterface::start` directly calls
`IO80211InfraInterface::registerInfraEthernetInterface`, saves its EAX result,
checks it, and branches on zero as success. The infra wrapper saves the nested
`registerEthernetInterface` return in `r14d` and returns that value in EAX.
The Ethernet queue overload calls the `IOSkywalkNetworkInterface` queue
registration overload and returns its EAX status. The network registration
body initializes and propagates nonzero IOReturn-style error values on failure.

This is evidence for `IOReturn` (`kIOReturnSuccess == 0`, nonzero means error),
not a C++ `bool` convention.

## Corrected vtable finding

Stage 9 incorrectly called the `[vtable + 0xc00]` call in
`IO80211InfraInterface::start` a registration dispatch. The exact 24H32 vtable
row resolves offset `0xc00` (slot 384) to
`IO80211InfraInterface::setInterfaceOFDMDesense(apple80211_channel, long long)`.
That call is unrelated to registration. The registration call is the distinct
direct call from `AppleBCMWLANSkywalkInterface::start` noted above.

The audit now checks the expected vtable target and separately checks the
Apple direct call path and its zero-success result test.

## Still not enabled

The confirmed method signatures are not sufficient to call registration yet.
The implementation still needs a faithful builder for Apple's 0x130-byte
`RegistrationInfo`, the actual queue-set configuration and queue-array order,
pool roles and lifetimes, packet refill rules, RX completion handoff, rollback,
and stop/deregister ordering. The current queue and RX owner objects are not
registered; `RTW88WCLInfraInterface::start` still fails closed; the radio is
not started; the controller does not publish a BSD interface.

No experimental Kext installation, configuration change, or OpenCore change is
part of this stage.

## Validation

The Stage 10 tests assert the non-virtual IOReturn declarations, keep all
registration invocations fenced, and exercise the corrected vtable/direct-call
interpretation with synthetic archive members. Host macOS x86_64 object builds
are checked separately from the user's full Xcode build. A target Mac build is
still required before considering this slice build-verified.
