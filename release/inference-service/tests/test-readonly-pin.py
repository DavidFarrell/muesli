#!/usr/bin/env python3
"""Build an isolated signed harness; use generated temporary fixtures only.

Arguments: fresh-output, signed-proof-app, signing-identity. Never run an app
installation or NSOpenPanel; temporary-path readability is not bookmark proof.
"""
from pathlib import Path
import ctypes
import fcntl
import hashlib
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import time

output, proof, identity = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
assert output.is_absolute() and not output.exists()
output.mkdir(mode=0o700)
tests = Path(__file__).resolve().parent
repo = tests.parents[2]
package = repo/'backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe'
runtime = proof/'Contents/XPCServices/paidiaconsulting.MuesliApp.InferenceService.xpc/Contents/Resources/python'
module = (package/'meeting_lease.py').read_text()
assert module.count('os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC') == 1
report = {'current_module_sha256': hashlib.sha256(module.encode()).hexdigest(), 'checks': {}}

def run(args, **kwargs):
    return subprocess.run(list(map(str,args)), check=True, **kwargs)

class ProcessInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in ('flags','status','xstatus','pid','ppid','uid','gid','ruid','rgid','svuid','svgid','reserved')] + [
        ('comm',ctypes.c_char*16),('name',ctypes.c_char*32)] + [(name,ctypes.c_uint32) for name in ('files','group','jobs','device','ttygroup','nice')] + [
        ('started_seconds',ctypes.c_uint64),('started_microseconds',ctypes.c_uint64)]
libproc=ctypes.CDLL('/usr/lib/libproc.dylib')
def process_identity(pid):
    info=ProcessInfo();path=ctypes.create_string_buffer(4096)
    if libproc.proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info)) != ctypes.sizeof(info):return None
    if libproc.proc_pidpath(pid,path,len(path)) <= 0:return None
    return (info.pid,info.started_seconds,info.started_microseconds,path.value.decode())

def events(path):
    try: return [json.loads(x) for x in path.read_text().splitlines() if x.startswith('{')]
    except (OSError, json.JSONDecodeError): return []

def until(predicate):
    end=time.monotonic()+10
    while time.monotonic()<end:
        value=predicate()
        if value: return value
        time.sleep(.01)
    raise AssertionError('Actual expected process state not observed')

def exclusive(folder, blocked):
    for name in ('.meeting-access.lock','.backend-owner.lock'):
        fd=os.open(folder/name,os.O_RDONLY|os.O_NOFOLLOW)
        try:
            try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:
                assert blocked
            else: assert not blocked
        finally: os.close(fd)

def ids(path):
    info=path.stat();return {'device':info.st_dev,'inode':info.st_ino}

bookmarker=output/'BookmarkFixture'
run(['/usr/bin/xcrun','clang','-fobjc-arc','-arch','arm64','-mmacosx-version-min=26.2','-framework','Foundation',tests/'BookmarkFixture.m','-o',bookmarker])
for variant in ('original','readonly'):
    app=output/(variant+'.app');resources=app/'Contents/Resources';macos=app/'Contents/MacOS'
    resources.mkdir(parents=True);macos.mkdir()
    plistlib.dump({'CFBundleIdentifier':'paidiaconsulting.MuesliApp.ReadOnlyLeaseProof','CFBundleExecutable':'ReadOnlyLeaseProof','CFBundlePackageType':'APPL'},(app/'Contents/Info.plist').open('wb'))
    run(['/bin/cp','-cR',runtime,resources/'python'])
    destination=resources/'python/lib/python3.12/site-packages/diarise_transcribe'
    # Only the new copied test bundle is changed; source/staging/old proof remain intact.
    shutil.rmtree(destination);shutil.copytree(package,destination,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    if variant=='original':
        readwrite=module.replace('os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC','os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC')
        (destination/'meeting_lease.py').write_text(readwrite)
        report['readwrite_negative_control_sha256']=hashlib.sha256(readwrite.encode()).hexdigest()
    shutil.copyfile(tests/'lease_probe.py',resources/'lease_probe.py')
    run(['/usr/bin/xcrun','clang','-fobjc-arc','-fblocks','-arch','arm64','-mmacosx-version-min=26.2','-framework','Foundation',tests/'ReadOnlyLeaseParent.m','-o',macos/'ReadOnlyLeaseProof'])
    entitlements=output/(variant+'-parent.entitlements')
    plistlib.dump({'com.apple.security.app-sandbox':True},entitlements.open('wb'))
    run(['codesign','--force','--sign',identity,'--options','runtime','--entitlements',tests.parent/'Child.entitlements',resources/'python/bin/python3.12'])
    run(['codesign','--force','--sign',identity,'--options','runtime','--entitlements',entitlements,app])
    run(['codesign','--verify','--deep','--strict',app])
    for binary, expected in [(macos/'ReadOnlyLeaseProof',{'com.apple.security.app-sandbox':True}), (resources/'python/bin/python3.12',{'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True})]:
        detail=run(['codesign','-d','--entitlements',':-','--verbose=4',binary],capture_output=True)
        assert plistlib.loads(detail.stdout)==expected and b'(runtime)' in detail.stderr
    for mutation in ([False] if variant=='original' else [False,True]):
        name=variant+('-changed' if mutation else '')
        fixture=output/name;fixture.mkdir();meeting=fixture/'meeting';meeting.mkdir();control=fixture/'control';control.mkdir()
        for lock in ('.meeting-access.lock','.backend-owner.lock'):
            (meeting/lock).touch(mode=0o400)
        token={'version':1,'folder':str(meeting),'directory':ids(meeting),'locks':{p.name:ids(p) for p in meeting.iterdir()}}
        log=fixture/'events.jsonl';err=fixture/'stderr.log'
        with log.open('w') as stdout,err.open('w') as stderr:
            bookmark=run([bookmarker,meeting],capture_output=True,text=True).stdout.strip()
            parent=subprocess.Popen([str(macos/'ReadOnlyLeaseProof'),str(meeting),json.dumps(token),str(control),bookmark],stdout=stdout,stderr=stderr)
        child=None; child_identity=None
        try:
            parent_event=until(lambda:next((x for x in events(log) if 'child' in x),None));child=parent_event['child'];child_identity=process_identity(child)
            outcome=until(lambda:next((x for x in events(log) if x.get('state') in {'pinned','rejected'}),None))
            assert outcome['pid']==child
            if variant=='original':
                assert outcome['state']=='rejected',outcome
                report['checks'][name]={'expected_readwrite_rejection':True,'outcome':outcome}
                continue
            assert outcome['state']=='pinned' and outcome['access_modes']==[os.O_RDONLY]*3 and outcome['noninheritable'],outcome
            child_identity=process_identity(child)
            assert child_identity and child_identity[-1]==str(resources/'python/bin/python3.12')
            exclusive(meeting,True)
            parent.kill();assert parent.wait(timeout=5)<0
            os.kill(child,0);exclusive(meeting,True)
            if mutation:
                (meeting/'.backend-owner.lock').rename(meeting/'old-backend-lock')
                (meeting/'.backend-owner.lock').touch(mode=0o400)
            (control/'release').touch()
            final=until(lambda:next((x for x in events(log) if x.get('state') in {'validated','rejected'}),None))
            assert final['state']==('rejected' if mutation else 'validated'),final
            def released():
                try: exclusive(meeting,False); return True
                except AssertionError:return False
            until(released)
            until(lambda: process_identity(child)!=child_identity)
            report['checks'][name]={'readonly_shared_pin':True,'held_after_parent_death':True,'released_only_after_child_exit':True,'outcome':final}
        finally:
            if parent.poll() is None:parent.kill()
            parent.wait(timeout=5)
            # Only the PID reported by our generated native parent is owned here.
            # A still-existing child may be exiting; never target unrelated process IDs.
            if child and child_identity and process_identity(child)==child_identity:
                assert child_identity[-1]==str(resources/'python/bin/python3.12')
                os.kill(child,signal.SIGKILL)
                until(lambda: process_identity(child)!=child_identity)
        json.dump(report,(output/'results.json').open('w'),indent=2,sort_keys=True)
json.dump(report,(output/'results.json').open('w'),indent=2,sort_keys=True)
print(json.dumps(report,indent=2,sort_keys=True))
