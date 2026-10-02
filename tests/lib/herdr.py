import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys
import shutil
import subprocess
import signal
import time

sys.dont_write_bytecode = True  # Import production code without dirtying the checkout.
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('managed', root / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# A positive wait is for its real condition, against a deadline wide enough
# for a loaded machine. Counts of short sleeps - two seconds for the first
# worker's prompt, five for a run to settle - ran out under the gate's
# parallel pool while the process they waited on was still on its way. The
# loop returns the moment the condition holds, so the width costs nothing on
# a quiet machine. Negative windows (nothing happens within N) are not this.
WAIT = 120

# fm-worker.sh and fm-review.sh ask a vendor's own status check about the
# round's login before a round (T-121), and a fake vendor CLI answers it,
# and --version, exactly as the real one did in its recorded transcript
# (tests/fixtures/auth-status) before the fake's own round behaviour runs.
# claude and codex answer signed in; cursor-agent has no recorded signed-in
# answer, so it answers as recorded - not logged in - and its rounds are
# refused, as gemini's are (no documented status command at all).
_fixtures = root / 'tests/fixtures/auth-status'
def _status_prelude(argv, fixture):
    return ('import subprocess as _fm_s, sys as _fm_y\n'
            '_fm_r, _fm_f = %r, %r\n'
            'if _fm_y.argv[1:] == ["--version"]: raise SystemExit(_fm_s.call([_fm_r, _fm_f, "--version"]))\n'
            'if _fm_y.argv[1:] == %r: raise SystemExit(_fm_s.call([_fm_r, _fm_f]))\n'
            % (str(_fixtures / 'replay.sh'), str(_fixtures / (fixture + '.txt')), argv))
STATUS_PRELUDE = {'claude': _status_prelude(['auth', 'status'], 'claude-signed-in'),
                  'codex': _status_prelude(['login', 'status'], 'codex-signed-in'),
                  'cursor-agent': _status_prelude(['status'], 'cursor-agent-signed-out')}

def eventually(predicate, seconds=WAIT):
    end = time.monotonic() + seconds
    while True:
        value = predicate()
        if value or time.monotonic() > end: return value
        time.sleep(.02)


class LifecycleFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.run = m.allocate(self.root, 'worker', 'T-035', '')
        self.owner = dict(owned=True, actor=self.run.name, task='T-035',
                          run=str(self.run), run_token=self.run.name, pane_id='owned', caller='caller',
                          terminal_id='terminal', shell_pid=91, tab_id='tab-owned',
                          caller_tab='tab-caller', workspace_id='workspace')
        m.save(self.run / 'owner.json', self.owner)
        # Observed on real Herdr (2026-09-23/24): after the adapter exits and the
        # pane is back at an idle shell prompt, `pane list` still reports
        # agent_status 'working'. The fixture reports what Herdr reports.
        self.pane = dict(pane_id='owned', terminal_id='terminal',
                         label=self.run.name, agent_status='working', tab_id='tab-owned', workspace_id='workspace',
                         tokens=dict(fm_actor=self.run.name, fm_task='T-035', fm_run=self.run.name))
        self.proc = dict(pane_id='owned', shell_pid=91, foreground_processes=[dict(pid=91)])
        self.tab = dict(tab_id='tab-owned', workspace_id='workspace', label=self.run.name, pane_count=1)
        self.layout = dict(tab_id='tab-owned', workspace_id='workspace', panes=[dict(pane_id='owned')], splits=[])
        self.calls = []
        (self.run / 'final.txt').write_text('Evidence.\nWORKER_COMPLETE:T-035\n')
        (self.run / 'cli.log').write_text('transcript')
        m.save(self.run / 'result.json', dict(actor=self.run.name, task='T-035', exit_code=0, status='completed'))

    def control(self, *args):
        self.calls.append(args)
        if args == ('api', 'snapshot'): return dict(snapshot=dict(tabs=[self.tab], panes=[self.pane], layouts=[self.layout]))
        if args[:2] == ('pane', 'get'): return dict(pane=self.pane)
        if args[:2] == ('pane', 'process-info'): return dict(process_info=self.proc)
        if args[:2] == ('pane', 'close'):
            self.assertTrue((self.run / 'result.json').is_file())
            self.assertTrue((self.run / 'final.txt').is_file())
            self.assertTrue((self.run / 'cli.log').is_file())
            return {}
        raise AssertionError(args)

    def close(self):
        return m.close_owned(self.run, self.owner, self.control)


class RosterFixture(unittest.TestCase):
    """T-104: each installation draws 24 worker and 24 reviewer names, and a
    name always means one role. T-089 gave every crew member a name."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        seeded = patch.dict(os.environ, {'FM_ROSTER_SEED': 't104'})
        seeded.start(); self.addCleanup(seeded.stop)
        # the round and the project are the run's own (T-116), never the shell's
        for key in ('FM_ROUND', 'FM_PROJECT'): os.environ.pop(key, None)

    def name(self, run):
        return json.loads((run / 'identity.json').read_text())['name']

    def finish(self, run):
        # What fm_record_end writes when a run's orchestration ends.
        m.save(run / 'orchestration-result.json', dict(process_exit=0))

    def crew(self):
        return json.loads((self.root / 'state/crew/rosters.json').read_text())

    def pin(self, text):
        (self.root / 'config.yaml').write_text(text)

    def quiet(self, call, *args):
        import io, contextlib
        said = io.StringIO()
        with contextlib.redirect_stderr(said): value = call(*args)
        return value, said.getvalue()

    def runs(self):
        return sorted(p.parent.name for p in (self.root / 'state/runs').glob('*/identity.json'))

    def review_opened(self, task, times, project=None):
        log = self.root / 'state/events.jsonl'; log.parent.mkdir(parents=True, exist_ok=True)
        with log.open('a') as out:
            for _ in range(times):
                event = dict(type='review_opened', task=task, actor='reviewer-x-t0-r1')
                if project: event['project'] = project
                out.write(json.dumps(event) + '\n')

    def identity(self, run):
        return json.loads((run / 'identity.json').read_text())

    def history(self, role, name, task, created, one_role=False):
        run = self.root / 'state/runs' / f'{role}-{name}-{task.lower().replace("-", "")}-r{created}'
        run.mkdir(parents=True)
        record = dict(actor=run.name, role=role, task=task, name=name, requested_alias='',
                      run=str(run), created=float(created))
        if one_role: record['one_role'] = True
        m.save(run / 'identity.json', record)
        self.finish(run)


class EntrypointsFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source_tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.source_tmp.cleanup)
        cls.source = Path(cls.source_tmp.name)
        for name in ('bin', 'skills'):
            shutil.copytree(root / name, cls.source / name)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        # Link immutable code from the one class copy. The two source files
        # that entrypoint cases intentionally overwrite get private copies.
        for name in ('bin', 'skills'):
            shutil.copytree(self.source / name, self.repo / name, copy_function=os.link)
        for name in ('bin/fm-gate.sh', 'bin/adapters/codex.sh'):
            (self.repo / name).unlink()
            shutil.copy2(self.source / name, self.repo / name)
        (self.repo / 'design/tasks').mkdir(parents=True)
        (self.repo / 'design/tasks/T-035.json').write_text(json.dumps(dict(id='T-035',title='test',scope=['src/**'],depends_on=[],acceptance=['works'])))
        (self.repo / 'design/design.md').write_text('## 6. Gates\nEvidence\n## 8. Board\n')
        (self.repo / 'config.yaml').write_text('vendor: codex\nconcurrency: 2\n')
        self.fake = self.repo / 'fakebin'; self.fake.mkdir()
        # no ambient terminal host: a developer's own tmux or cmux is not the fixture's
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'TMUX', 'CMUX_'))}
        # The fake git below answers `config` with nothing, so the identity a
        # commit needs is the fixture's own: a worker whose commit fails stops.
        self.env.update(PATH=str(self.fake)+os.pathsep+os.environ['PATH'], HERDR_ENV='1', HERDR_PANE_ID='caller',
                        FM_ROOT=str(self.repo), FM_TEST_ROOT=str(self.repo), FM_HERDR_TIMEOUT=str(WAIT),
                        FM_GIT_NAME='t', FM_GIT_EMAIL='a@b.c',
                        # the session a round belongs to is this test, never the
                        # operator's own (T-151): a round ends when it does
                        FM_SESSION_PID=str(os.getpid()))
        # Every vendor round runs behind bin/fm-sandbox.sh (T-105), and a host
        # with no OS sandbox refuses every vendor. A runner cannot be relied on
        # to have one, so the sandbox binary is a stand-in, as in
        # tests/adapter-contract.test.sh: it records what it was handed and
        # runs the command. It lives outside fakebin, so nothing on PATH is it.
        tool=self.repo/'sandbox-tool'; tool.mkdir()
        (tool/'bwrap').write_text('#!/usr/bin/env bash\n'
                                  'printf "%s\\n" "$@" >> "$FM_TEST_ROOT/sandboxed"\n'
                                  'while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done\n'
                                  'shift\nexec "$@"\n')
        (tool/'bwrap').chmod(0o755)
        self.env.update(FM_SANDBOX_OS='linux', FM_SANDBOX_TOOL=str(tool/'bwrap'))
        # Every vendor's round is handed the operator's login (T-117) and
        # refused without one, and fm-worker.sh and fm-review.sh ask the
        # vendor's own status check about that login before a round (T-121).
        # claude's crew token and cursor-agent's key are the variables fm
        # hands in, so these say one is already in the environment. codex's
        # and gemini's round login is a copy of their login file - a key in
        # the shell is one the round sheds - so the fixture's own HOME holds
        # those files, and the runner's keychain and home are never read.
        home=self.repo/'home'
        (home/'.codex').mkdir(parents=True); (home/'.gemini').mkdir()
        (home/'.codex/auth.json').write_text(json.dumps(dict(OPENAI_API_KEY=None,tokens=dict(
            id_token='id-suite',access_token='at-suite',refresh_token='rt-suite',account_id='acct'))))
        (home/'.gemini/oauth_creds.json').write_text(json.dumps(dict(access_token='at-suite',refresh_token='rt-suite',
            expiry_date=int((time.time()+86400)*1000))))
        for f in (home/'.codex/auth.json',home/'.gemini/oauth_creds.json'): f.chmod(0o600)
        for k in ('CODEX_API_KEY','OPENAI_API_KEY','GEMINI_API_KEY','GOOGLE_API_KEY','ANTHROPIC_API_KEY'):
            self.env.pop(k,None)
        self.env.update(HOME=str(home),CLAUDE_CODE_OAUTH_TOKEN='fm-suite-token',CURSOR_API_KEY='fm-suite-key')
        self.executable('herdr', r'''
import json, os, pathlib, subprocess, sys, uuid
r=pathlib.Path(os.environ['FM_TEST_ROOT']); a=sys.argv[1:]
with (r/'controls').open('a') as f: f.write(json.dumps(a)+'\n')
# A temp name that glob('pane-*') / glob('tab-*') can match is a half-written
# file the next `api snapshot` parses: concurrent launches went red at random
# on a JSONDecodeError inside the double. The dot keeps it out of both globs.
def inflight(p): return p.with_name('.'+p.name+'.tmp')
def save(p,v):
 t=inflight(p); t.write_text(json.dumps(v)); t.replace(p)
def pane(p):
 if p=='caller': return dict(pane_id=p, terminal_id='caller-terminal',tab_id='caller-tab',workspace_id='workspace')
 return json.loads((r/p).read_text())
result={}
# A Herdr command that fails exits non-zero, as the real one does: the pane
# run, or only the report that the pane is working, so the idle one still lands.
fail=os.environ.get('FM_TEST_HERDR_FAIL')
if (fail=='pane-run' and a[:2]==['pane','run']) or (
        fail=='report-working' and a[:2]==['pane','report-agent'] and a[a.index('--state')+1]=='working'):
 print('error: '+' '.join(a[:2])+' failed',file=sys.stderr); raise SystemExit(1)
if a[:2]==['tab','create']:
 assert '--no-focus' in a and '--focus' not in a
 assert a[a.index('--workspace')+1]=='workspace'
 p='pane-'+uuid.uuid4().hex
 t='tab-'+uuid.uuid4().hex
 v=dict(pane_id=p,terminal_id=p+'-terminal',tab_id=t,workspace_id='workspace',label='',tokens={},agent_status='idle')
 tab=dict(tab_id=t,workspace_id='workspace',label=a[a.index('--label')+1],pane_count=1)
 save(r/p,v); save(r/t,tab); result={'root_pane':v,'tab':tab}
 if os.environ.get('FM_TEST_FOCUS')=='changed': (r/'focus-changed').touch()
elif a==['api','snapshot']:
 panes=[pane(p.name) for p in r.glob('pane-*')]
 tabs=[json.loads(p.read_text()) for p in r.glob('tab-*')]
 layouts=[dict(tab_id=t['tab_id'],workspace_id='workspace',panes=[dict(pane_id=p['pane_id']) for p in panes if p['tab_id']==t['tab_id']],splits=[]) for t in tabs]
 focus='other' if (r/'focus-changed').exists() else 'caller'
 result={'snapshot':dict(panes=panes,tabs=tabs,layouts=layouts,focused_pane_id=focus,focused_tab_id='caller-tab',focused_workspace_id='workspace')}
 if (r/'malformed').exists(): result['snapshot']['layouts']=None
elif a[:2]==['pane','get']: result={'pane':pane(a[2])}
elif a[:2]==['pane','list']: result={'panes':[]}
# Leave a save() half-written, through the same naming save() uses, so the
# snapshot assertion cannot go stale by hand-spelling the temp name.
elif a[:2]==['test','inflight']: inflight(r/a[2]).write_text('{"pane_id": "half')
elif a[:2]==['pane','process-info']:
 shell=42
 if os.environ.get('FM_TEST_CHANGE')=='late-shell' and list(pathlib.Path(os.environ['FM_RUN_DIR']).glob('codex-*')):
  count=r/('count-'+a[3]); n=int(count.read_text())+1 if count.exists() else 1; count.write_text(str(n))
  if n>=2: shell=43
 # Derive foreground from the command this fake was asked to run, not only from
 # an injected busy flag — otherwise shell_only assertions are vacuous.
 fg=shell
 # what runs in the pane is the follower `pane run` was given, and the pane is
 # idle again the moment it ends; one file per pane, as runs share a fixture
 runner=r/('follower-'+a[3]+'.pid')
 if runner.exists():
  try:
   rpid=int(runner.read_text().strip())
   os.kill(rpid,0)
   fg=rpid
  except (ValueError, ProcessLookupError, OSError):
   pass
 if pane(a[3]).get('busy'):
  fg=99
 result={'process_info':dict(pane_id=a[3],shell_pid=shell,foreground_processes=[dict(pid=fg)])}
elif a[:2]==['pane','rename']:
 v=pane(a[2]); v['label']=a[3]; save(r/a[2],v)
elif a[:2]==['pane','report-metadata']:
 v=pane(a[2]); v['tokens']={a[i+1].split('=',1)[0]:a[i+1].split('=',1)[1] for i in range(len(a)-1) if a[i]=='--token'}; save(r/a[2],v)
elif a[:2]==['pane','report-agent']:
 # Observed on real Herdr (2026-09-23/24): once a pane has been 'working',
 # `pane list` keeps saying 'working' after the agent exits and the shell is
 # idle again, whatever state is reported afterwards.
 v=pane(a[2]); state=a[a.index('--state')+1]
 if v.get('agent_status')!='working': v['agent_status']=state
 save(r/a[2],v)
elif a[:2]==['agent','rename']:
 assert a[3]==pane(a[2])['label']
elif a[:2]==['pane','run']:
 assert a[2]!='caller'
 # Apply resource mutations before the child runs so ownership-safe close
 # (pane-child or transport) observes them. Mutating after a synchronous
 # child returns left autoclose racing a post-run fixture edit.
 v=pane(a[2]); change=os.environ.get('FM_TEST_CHANGE')
 if change=='moved': v['tab_id']='caller-tab'
 if change=='reused': v['terminal_id']='new-terminal'
 if change=='identity': v['tokens']['fm_actor']='other'
 if change=='busy': v['busy']=True
 if change=='unknown': v['tab_id']=None
 if change=='malformed': (r/'malformed').touch()
 if change=='shared':
  tab=json.loads((r/v['tab_id']).read_text()); tab['pane_count']=2; save(r/v['tab_id'],tab)
 if change=='added':
  save(r/('pane-user-'+a[2]),dict(pane_id='user',tab_id=v['tab_id'],workspace_id='workspace'))
 save(r/a[2],v)
 # Real `pane run` types the command into the pane's shell and returns at
 # once; the round is not in that pane, so nothing here may wait for it.
 # The pane's output is what the follower prints, kept where a test can read it.
 import shlex
 shown=open(r/('shown-'+a[2]),'ab')
 child=subprocess.Popen(shlex.split(a[3]),stdin=subprocess.DEVNULL,stdout=shown,stderr=subprocess.STDOUT,start_new_session=True)
 (r/('follower-'+a[2]+'.pid')).write_text(str(child.pid))
 (r/'mock-runner.pid').write_text(str(child.pid))
elif a[:2]==['pane','close']:
 v=pane(a[2]); token=v['tokens']['fm_run']; run=pathlib.Path(token)
 if not run.is_absolute():
  matches=list(pathlib.Path(os.environ['FM_TEST_ROOT']).glob('state/runs/*/'+token))
  assert matches, token; run=matches[0]
 assert json.loads((run/'result.json').read_text())['status']=='completed'
 assert (run/'final.txt').stat().st_size and (run/'cli.log').stat().st_size
 (r/'closed').write_text(a[2])
else: raise SystemExit('unsupported fake Herdr command '+str(a))
print(json.dumps({'result':result}))
''')
        self.executable('codex', r'''
import json,os,pathlib,sys,time
r=pathlib.Path(os.environ['FM_TEST_ROOT']); prompt=sys.stdin.read()
actor=os.environ['FM_ACTOR']; role=os.environ['FM_ROLE']; task=os.environ['FM_TASK']
(r/(actor+'.login')).write_text(json.dumps({name:os.environ[name] for name in ('CODEX_API_KEY','CODEX_HOME') if name in os.environ}))
(r/(actor+'.prompt')).write_text(prompt)
assert actor in prompt and ('explicitly dispatched '+role) in prompt
if os.environ.get('FM_TEST_ASYNC')=='1':
 pathlib.Path('surviving-work').write_text(actor)
 pathlib.Path('.fm-say.md').write_text('retained evidence')
 (r/'model.pid').write_text(str(os.getpid()))
 while not (r/'release-model').exists(): time.sleep(.02)
# held until the test says so, rather than for a number of seconds a loaded
# machine can spend before the test has looked; T-089's same-name retirement
# test holds all three runs live here until it touches `release`
if os.environ.get('FM_TEST_HOLD'):
 while not (r/os.environ['FM_TEST_HOLD']).exists(): time.sleep(.02)
time.sleep(float(os.environ.get('FM_TEST_DELAY','0')))
marker=role.upper()+'_'+os.environ.get('FM_TEST_STATUS','COMPLETE')+':'+task
verdict=os.environ.get('FM_TEST_VERDICT','APPROVE')
final=(verdict+':'+task+'\n' if role=='reviewer' else 'Implemented\n')+marker+'\n'
if os.environ.get('FM_TEST_EMPTY')!='1':
 if '--output-last-message' in sys.argv:
  pathlib.Path(sys.argv[sys.argv.index('--output-last-message')+1]).write_text(final)
 for event in [dict(type='turn.started'),
               dict(type='item.completed',item=dict(id='0',type='agent_message',text=final)),
               dict(type='turn.completed',usage={})]:
  print(json.dumps(event))
if role=='worker': pathlib.Path('work.txt').write_text('done')
raise SystemExit(int(os.environ.get('FM_TEST_EXIT','0')))
''')
        self.executable('git', r'''
import json,os,pathlib,sys
r=pathlib.Path(os.environ['FM_TEST_ROOT']); a=sys.argv[1:]
if a[0]=='-C' and a[2] in ('show','merge-base','diff-tree'): a=a[2:]
if a[0]=='show':
 p=r/a[-1].split(':',1)[-1]
 if not p.is_file(): sys.exit(128)
 print(p.read_text())
elif 'rev-parse' in a and a[-1] in ('HEAD', 'work^{commit}'):
 # A successful head query returns a full object id, never empty stdout.
 print('a'*40)
elif a[0]=='merge-base': print('b'*40)
elif a[0] in ('show-ref','ls-remote'): sys.exit(1)
elif a[:2]==['worktree','add']:
 pathlib.Path(a[-2]).mkdir(parents=True,exist_ok=True)
elif 'status' in a:
 p=pathlib.Path(a[a.index('-C')+1]); print('?? work.txt' if (p/'work.txt').exists() else '')
elif a[0]=='diff': print('diff --git a/test b/test\n+change')
elif a[0]=='branch': print('t-035-test')
''')
        self.executable('gh', "import sys\nprint('https://example.invalid/pull/35' if 'create' in sys.argv else '[]')\n")

    def executable(self, name, content):
        p=self.fake/name; p.write_text('#!'+sys.executable+'\n'+STATUS_PRELUDE.get(name,'')+content); p.chmod(0o755)

    def invoke(self, script, args=(), **env):
        return subprocess.run(['bash',str(self.repo/'bin'/script),*args,'--repo',str(self.repo)],
                              env=dict(self.env,**env),capture_output=True,text=True,timeout=WAIT)

    def results(self): return list((self.repo/'state/runs').glob('*/last-result.json'))

    def wait_for(self, predicate):
        value=eventually(predicate)
        if value: return value
        self.fail('asynchronous process did not reach expected state')

    def no_live_runs(self):
        # In-process inspection must never inherit a developer's real Herdr.
        with patch.dict(os.environ, {'FM_TRANSPORT':'direct'}):
            return not any(r['live'] for r in m.inspect(self.repo)['runs'])

    TMUX_STUB = r'''
import json,os,pathlib,shlex,subprocess,sys
r=pathlib.Path(os.environ['FM_TEST_ROOT']); a=sys.argv[1:]
with (r/'tmux-calls').open('a') as f: f.write(json.dumps(a)+'\n')
# tmux(1): new-window [-abdkPS] [-c start-directory] [-e environment]
#   [-F format] [-n window-name] [-t target-window] [shell-command [argument ...]]
#   "-P prints information about the new window after it has been created. By
#   default, it uses the format '#{session_name}:#{window_index}' but a
#   different format may be specified with -F." #{window_id} is "@N".
#   "-d: the session does not make the new window the current window."
if a[:1]!=['new-window']: sys.exit('unknown command: '+(a[0] if a else ''))
flags,valued,i={},set('ceFnt'),1
while i<len(a) and a[i].startswith('-') and len(a[i])>1:
 for j,c in enumerate(a[i][1:]):
  if c in valued:
   v=a[i][j+2:] or a[i+1]; i+=0 if a[i][j+2:] else 1; flags[c]=v; break
  if c not in 'abdkPS': sys.exit('new-window: unknown option -- '+c)
  flags[c]=True
 i+=1
command=a[i:]
n=7+len((r/'tmux-calls').read_text().splitlines())
if command:
 subprocess.Popen(shlex.split(command[0]) if len(command)==1 else command,stdin=subprocess.DEVNULL,
  stdout=open(r/'tmux-shown','ab'),stderr=subprocess.STDOUT,start_new_session=True)
if flags.get('P'):
 print(flags.get('F','#{session_name}:#{window_index}').replace('#{window_id}','@%d'%n)
       .replace('#{session_name}','0').replace('#{window_index}',str(n)))
'''

    CMUX_STUB = r'''
import json,os,pathlib,shlex,subprocess,sys
r=pathlib.Path(os.environ['FM_TEST_ROOT']); a=sys.argv[1:]
with (r/'cmux-calls').open('a') as f: f.write(json.dumps(a)+'\n')
# cmux <command> --help, from the installed cmux (checked 2026-09-29):
#   new-workspace [--cwd <path>] [--command <text>]
#     --command <text>  Send text+Enter to the new workspace after creation
#   rename-workspace [--workspace <id|ref|index>] [--] <title>
#   close-workspace --workspace <id|ref|index>   (required)
#   "Output defaults to refs (window:1/workspace:2/pane:3/surface:4)"
def options(rest,known):
 got,pos,i={},[],0
 while i<len(rest):
  if rest[i]=='--': pos+=rest[i+1:]; break
  if rest[i].startswith('--'):
   if rest[i] not in known: sys.exit('Error: Unknown flag '+rest[i])
   got[rest[i]]=rest[i+1]; i+=2; continue
  pos.append(rest[i]); i+=1
 return got,pos
count=r/'cmux-workspaces'
focus=r/'cmux-focus'
def rows():
 out=[dict(id='caller-uuid',ref='workspace:1',title='Captain')]
 if count.exists():
  for n in range(7,int(count.read_text())+1):
   title=r/('cmux-title-workspace-'+str(n))
   out.append(dict(id='uuid-'+str(n),ref='workspace:'+str(n),title=title.read_text() if title.exists() else 'Untitled'))
 return out
if a[:1]==['capabilities']:
 print(json.dumps(dict(access_mode='password'))); sys.exit(0)
if a[:1]==['list-workspaces']:
 print(json.dumps(dict(workspaces=rows()))); sys.exit(0)
if a[:1]==['current-window']:
 print('window:1'); sys.exit(0)
if a[:1]==['current-workspace']:
 print(focus.read_text() if focus.exists() else 'workspace:1'); sys.exit(0)
if a[:1]==['select-workspace']:
 focus.write_text(a[2]); print('OK'); sys.exit(0)
if a[:1]==['tree']:
 print(json.dumps(next(row for row in rows() if row['ref']==a[2]))); sys.exit(0)
if a[:1]==['new-workspace']:
 got,pos=options(a[1:],{'--cwd','--command'})
 if pos: sys.exit('Error: unexpected argument '+pos[0])
 n=int(count.read_text())+1 if count.exists() else 7; count.write_text(str(n))
 focus.write_text('workspace:%d'%n)
 if '--command' in got:
  sys.path.insert(0,str(r/'bin/lib'))
  import fm_lifeline
  fm_lifeline.start(shlex.split(got['--command']),owner=int(os.environ['FM_SESSION_PID']),
   stdin=subprocess.DEVNULL,stdout=open(r/'cmux-shown','ab'),stderr=subprocess.STDOUT)
 print('OK workspace:%d'%n)
elif a[:1]==['rename-workspace']:
 got,pos=options(a[1:],{'--workspace'})
 if len(pos)!=1: sys.exit('Error: rename-workspace requires a title')
 (r/('cmux-title-'+got.get('--workspace','current').replace(':','-'))).write_text(pos[0]); print('OK')
elif a[:1]==['close-workspace']:
 got,pos=options(a[1:],{'--workspace'})
 if '--workspace' not in got or pos: sys.exit('Error: close-workspace requires --workspace')
 print('OK')
else: sys.exit('Error: Unknown command '+(a[0] if a else ''))
'''

    LEAKED=dict(GH_TOKEN='leak-gh', GITHUB_TOKEN='leak-github', GH_ENTERPRISE_TOKEN='leak-ghe',
                CLAUDE_CODE_MESSAGING_TOKEN='leak-messaging', AWS_SECRET_ACCESS_KEY='leak-aws', FOO='leak-foo')

    def recorded_environment_case(self, api_key):
        self.env['CODEX_API_KEY']='fm-suite-key'
        if api_key:
            with (self.repo/'config.yaml').open('a') as config:
                config.write('billing:\n  codex: api-key\n')
        # a round in a Herdr window, a reviewer's, and a headless one
        for script,args,extra in (('fm-worker.sh',['--task','T-035'],{}),
                                  ('fm-review.sh',['--task','T-035','--branch','work'],{}),
                                  ('fm-worker.sh',['--task','T-035'],dict(HERDR_ENV='0'))):
            with self.subTest(script=script,**extra):
                answer=self.invoke(script,args,**self.LEAKED,**extra)
                self.assertEqual(0,answer.returncode,answer.stderr)
                latest=max(self.results(),key=lambda p:p.stat().st_mtime_ns)
                result=json.loads(latest.read_text()); attempt=Path(result['attempt'])
                # the round still starts and finishes
                self.assertEqual('completed',result['status'])
                self.assertEqual('0',(attempt/'runner.exit').read_text().strip())
                text=(attempt/'environment.json').read_text(); environment=json.loads(text)
                self.assertNotIn('FM_ADAPTER_CONFIG',environment)
                code=Path(environment['FM_CODE_ROOT'])
                self.assertNotEqual(self.repo,code)
                self.assertFalse((code/'config.yaml').exists())
                launched=json.loads((self.repo/(result['actor']+'.login')).read_text())
                for name,value in self.LEAKED.items():
                    self.assertNotIn(name,environment)
                    self.assertNotIn(value,text)
                # its own login, and no other vendor's (the fixture sets all four)
                if api_key:
                    self.assertEqual('fm-suite-key',environment['CODEX_API_KEY'])
                    self.assertEqual('fm-suite-key',launched['CODEX_API_KEY'])
                else:
                    self.assertNotIn('CODEX_API_KEY',environment)
                    self.assertNotIn('CODEX_API_KEY',launched)
                    self.assertNotEqual(str(self.env['HOME'])+'/.codex',launched['CODEX_HOME'])
                for other in ('CLAUDE_CODE_OAUTH_TOKEN','CURSOR_API_KEY','GEMINI_API_KEY'):
                    self.assertNotIn(other,environment)
                self.assertEqual(result['actor'],environment['FM_ACTOR'])
                self.assertIn(str(self.fake),environment['PATH'])

    def handed_environment_case(self, api_key):
        self.env.update(CODEX_API_KEY='fm-suite-key', FM_CODE_ROOT=str(m.snapshot(self.repo)))
        self.assertNotIn('FM_ADAPTER_CONFIG',self.env)
        self.assertFalse((Path(self.env['FM_CODE_ROOT'])/'config.yaml').exists())
        if api_key:
            with (self.repo/'config.yaml').open('a') as config:
                config.write('billing:\n  codex: api-key\n')
        # an environment.json an older launcher wrote from all of os.environ
        # still reaches the adapter through the same allowlist
        attempt=self.repo/'state/runs/worker-env-t035-r1/codex-env'; attempt.mkdir(parents=True)
        adapter=self.repo/'handed/codex.sh'; adapter.parent.mkdir()
        adapter.write_text('#!/usr/bin/env bash\nenv > "$FM_TEST_ROOT/handed-env"\n'); adapter.chmod(0o755)
        (attempt/'prompt.md').write_text('go\n')
        m.save(attempt/'invocation.json',dict(adapter=str(adapter),prompt=str(attempt/'prompt.md'),
                                              tree=str(self.repo),actor='worker-env-t035-r1',role='worker',task='T-035'))
        m.save(attempt/'environment.json',dict(self.env,**self.LEAKED,ANTHROPIC_API_KEY='leak-other'))
        fd=os.open(attempt/'execution.lock',os.O_RDWR|os.O_CREAT); self.addCleanup(os.close,fd)
        with patch.dict(os.environ,{'FM_HEARTBEAT_SECS':'0'}):
            self.assertEqual(0,m.execute_child(attempt,fd))
        handed=dict(line.split('=',1) for line in (self.repo/'handed-env').read_text().splitlines() if '=' in line)
        for name in (*self.LEAKED,'CLAUDE_CODE_OAUTH_TOKEN','ANTHROPIC_API_KEY','CURSOR_API_KEY','GEMINI_API_KEY'):
            self.assertNotIn(name,handed)
        if api_key:
            self.assertEqual('fm-suite-key',handed['CODEX_API_KEY'])
        else:
            self.assertNotIn('CODEX_API_KEY',handed)
        self.assertEqual(str(self.repo),handed['FM_TEST_ROOT'])


class EmitStatusFixture(unittest.TestCase):
    """T-036: mid-run activity goes through emit-status → fm-emit.sh only."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'bin').mkdir(); (self.root/'state').mkdir()
        shutil.copy(root/'bin/fm-emit.sh', self.root/'bin/fm-emit.sh')
        shutil.copy(root/'bin/fm-herdr.py', self.root/'bin/fm-herdr.py')

    def events(self):
        path = self.root/'state/events.jsonl'
        if not path.exists(): return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


class AgentLostFixture(unittest.TestCase):
    """T-118: a run whose recorded process is gone and that never said
    agent_finished gets one agent_lost, from the launcher side's deck
    reconcile through fm-emit, never from the model; a live run gets none."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'bin').mkdir(); (self.root/'state/runs').mkdir(parents=True)
        shutil.copy(root/'bin/fm-emit.sh', self.root/'bin/fm-emit.sh')
        self.log = self.root/'state/events.jsonl'
        # a pid that existed and is gone: its own child, started and reaped
        gone = subprocess.Popen(['true']); gone.wait(); self.dead = gone.pid

    def say(self, actor, type_, task='T-118', data=None):
        line = dict(ts='2026-09-26T10:00:00Z', actor=actor, type=type_, task=task,
                    data=data or {'role': 'worker'}, summary={'en': type_, 'zh-TW': type_})
        with self.log.open('a') as f: f.write(json.dumps(line) + '\n')

    def events(self):
        return [json.loads(l) for l in self.log.read_text().splitlines() if l.strip()]

    def recorded(self, actor, pid, token):
        run = self.root/'state/runs'/actor; run.mkdir()
        m.save(run/'process.json', dict(actor=actor, role='worker', task='T-118', pid=pid, token=token))

