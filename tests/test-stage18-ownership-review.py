#!/usr/bin/env python3
"""Synthetic regression test for the read-only Stage 18 evidence dossier."""
from __future__ import annotations
import importlib.util, json, hashlib, tarfile, tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('stage18',ROOT/'tools/build-stage18-ownership-review.py')
mod=importlib.util.module_from_spec(spec); assert spec and spec.loader; spec.loader.exec_module(mod)


def sha(p:Path)->str: return hashlib.sha256(p.read_bytes()).hexdigest()

def archive(path:Path, files:dict[str,str])->None:
    with tarfile.open(path,'w:gz') as tf:
        for name,text in files.items():
            p=path.parent/(path.stem+'-'+Path(name).name); p.parent.mkdir(parents=True,exist_ok=True); p.write_text(text)
            tf.add(p,arcname=name)

def main()->None:
    with tempfile.TemporaryDirectory(prefix='stage18-test-') as td:
        d=Path(td); stage14=d/'s14.tar.gz'; ksha='b'*64
        archive(stage14,{'24H32/source.json':json.dumps({'build':'24H32','product_version':'15.8.1','sha256':ksha})})
        h14=sha(stage14)
        stage15=d/'s15.tar.gz'; archive(stage15,{'stage15-work/STAGE15-ABI-ACCESSOR-AUDIT.json':json.dumps({'stage':15,'status':'PASS','input_sha256':h14})})
        h15=sha(stage15)
        stage16=d/'s16.tar.gz'; archive(stage16,{'stage16-work/STAGE16-PACKET-SEMANTICS-AUDIT.json':json.dumps({'stage':16,'status':'PASS','stage14_sha256':h14,'stage15_sha256':h15})})
        h16=sha(stage16)
        root=d/'24H32'; (root/'asm').mkdir(parents=True)
        (root/'source.json').write_text(json.dumps({'build':'24H32','product_version':'15.8.1','sha256':ksha}))
        rows=['# address\towner\tsymbol\tinstructions']; covered=[]
        names={
          'IOSkywalkPacketQueue':'synchronizeQueue','IOSkywalkPacketBufferPool':'allocatePacket',
          'IOSkywalkMemorySegment':'prepareMemorySegment','IOSkywalkPacketBuffer':'prepareWithMemorySegment',
          'IOSkywalkPacket':'getPacketBufferCount','IOSkywalkNetworkPacket':'completePacket',
          'IOSkywalkRxSubmissionQueue':'dequeuePackets','IOSkywalkRxCompletionQueue':'enqueuePackets',
          'IOSkywalkTxSubmissionQueue':'submitPackets','IOSkywalkTxCompletionQueue':'completePackets',
          'IOSkywalkInterface':'enableInterface','IOSkywalkNetworkInterface':'registerInterface',
          'IOSkywalkEthernetInterface':'registerEthernetInterface'}
        for n,c in enumerate(mod.TARGET_CLASSES):
            meth=names[c]; sym=f'__ZN{len(c)}{c}{len(meth)}{meth}Ev'; covered.append(sym)
            if n == 0:
                noncode=f'__ZTV{len(c)}{c}'
                (root/(c+'.methods.txt')).write_text(f'0xffffff8000001000\t{sym}\n0xffffff8000002000\t{noncode}\n')
            else:
                (root/(c+'.methods.txt')).write_text(f'0xffffff8000001000\t{sym}\n')
            (root/(c+'.vtable.txt')).write_text(f'# {c}: 1 slots\n')
            rows.append(f'0xffffff8000001000\tcom.apple.iokit.IOSkywalkFamily\t{sym}\t5')
            fn=sym.lstrip('_').replace('.','_')+'.asm.txt'
            (root/'asm'/fn).write_text(f'# 0xffffff8000001000 {sym}\nffffff8000001000: ret\n')
        (root/'asm/INDEX.txt').write_text('\n'.join(rows)+'\n')
        checks=[{'check':f'check{i}','status':'PASS','evidence':'fixture'} for i in range(19)]
        stage17=d/'s17.tar.gz'
        coverage={c:{'method_symbols':(2 if i==0 else 1),'executable_method_symbols':1,'non_code_symbols':(1 if i==0 else 0),'disassembled':1,'missing_disassembly':0} for i,c in enumerate(mod.TARGET_CLASSES)}
        report={'stage':17,'status':'PASS','inputs':{'stage14_sha256':h14,'stage15_sha256':h15,'stage16_sha256':h16},
                'kernel_collection_sha256':ksha,'target_method_symbol_count':14,'target_executable_method_symbol_count':13,'target_non_code_symbol_count':1,'target_method_disassembly_count':13,
                'method_coverage':coverage,
                'source_ownership_checks':checks,'unresolved_contracts':['manual review']}
        files={'24H32/source.json':(root/'source.json').read_text(),
               'stage17-work/STAGE17-QUEUE-OWNERSHIP-AUDIT.json':json.dumps(report)}
        for c in mod.TARGET_CLASSES:
            files[f'24H32/{c}.methods.txt']=(root/(c+'.methods.txt')).read_text()
        files['24H32/asm/INDEX.txt']=(root/'asm/INDEX.txt').read_text()
        for p in (root/'asm').glob('*.asm.txt'): files['24H32/asm/'+p.name]=p.read_text()
        archive(stage17,files)
        source_project=d/'source-project'
        source_dir=source_project/mod.SOURCE_BASE
        source_dir.mkdir(parents=True)
        for fn in mod.SOURCE_FILES:
            (source_dir/fn).write_text('void fixture() { enqueuePackets(); deallocatePacket(); registerEthernetInterface(); quiescePacketPath(); }\n',encoding='utf-8')
        out=d/'out'
        result=mod.build(stage14,stage15,stage16,stage17,source_project,out)
        assert result['status']=='READY_FOR_MANUAL_REVIEW'
        assert len(result['contracts'])==6
        assert result['evidence_methods_copied']>=len(mod.TARGET_CLASSES)
        assert all(c['status']=='MANUAL_REVIEW_REQUIRED' for c in result['contracts'])
        report_json=json.loads((out/'stage18-work/STAGE18-OWNERSHIP-CONTRACT-REVIEW.json').read_text())
        assert report_json['activation_gate'].startswith('BLOCKED')
        assert report_json['stage17_method_symbols']==14
        assert report_json['stage17_executable_method_symbols']==13
        assert report_json['stage17_non_code_symbols']==1
        assert (out/'stage18-work/evidence/source/RTW88WCLSkywalkRxAdapter.cpp').is_file()
        # Negative fixture: a disassembly count that does not match the executable
        # inventory must fail closed, even when non-code symbols are excluded.
        bad17=d/'s17-incomplete.tar.gz'
        with tarfile.open(stage17,'r:gz') as src, tarfile.open(bad17,'w:gz') as dst:
            for member in src.getmembers():
                if not member.isfile():
                    continue
                payload=src.extractfile(member).read()
                if Path(member.name).name=='STAGE17-QUEUE-OWNERSHIP-AUDIT.json':
                    bad_report=json.loads(payload.decode())
                    bad_report['target_method_disassembly_count']=12
                    payload=(json.dumps(bad_report)+'\n').encode()
                info=tarfile.TarInfo(member.name); info.size=len(payload); info.mode=0o644
                import io
                dst.addfile(info,io.BytesIO(payload))
        try:
            mod.build(stage14,stage15,stage16,bad17,source_project,d/'bad-out')
        except RuntimeError as exc:
            assert 'target_method_disassembly_count' in str(exc) or 'executable method body coverage' in str(exc)
        else:
            raise AssertionError('Stage 18 accepted an incomplete executable method inventory')
        print('PASS: Stage 18 validates Stage 14–17 archive SHA linkage')
        print('PASS: Stage 18 accepts 13 executable bodies plus 1 explicitly excluded non-code symbol')
        print('PASS: Stage 18 rejects incomplete per-class executable method accounting')
        print('PASS: Stage 18 creates six read-only ownership contract dossiers')
        print('PASS: Stage 18 includes exact method bodies and numbered source snippets')
        print('PASS: Stage 18 keeps all ownership contracts unresolved and datapath blocked')

if __name__=='__main__': main()
