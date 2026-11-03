#!/usr/bin/env python3
"""Build a read-only Stage 18 ownership-contract evidence dossier from Stage 17."""
from __future__ import annotations
import argparse, hashlib, json, re, tarfile, tempfile, shutil
from pathlib import Path

TARGET_CLASSES = (
    "IOSkywalkPacketQueue", "IOSkywalkPacketBufferPool", "IOSkywalkMemorySegment",
    "IOSkywalkPacketBuffer", "IOSkywalkPacket", "IOSkywalkNetworkPacket",
    "IOSkywalkRxSubmissionQueue", "IOSkywalkRxCompletionQueue",
    "IOSkywalkTxSubmissionQueue", "IOSkywalkTxCompletionQueue",
    "IOSkywalkInterface", "IOSkywalkNetworkInterface", "IOSkywalkEthernetInterface",
)
SOURCE_BASE = Path("driver/RTL88WiFi/src/kext/wcl24h32")
SOURCE_FILES = (
    "RTW88WCLSkywalkQueues.cpp", "RTW88WCLSkywalkRxAdapter.cpp",
    "RTW88WCLSkywalkTxAdapter.cpp", "RTW88WCLTxCompletionSlots.hpp",
    "RTW88WCLMbufRing.hpp", "RTW88WCLController.cpp",
    "RTW88WCLController.hpp", "RTW88WCLInfraInterface.cpp",
)
CONTRACTS = (
    {
        "id": "rx_completion_enqueue",
        "title": "RX completion enqueue ownership and callback packet-array semantics",
        "classes": ("IOSkywalkRxCompletionQueue", "IOSkywalkNetworkPacket", "IOSkywalkPacket", "IOSkywalkPacketBufferPool", "IOSkywalkPacketBuffer"),
        "pattern": r"enqueue|complete|packet|buffer|release|retain|enable|disable|synchron|push|pop|submit|dequeue|drain|notify|service",
        "sources": ("RTW88WCLSkywalkQueues.cpp", "RTW88WCLSkywalkRxAdapter.cpp", "RTW88WCLController.cpp", "RTW88WCLController.hpp"),
        "source_pattern": r"rxCompletion|enqueue|sink|stagedRx|deallocatePacket|accept|reject|drain|recycle|completion",
        "questions": ("What exact argument shape and packet-array ownership does the kernel callback require?", "At what instruction/API boundary does ownership transfer on success?", "What must happen on partial acceptance or callback failure?", "Which context invokes completion and what operations are legal there?"),
    },
    {
        "id": "rx_submission_replenish",
        "title": "RX submission dequeue, buffer replenishment and retry ownership",
        "classes": ("IOSkywalkRxSubmissionQueue", "IOSkywalkPacketQueue", "IOSkywalkPacketBufferPool", "IOSkywalkPacketBuffer", "IOSkywalkMemorySegment", "IOSkywalkPacket"),
        "pattern": r"dequeue|replenish|submit|refill|allocate|deallocate|prepare|complete|enable|disable|sync|start|stop|packet|buffer|segment|dma|map|unmap|flush|service|process",
        "sources": ("RTW88WCLSkywalkQueues.cpp", "RTW88WCLSkywalkRxAdapter.cpp", "RTW88WCLController.cpp", "RTW88WCLController.hpp"),
        "source_pattern": r"rxSubmission|allocatePacket|deallocatePacket|enqueueFrame|checkForWork|prepared|replenish|refill|stop\(|start\(|drain|recycle",
        "questions": ("Does dequeue transfer a packet/buffer reference or merely borrow it?", "What is the exact replenishment trigger and minimum buffer count?", "How are no-buffer and transient errors retried without double-free?", "Which prepare/complete calls are required before reuse?"),
    },
    {
        "id": "tx_completion_acceptance",
        "title": "TX completion queue acceptance and packet-retain transfer",
        "classes": ("IOSkywalkTxCompletionQueue", "IOSkywalkTxSubmissionQueue", "IOSkywalkNetworkPacket", "IOSkywalkPacket", "IOSkywalkPacketBufferPool", "IOSkywalkPacketBuffer"),
        "pattern": r"enqueue|complete|packet|buffer|enable|disable|synchron|notify|release|retain|dequeue|submit|start|stop|drain|service|process|cancel",
        "sources": ("RTW88WCLSkywalkQueues.cpp", "RTW88WCLSkywalkTxAdapter.cpp", "RTW88WCLTxCompletionSlots.hpp", "RTW88WCLController.cpp"),
        "source_pattern": r"txCompletion|txSubmission|submitPacket|backendCompletion|drainCompletions|TicketPool|retain\(|release\(|complete\(|finish\(",
        "questions": ("Does queue acceptance retain the packet or consume the caller's reference?", "When may the driver release its packet retain relative to completion callback return?", "Can completion run synchronously during submit, or only later?", "What are the error, cancellation and teardown ownership paths?"),
    },
    {
        "id": "pool_buffer_segment_prepare_complete",
        "title": "Packet-buffer and memory-segment prepare/complete requirements",
        "classes": ("IOSkywalkPacketBufferPool", "IOSkywalkPacketBuffer", "IOSkywalkMemorySegment", "IOSkywalkPacket"),
        "pattern": r"prepare|complete|memory|descriptor|virtual|address|packet|dma|map|unmap|segment|buffer|allocate|deallocate|create|destroy|release|retain|sync|direction|cache",
        "sources": ("RTW88WCLSkywalkQueues.cpp", "RTW88WCLSkywalkRxAdapter.cpp", "RTW88WCLSkywalkTxAdapter.cpp", "RTW88WCLController.cpp"),
        "source_pattern": r"allocatePacket|deallocatePacket|prepareWithMemorySegment|completeWithMemorySegment|MemorySegment|PacketBuffer|pool|dma|map|direction|prepare|complete",
        "questions": ("Which object owns the DMA descriptor and mapped address?", "What prepare/complete pair is required for each allocation option?", "Are offsets and lengths bounded by both segment and buffer sizes?", "What cleanup order applies after partial prepare failure?"),
    },
    {
        "id": "ethernet_registration_lifecycle",
        "title": "Ethernet interface registration, failure ownership and deregistration",
        "classes": ("IOSkywalkInterface", "IOSkywalkNetworkInterface", "IOSkywalkEthernetInterface"),
        "pattern": r"register|deregister|unregister|attach|detach|enable|disable|start|stop|init|free|setLink|interface|ethernet|queue|provider|client|service|open|close|publish|remove",
        "sources": ("RTW88WCLSkywalkQueues.cpp", "RTW88WCLController.cpp", "RTW88WCLController.hpp", "RTW88WCLInfraInterface.cpp"),
        "source_pattern": r"RegistrationInfo|registerEthernetInterface|deregister|register|prepareRegistrationInfo|start\(|stop\(|enable\(|disable\(|powerOn|powerOff|queue|release\(",
        "questions": ("Which object owns RegistrationInfo and its backing arrays on success?", "Who releases partially constructed registration state on each failure edge?", "Does deregistration synchronously quiesce callbacks and release queues?", "What ordering is required between interface stop, deregistration and pool release?"),
    },
    {
        "id": "queue_enable_synchronize_teardown",
        "title": "Queue enable/disable/synchronize and teardown ordering",
        "classes": ("IOSkywalkPacketQueue", "IOSkywalkRxSubmissionQueue", "IOSkywalkRxCompletionQueue", "IOSkywalkTxSubmissionQueue", "IOSkywalkTxCompletionQueue", "IOSkywalkInterface", "IOSkywalkNetworkInterface", "IOSkywalkEthernetInterface"),
        "pattern": r"enable|disable|synchron|sync|start|stop|init|free|reset|flush|cancel|close|open|deactiv|activ|register|unregister|submit|complete|queue|drain|quiesce|wait",
        "sources": ("RTW88WCLSkywalkQueues.cpp", "RTW88WCLSkywalkRxAdapter.cpp", "RTW88WCLSkywalkTxAdapter.cpp", "RTW88WCLController.cpp", "RTW88WCLController.hpp", "RTW88WCLInfraInterface.cpp"),
        "source_pattern": r"createQueues|destroyQueues|quiescePacketPath|releaseNativeResources|removeEventSource|stop\(|enable\(|disable\(|synchron|register|deregister|release\(",
        "questions": ("Which operation prevents new submissions before synchronization begins?", "Does synchronize wait for callback exit, queue drain, or both?", "Can callbacks race with queue/pool release?", "What exact order is required when shutdown must be retried?"),
    },
)


def sha256(path: Path) -> str:
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()


def read_json_member(tf: tarfile.TarFile, basename: str) -> dict:
    hits=[m for m in tf.getmembers() if m.isfile() and Path(m.name).name==basename]
    if len(hits)!=1: raise RuntimeError(f"Expected one {basename} in {tf.name}, found {len(hits)}")
    f=tf.extractfile(hits[0])
    if f is None: raise RuntimeError(f"Cannot read {basename}")
    return json.loads(f.read().decode('utf-8','replace'))


def safe_extract(archive: Path, dest: Path) -> None:
    dest.mkdir(parents=True,exist_ok=True); root=dest.resolve()
    with tarfile.open(archive,'r:gz') as tf:
        members=tf.getmembers()
        if not members: raise RuntimeError(f"Empty archive: {archive}")
        for m in members:
            p=Path(m.name)
            if p.is_absolute() or '..' in p.parts or not (m.isfile() or m.isdir()):
                raise RuntimeError(f"Unsafe archive member: {m.name}")
            out=(root/p).resolve()
            if out!=root and root not in out.parents: raise RuntimeError(f"Archive path escapes: {m.name}")
        tf.extractall(dest,members=members)


def one_file(root: Path, name: str) -> Path:
    hits=[p for p in root.rglob(name) if p.is_file()]
    if len(hits)!=1: raise RuntimeError(f"Expected exactly one {name}; found {len(hits)}")
    return hits[0]


def parse_index(root: Path) -> dict[str,dict]:
    path=one_file(root,'INDEX.txt'); out={}
    for line in path.read_text(encoding='utf-8',errors='replace').splitlines():
        m=re.match(r'^\s*(0x[0-9a-fA-F]+)\t([^\t]*)\t(__Z\S+)\t(\d+)',line)
        if m: out[m.group(3)]={'address':m.group(1),'owner':m.group(2),'instructions':int(m.group(4))}
    return out


def parse_methods(root: Path) -> dict[str,list[str]]:
    out={}
    for cls in TARGET_CLASSES:
        p=one_file(root,cls+'.methods.txt')
        syms=[]
        for line in p.read_text(encoding='utf-8',errors='replace').splitlines():
            m=re.search(r'(__Z\S+)',line)
            if m: syms.append(m.group(1))
        out[cls]=list(dict.fromkeys(syms))
        if not out[cls]: raise RuntimeError(f"Empty method list for {cls}")
    return out


def asm_map(root: Path) -> dict[str,Path]:
    out={}
    for p in root.rglob('*.asm.txt'):
        try: first=p.read_text(encoding='utf-8',errors='replace').splitlines()[0]
        except (OSError,IndexError): continue
        m=re.match(r'^#\s+0x[0-9a-fA-F]+\s+(__Z\S+)',first)
        if m: out[m.group(1)]=p
    return out


def source_snippets(project: Path, filenames: tuple[str,...], pattern: str, radius: int=4) -> tuple[list[dict],dict[str,str]]:
    rx=re.compile(pattern,re.I); rows=[]; snapshots={}
    for fn in filenames:
        p=project/SOURCE_BASE/fn
        if not p.is_file(): raise RuntimeError(f"Missing required source evidence: {p}")
        text=p.read_text(encoding='utf-8',errors='replace'); snapshots[fn]=text
        lines=text.splitlines(); selected=set()
        for i,line in enumerate(lines):
            if rx.search(line):
                for j in range(max(0,i-radius),min(len(lines),i+radius+1)): selected.add(j)
        if selected:
            groups=[]
            for idx in sorted(selected):
                if groups and idx==groups[-1][-1]+1: groups[-1].append(idx)
                else: groups.append([idx])
            for g in groups:
                rows.append({'file':fn,'start_line':g[0]+1,'end_line':g[-1]+1,
                             'text':'\n'.join(f'{i+1:5d}: {lines[i]}' for i in g)})
    return rows,snapshots


def build(stage14:Path,stage15:Path,stage16:Path,stage17:Path,project:Path,out:Path)->dict:
    for p in (stage14,stage15,stage16,stage17):
        if not p.is_file(): raise RuntimeError(f"Missing prerequisite archive: {p}")
    h14,h15,h16,h17=(sha256(p) for p in (stage14,stage15,stage16,stage17))
    with tarfile.open(stage15,'r:gz') as tf: s15=read_json_member(tf,'STAGE15-ABI-ACCESSOR-AUDIT.json')
    with tarfile.open(stage16,'r:gz') as tf: s16=read_json_member(tf,'STAGE16-PACKET-SEMANTICS-AUDIT.json')
    with tarfile.open(stage17,'r:gz') as tf: s17=read_json_member(tf,'STAGE17-QUEUE-OWNERSHIP-AUDIT.json')
    if s15.get('status')!='PASS' or s15.get('input_sha256')!=h14: raise RuntimeError('Stage 15 PASS/hash linkage failed')
    if s16.get('status')!='PASS' or s16.get('stage14_sha256')!=h14 or s16.get('stage15_sha256')!=h15:
        raise RuntimeError('Stage 16 PASS/hash linkage failed')
    if s17.get('stage')!=17 or s17.get('status')!='PASS' or s17.get('inputs',{}).get('stage14_sha256')!=h14 or s17.get('inputs',{}).get('stage15_sha256')!=h15 or s17.get('inputs',{}).get('stage16_sha256')!=h16:
        raise RuntimeError('Stage 17 PASS/hash linkage failed')
    coverage=s17.get('method_coverage',{})
    if set(coverage) != set(TARGET_CLASSES):
        raise RuntimeError('Stage 17 method coverage does not contain exactly the 13 target classes')
    total_symbols = total_executable = total_non_code = total_disassembled = total_missing = 0
    for cls in TARGET_CLASSES:
        row = coverage[cls]
        symbols = int(row.get('method_symbols', -1))
        executable = int(row.get('executable_method_symbols', -1))
        non_code = int(row.get('non_code_symbols', -1))
        disassembled = int(row.get('disassembled', -1))
        missing = int(row.get('missing_disassembly', -1))
        if min(symbols, executable, non_code, disassembled, missing) < 0:
            raise RuntimeError(f'Stage 17 coverage counters are incomplete for {cls}')
        if symbols != executable + non_code:
            raise RuntimeError(f'Stage 17 symbol classification is inconsistent for {cls}')
        if executable != disassembled + missing:
            raise RuntimeError(f'Stage 17 executable-body accounting is inconsistent for {cls}')
        total_symbols += symbols
        total_executable += executable
        total_non_code += non_code
        total_disassembled += disassembled
        total_missing += missing
    expected_totals = (
        ('target_method_symbol_count', total_symbols),
        ('target_executable_method_symbol_count', total_executable),
        ('target_non_code_symbol_count', total_non_code),
        ('target_method_disassembly_count', total_disassembled),
    )
    for key, actual in expected_totals:
        if s17.get(key) != actual:
            raise RuntimeError(f'Stage 17 {key} does not match per-class coverage: report={s17.get(key)}, calculated={actual}')
    if total_missing or total_disassembled != total_executable:
        raise RuntimeError(f'Stage 17 executable method body coverage is incomplete: {total_disassembled}/{total_executable}, missing={total_missing}')
    if not all(x.get('status')=='PASS' for x in s17.get('source_ownership_checks',[])):
        raise RuntimeError('Stage 17 source ownership checks are not all PASS')
    if len(s17.get('source_ownership_checks',[]))!=19: raise RuntimeError('Unexpected Stage 17 ownership-check count')

    work=out/'stage18-work'; evidence=work/'evidence'; (evidence/'methods').mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='stage18-stage17-') as td:
        tmp=Path(td); safe_extract(stage17,tmp)
        root=tmp/'24H32'
        if not root.is_dir(): raise RuntimeError('Stage 17 archive has no 24H32 root')
        src=json.loads(one_file(root,'source.json').read_text(encoding='utf-8'))
        if src.get('build')!='24H32' or src.get('product_version')!='15.8.1' or src.get('sha256')!=s17.get('kernel_collection_sha256'):
            raise RuntimeError('Stage 17 kernel collection identity mismatch')
        methods=parse_methods(root); idx=parse_index(root); am=asm_map(root)
        all_methods=sum(len(v) for v in methods.values())
        all_asm=sum(1 for cls,syms in methods.items() for sym in syms if sym in idx and sym in am)
        if all_asm!=s17.get('target_method_disassembly_count'):
            raise RuntimeError(f"Stage 17 disassembly count mismatch: archive has {all_asm}, report says {s17.get('target_method_disassembly_count')}")
        contract_results=[]; copied=set(); source_snapshots={}
        for spec in CONTRACTS:
            candidate=[]
            regex=re.compile(spec['pattern'],re.I)
            for cls in spec['classes']:
                for sym in methods[cls]:
                    if regex.search(sym) and sym in idx:
                        if sym not in am: raise RuntimeError(f"Stage 17 report says covered but assembly missing: {sym}")
                        candidate.append({'class':cls,'symbol':sym,**idx[sym], 'asm_path':str(am[sym].relative_to(root))})
                        if sym not in copied:
                            dest=evidence/'methods'/am[sym].name
                            shutil.copy2(am[sym],dest); copied.add(sym)
            snippets,snaps=source_snippets(project,spec['sources'],spec['source_pattern'])
            source_snapshots.update(snaps)
            contract_results.append({
                'id':spec['id'],'title':spec['title'],'status':'MANUAL_REVIEW_REQUIRED',
                'candidate_method_count':len(candidate),'candidate_methods':candidate,
                'source_evidence':snippets,'review_questions':list(spec['questions']),
                'note':'Candidate selection is name-assisted only. Read each exact assembly body and source path; no ownership conclusion is inferred automatically.'
            })
        source_dir=evidence/'source'; source_dir.mkdir(parents=True,exist_ok=True)
        for fn,text in source_snapshots.items():
            (source_dir/fn).write_text(text,encoding='utf-8')
        result={
            'stage':18,'status':'READY_FOR_MANUAL_REVIEW',
            'meaning':'Read-only evidence dossier for manual RX/TX queue ownership contract review; not an implementation approval.',
            'platform':'macOS 15.8.1 (24H32), x86_64',
            'inputs':{'stage14_sha256':h14,'stage15_sha256':h15,'stage16_sha256':h16,'stage17_archive_sha256':h17},
            'kernel_collection_sha256':src['sha256'],
            'stage17_method_symbols':s17['target_method_symbol_count'],
            'stage17_executable_method_symbols':s17['target_executable_method_symbol_count'],
            'stage17_non_code_symbols':s17['target_non_code_symbol_count'],
            'stage17_disassembled_methods':s17['target_method_disassembly_count'],
            'stage17_source_checks_passed':sum(x['status']=='PASS' for x in s17['source_ownership_checks']),
            'evidence_methods_copied':len(copied),
            'contracts':contract_results,
            'activation_gate':'BLOCKED — do not register queues, accept packet ownership, start the radio or publish the Ethernet interface until every contract has been manually resolved and separately tested.',
            'safety_boundary':'No driver source is changed by Stage 18. This stage only packages exact Stage 17 disassembly and current driver source evidence for review.'
        }
        (work/'STAGE18-OWNERSHIP-CONTRACT-REVIEW.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n',encoding='utf-8')
        md=['# Stage 18 — RX/TX ownership contract review dossier','',f"**Status:** {result['status']}",'',
            'This stage collects evidence for manual review. It does not infer ownership from names and does not authorize datapath activation.','',
            '## Verified inputs','',f"- Stage 14: `{h14}`",f"- Stage 15: `{h15}`",f"- Stage 16: `{h16}`",f"- Stage 17: `{h17}`",f"- Kernel collection: `{src['sha256']}`",'',
            f"- Stage 17 all class symbols: {result['stage17_method_symbols']}",
            f"- Stage 17 executable bodies: {result['stage17_disassembled_methods']}/{result['stage17_executable_method_symbols']}",
            f"- Stage 17 non-code symbols excluded: {result['stage17_non_code_symbols']}",
            f"- Stage 17 source checks: {result['stage17_source_checks_passed']}/19",f"- Exact method bodies copied into this dossier: {len(copied)}",'']
        for c in contract_results:
            md += [f"## {c['id']}: {c['title']}",'',f"**Status:** {c['status']}",f"**Candidate method bodies:** {c['candidate_method_count']}",'',
                   '### Kernel method candidates','']
            if c['candidate_methods']:
                md += ['| Class | Address | Instructions | Exact symbol | Assembly file |','|---|---:|---:|---|---|']
                for m in c['candidate_methods']:
                    md.append(f"| `{m['class']}` | `{m['address']}` | {m['instructions']} | `{m['symbol']}` | `{m['asm_path']}` |")
            else: md.append('No executable methods matched the conservative name filter; inspect the full class method lists in Stage 17 archive.')
            md += ['', '### Source evidence snippets','']
            for sn in c['source_evidence']:
                md += [f"**{sn['file']}:{sn['start_line']}-{sn['end_line']}**",'','```cpp',sn['text'],'```','']
            md += ['### Manual questions','']+[f"- [ ] {q}" for q in c['review_questions']]+['','**Review outcome:** `UNRESOLVED — do not enable this contract`','']
        md += ['## Activation gate','',f"**{result['activation_gate']}**",'',result['safety_boundary'],'']
        (work/'STAGE18-OWNERSHIP-CONTRACT-REVIEW.md').write_text('\n'.join(md),encoding='utf-8')
        (work/'STAGE18-INPUTS.sha256').write_text('\n'.join(f'{v}  {k}' for k,v in result['inputs'].items())+'\n',encoding='utf-8')
    return result


def main()->int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--stage14-archive',required=True,type=Path);p.add_argument('--stage15-archive',required=True,type=Path)
    p.add_argument('--stage16-archive',required=True,type=Path);p.add_argument('--stage17-archive',required=True,type=Path)
    p.add_argument('--project-root',type=Path,default=Path(__file__).resolve().parents[1]);p.add_argument('--out',required=True,type=Path)
    a=p.parse_args()
    try:
        result=build(a.stage14_archive,a.stage15_archive,a.stage16_archive,a.stage17_archive,a.project_root.resolve(),a.out)
    except (OSError,RuntimeError,ValueError,tarfile.TarError,json.JSONDecodeError) as e:
        p.error(str(e))
    print('Stage 18 status: '+result['status'])
    for c in result['contracts']: print(f"STAGE18_CONTRACT: {c['id']} candidates={c['candidate_method_count']} status={c['status']}")
    print(f"Stage 18 evidence method bodies: {result['evidence_methods_copied']}")
    print('DATAPATH_ACTIVATION: BLOCKED pending manual contract sign-off')
    return 0
if __name__=='__main__': raise SystemExit(main())
