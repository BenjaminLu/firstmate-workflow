from herdr import *

class Entrypoints(EntrypointsFixture):
    def test_a_rounds_recorded_environment_is_its_allowlist_never_the_launchers(self):
        self.recorded_environment_case(False)

    def test_api_billing_records_the_chosen_codex_key(self):
        self.recorded_environment_case(True)

    def test_the_runner_hands_the_adapter_only_the_allowlist(self):
        self.handed_environment_case(False)

    def test_api_billing_hands_the_adapter_the_chosen_codex_key(self):
        self.handed_environment_case(True)

    def test_each_vendor_is_handed_the_login_variables_its_policy_names(self):
        # the allowlist's logins are the policy's `given` (bin/fm-config.sh), in order
        policy=subprocess.run(['bash','-c','. "$1/bin/fm-config.sh" && fm_policy worker "" "$1/config.yaml"',
                               'policy',str(self.repo)],env=self.env,capture_output=True,text=True,timeout=WAIT)
        self.assertEqual(0,policy.returncode,policy.stderr)
        vendors=json.loads(policy.stdout)['vendors']
        self.assertEqual({v:list(d['login'].get('given',[])) for v,d in vendors.items() if d['login'].get('given')},
                         {v:list(names) for v,names in m.ROUND_LOGIN.items()})
        # The first eligible login wins; settings never live in the snapshot.
        code=m.snapshot(self.repo)
        self.assertFalse((code/'config.yaml').exists())
        base=dict(PATH='/bin',FM_ROOT=str(self.repo),FM_CODE_ROOT=str(code))
        both=dict(base,CLAUDE_CODE_OAUTH_TOKEN='a',ANTHROPIC_API_KEY='b',FOO='x')
        self.assertEqual(dict(base,CLAUDE_CODE_OAUTH_TOKEN='a'),m.round_environment(both,'claude'))
        self.assertEqual(base,
                         m.round_environment(dict(both,CLAUDE_CODE_OAUTH_TOKEN=''),'claude'))
        self.assertEqual(base,m.round_environment(both,'mock'))
        for vendor,names in m.ROUND_LOGIN.items():
            for api_key in (False,True):
                with self.subTest(vendor=vendor,api_key=api_key):
                    config=self.repo/'config.yaml'
                    config.write_text('billing:\n  '+vendor+': '+('api-key' if api_key else 'subscription')+'\n')
                    source=dict(FM_ROOT=str(self.repo),FM_CODE_ROOT=str(code),
                                **{name:'login' for name in names})
                    expected={k:v for k,v in source.items() if k.startswith('FM_')}
                    if api_key or vendor in ('claude','cursor-agent'):
                        expected[names[0]]='login'
                    self.assertEqual(expected,m.round_environment(source,vendor))
        config.write_text('billing:\n  claude: api-key\n')
        source=dict(FM_ADAPTER_CONFIG=str(config),FM_CODE_ROOT=str(self.repo),ANTHROPIC_API_KEY='b')
        self.assertEqual(source,m.round_environment(source,'claude'))

    def test_new_role_resets_inherited_adapter_guard(self):
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],
                           FM_CONTEXT_READY='1',FM_ATTEMPT_DIR='/unused-parent',FM_FINAL_PATH='/unused-parent/final')
        self.assertEqual(0,answer.returncode,answer.stderr)
        self.assertTrue((self.repo/'controls').exists())
        self.assertEqual(1,len(self.results()))

    def test_managed_rounds_run_inside_the_os_sandbox(self):
        # T-105: a worker and a reviewer each start their CLI inside the OS
        # sandbox, confined to their own tree with no network of their own
        for script,args in (('fm-worker.sh',['--task','T-035']),
                            ('fm-review.sh',['--task','T-035','--branch','work'])):
            with self.subTest(script=script):
                (self.repo/'sandboxed').unlink(missing_ok=True)
                answer=self.invoke(script,args)
                self.assertEqual(0,answer.returncode,answer.stderr)
                handed=(self.repo/'sandboxed').read_text().splitlines()
                self.assertIn('--unshare-net',handed)
                self.assertIn('--',handed)

    def test_unknown_adapter_remains_configuration_error(self):
        answer=self.invoke('fm-worker.sh',['--task','T-035','--vendor','unknown'])
        self.assertEqual(65,answer.returncode,answer.stderr)
        self.assertFalse((self.repo/'controls').exists())

    def test_fallback_keeps_one_actor_and_owned_pane(self):
        self.executable('claude', "print('Authentication required.')\nraise SystemExit(2)\n")
        (self.repo/'config.yaml').write_text('vendor: claude\nfallback:\n  - codex\n')
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'])
        self.assertEqual(0,answer.returncode,answer.stderr)
        calls=[json.loads(s) for s in (self.repo/'controls').read_text().splitlines()]
        self.assertEqual(1,len([c for c in calls if c[:2]==['tab','create']]))
        names={c[3] for c in calls if c[:2]==['agent','rename']}
        self.assertEqual(1,len(names))
        result=json.loads(self.results()[0].read_text())
        self.assertEqual(names,{result['actor']})
        self.assertEqual(2,len(list(self.results()[0].parent.glob('*/result.json'))))

    def test_all_supported_cli_formats_inject_roles_and_keep_final(self):
        # Only a vendor whose round's login its own status check confirms
        # runs (T-121): claude's recording says signed in. cursor-agent's
        # recorded answer is "Not logged in" and gemini has no status check,
        # so each is refused before its CLI sees a prompt, with the reason
        # on the board; their JSON formats are adapter-contract's to check.
        for vendor in ('claude','cursor-agent','gemini'):
            self.executable(vendor, r'''
import json,os,pathlib,sys
prompt=sys.stdin.read(); assert os.environ['FM_ACTOR'] in prompt
pathlib.Path(os.environ['FM_TEST_ROOT'],'prompted-'+pathlib.Path(sys.argv[0]).name).touch()
assert 'explicitly dispatched reviewer' in prompt
assert '--output-format' in sys.argv and 'json' in sys.argv
final='REJECT:T-035\nREVIEWER_COMPLETE:T-035'
print(json.dumps({'type':'result','result':final,'response':final}))
''')
            answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work','--vendor',vendor])
            if vendor=='claude':
                self.assertEqual(0,answer.returncode,answer.stderr)
                self.assertIn('REJECT:T-035',answer.stdout)
                self.assertTrue((self.repo/'prompted-claude').exists())
            else:
                self.assertNotEqual(0,answer.returncode,answer.stderr)
                self.assertFalse((self.repo/('prompted-'+vendor)).exists(),vendor+' never sees a prompt')
                log=self.repo/'state/events.jsonl'
                events=[json.loads(l) for l in (log.read_text().splitlines() if log.exists() else []) if l.strip()]
                refused=[e['summary'] for e in events if e.get('type')=='vendor_unavailable']
                status='indeterminate' if vendor=='gemini' else 'unauthenticated'
                self.assertTrue(any(s['en'].startswith(vendor+': '+status+': ') for s in refused),refused)
                self.assertTrue(any(s['zh-TW'].startswith(vendor+'：') for s in refused),refused)
        statuses=[json.loads(p.read_text())['status'] for p in self.results()]
        self.assertEqual(1,statuses.count('completed'),statuses)

    def test_real_dispatch_and_autopilot_paths_use_managed_adapters(self):
        # The binding service must resolve this checkout without an ambient
        # GH_REPO before it can fetch and verify the authoritative PR head.
        origin = subprocess.run(['git', '-C', str(self.repo), 'config', '--get',
                                 'remote.origin.url'], env=self.env,
                                capture_output=True, text=True, timeout=WAIT)
        self.assertEqual(0, origin.returncode, origin.stderr)
        self.assertEqual('https://github.com/fixture/project.git', origin.stdout.strip())
        # Production dispatch launches the production worker; only git/gh/model
        # boundaries are fake. No external account is used; the only captain
        # decision is the fixture's A on T-035's readiness card, without which
        # the dispatcher holds the task (T-059).
        subprocess.run([str(self.repo/'bin/fm-emit.sh'),'--actor','captain','--type','greenlit'],
                       env=self.env,check=True,capture_output=True)
        subprocess.run(['bash',str(self.repo/'bin/fm-ready.sh'),'judged','--task','T-035',
                        '--decision','D-1000','--repo',str(self.repo)],
                       env=self.env,check=True,capture_output=True)
        (self.repo/'state/decisions').mkdir(parents=True,exist_ok=True)
        (self.repo/'state/decisions/D-1000.json').write_text('{"id":"D-1000","task":"T-035","kind":"choice","chosen":"A"}\n')
        answer=self.invoke('fm-dispatch.sh')
        self.assertEqual(0,answer.returncode,answer.stderr)
        paths=eventually(lambda:list((self.repo/'state/runs').glob('*/orchestration-result.json')))
        self.assertTrue(paths)
        self.assertEqual(0,json.loads(paths[0].read_text())['process_exit'])
        # Gate 7 requests a reviewer; gate execution itself is outside this test.
        (self.repo/'bin/fm-gate.sh').write_text('#!/usr/bin/env bash\nexit 7\n')
        answer=subprocess.run([sys.executable,str(root/'tests/lib/autopilot_turn.py'),str(self.repo)],
                              env=self.env,capture_output=True,text=True,timeout=WAIT)
        self.assertEqual(0,answer.returncode,answer.stderr)
        self.assertNotIn('authoritative head unknown or stale', answer.stdout + answer.stderr)
        # Autopilot verifies before gates and launch, then review verifies before preparation,
        # after the CI wait and before publication. Each review verification
        # also resolves or rechecks the live base through base mode.
        pair = ['refs/pull/35/head', 'refs/heads/main']
        self.assertEqual(pair * 2 + (pair + ['refs/heads/main']) * 3,
                         (self.repo/'binding-fetches').read_text().splitlines())
        self.assertEqual({'worker','reviewer'},{json.loads(p.read_text())['role'] for p in self.results()})

unittest.main(argv=['herdr', *os.environ.get('FM_TEST_CASES','').split()], verbosity=2)
