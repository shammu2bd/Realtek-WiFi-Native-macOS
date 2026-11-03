#!/usr/bin/env python3
"""Stage 17 read-only audit: exact queue method inventory and ownership fences."""
from __future__ import annotations
import argparse, hashlib, json, re, tarfile, tempfile
from pathlib import Path

TARGET_CLASSES = (
    "IOSkywalkPacketQueue", "IOSkywalkPacketBufferPool", "IOSkywalkMemorySegment",
    "IOSkywalkPacketBuffer", "IOSkywalkPacket", "IOSkywalkNetworkPacket",
    "IOSkywalkRxSubmissionQueue", "IOSkywalkRxCompletionQueue",
    "IOSkywalkTxSubmissionQueue", "IOSkywalkTxCompletionQueue",
    "IOSkywalkInterface", "IOSkywalkNetworkInterface", "IOSkywalkEthernetInterface",
)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_extract(archive: Path, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    root = dest.resolve()
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()
        if not members:
            raise RuntimeError(f"Empty archive: {archive}")
        for m in members:
            p = Path(m.name)
            if p.is_absolute() or ".." in p.parts or not (m.isfile() or m.isdir()):
                raise RuntimeError(f"Unsafe archive member: {m.name}")
            out = (root / p).resolve()
            if out != root and root not in out.parents:
                raise RuntimeError(f"Archive path escapes destination: {m.name}")
        tf.extractall(dest, members=members)


def one_file(root: Path, name: str) -> Path:
    hits = [p for p in root.rglob(name) if p.is_file()]
    if len(hits) != 1:
        raise RuntimeError(f"Expected exactly one {name}; found {len(hits)}")
    return hits[0]


def json_in_archive(archive: Path, filename: str) -> dict:
    with tarfile.open(archive, "r:gz") as tf:
        hits = [m for m in tf.getmembers() if m.isfile() and Path(m.name).name == filename]
        if len(hits) != 1:
            raise RuntimeError(f"{archive.name}: expected one {filename}; found {len(hits)}")
        f = tf.extractfile(hits[0])
        if f is None:
            raise RuntimeError(f"Unable to read {filename} from {archive.name}")
        return json.loads(f.read().decode("utf-8", "replace"))


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"(?m)//.*$", "", text)


def function_body(text: str, marker: str) -> str:
    start = text.find(marker)
    if start < 0:
        return ""
    brace = text.find("{", start)
    if brace < 0:
        return ""
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{": depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0: return text[brace + 1:i]
    return ""


def source_audit(project: Path) -> list[dict]:
    base = project / "driver/RTL88WiFi/src/kext/wcl24h32"
    names = (
        "RTW88WCLSkywalkQueues.cpp", "RTW88WCLSkywalkRxAdapter.cpp",
        "RTW88WCLSkywalkTxAdapter.cpp", "RTW88WCLTxCompletionSlots.hpp",
        "RTW88WCLMbufRing.hpp", "RTW88WCLController.cpp", "RTW88WCLController.hpp",
        "RTW88WCLInfraInterface.cpp",
    )
    missing = [str(base / n) for n in names if not (base / n).is_file()]
    if missing:
        raise RuntimeError("Required source files missing: " + ", ".join(missing))
    raw = {n: (base / n).read_text(encoding="utf-8", errors="replace") for n in names}
    src = {n: strip_comments(v) for n, v in raw.items()}
    q, rx, tx = src[names[0]], src[names[1]], src[names[2]]
    slots, ring, ctrl = src[names[3]], src[names[4]], src[names[5]]
    infra = src[names[7]]
    checks = []
    callbacks = {
        "txSubmissionAction": "IOReturn RTW88WCLSkywalkQueues::txSubmissionAction",
        "txCompletionAction": "IOReturn RTW88WCLSkywalkQueues::txCompletionAction",
        "rxSubmissionAction": "IOReturn RTW88WCLSkywalkQueues::rxSubmissionAction",
        "rxCompletionAction": "IOReturn RTW88WCLSkywalkQueues::rxCompletionAction",
    }
    bodies = {k: function_body(q, v) for k, v in callbacks.items()}
    def add(name, passed, evidence):
        checks.append({"check": name, "status": "PASS" if passed else "FAIL", "evidence": evidence})

    add("all four native queue callbacks remain fail-closed",
        all(b and "return kIOReturnNotReady;" in b for b in bodies.values()),
        "TX/RX submission and completion callbacks return kIOReturnNotReady")
    add("TX submission validates packet view before declining acceptance",
        "RTW88WCLResolveEthernetTxPacket" in bodies["txSubmissionAction"] and
        "return kIOReturnNotReady;" in bodies["txSubmissionAction"],
        "packet validation is present; native queue ownership is not accepted")
    add("all four queue objects are allocated with the matching factories",
        all(x in q for x in ("IOSkywalkTxSubmissionQueue::withPool", "IOSkywalkTxCompletionQueue::withPool",
                              "IOSkywalkRxSubmissionQueue::withPool", "IOSkywalkRxCompletionQueue::withPool")),
        "four queue factory calls found")
    add("queues are released before their backing pools",
        q.find("_rxCompletion->release()") < q.find("_rxPool->release()") < q.find("_txPool->release()") and
        q.find("_txSubmission->release()") < q.find("_txPool->release()"),
        "destroyQueues releases queue references before pools")
    add("driver implementation has no queue registration or enqueue calls",
        not re.search(r"\bregisterEthernetInterface\s*\(", q + rx + tx + ctrl + infra) and
        not re.search(r"\benqueuePackets\s*\(", q + rx + tx + ctrl + infra),
        "no registerEthernetInterface/enqueuePackets call sites")

    rx_work = function_body(rx, "bool RTW88WCLSkywalkRxAdapter::checkForWork")
    add("RX sink acceptance transfers ownership and rejection recycles packet",
        "const bool accepted = _sink && _sink(packet, _sinkContext);" in rx_work and
        "if (!accepted)" in rx_work and "_rxPool->deallocatePacket(packet)" in rx_work,
        "false sink result returns packet to pool; true transfers ownership")
    add("original RTW88 mbuf is freed after deferred conversion",
        "mbuf_freem(source);" in rx_work,
        "source mbuf released in workloop drain")
    add("failed native packet construction recycles partial allocation",
        "if (!valid)" in rx and "pool->deallocatePacket(packet)" in rx,
        "conversion failure returns packet to pool")
    add("controller RX sink transfers only into fixed-capacity packet ring",
        "return self->_stagedRxPackets.push(preparedPacket);" in ctrl and
        "RTW88WCLMbufRing<IOSkywalkPacket *, kStagedRxPacketCapacity>" in raw[names[6]] and
        "kStagedRxPacketCapacity = 128" in raw[names[6]],
        "successful ring push is the only staged RX ownership transfer")
    add("pointer ring is bounded, power-of-two and rejects full pushes without allocation",
        "Capacity >= 2" in ring and "Capacity & (Capacity - 1)" in ring and
        "return false;" in ring and "new " not in ring and "malloc(" not in ring,
        "fixed MPMC ring; failed push leaves ownership with producer")
    add("teardown is ordered after packet-path quiescence and RX drain",
        ctrl.find("quiescePacketPath()") < ctrl.find("_radio->stop()") <
        ctrl.find("_rxAdapter->stop()") < ctrl.find("recycleStagedRxPackets()") <
        ctrl.find("_skywalkQueues->destroyQueues()"),
        "quiesce -> stop radio -> stop RX adapter -> recycle packets -> destroy queues")
    recycle = function_body(ctrl, "IOReturn RTW88WCLController::recycleStagedRxPackets")
    add("staged packet ring drains while pool is alive with disposal fallback",
        "_stagedRxPackets.pop(&packet)" in recycle and "pool->deallocatePacket(packet)" in recycle and
        "pool->disposeAllPackets()" in recycle,
        "individual recycle plus pool disposal fallback")
    rx_stop = function_body(rx, "void RTW88WCLSkywalkRxAdapter::stop")
    add("RX workloop source is removed before retained pool release",
        0 <= rx_stop.find("removeEventSource(this)") < rx_stop.find("_rxPool->release()") and
        "while (_frames.pop(&packet))" in rx_stop,
        "adapter removes source and drains mbuf ring before releasing pool")
    enter = function_body(ctrl, "bool RTW88WCLController::enterPacketPath")
    quiesce = function_body(ctrl, "IOReturn RTW88WCLController::quiescePacketPath")
    add("packet-path entry increments in-flight count and rechecks active state",
        "_packetPathInFlight" in enter and "kPacketPathActive" in enter and "__atomic_sub_fetch" in enter,
        "entry race is rolled back when quiesce wins")
    add("quiesce prevents owner teardown while packet operations are in flight",
        "kPacketPathQuiescing" in quiesce and "_packetPathInFlight" in quiesce and
        "return kIOReturnBusy;" in quiesce,
        "in-flight operations keep owners live for retry")

    submit = function_body(tx, "IOReturn RTW88WCLSkywalkTxAdapter::submitPacket")
    add("TX adapter retains packet before reserving bounded completion ticket",
        0 <= submit.find("packet->retain()") < submit.find("_tickets.reserve(packet)") and
        "packet->release()" in submit,
        "packet retained until deferred ticket drain")
    backend = function_body(tx, "void RTW88WCLSkywalkTxAdapter::backendCompletion")
    add("RTW88 completion callback only publishes ticket state",
        "TicketPool::complete(ticket, transmitted)" in backend and "release()" not in backend and
        "IOLog" not in backend and "enqueuePackets" not in backend,
        "backend callback does not call Skywalk or release OSObjects")
    drain = function_body(tx, "uint32_t RTW88WCLSkywalkTxAdapter::drainCompletions")
    add("TX packet retain is released only after deferred completion sink returns",
        0 <= drain.find("sink(packet, transmitted, context)") < drain.find("TicketPool::finish(ticket)") <
        drain.find("packet->release()"),
        "deferred context runs sink before ticket and packet release")
    infra_start = function_body(infra, "bool RTW88WCLInfraInterface::start")
    infra_enable = function_body(infra, "IOReturn RTW88WCLInfraInterface::enable")
    controller_without_definition = ctrl.replace(
        "IOReturn RTW88WCLController::activatePacketPath(", "", 1)
    activation_calls = re.findall(
        r"\bactivatePacketPath\s*\(", controller_without_definition + infra)
    start_refuses_publication = (
        bool(infra_start) and "return false;" in infra_start and
        "super::start(" not in infra_start
    )
    enable_activation_is_gated = (
        bool(infra_enable) and
        infra_enable.find("_bridge.powerOn()") >= 0 and
        infra_enable.find("_controller->activatePacketPath(this)") > infra_enable.find("_bridge.powerOn()") and
        "if (status != kIOReturnSuccess)" in infra_enable and
        "_bridge.powerOff();" in infra_enable
    )
    add("native interface start refuses publication; latent activation is only in its gated enable callback",
        start_refuses_publication and enable_activation_is_gated and
        len(activation_calls) == 1 and
        not re.search(r"\bregisterEthernetInterface\s*\(", q + rx + tx + ctrl + infra) and
        not re.search(r"\benqueuePackets\s*\(", q + rx + tx + ctrl + infra),
        "InfraInterface::start returns false without super::start; enable contains the sole activation call after powerOn; no register/enqueue call sites")
    return checks


def parse_index(stage17_root: Path) -> set[str]:
    paths = list(stage17_root.rglob("asm/INDEX.txt"))
    if len(paths) != 1:
        raise RuntimeError(f"Expected one asm/INDEX.txt; found {len(paths)}")
    out = set()
    for line in paths[0].read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^\s*0x[0-9a-fA-F]+\t[^\t]*\t(__Z\S+)\t", line)
        if m: out.add(m.group(1))
    return out


def parse_methods(stage17_root: Path) -> dict[str, list[str]]:
    out = {}
    for cls in TARGET_CLASSES:
        hits = list(stage17_root.rglob(cls + ".methods.txt"))
        if len(hits) != 1:
            raise RuntimeError(f"Expected one {cls}.methods.txt; found {len(hits)}")
        symbols = []
        for line in hits[0].read_text(encoding="utf-8", errors="replace").splitlines():
            fields = line.split("\t")
            if len(fields) >= 2 and fields[-1].startswith("__Z"):
                symbols.append(fields[-1])
        out[cls] = list(dict.fromkeys(symbols))
        if not out[cls]:
            raise RuntimeError(f"{cls}.methods.txt has no exact symbols")
    return out


def parse_executable_methods(stage17_root: Path, all_methods: dict[str, list[str]]) -> dict[str, list[str]]:
    path = one_file(stage17_root, "stage17-executable-methods.txt")
    executable = {cls: [] for cls in TARGET_CLASSES}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 2:
            raise RuntimeError(f"Malformed executable-method row: {line}")
        cls, symbol = fields
        if cls not in executable:
            raise RuntimeError(f"Unexpected class in executable-method inventory: {cls}")
        if symbol not in all_methods[cls]:
            raise RuntimeError(f"Executable method is not present in {cls}.methods.txt: {symbol}")
        executable[cls].append(symbol)
    for cls, symbols in executable.items():
        executable[cls] = list(dict.fromkeys(symbols))
        if not executable[cls]:
            raise RuntimeError(f"{cls} has no executable methods in Stage 17 inventory")
    return executable


def audit(stage14: Path, stage15: Path, stage16: Path, stage17_root: Path,
          manifest_path: Path, project: Path, out_dir: Path) -> dict:
    for p in (stage14, stage15, stage16):
        if not p.is_file(): raise RuntimeError(f"Required archive missing: {p}")
    h14, h15, h16 = (sha256_file(p) for p in (stage14, stage15, stage16))
    s15 = json_in_archive(stage15, "STAGE15-ABI-ACCESSOR-AUDIT.json")
    s16 = json_in_archive(stage16, "STAGE16-PACKET-SEMANTICS-AUDIT.json")
    if s15.get("stage") != 15 or s15.get("status") != "PASS" or s15.get("input_sha256") != h14:
        raise RuntimeError("Stage 15 PASS/input SHA does not match supplied Stage 14 archive")
    if s16.get("stage") != 16 or s16.get("status") != "PASS" or \
       s16.get("stage14_sha256") != h14 or s16.get("stage15_sha256") != h15:
        raise RuntimeError("Stage 16 PASS/input hashes do not match supplied Stage 14/15 archives")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("stage") != 17 or manifest.get("stage14_archive_sha256") != h14:
        raise RuntimeError("Stage 17 manifest does not match supplied Stage 14 archive")
    with tempfile.TemporaryDirectory(prefix="stage17-stage14-") as tmp:
        extracted = Path(tmp) / "stage14"
        safe_extract(stage14, extracted)
        source14 = json.loads(one_file(extracted, "source.json").read_text(encoding="utf-8"))
    source17 = json.loads(one_file(stage17_root, "source.json").read_text(encoding="utf-8"))
    if source17.get("build") != "24H32" or source17.get("product_version") != "15.8.1":
        raise RuntimeError("Stage 17 dump does not identify macOS 15.8.1 build 24H32")
    if source17.get("sha256") != source14.get("sha256") or manifest.get("kernel_collection_sha256") != source14.get("sha256"):
        raise RuntimeError("Stage 17 kernel collection does not match Stage 14")

    index = parse_index(stage17_root)
    methods = parse_methods(stage17_root)
    executable_methods = parse_executable_methods(stage17_root, methods)
    coverage = {}
    missing = {}
    for cls, symbols in methods.items():
        executable = executable_methods[cls]
        absent = [x for x in executable if x not in index]
        coverage[cls] = {
            "method_symbols": len(symbols),
            "executable_method_symbols": len(executable),
            "non_code_symbols": len(symbols) - len(executable),
            "disassembled": len(executable)-len(absent),
            "missing_disassembly": len(absent),
        }
        if absent: missing[cls] = absent
    checks = source_audit(project)
    status = "PASS" if not missing and all(x["status"] == "PASS" for x in checks) else "REVIEW_REQUIRED"
    result = {
        "stage": 17, "status": status,
        "meaning": "method-body collection plus source-level pre-activation ownership audit only",
        "platform": "macOS 15.8.1 (24H32), x86_64",
        "inputs": {"stage14_sha256": h14, "stage15_sha256": h15, "stage16_sha256": h16},
        "kernel_collection_sha256": source17.get("sha256"),
        "method_coverage": coverage,
        "target_method_symbol_count": sum(x["method_symbols"] for x in coverage.values()),
        "target_executable_method_symbol_count": sum(x["executable_method_symbols"] for x in coverage.values()),
        "target_non_code_symbol_count": sum(x["non_code_symbols"] for x in coverage.values()),
        "target_method_disassembly_count": sum(x["disassembled"] for x in coverage.values()),
        "missing_method_bodies": missing,
        "source_ownership_checks": checks,
        "activation_gate": "BLOCKED — registration, queue enqueue, TX/RX completion handoff, radio start and interface publication remain disabled",
        "unresolved_contracts": [
            "RX completion enqueue ownership transition and callback packet-array semantics.",
            "RX submission dequeue/replenishment ownership and retry semantics.",
            "TX completion queue acceptance and packet-retain transfer semantics.",
            "Packet-buffer and memory-segment prepare/complete requirements for configured pool options.",
            "Ethernet interface registration success/failure ownership and deregistration order.",
            "Queue enable/disable/synchronize and teardown order with in-flight callbacks.",
        ],
        "safety_boundary": "read-only; no queue is registered, no packet is submitted/enqueued, no radio starts and no interface is published",
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "STAGE17-QUEUE-OWNERSHIP-AUDIT.json").write_text(json.dumps(result, indent=2, sort_keys=True)+"\n", encoding="utf-8")
    lines = ["# Stage 17 — queue lifecycle and RX/TX ownership evidence audit", "",
             f"**Status:** {status}", "", f"- Stage 14 SHA-256: `{h14}`",
             f"- Stage 15 SHA-256: `{h15}`", f"- Stage 16 SHA-256: `{h16}`",
             f"- Kernel collection SHA-256: `{source17.get('sha256')}`", "",
             "## Class method/disassembly coverage", "",
             "| Class | All symbols | Executable methods | Non-code | Disassembled | Missing |",
             "|---|---:|---:|---:|---:|---:|"]
    for cls in TARGET_CLASSES:
        row = coverage[cls]
        lines.append(f"| `{cls}` | {row['method_symbols']} | {row['executable_method_symbols']} | {row['non_code_symbols']} | {row['disassembled']} | {row['missing_disassembly']} |")
    lines += ["", "## Source ownership and fail-closed checks", "",
              "| Check | Result | Evidence |", "|---|---|---|"]
    for row in checks:
        lines.append(f"| {row['check']} | **{row['status']}** | {row['evidence']} |")
    lines += ["", "## Unresolved contracts", ""]
    lines += [f"- {x}" for x in result["unresolved_contracts"]]
    lines += ["", "## Activation gate", "",
              "**BLOCKED.** This stage collects the exact 24H32 methods and verifies that the project remains fail-closed. "
              "It does not infer queue ownership from method names alone, and it does not enable the datapath.", ""]
    (out_dir / "STAGE17-QUEUE-OWNERSHIP-AUDIT.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"Stage 17 status: {status}")
    for cls in TARGET_CLASSES:
        row = coverage[cls]
        print(f"STAGE17_METHODS: {cls} {row['disassembled']}/{row['method_symbols']} disassembled")
    print(f"Stage 17 source ownership checks: {sum(x['status']=='PASS' for x in checks)}/{len(checks)}")
    print(f"Stage 17 executable method bodies: {result['target_method_disassembly_count']}/{result['target_executable_method_symbol_count']}")
    print(f"Stage 17 non-code class symbols excluded from body coverage: {result['target_non_code_symbol_count']}")
    print("DATAPATH_ACTIVATION: BLOCKED")
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stage14-archive", required=True, type=Path)
    ap.add_argument("--stage15-archive", required=True, type=Path)
    ap.add_argument("--stage16-archive", required=True, type=Path)
    ap.add_argument("--stage17-root", required=True, type=Path)
    ap.add_argument("--manifest", required=True, type=Path)
    ap.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    try:
        result = audit(args.stage14_archive, args.stage15_archive, args.stage16_archive,
                       args.stage17_root, args.manifest, args.project_root.resolve(), args.out)
    except (OSError, RuntimeError, ValueError, tarfile.TarError, json.JSONDecodeError) as exc:
        ap.error(str(exc))
    return 0 if result["status"] == "PASS" else 2

if __name__ == "__main__":
    raise SystemExit(main())
