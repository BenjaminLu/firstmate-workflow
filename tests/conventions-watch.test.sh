#!/usr/bin/env bash
# Scheduled onboarding is exercised through the real fm_watch.cycle path.
# tests/lib/onboarding/repository.json
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 - "$ROOT" <<'PY'
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock
from contextlib import ExitStack
sys.dont_write_bytecode=True
root=Path(sys.argv[1]); sys.path.insert(0,str(root/'bin/lib'))
import fm_conventions_watch as C
import fm_watch as W
from fm_onboard import infer, approve

class ScheduledConventions(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.engine=Path(self.tmp.name)/'engine'; self.engine.mkdir()
        self.private=Path(self.tmp.name)/'private'
        self.homes={name:self.private/'projects'/name for name in ('one','two')}
        config='default_project: self\nprojects:\n  self:\n    repo: .\n    github: owner/engine\n    base: main\n    required_check: ci\n'
        self.e=dict(repository='consenlabs/tokenlon-mm-agent',base='master',source='github',pulls=[],commits=[],
                    repository_info=json.loads((root/'tests/lib/onboarding/repository.json').read_text()),protection={'status':'unknown'})
        for name,home in self.homes.items():
            config+=f'  {name}:\n    github: consenlabs/tokenlon-mm-agent\n    base: master\n    required_check: ci\n'
            approve(home,self.e,infer(self.e),dict(confirmed=True,policy_confirmed=True,captain='captain',intent='test',product='app',required_checks=['ci'],contract={'check':'true'},reinspect_seconds=100 if name=='one' else 200))
        (self.engine/'config.yaml').write_text(config)
        self.env=patch.dict(os.environ,{**{k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_'))},'FM_HOME':str(self.private),'FM_PROJECT':'self'},clear=True)
        self.env.start(); self.addCleanup(self.env.stop)
    def test_self_only_and_unconfirmed_registry_have_no_timer(self):
        for names in (['self'], ['self', 'pending']):
            with patch.object(C,'project_names',return_value=names), patch.object(C,'registry_value',side_effect=lambda engine,name,field: str(self.engine if name=='self' else self.private/'pending')):
                self.assertIsNone(C.tick(self.engine))

    def test_registry_reads_have_a_timeout(self):
        import fm_onboard as O
        with patch.object(O.subprocess,'run',return_value=Mock(returncode=0,stdout='home')) as run:
            O.registry_value(self.engine,'one','home')
            self.assertGreater(run.call_args.kwargs['timeout'],0)
            self.assertLessEqual(run.call_args.kwargs['timeout'],30)

    def test_onboarding_approval_and_edit_ring_after_persistence(self):
        import fm_onboard as O
        fresh=self.engine/'fresh'; fresh.mkdir()
        answers=self.engine/'answers.json'
        answers.write_text(json.dumps(dict(confirmed=True,policy_confirmed=True,captain='captain',intent='start',product='app',repository='owner/new',visibility='private',base='main',bootstrap_authorized=True,merge_method='squash',available_merge_methods=['squash'],delete_branch=False,required_checks=['ci'],contract={'check':'true'})))
        home=self.private/'projects/new'
        original_ring=W.life.ring
        def rang(engine,line):
            self.assertEqual(engine,self.engine)
            self.assertTrue((home/'CONVENTIONS.md').exists())
            self.assertIn('  new:',(self.engine/'config.yaml').read_text())
            return original_ring(engine,line)
        with W.life.Doorbell(self.engine) as bell, patch.object(W.life,'ring',side_effect=rang) as ring:
            self.assertEqual(O.main(['add',str(fresh),'--name','new','--repo',str(self.engine),'--answers',str(answers)]),0)
            self.assertEqual(ring.call_count,1)
            self.assertTrue(bell.wait(0), 'approval must wake the existing idle watcher')
            changes=self.engine/'changes.json'; changes.write_text('{"reinspect_seconds":120}')
            self.assertEqual(O.main(['edit','new','--repo',str(self.engine),'--changes',str(changes),'--captain','captain','--intent','cadence']),0)
            self.assertEqual(ring.call_count,2)
            self.assertTrue(bell.wait(0), 'edit must wake the existing idle watcher')

    def test_taken_items_skip_registry_entirely(self):
        directory=self.engine/'state/watch'; (directory/'wake').mkdir(parents=True,exist_ok=True)
        def take(engine,stage):
            (directory/'wake'/f'{stage}.staged').write_text('[]')
            return [{'id':'ready'}]
        with ExitStack() as stack:
            for target,name,value in [(W.life,'hold',Mock(return_value=os.getpid())),(W.life,'Doorbell',Mock(return_value=Mock(path='test-bell'))),(W,'start_cycle',Mock()),(W.os,'dup2',Mock()),(W.signal,'signal',Mock()),(W,'take',Mock(side_effect=take)),(W,'wake_line',Mock(return_value='ready'))]:
                stack.enter_context(patch.object(target,name,value))
            tick=stack.enter_context(patch.object(C,'tick',side_effect=AssertionError('delivery consulted registry')))
            self.assertEqual(W.cycle(self.engine),0)
            tick.assert_not_called()

    def test_every_project_has_its_own_deadline(self):
        inspect=Mock(return_value=self.e)
        self.assertEqual(C.tick(self.engine,clock=lambda:1000,inspect=inspect),100)
        self.assertEqual(inspect.call_count,2)
        self.assertEqual(C.tick(self.engine,clock=lambda:1050,inspect=inspect),50)
        self.assertEqual(inspect.call_count,2)
        C.tick(self.engine,clock=lambda:1100,inspect=inspect)
        self.assertEqual(inspect.call_count,3)
    def test_one_project_failure_does_not_skip_the_other(self):
        save=C.save
        def fail_one(path,value):
            if self.homes['one'] in path.parents: raise OSError('read-only project')
            save(path,value)
        inspect=Mock(return_value=self.e)
        with patch.object(C,'save',side_effect=fail_one):
            self.assertGreater(C.tick(self.engine,clock=lambda:1000,inspect=inspect),0)
        self.assertEqual(inspect.call_count,1)
    def test_owned_inspector_uses_real_lifeline_and_finishes(self):
        children=[]; start=W.life.start
        # Real keeper and inspector; a local executable substitutes only gh.
        gh=self.engine/'gh'; gh.write_text('#!/bin/sh\necho unavailable >&2\nexit 1\n'); gh.chmod(0o755)
        def owned(*args,**kwargs):
            self.assertEqual(kwargs['owner'],os.getpid())
            child=start(*args,**kwargs); children.append(child)
            # Wait on process completion, not polling; deterministic queue
            # availability lets the real cycle consume the inspector's wake.
            child.wait(timeout=20)
            return child
        try:
            with ExitStack() as stack:
                stack.enter_context(patch.dict(os.environ,{'FM_GH':str(gh)}))
                stack.enter_context(patch.object(W.life,'start',side_effect=owned))
                stack.enter_context(patch.object(W.life,'hold',return_value=os.getpid()))
                stack.enter_context(patch.object(W.life,'Doorbell',return_value=Mock(path='test-bell',wait=Mock(side_effect=AssertionError('inspector failed to wake engine')))))
                stack.enter_context(patch.object(W,'start_cycle'))
                stack.enter_context(patch.object(W.os,'dup2'))
                stack.enter_context(patch.object(W.signal,'signal'))
                self.assertEqual(W.cycle(self.engine),0)
            self.assertTrue((self.engine/'state/watch/wake/1.json').exists())
            self.assertEqual(len(children),2)
            for child in children: self.assertEqual(child.wait(timeout=20),0)
            for home in self.homes.values():
                self.assertIn('unavailable',(home/'state/onboarding/inspection-error.txt').read_text())
            wakes=[json.loads(line) for line in (self.engine/'state/session/wake.jsonl').read_text().splitlines()]
            self.assertEqual({item['project'] for item in wakes},{'one','two'})
        finally:
            for child in children:
                if child.poll() is None: child.terminate()
                child.wait(timeout=20)
    def test_cycle_delivers_wake_despite_inspection_failure(self):
        # Keep the real cycle, locks and files; replace process ownership and
        # successor startup so this unit owns no background process.
        for error in (OSError('stamp denied'),ImportError('inspector missing'),W.life.OwnerGone('owner gone')):
            with self.subTest(error=type(error).__name__), ExitStack() as stack:
                directory=self.engine/'state/watch'; (directory/'wake').mkdir(parents=True,exist_ok=True)
                bell=Mock(path='test-bell')
                stack.enter_context(patch.object(W.life,'hold',return_value=os.getpid()))
                stack.enter_context(patch.object(W.life,'Doorbell',return_value=bell))
                stack.enter_context(patch.object(W.life,'ring'))
                stack.enter_context(patch.object(W,'start_cycle'))
                stack.enter_context(patch.object(W.os,'dup2'))
                stack.enter_context(patch.object(W.signal,'signal'))
                tick=stack.enter_context(patch.object(C,'tick',side_effect=error))
                count=[0]
                def take(engine,stage):
                    count[0]+=1
                    if count[0]<3: return []
                    (directory/'wake'/f'{stage}.staged').write_text('[]')
                    return [{'id':'ready'}]
                stack.enter_context(patch.object(W,'take',side_effect=take))
                stack.enter_context(patch.object(W,'wake_line',return_value='ready'))
                self.assertEqual(W.cycle(self.engine),0)
                self.assertEqual(tick.call_args.kwargs['owner'],os.getpid())
                self.assertEqual(bell.wait.call_count,1)
                self.assertIsNone(bell.wait.call_args.args[0])
                generation=(directory/'generation').read_text().strip()
                self.assertTrue((directory/'wake'/f'{generation}.json').exists())
unittest.main(argv=['conventions-watch'],verbosity=2)
PY
assert_eq 0 "$?" "registry-wide convention timers preserve wake delivery and owned inspector lifetime"
finish
