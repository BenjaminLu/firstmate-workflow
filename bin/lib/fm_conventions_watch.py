"""Timed convention drift proposals; no approval or merge action is inferred."""
import json
import os
from pathlib import Path
import time
import subprocess
import sys
import threading

sys.dont_write_bytecode = True

from fm_conventions import read_policy
from fm_onboard import atomic, drift, inspect_remote, registry_value, save


def project_names(engine):
    """Read the full registry, never the caller's selected/default project."""
    code=Path(__file__).resolve().parents[1]/'fm-config.sh'
    result=subprocess.run(['bash','-c','. "$1"; fm_projects "$2/config.yaml"',
                           '_',str(code),str(engine)],capture_output=True,text=True,timeout=30)
    if result.returncode:
        raise ValueError(result.stderr.strip() or 'project registry unavailable')
    return result.stdout.splitlines()


def design_sync(engine, name, run=subprocess.run):
    home = Path(registry_value(engine, name, 'home'))
    code = Path(__file__).resolve().parents[1]/'fm-project.sh'
    try:
        return run([str(code), 'sync', name, '--repo', str(engine)],
                   stdin=subprocess.DEVNULL, timeout=300).returncode
    except (subprocess.TimeoutExpired, OSError) as error:
        atomic(home/'state/onboarding/inspection-error.txt', str(error)+'\n')
        return 70


def tick(engine, *, clock=time.time, inspect=inspect_remote, wake=None, owner=None):
    """Schedule every registered external policy with independent deadlines.

    Errors in one private project cannot suppress another project or engine
    wakes. Policy writers ring the doorbell after approval or an edit.
    """
    delays=[]
    for name in project_names(engine):
        try:
            delay=project_tick(engine,name,clock=clock,inspect=inspect,wake=wake,owner=owner)
            if delay is not None: delays.append(delay)
        except Exception as error:
            # The optional inspector is not on the wake delivery critical path.
            print(f'conventions inspection {name}: {error}',file=sys.stderr)
    return max(1,min(delays)) if delays else None


def project_tick(engine, name, *, clock, inspect, wake, owner):
    try:
        home=Path(registry_value(engine,name,'home'))
        if home == Path(engine).resolve(): return None
        policy=read_policy(home/'CONVENTIONS.md')
    except (ValueError,OSError):
        return None
    period=policy['reinspect_seconds']
    stamp=home/'state/onboarding/next-inspection.json'
    try: due=json.loads(stamp.read_text())['at']
    except (OSError,ValueError,KeyError): due=0
    current=clock()
    if current < due: return due-current
    # Persist the next deadline before I/O. Restarts don't hammer GitHub after
    # a failure; unreadability is retained and proposed, never a policy edit.
    save(stamp,{'at':current+period})
    if owner is not None:
        # The inspector belongs to the harness owner, not this short watcher
        # generation. Repository I/O never blocks the queue's doorbell.
        import fm_lifeline as life
        # The project is an explicit argument. Preserve the watcher's routing
        # environment so the child rings the engine queue this cycle serves.
        env=dict(os.environ)
        with (home/'state/onboarding/inspection.log').open('ab') as log:
            child=life.start([sys.executable,str(Path(__file__).resolve()),str(engine),name],
                             owner=owner, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        threading.Thread(target=child.wait,daemon=True).start()
    else:
        inspect_and_propose(engine, home, policy, name, inspect, wake)
    return period


def inspect_and_propose(engine, home, policy, name, inspect, wake):
    try:
        proposal=drift(home,inspect(policy['repository']))
        if proposal and wake:
            wake(engine,'conventions-'+name,'conventions_drift',
                 'Project conventions drift requires captain confirmation',
                 {'project':name,'summary':{'en':'Repository conventions changed; review the private proposal.',
                                          'zh-TW':'儲存庫慣例已變更；請審閱私有提案。'}})
    except (OSError,ValueError,KeyError) as error:
        atomic(home/'state/onboarding/inspection-error.txt',str(error)+'\n')
        if wake:
            wake(engine,'conventions-'+name,'conventions_unknown',
                 'Repository convention inspection is unavailable',
                 {'project':name,'summary':{'en':'Convention inspection unavailable; existing policy remains unchanged.',
                                          'zh-TW':'無法檢查儲存庫慣例；現有政策維持不變。'}})


if __name__ == '__main__':
    import fm_lifeline as life
    engine=Path(sys.argv[1]); name=sys.argv[2]
    home=Path(registry_value(engine,name,'home'))
    inspect_and_propose(engine,home,read_policy(home/'CONVENTIONS.md'),name,inspect_remote,life.push)
    design_sync(engine, name)
