#!/usr/bin/env python3
"""Audited lifecycle/stress/failure checks. Refuses physical devices."""
import argparse
from collections import Counter
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
PKG = 'guide.guidelabs.codexdrop'
RUNNER = PKG + '.test/androidx.test.runner.AndroidJUnitRunner'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', default='emulator-5580')
parser.add_argument('--adb', default=str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
parser.add_argument('--groups', default='base,cleanup,lifecycle,stress,discovery,denied,partial,blocked,upload,commit,confirm,process-precommit,process-postcommit,process-revoke')
args = parser.parse_args()
if not re.fullmatch(r'emulator-\d+',args.serial): sys.exit('Physical devices are forbidden.')
def adb(*command, check=True, timeout=90):
    result = subprocess.run([args.adb,'-s',args.serial,*command],check=False,capture_output=True,text=True,timeout=timeout)
    if check and result.returncode: raise RuntimeError('adb operation failed: '+command[0]+' '+(command[1] if len(command)>1 else ''))
    return result
if adb('shell','getprop','ro.kernel.qemu').stdout.strip() != '1': sys.exit('Device must be an emulator.')
api = int(adb('shell','getprop','ro.build.version.sdk').stdout.strip())
OUT = ROOT / f'.codex-artifacts/android-hardening/api{api}-{args.serial}'
OUT.mkdir(parents=True,exist_ok=True)
results=[]
@contextmanager
def fixture(name, mode='verified', delay=2):
    audit = OUT / (name+'-audit.json')
    with (OUT/(name+'-server.log')).open('w') as error:
        process = subprocess.Popen([sys.executable,str(ROOT/'android/core/src/test/resources/receiver_fixture.py'),str(ROOT)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=error,text=True,env={**os.environ,'CODEX_DROP_FIXTURE_MODE':mode,'CODEX_DROP_FIXTURE_DELAY':str(delay),'CODEX_DROP_FIXTURE_AUDIT':str(audit)})
        try:
            line = process.stdout.readline()
            if not line: raise RuntimeError('Fixture failed: '+name)
            yield json.loads(line)
        finally:
            if process.poll() is None:
                process.stdin.write('stop\n');process.stdin.flush();process.stdin.close()
                try: process.wait(timeout=12)
                except subprocess.TimeoutExpired: process.kill();process.wait()
            if process.returncode != 0: raise RuntimeError('Fixture shutdown failed: '+name)

def inspect_audit(name, expected_deliveries=None):
    data=json.loads((OUT/(name+'-audit.json')).read_text())
    writes=Counter((e['path'],e.get('id')) for e in data['events'] if e['method']=='POST')
    if any(n != 1 for n in writes.values()): raise AssertionError('Repeated submission: '+name)
    deliveries=Counter(d['id'] for d in data['deliveries'])
    if any(n != 1 for n in deliveries.values()): raise AssertionError('Repeated delivery: '+name)
    if any(d['indices'] != list(range(d['count'])) for d in data['deliveries']): raise AssertionError('Wrong image ordering: '+name)
    if any(j['attempts'] > 1 for j in data['jobs']): raise AssertionError('Repeated worker attempt: '+name)
    if expected_deliveries is not None and len(data['deliveries']) != expected_deliveries:
        raise AssertionError(f'{name}: expected {expected_deliveries} deliveries, got {len(data["deliveries"])}')
    return {'jobs':len(data['jobs']),'deliveries':len(data['deliveries']),'uniqueSubmissionPaths':len(writes)}

CASES={
 'cleanup':('TransportCleanupHardeningTest','verified',1,0),
 'base':('PlatformTest,FlowTest','verified',6,1),
 'lifecycle':('LifecycleHardeningTest','verified',4,3),
 'recreate':('LifecycleHardeningTest#recreationWhileReadingKeepsTheSameTransfer','verified',1,1),
 'rotate':('LifecycleHardeningTest#rotationAndBackgroundAfterCommitDoNotReplay','verified',1,1),
 'concurrent':('LifecycleHardeningTest#simultaneousShareIsRefusedAndCancelBeforeCommitStopsDelivery','verified',1,0),
 'stress':('StressHardeningTest','verified',2,6),
 'discovery':('DiscoveryHardeningTest','verified',3,0),
 'denied':('PermissionHardeningTest','permission_denied',1,0),
 'partial':('PartialHardeningTest','partial_first',1,2),
 'blocked':('PartialHardeningTest','blocked_first',1,2),
 'upload':('FailureHardeningTest','upload_lost',1,0),
 'commit':('FailureHardeningTest','commit_lost',1,1),
 'confirm':('FailureHardeningTest','confirmation_lost',1,1),
}
def runtime_case(name):
    classes,mode,total,deliveries=CASES[name]
    if name=='denied' and api<37:
        results.append({'group':name,'skipped':'LAN runtime permission is API37+'});return
    if name=='denied': adb('shell','pm','revoke',PKG, 'android.permission.ACCESS_LOCAL_NETWORK',check=False)
    with fixture(name,mode,delay=8 if name in ('lifecycle','rotate') else 2) as config:
        selected=','.join(PKG+'.'+c for c in classes.split(','))
        result=adb('shell','am','instrument','-w','-r','-e','class',selected,'-e','fixture',"'"+json.dumps(config,separators=(',',':'))+"'",RUNNER,timeout=240)
        log=result.stdout+result.stderr;(OUT/(name+'-tests.log')).write_text(log)
        matched = re.search(r'OK \((\d+) tests?\)',log)
        if not matched or int(matched[1]) != total or 'FAILURES' in log or 'INSTRUMENTATION_STATUS_CODE: -4' in log:
            raise AssertionError('Instrumented group failed or skipped checks: '+name)
    summary=inspect_audit(name,deliveries)
    results.append({'group':name,'tests':total,'passed':True,**summary})
    if name=='denied': adb('shell','pm','grant',PKG,'android.permission.ACCESS_LOCAL_NETWORK')
    if name=='base':
        for filename in ['setup.png','share-review.png','share-progress.png']:
            data = subprocess.run([args.adb,'-s',args.serial,'exec-out','run-as',PKG,'cat','files/'+filename],check=True,capture_output=True,timeout=30).stdout
            if not data.startswith(bytes.fromhex("89504e470d0a1a0a")): raise AssertionError("Screenshot is not PNG: "+filename)
            (OUT/filename).write_bytes(data)
    print('PASS '+name,flush=True)

def activity_record(dump, component, task):
    # Android versions differ in the spacing after "Hist". Match the identity
    # in the record header, then keep only its more deeply indented details.
    header=re.compile(r'^[ \t]*\* Hist[ \t]+#\d+:[ \t]*ActivityRecord\{[^\n]*[ \t]'+re.escape(component)+r'[ \t]+t'+str(task)+r'(?=[ \t}])')
    lines=dump.splitlines(keepends=True)
    for index,line in enumerate(lines):
        if not header.search(line): continue
        indent=len(line)-len(line.lstrip(' \t'))
        end=index+1
        while end<len(lines):
            detail=lines[end]
            if detail.strip() and len(detail)-len(detail.lstrip(' \t'))<=indent: break
            end+=1
        return ''.join(lines[index:end])
    return ''

def process_case(name):
    phase='precommit' if name.endswith('precommit') else 'postcommit'
    if name.endswith('revoke') and api<37: raise AssertionError('Revocation requires API37')
    with fixture(name,delay=12) as config:
        # Setup ends before the app is started normally. Killing instrumentation would
        # force-stop its tasks and cannot test Android's actual saved-state behavior.
        setup=adb('shell','am','instrument','-w','-r','-e','class',PKG+'.ProcessSetupTest','-e','fixture',"'"+json.dumps(config,separators=(',',':'))+"'",RUNNER)
        (OUT/(name+'-setup.log')).write_text(setup.stdout+setup.stderr)
        if 'OK (1 test)' not in setup.stdout or 'INSTRUMENTATION_STATUS_CODE: -4' in setup.stdout: raise AssertionError('Process fixture setup failed')
        try:
            adb('shell','am','force-stop',PKG+'.test')
            adb('shell','am','start','-W','-n',PKG+'.test/'+PKG+'.TaskSourceActivity','--es','source','blocked.png' if phase=='precommit' else 'tiny.png')
            eventfile=OUT/(name+'-audit.json.events')
            deadline=time.monotonic()+30
            ready=[]
            while time.monotonic()<deadline:
                events=[]
                if eventfile.exists():
                    for line in eventfile.read_text().splitlines():
                        try: events.append(json.loads(line))
                        except json.JSONDecodeError: pass
                ready=[e for e in events if e['method']==('CREATED' if phase=='precommit' else 'ACCEPTED')]
                if ready: break
                time.sleep(.1)
            if not ready: raise AssertionError('Normal app never reached '+phase)
            request_id=ready[0]['id']
            task=int(adb('shell','run-as',PKG+'.test','cat','files/source-task.txt').stdout.strip())
            pid=int(adb('shell','pidof',PKG).stdout.strip())
            adb('shell','input','keyevent','KEYCODE_HOME')
            deadline=time.monotonic()+10
            saved_block=''
            retained=False
            while time.monotonic()<deadline:
                dump=adb('shell','dumpsys','activity','activities').stdout
                saved_block=activity_record(dump,PKG+'/.ShareActivity',task)
                retained=bool(re.search(r'(?:mState|state)=STOPPED\b',saved_block) and re.search(r'(?:mHaveState|haveState)=true\b',saved_block))
                if retained: break
                time.sleep(.15)
            (OUT/(name+'-before-kill-activities.txt')).write_text(dump)
            (OUT/(name+'-before-kill-state.txt')).write_text(saved_block)
            if not retained: raise AssertionError('OS has not retained stopped saved state before kill')
            if name.endswith('revoke'): adb('shell','pm','revoke',PKG,'android.permission.ACCESS_LOCAL_NETWORK')
            else: adb('shell','run-as',PKG,'kill','-9',str(pid))
            deadline=time.monotonic()+10
            while str(pid) in adb('shell','pidof',PKG,check=False).stdout.split() and time.monotonic()<deadline: time.sleep(.1)
            if str(pid) in adb('shell','pidof',PKG,check=False).stdout.split(): raise AssertionError('Original process survived')
            adb('shell','am','start','-n',PKG+'.test/'+PKG+'.TaskRestorerActivity','--ei','taskId',str(task))
            deadline=time.monotonic()+15
            text=''
            while time.monotonic()<deadline:
                adb('shell','uiautomator','dump','/sdcard/codex-drop-restored.xml',check=False,timeout=30)
                xml=adb('shell','cat','/sdcard/codex-drop-restored.xml',check=False).stdout
                try: text=' '.join(n.get('text','') for n in ET.fromstring(xml).iter('node'))
                except ET.ParseError: text=''
                if 'Share interrupted' in text: break
                time.sleep(.2)
            (OUT/(name+'-restored.xml')).write_text(xml)
            if 'Share interrupted' not in text: raise AssertionError('Normal saved task did not restore into review: '+name)
            image=subprocess.run([args.adb,'-s',args.serial,'exec-out','screencap','-p'],check=True,capture_output=True,timeout=20).stdout
            (OUT/(name+'-restored.png')).write_bytes(image)
            new=adb('shell','pidof',PKG).stdout.strip()
            if not new or new==str(pid): raise AssertionError('No replacement app process')
            saved=adb('shell','run-as',PKG,'cat','no_backup/receipts/'+request_id+'.json',check=False)
            if phase=='postcommit':
                if json.loads(saved.stdout)['id']!=request_id: raise AssertionError('Durable receipt lost')
            elif saved.returncode==0: raise AssertionError('Precommit unexpectedly saved receipt')
            results.append({'group':name,'passed':True,'oldPid':pid,'newPid':new,'savedTaskRestored':True,'durableReceipt':phase=='postcommit'})
        finally:
            adb('shell','am','force-stop',PKG,check=False)
            adb('shell','am','force-stop',PKG+'.test',check=False)
            adb('shell','run-as',PKG,'rm','-f','no_backup/emulator-fixture.json',check=False)
            if api>=37: adb('shell','pm','grant',PKG,'android.permission.ACCESS_LOCAL_NETWORK',check=False)
    summary=inspect_audit(name,0 if phase=='precommit' else 1)
    if summary['jobs']!=1: raise AssertionError('Original share replayed after process death')
    results[-1].update(summary)
    print('PASS '+name,flush=True)

font=adb('shell','settings','get','system','font_scale').stdout.strip()
try:
    for file,folder,extra in [('app-debug.apk','debug',[]),('app-debug-androidTest.apk','androidTest/debug',['-t'])]:
        adb('install','-r',*extra,str(ROOT/'android/app/build/outputs/apk'/folder/file))
    adb('shell','settings','put','system','font_scale','1.5')
    for group in args.groups.split(','):
        if group.startswith('process-'):
            if group=='process-revoke' and api<37:
                results.append({'group':group,'skipped':'LAN runtime permission is API37+'});continue
            process_case(group)
        else: runtime_case(group)
finally:
    adb('shell','settings','put','system','font_scale',font if font and font!='null' else '1.0',check=False)
    if api>=37: adb('shell','pm','grant',PKG,'android.permission.ACCESS_LOCAL_NETWORK',check=False)
    (OUT/'results.json').write_text(json.dumps({'api':api,'serial':args.serial,'results':results},indent=2)+'\n')
print('PASS: all requested emulator hardening groups; evidence '+str(OUT))
