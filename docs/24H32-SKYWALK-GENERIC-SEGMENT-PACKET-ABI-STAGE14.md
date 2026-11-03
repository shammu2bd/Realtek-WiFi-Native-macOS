# Stage 14 — generic Skywalk memory-segment and packet ABI

## Purpose

Stage 13 confirmed the specialized Apple BCM PCIe pool design, but that class
uses a provider-specific subclass, mapper and PCIe memory-segment objects. None
of those BCM-specific mechanisms should be transplanted into RTL88WiFi.

The current Realtek source already has a bounded, staged
`RTW88WCLSkywalkQueues::createQueues()` implementation. It creates two generic
`IOSkywalkPacketBufferPool` instances with `withName()` and then creates the
four generic queue objects. The controller's start path currently reaches this
allocation stage but then deliberately refuses publication and unwinds the
resources. This is not a live datapath: callback handlers remain fail-closed,
queues are not registered or scheduled, and radio start is fenced.

The remaining ABI gap is the generic segment and packet object lifecycle used
by `IOSkywalkPacketBufferPool`. In particular, the pool's default
`newMemorySegment()` constructs an `IOSkywalkMemorySegment`; the kernel pool
segment constructor then looks up the segment object and enters the pool's
`prepareMemorySegment()` path. Stage 14 collects exact methods for these core
classes alongside the already-reviewed generic queue/pool ownership classes.

## Exact target classes

- `IOSkywalkPacketQueue`
- `IOSkywalkPacketBufferPool`
- `IOSkywalkQueueSet`
- `IOSkywalkLogicalLink`
- `IOSkywalkMemorySegment`
- `IOSkywalkPacketBuffer`
- `IOSkywalkPacket`
- `IOSkywalkNetworkPacket`

The Stage 8–10 registration seed symbols are retained. The Apple BCM PCIe
provider subclasses are intentionally not targets in this stage.

### Stage 14 collector correction

The upstream WTLKcAbi `dump.py` has an explicit `CLASSES` allow-list. It
previously omitted `IOSkywalkMemorySegment`, even though the class is in the
24H32 Skywalk class inventory. That caused `dump_sizes()` to report its
instance size while `dump_vtables()` never requested its vtable or method list.

The collector now copies the WTLKcAbi checkout into its own temporary work
directory, applies `tools/patch-kcabi-class-list-stage14.py` to that temporary
`dump.py`, and runs both passes from the patched copy. The user's
`$HOME/src/kcabi` / WTLKcAbi checkout remains unchanged. The patcher is
idempotent and fails closed if the upstream `CLASSES` block or the expected
generic packet-buffer anchors change. No ABI symbols are invented.

## Run on macOS 15.8.1 / 24H32 / x86_64

From the extracted Stage 14 project root:

Use the `runlog` command installed in the one-time setup so the same
`~/Desktop/output.log` is overwritten and committed to
`shammu2bd/BDIX-TV` after every run:

```sh
runlog bash -lc '
cd "$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source" || exit 1
python3 tests/test-wcl-generic-skywalk-segment-ref-stage14.py &&
bash -n tools/collect-sequoia-abi-24H32-stage14.sh &&
tools/collect-sequoia-abi-24H32-stage14.sh build/sequoia-abi-24H32-stage14
'
```

The collector creates this archive after a successful two-pass run:

`build/sequoia-abi-24H32-stage14/RTL88WiFi-Sequoia-24H32-stage14-generic-skywalk-segment-packet-kcabi.tar.gz`

Upload that archive to the GitHub repository root. The `runlog` helper
synchronizes only `output.log`; it does not upload the binary ABI archive.

## Safety boundary

This is a read-only ABI evidence pass. It does not change the Kext source, call
registration, add queues to a workloop, enable any TX/RX callback, publish a BSD
interface, or start the radio. Do not install or load an experimental Kext or
change the working OpenCore/legacy-driver configuration based on this stage.
