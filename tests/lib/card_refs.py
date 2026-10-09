"""Behavioral diff-reference assertions; helper import failures are setup errors."""
import importlib.util
from pathlib import Path
import hashlib
import sys
import json
import os
import subprocess
import tempfile
import shlex
import shutil

os.environ['HERDR_ENV'] = '0'
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
sys.path.insert(0, str(ROOT / 'tests/lib'))

HELPER = (ROOT / 'bin/lib/fm_card_refs.py').is_file()
HELPER_SKIP = 'setup: bin/lib/fm_card_refs.py unavailable; helper cases not run (not behavioral)'

@unittest.skipUnless(HELPER, HELPER_SKIP)
class CardRefs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Availability on historical roots is setup, never behavioral RED.
        global refs
        import fm_card_refs as refs

    def test_unlisted_valid_hunkless_entries_do_not_block_evidence(self):
        text = "diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1 +1 @@\n-old\n+new\n"
        variants = ("diff --git a/tool b/tool\nold mode 100644\nnew mode 100755\n",
                    "diff --git a/empty b/empty\nnew file mode 100644\nindex 0000000..e69de29\n",
                    "diff --git a/empty b/empty\ndeleted file mode 100644\nindex e69de29..0000000\n")
        for extra in variants:
            with self.subTest(diff=extra):
                entries = refs.parse_diff(text + extra, "owner/repo", 7)
                self.assertEqual("new", refs.point_code(entries, ["src/a.py"])[0]["snippet"])
                with self.assertRaisesRegex(ValueError, "no supported hunks"):
                    refs.point_code(entries, [entries[-1]["new"] or entries[-1]["old"]])
        for extra in ("", "old mode 100644\n", "unknown metadata\n", "index abc..def\n"):
            with self.subTest(invalid=extra), self.assertRaises(ValueError):
                refs.parse_diff(text + "diff --git a/tool b/tool\n" + extra, "owner/repo", 7)

    def test_right_hunk_and_snippet_cap(self):
        diff = 'diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1,1 +1,14 @@\n old\n' + ''.join('+new\n' for _ in range(13))
        entries = refs.parse_diff(diff, 'owner/repo', 7)
        code = refs.point_code(entries, ['src/a.py'])
        self.assertEqual((1, 14), (code[0]['start'], code[0]['end']))
        self.assertEqual(12, len(code[0]['snippet'].splitlines()))
        self.assertEqual('https://github.com/owner/repo/pull/7/files#diff-' + hashlib.sha256(b'src/a.py').hexdigest() + 'R1', code[0]['url'])

    def test_deletion_binary_rename_and_quoted_unicode(self):
        diff = ('diff --git a/gone b/gone\n--- a/gone\n+++ /dev/null\n@@ -3,2 +0,0 @@\n-old\n-gone\n'
                'diff --git a/image b/image\nBinary files a/image and b/image differ\n'
                'diff --git a/old b/new\nsimilarity index 100%\nrename from old\nrename to new\n'
                'diff --git "a/space \\303\\251" "b/space \\303\\251"\n--- "a/space \\303\\251"\n+++ "b/space \\303\\251"\n@@ -1 +1 @@\n-x\n+y\n')
        entries = refs.parse_diff(diff, 'owner/repo', 7)
        deletion = refs.point_code(entries, ['gone'])[0]
        self.assertEqual('left', deletion['side'])
        self.assertTrue(deletion['url'].endswith('L3'))
        self.assertEqual('binary', refs.point_code(entries, ['image'])[0]['kind'])
        self.assertEqual('rename', refs.point_code(entries, ['old', 'new'])[0]['kind'])
        self.assertEqual('space é', refs.point_code(entries, ['space é'])[0]['file'])
        self.assertIn('space%20%C3%A9', refs.blob_url('owner/repo', 'a' * 40, 'space é'))

    def test_deletion_only_with_context_uses_old_range(self):
        diff = 'diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -3,3 +3,2 @@\n context\n-removed\n tail\n'
        code = refs.point_code(refs.parse_diff(diff, 'owner/repo', 7), ['a'])[0]
        self.assertEqual('left', code['side'])
        self.assertEqual((3,5), (code['start'],code['end']))
        self.assertEqual('context\nremoved\ntail',code['snippet'])
        self.assertTrue(code['url'].endswith('L3'))

    def test_mixed_quoted_rename_and_embedded_prefix(self):
        self.assertEqual(('old','é'),refs.header_paths('diff --git a/old "b/\\303\\251"'))
        self.assertEqual(('x b/y','x b/y'),refs.header_paths('diff --git a/x b/y b/x b/y'))

    def test_rename_metadata_resolves_unquoted_header_separator_and_literal_prefix(self):
        diff = 'diff --git a/x b/y b/a/new b/z\nsimilarity index 100%\nrename from x b/y\nrename to a/new b/z\n'
        code = refs.point_code(refs.parse_diff(diff,'owner/repo',7),['x b/y','a/new b/z'])
        self.assertEqual(1,len(code))
        self.assertEqual('a/new b/z',code[0]['file'])
        self.assertTrue(code[0]['url'].endswith(hashlib.sha256(b'a/new b/z').hexdigest()))

    def test_missing_files_paths_and_repository_identity(self):
        with self.assertRaisesRegex(ValueError, 'absent'):
            refs.point_code([], ['missing'])
        for path in ('/a', '../a', 'a/./b', 'a//b', 'a\x00b'):
            with self.subTest(path=path), self.assertRaises(ValueError): refs.repository_path(path)
        for identity in ('_owner/repo','owner_/repo','-owner/repo','owner./repo','owner-/repo','owner/..'):
            with self.subTest(identity=identity), self.assertRaises(ValueError): refs.repository(identity)
        self.assertEqual('owner/repo', refs.discovery_identity({'nameWithOwner': 'owner/repo', 'url': 'https://github.com/owner/repo/'}))
        for url in ('http://github.com/owner/repo', 'https://evil.test/owner/repo', 'https://github.com/other/repo', None):
            with self.subTest(url=url), self.assertRaises(ValueError):
                refs.discovery_identity({'nameWithOwner': 'owner/repo', 'url': url})

    def test_read_arguments_cwd_and_private_prose(self):
        root = ROOT
        spec = {'acceptance': ['/private/authored acceptance'], 'change_refs': [
            {'files': ['src/a.py'], 'tests': [{'file': 'tests/a.py', 'name': 'test_a'}], 'acceptance': [0]}]}
        diff = 'diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1 +1 @@\n-x\n+y\n'
        calls = []
        def read(argv, cwd):
            calls.append((argv, cwd))
            if argv[0] == 'git': return 'header\ndef test_a():\n    pass\n'
            if argv[1:3] == ['repo', 'view']:
                return '{"nameWithOwner":"owner/repo","url":"https://github.com/owner/repo"}'
            if argv[1:3] == ['pr', 'diff']: return diff
            return '{"headRefOid":"' + 'a' * 40 + '"}'
        with patch.object(refs, 'read', side_effect=read):
            result = refs.build_refs(spec, root, '', 7, 'a' * 40, True, 'T-X')
        self.assertIsNone(result['spec_url'])
        self.assertEqual(2, result['points'][0]['tests'][0]['line'])
        self.assertEqual(['repo', 'view', '--json', 'nameWithOwner,url'], calls[0][0][1:])
        for argv, cwd in calls:
            self.assertEqual(root, cwd)
            self.assertNotIn('/private/authored acceptance', argv)
            if argv[1:2] == ['pr']:
                self.assertEqual('owner/repo', argv[argv.index('--repo') + 1])
        for point in result['points']:
            for item in point['code'] + point['tests']:
                self.assertTrue(item['url'].startswith('https://github.com/owner/repo/'))
                self.assertNotIn('/private/', item['url'])

    def test_truncation_head_checks_and_missing_test(self):
        diff = 'diff --git a/a b/a\n--- a/a\n+++ b/a\n' + ''.join(f'@@ -{n} +{n} @@\n-x\n+y\n' for n in range(1, 24))
        spec = {'acceptance': ['works'], 'change_refs': [{'files': ['a'], 'tests': [{'file': 'tests/a.py', 'name': 'missing'}], 'acceptance': [0]}]}
        with patch.object(refs, 'read', side_effect=['{"headRefOid":"' + 'a' * 40 + '"}', diff, '{"headRefOid":"' + 'a' * 40 + '"}', 'other']):
            result = refs.build_refs(spec, ROOT, 'owner/repo', 7, 'a' * 40, True, 'T-X')
        self.assertIsNone(result['spec_url'])
        self.assertEqual(3, result['points'][0]['more'])
        self.assertEqual(20, len(result['points'][0]['code']))
        self.assertIsNone(result['points'][0]['tests'][0]['line'])
        for responses in ([ '{"headRefOid":"bad"}' ], ['{"headRefOid":"' + 'a' * 40 + '"}', diff, '{"headRefOid":"bad"}']):
            with patch.object(refs, 'read', side_effect=responses), self.assertRaisesRegex(ValueError, 'head'):
                refs.build_refs(spec, ROOT, 'owner/repo', 7, 'a' * 40, False, 'T-X')


@unittest.skipUnless(HELPER, HELPER_SKIP)
class ExecutableRefs(unittest.TestCase):
    """Real git objects/diffs and an executable gh boundary; no mocked reads."""
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.git('init', '-q', '--object-format=sha1')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.test')
        self.write('space é.py', 'old\n')
        self.write('gone.py', 'removed\n')
        self.write('old.py', 'rename content\n')
        self.write('tool', 'executable content\n')
        self.write('image.bin', b'\x00old')
        self.write('many.py', ''.join(f'line {n}\n' for n in range(240)))
        self.write('tests/test space é.py', 'header\ndef test_saved():\n    pass\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture base')
        self.base = self.git('rev-parse', 'HEAD').strip()
        self.write('space é.py', ''.join(f'added {n}\n' for n in range(15)))
        (self.root / 'gone.py').unlink()
        (self.root / 'old.py').rename(self.root / 'new.py')
        self.write('image.bin', b'\x00new')
        self.write('many.py', ''.join(('changed' if n % 10 == 0 else 'line') + f' {n}\n' for n in range(240)))
        self.git('add', '-A')
        self.git('commit', '-qm', 'fixture head')
        self.head = self.git('rev-parse', 'HEAD').strip()
        self.write('diff.txt', self.git('diff', '--find-renames', self.base, self.head))
        self.write('identity.json', json.dumps({'nameWithOwner':'owner/repo','url':'https://github.com/owner/repo'}))
        self.write('heads.json', json.dumps([self.head, self.head]))
        self.write('gh', r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(__file__).parent
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps({'argv':args,'cwd':os.getcwd()}) + '\n')
if args[:2] == ['repo','view']:
    print((root / 'identity.json').read_text())
elif args[:2] == ['pr','diff']:
    print((root / 'diff.txt').read_text(), end='')
elif args[:2] == ['pr','view']:
    counter = root / 'views'
    n = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(n+1))
    print(json.dumps({'headRefOid':json.loads((root / 'heads.json').read_text())[n]}))
else:
    sys.exit(2)
""")
        (self.root / 'gh').chmod(0o755)
        self.spec = {'acceptance':['/private/intentionally authored prose'], 'change_refs':[
            {'files':['space é.py','gone.py'], 'tests':[{'file':'tests/test space é.py','name':'test_saved'}], 'acceptance':[0]},
            {'files':['old.py','new.py','image.bin'], 'tests':[{'file':'tests/test space é.py','name':'absent'}], 'acceptance':[0]}]}

    def write(self, file, content):
        path = self.root / file; path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes): path.write_bytes(content)
        else: path.write_text(content)

    def git(self, *args):
        return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', '-c', 'core.excludesFile=/dev/null', *args], cwd=self.root, check=True, capture_output=True, text=True).stdout

    def invoke(self, repo='', external=True):
        self.write('spec.json', json.dumps(self.spec))
        argv = [sys.executable, str(ROOT / 'bin/lib/fm_card_refs.py'), '--spec', str(self.root / 'spec.json'),
                '--root', str(self.root), '--pr','7','--head',self.head,'--task','T-X']
        if repo: argv += ['--repo',repo]
        if external: argv += ['--external']
        return subprocess.run(argv, cwd=self.root, env=dict(os.environ, FM_GH=str(self.root / 'gh')),
                              capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]

    def test_real_git_diff_sources_and_read_only_argv(self):
        result = self.invoke()
        self.assertEqual(0, result.returncode, result.stderr)
        doc = json.loads(result.stdout)
        self.assertIsNone(doc['spec_url'])
        code = doc['points'][0]['code']
        added = next(c for c in code if c['file'] == 'space é.py')
        self.assertEqual((1,15), (added['start'],added['end']))
        self.assertEqual(12,len(added['snippet'].splitlines()))
        self.assertTrue(added['url'].endswith(hashlib.sha256('space é.py'.encode()).hexdigest()+'R1'))
        deleted = next(c for c in code if c['file'] == 'gone.py')
        self.assertEqual('left',deleted['side'])
        self.assertTrue(deleted['url'].endswith('L1'))
        self.assertEqual(['rename','binary'], [c['kind'] for c in doc['points'][1]['code']])
        self.assertEqual(2,doc['points'][0]['tests'][0]['line'])
        self.assertIn('test%20space%20%C3%A9.py#L2',doc['points'][0]['tests'][0]['url'])
        self.assertIsNone(doc['points'][1]['tests'][0]['url'])
        calls = self.calls()
        self.assertEqual(['repo','view','--json','nameWithOwner,url'], calls[0]['argv'])
        self.assertEqual(['view','diff','view'],[c['argv'][1] for c in calls[1:]])
        for call in calls:
            self.assertEqual(str(self.root),call['cwd'])
            self.assertNotIn('/private/',json.dumps(call['argv']))
            if call['argv'][0] == 'pr': self.assertEqual('owner/repo',call['argv'][call['argv'].index('--repo')+1])
        self.assertNotIn('spec.json',json.dumps(calls))

    def test_real_git_unlisted_mode_and_empty_file(self):
        for variant in ('mode', 'empty'):
            with self.subTest(variant=variant):
                if variant == 'mode': self.git('update-index', '--chmod=+x', 'tool')
                else: self.write('empty', ''); self.git('add', 'empty')
                self.write('diff.txt', self.git('diff', '--cached', self.base))
                (self.root/'views').unlink(missing_ok=True)
                result = self.invoke('owner/repo')
                self.assertEqual(0, result.returncode, result.stderr)
                doc = json.loads(result.stdout)
                self.assertEqual('space é.py', doc['points'][0]['code'][0]['file'])
                self.assertEqual(2, doc['points'][0]['tests'][0]['line'])

    def test_discovery_refuses_before_followup_reads(self):
        for url in ('https://evil.test/owner/repo','http://github.com/owner/repo',None,'https://github.com/other/repo'):
            with self.subTest(url=url):
                self.write('identity.json',json.dumps({'nameWithOwner':'owner/repo','url':url}))
                (self.root / 'calls.jsonl').unlink(missing_ok=True)
                result = self.invoke()
                self.assertEqual(65,result.returncode)
                self.assertIn('repository discovery',result.stderr)
                self.assertEqual(1,len(self.calls()))
                self.assertEqual('',result.stdout)

    def test_registered_skips_discovery_and_each_head_race_refuses(self):
        for heads in ([self.base,self.head],[self.head,self.base]):
            with self.subTest(heads=heads):
                self.write('heads.json',json.dumps(heads))
                (self.root / 'views').unlink(missing_ok=True)
                (self.root / 'calls.jsonl').unlink(missing_ok=True)
                result = self.invoke('owner/repo')
                self.assertEqual(65,result.returncode)
                self.assertIn('head differs',result.stderr)
                self.assertFalse(any(c['argv'][0]=='repo' for c in self.calls()))
                self.assertEqual('',result.stdout)

    def test_real_git_hunk_cap_is_not_a_mocked_parse_result(self):
        self.write('diff.txt',self.git('diff','--unified=0',self.base,self.head))
        self.spec['change_refs']=[dict(files=['many.py'],tests=[dict(file='tests/test space é.py',name='test_saved')],acceptance=[0])]
        result=self.invoke('owner/repo')
        self.assertEqual(0,result.returncode,result.stderr)
        point=json.loads(result.stdout)['points'][0]
        self.assertEqual(20,len(point['code']))
        self.assertEqual(4,point['more'])

    def test_absent_file_is_behavioral_refusal_after_successful_reads(self):
        self.spec['change_refs'][0]['files'] = ['missing.py']
        result = self.invoke('owner/repo')
        self.assertEqual(65,result.returncode)
        self.assertIn('absent from diff',result.stderr)
        self.assertEqual(3,len(self.calls()))


class StockRequests(unittest.TestCase):
    """Stock request publication with real committed specs and authoritative pins."""
    def setUp(self):
        # Test-only overlays must retain these exact source-root dependencies:
        # tests/decide.test.sh fixture prefix, tests/lib/project-storage.sh and
        # tests/lib/ste_cases.py (card and walk_card). Production modules always
        # come from ROOT/bin/lib, including on a historical behavioral baseline.
        source = (ROOT / 'tests/decide.test.sh').read_text().split('\nd="$(fixture)"',1)[0]
        source = source.replace('ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"','ROOT='+shlex.quote(str(ROOT)))
        result = subprocess.run(['bash','-c',source+'\nengine="$(fixture)"\nprintf "language: en\\n" > "$engine/config.yaml"\nproject_fixture_config "$engine" || exit $?\nprintf "%s\\n" "$engine"'],capture_output=True,text=True,check=True)
        self.root = Path(result.stdout.strip()); self.addCleanup(shutil.rmtree,self.root)
        self.addCleanup(shutil.rmtree,Path((self.root/'.fixture-fm-home').read_text().strip()))
        self.git('init','-q','-b','main','--object-format=sha1')
        self.git('config','user.name','Fixture'); self.git('config','user.email','fixture@example.test')
        from ste_cases import card, walk_card
        self.details = card()
        self.details['en']['title'] = 'MERGE CARD — merge PR #7: The check passes.'
        self.details['zh-TW']['title'] = '【合併卡】合併 PR #7：檢查通過。'
        fields = ('intent','why','scope_in','scope_out','done','notes','before_nodes','after_nodes','change_points','door','check')
        explain = {lang:{k:v for k,v in loc.items() if k in fields} for lang,loc in walk_card().items()}
        self.enriched = dict(id='T-242',scope=['src/**'],acceptance=['The check passes.'],explain=explain,
                             change_refs=[dict(files=['src/a.py'],tests=[dict(file='tests/a.py',name='test_a')],acceptance=[0])],check_answer=0)
        self.legacy = dict(id='T-242',scope=['src/**'],acceptance=['The check passes.'])
        self.write('design/design.md','Fixture design.\n')
        self.write('config.yaml','language: en\nproject:\n  setup: echo fixture\n  check: bin/ci.sh\n  tests:\n    - tests/**\n  test: bash {file}\n  docs:\n    - design/**\n')
        self.write('src/a.py','old\n'); self.write('tests/a.py','header\ndef test_a():\n    pass\n')
        self.commit_spec(self.legacy)
        self.base = self.head
        self.write('src/a.py','new\n')
        self.commit_spec(self.enriched)
        self.write('.fixture-diff',self.git('diff',self.base,self.head))
        self.request_number = 0
        self.env = dict(os.environ,FM_GH=str(self.root / 'gh'),FM_ROOT=str(self.root),HERDR_ENV='0')
        self.pin_env = dict(FM_ENGINE_ROOT=str(self.root),FM_TARGET_ROOT=str(self.root),FM_STATE_DIR=str(self.root/'state'),
                            FM_TASKS_DIR=str(self.root/'design/tasks'),FM_DESIGN=str(self.root/'design/design.md'),FM_PROJECT='',FM_EXTERNAL='0',FM_BASE='main')

    def write(self,file,text):
        path=self.root/file; path.parent.mkdir(parents=True,exist_ok=True); path.write_text(text)

    def git(self,*args):
        return subprocess.run(['git','-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-c','core.excludesFile=/dev/null',*args],cwd=self.root,capture_output=True,text=True,check=True).stdout

    def commit_spec(self,spec):
        self.write('design/tasks/T-242.json',json.dumps(spec)+'\n')
        self.git('add','design','config.yaml','src','tests')
        self.git('commit','-qm','fixture source')
        self.head=self.git('rev-parse','HEAD').strip()
        self.write('prs.jsonl',json.dumps(dict(number=7,state='OPEN',headRefOid=self.head,headRefName='t-242-fixture',title='T-242: fixture'))+'\n')

    def request(self,ident=None,details=None,kind='merge',purpose=None):
        if ident is None:
            self.request_number += 1
            ident = 'D-' + str(924200 + self.request_number)
        self.last_request_id = ident
        self.write('authored.json',json.dumps(self.details if details is None else details))
        argv=['bash',str(self.root/'bin/fm-decide.sh'),'--request',ident,'--kind',kind,
              '--details',str(self.root/'authored.json')]
        if kind != 'merge-untracked': argv += ['--task','T-242']
        if kind != 'choice': argv += ['--pr','7','--expected-head',self.head]
        if purpose: argv += ['--purpose',purpose]
        return subprocess.run(argv,cwd=self.root,env=self.env,capture_output=True,text=True)

    def pending(self,ident=None):
        ident = self.last_request_id if ident is None else ident
        return self.root/'state/pending'/ (ident+'.json')

    def test_stock_mixed_real_git_diff_preserves_listed_evidence(self):
        self.write('tool', 'executable content\n')
        self.git('add', 'tool'); self.git('commit', '-qm', 'fixture tool')
        for variant in ('mode', 'empty'):
            with self.subTest(variant=variant):
                if variant == 'mode': self.git('update-index', '--chmod=+x', 'tool')
                else: self.write('empty', ''); self.git('add', 'empty')
                self.git('commit', '-qm', 'fixture hunkless ' + variant)
                self.head = self.git('rev-parse', 'HEAD').strip()
                self.write('prs.jsonl', json.dumps(dict(number=7,state='OPEN',headRefOid=self.head,headRefName='t-242-fixture',title='T-242: fixture'))+'\n')
                # Whole PR includes the genuine text diff and hunkless entry.
                self.write('.fixture-diff', self.git('diff', self.base, self.head))
                result = self.request()
                self.assertEqual(0, result.returncode, result.stderr)
                doc = json.loads(self.pending().read_text())
                self.assertIn('change_points', doc['details']['en'])
                self.assertIn('refs', doc['details'])
                self.assertEqual('src/a.py', doc['details']['refs']['points'][0]['code'][0]['file'])
                self.assertEqual('new', doc['details']['refs']['points'][0]['code'][0]['snippet'])

    def test_no_pin_reads_committed_spec_and_ignores_mutable_file(self):
        self.write('design/tasks/T-242.json',json.dumps(self.legacy))
        result=self.request()
        self.assertEqual(0,result.returncode,result.stderr)
        doc=json.loads(self.pending().read_text())
        self.assertIn('change_points', doc['details']['en'])
        self.assertIn('refs', doc['details'])
        self.assertEqual(self.enriched['explain']['en']['change_points'],doc['details']['en']['change_points'])
        self.assertEqual(2,doc['details']['refs']['points'][0]['tests'][0]['line'])
        self.assertIn('/blob/'+self.head+'/',doc['details']['refs']['spec_url'])
        self.assertNotIn('check_answer',doc['details'])

    def test_legacy_card_needs_neither_helper_nor_repository_discovery(self):
        self.commit_spec(self.legacy)
        (self.root/'bin/lib/fm_card_refs.py').unlink(missing_ok=True)
        self.assertFalse((self.root/'bin/lib/fm_card_refs.py').exists())
        result=self.request(); self.assertEqual(0,result.returncode,result.stderr)
        doc=json.loads(self.pending().read_text())
        walk=doc['details'].pop('walk')
        self.assertEqual(dict(status='absent',head=self.head,reason='no local review'),walk)
        self.assertEqual(self.details,doc['details'])
        self.assertNotIn('check_answer',doc)
        calls=(self.root/'ghcalls').read_text()
        self.assertNotIn('repo view',calls)
        self.assertNotIn('pr diff',calls)

    def test_matching_authored_walk_is_preserved_and_refs_attached(self):
        from copy import deepcopy
        details=deepcopy(self.details)
        for lang in ('en','zh-TW'):
            for field in ('change_points','door','check'): details[lang][field]=deepcopy(self.enriched['explain'][lang][field])
        result=self.request(details=details); self.assertEqual(0,result.returncode,result.stderr)
        doc=json.loads(self.pending().read_text())
        for lang in ('en','zh-TW'):
            self.assertIn('change_points', doc['details'][lang])
            for field in ('change_points','door','check'): self.assertEqual(details[lang][field],doc['details'][lang][field])
        self.assertIn('refs',doc['details'])

    def test_each_exact_head_view_race_is_cardless(self):
        (self.root/'gh').rename(self.root/'gh-real')
        self.write('gh',r"""#!/usr/bin/env python3
import json, subprocess, sys
from pathlib import Path
root=Path(__file__).parent
if sys.argv[-2:] == ['--json','headRefOid']:
    counter=root/'race-views'
    n=int(counter.read_text())+1 if counter.exists() else 1
    counter.write_text(str(n))
    if n == int((root/'race-at').read_text()):
        print(json.dumps({'headRefOid':'b'*40})); sys.exit(0)
sys.exit(subprocess.call([str(root/'gh-real'),*sys.argv[1:]]))
""")
        (self.root/'gh').chmod(0o755)
        for view in (1,2):
            with self.subTest(view=view):
                self.write('race-at',str(view)); (self.root/'race-views').unlink(missing_ok=True)
                result=self.request()
                self.assertEqual(65,result.returncode,result.stderr)
                self.assertIn('head differs',result.stderr)
                self.assertFalse(self.pending().exists())
                self.assertEqual([], list((self.root/'state/pending').glob('*.json')))

    def test_author_mismatches_and_orphan_fields_refuse_without_card(self):
        from copy import deepcopy
        for field in ('intent','change_points','door','check'):
            with self.subTest(field=field):
                details=deepcopy(self.details)
                if field=='intent': details['en']['intent'][0]['text']='Different intent.'
                else: details['en'][field]={'different':'value'}
                result=self.request(details=details)
                self.assertEqual(65,result.returncode,result.stderr)
                self.assertIn(field,result.stderr)
                self.assertFalse(self.pending().exists())
                self.assertEqual([], list((self.root/'state/pending').glob('*.json')))
        missing=deepcopy(self.details)
        for lang in ('en','zh-TW'): missing[lang].pop('intent')
        result=self.request(details=missing)
        self.assertEqual(65,result.returncode)
        self.assertIn('author the intent card from the spec',result.stderr)
        self.assertFalse(self.pending().exists())
        self.assertEqual([], list((self.root/'state/pending').glob('*.json')))

    def test_nonmerge_kinds_refuse_every_walk_field(self):
        for kind,purpose in [('choice',None),('choice','dispatch'),('choice','repin'),('choice','scope'),('merge-untracked',None)]:
            for field in ('change_points','door','check'):
                with self.subTest(kind=kind,purpose=purpose,field=field):
                    details=json.loads(json.dumps(self.details)); details['en'][field]={}
                    result=self.request(details=details,kind=kind,purpose=purpose)
                    self.assertEqual(65,result.returncode,result.stderr)
                    self.assertFalse(self.pending().exists())
                    self.assertEqual([], list((self.root/'state/pending').glob('*.json')))

    def test_one_way_missing_answer_and_details_points_without_spec_points(self):
        malformed=dict(self.enriched); malformed.pop('check_answer')
        self.commit_spec(malformed)
        result=self.request(); self.assertEqual(65,result.returncode)
        self.assertFalse(self.pending().exists())
        self.assertEqual([], list((self.root/'state/pending').glob('*.json')))
        self.commit_spec(self.legacy)
        details=json.loads(json.dumps(self.details)); details['en']['change_points']=[dict(intent=1,how='The check passes.')]
        result=self.request(details=details); self.assertEqual(65,result.returncode)
        self.assertFalse(self.pending().exists())
        self.assertEqual([], list((self.root/'state/pending').glob('*.json')))

    def test_discovery_refusals_are_cardless_at_stock_boundary(self):
        original=(self.root/'gh').read_text()
        canonical='{"nameWithOwner":"owner/engine","url":"https://github.com/owner/engine"}'
        for url in ('https://evil.test/owner/engine','http://github.com/owner/engine',None,'https://github.com/other/engine'):
            with self.subTest(url=url):
                doc=json.dumps(dict(nameWithOwner='owner/engine',url=url))
                self.write('gh',original.replace(canonical,doc))
                (self.root/'ghcalls').unlink(missing_ok=True)
                result=self.request()
                self.assertEqual(65,result.returncode,result.stderr)
                self.assertIn('repository discovery',result.stderr)
                self.assertFalse(self.pending().exists())
                self.assertEqual([], list((self.root/'state/pending').glob('*.json')))
                calls=(self.root/'ghcalls').read_text().splitlines()
                discovery=next(i for i,line in enumerate(calls) if line.startswith('repo view'))
                self.assertEqual(discovery+1,len(calls))

    def test_schema_combinations_refuse_before_publication_and_two_way_succeeds(self):
        from copy import deepcopy
        mutations=[
            lambda s: s.pop('change_refs'),
            lambda s: s.update(change_refs=[]),
            lambda s: s['explain']['en'].pop('door'),
            lambda s: s['explain']['en'].pop('check'),
            lambda s: s['explain']['en']['check'].pop('about'),
            lambda s: s['explain']['en']['door'].update(rollback=''),
            lambda s: s['explain']['en']['change_points'][0].update(intent=True),
            lambda s: s['explain']['en']['change_points'][0].update(intent=2),
            lambda s: s['explain']['zh-TW']['door'].update(kind='two-way'),
            lambda s: s['change_refs'][0].update(acceptance=[1]),
            lambda s: s['change_refs'][0].update(acceptance=[True]),
            lambda s: s.update(check_answer=True),
            lambda s: s.update(check_answer=2),
            lambda s: s.update(check_answer=1),
            lambda s: s['explain']['zh-TW']['check']['options'].__setitem__(0,'不存在。'),
        ]
        for n,mutate in enumerate(mutations):
            with self.subTest(case=n):
                spec=deepcopy(self.enriched); mutate(spec); self.commit_spec(spec)
                result=self.request()
                self.assertEqual(65,result.returncode,result.stderr)
                self.assertFalse(self.pending().exists())
                self.assertEqual([], list((self.root/'state/pending').glob('*.json')))
        two=deepcopy(self.enriched); two.pop('check_answer')
        for loc in two['explain'].values(): loc['door']['kind']='two-way'; loc.pop('check')
        malformed=deepcopy(two); malformed['check_answer']=0; self.commit_spec(malformed)
        result=self.request(); self.assertEqual(65,result.returncode)
        self.assertFalse(self.pending().exists())
        self.assertEqual([], list((self.root/'state/pending').glob('*.json')))
        self.commit_spec(two)
        result=self.request(); self.assertEqual(0,result.returncode,result.stderr)
        doc=json.loads(self.pending().read_text())
        self.assertIn('change_points', doc['details']['en'])
        self.assertIn('refs', doc['details'])
        self.assertEqual('two-way',doc['details']['en']['door']['kind'])
        self.assertNotIn('check_answer',doc)
        self.assertNotIn('check',doc['details']['en'])

    def test_corrupt_pin_refuses_before_card(self):
        self.write('state/pins/T-242/1.json','{"schema":1}')
        result=self.request()
        self.assertEqual(65,result.returncode)
        self.assertFalse(self.pending().exists())
        self.assertEqual([], list((self.root/'state/pending').glob('*.json')))

    def test_external_no_pin_uses_private_spec_and_target_clone_cwd(self):
        home=Path((self.root/'.fixture-fm-home').read_text().strip()); workspace=home/'projects/beta'; target=workspace/'repo'
        target.parent.mkdir(parents=True)
        subprocess.run(['git','clone','--quiet','--local',str(self.root),str(target)],check=True,capture_output=True)
        private=json.loads(json.dumps(self.enriched))
        private['acceptance']=['Private authored /private/customer acceptance.']
        (workspace/'tasks').mkdir(parents=True)
        (workspace/'tasks/T-242.json').write_text(json.dumps(private))
        self.write('config.yaml','home: '+str(home)+'\ndefault_project: alpha\nprojects:\n  alpha:\n    repo: .\n    github: owner/engine\n    base: main\n    required_check: ci\n  beta:\n    github: owner/private\n    base: main\n    required_check: ci\n')
        # Record actual argv/cwd before executing the stock fixture gh reader.
        (self.root/'gh').rename(self.root/'gh-real')
        self.write('gh',r"""#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
root=Path(__file__).parent
with (root/'captured.jsonl').open('a') as out:
    out.write(json.dumps({'argv':sys.argv[1:],'cwd':os.getcwd()})+'\n')
sys.exit(subprocess.call([str(root/'gh-real'),*sys.argv[1:]]))
""")
        (self.root/'gh').chmod(0o755)
        self.env['FM_PROJECT']='beta'
        allocated=subprocess.run(['bash',str(self.root/'bin/fm-decide.sh'),'--allocate','--task','T-242','--kind','merge'],cwd=self.root,env=self.env,capture_output=True,text=True)
        self.assertEqual(0,allocated.returncode,allocated.stderr)
        self.assertEqual('D-beta-T242-1',allocated.stdout.strip())
        result=self.request(allocated.stdout.strip())
        self.assertEqual(0,result.returncode,result.stderr)
        doc=json.loads((workspace/'state/pending/D-beta-T242-1.json').read_text())
        self.assertIn('change_points', doc['details']['en'])
        self.assertIn('refs', doc['details'])
        self.assertIsNone(doc['details']['refs']['spec_url'])
        self.assertEqual(2,doc['details']['refs']['points'][0]['tests'][0]['line'])
        calls=[json.loads(line) for line in (self.root/'captured.jsonl').read_text().splitlines()]
        evidence=[call for call in calls if call['argv'][:2]==['pr','diff'] or call['argv'][-2:]==['--json','headRefOid']]
        self.assertEqual(3,len(evidence))
        for call in evidence: self.assertEqual(str(target),call['cwd'])
        self.assertFalse(any(call['argv'][0]=='repo' for call in calls))
        self.assertNotIn(str(home),json.dumps([call['argv'] for call in calls]))
        self.assertNotIn('Private authored',json.dumps(calls))
        for call in calls:
            self.assertEqual(['pr'],call['argv'][:1])
            self.assertIn(call['argv'][1],('view','diff'))
            self.assertEqual('owner/private',call['argv'][call['argv'].index('--repo')+1])
        for point in doc['details']['refs']['points']:
            for ref in point['code']+point['tests']:
                self.assertTrue(ref['url'].startswith('https://github.com/owner/private/'))
                self.assertNotIn(str(home),ref['url'])
        self.assertIn('Private authored',doc['details']['refs']['acceptance'][0])

    def test_old_pin_new_repin_and_pending_legacy_stays_legacy(self):
        from fm_spec_pins import Pins
        # Each authorization is a fixture record, not an approval of real work.
        self.git('reset','--soft',self.base)
        self.write('design/tasks/T-242.json',json.dumps(self.legacy)+'\n')
        self.git('reset','-q')
        self.head=self.base
        self.write('prs.jsonl',json.dumps(dict(number=7,state='OPEN',headRefOid=self.head,headRefName='t-242-fixture',title='T-242: fixture'))+'\n')
        event=dict(ts='2026-10-01T00:00:00Z',actor='captain',type='greenlit',task='T-242')
        self.write('state/events.jsonl',json.dumps(event)+'\n')
        pins=Pins(self.pin_env,'T-242')
        pins.create()
        self.write('design/tasks/T-242.json',json.dumps(self.enriched)+'\n')
        result=self.request(); self.assertEqual(0,result.returncode,result.stderr)
        old_path=self.pending()
        old=old_path.read_bytes()
        self.assertNotIn('change_points',json.loads(old)['details']['en'])
        self.commit_spec(self.enriched)
        decision=dict(id='D-fixture-repin',task='T-242',project='firstmate-workflow',chosen='A',kind='choice',ts='2026-10-02T00:00:00Z')
        self.write('state/decisions/D-fixture-repin.json',json.dumps(decision))
        event=dict(ts=decision['ts'],actor='captain',type='decision_made',task='T-242',data=dict(decision=decision['id'],chosen='A'))
        with (self.root/'state/events.jsonl').open('a') as out: out.write(json.dumps(event)+'\n')
        pins.create(decision='D-fixture-repin')
        result=self.request('D-9243'); self.assertEqual(0,result.returncode,result.stderr)
        self.assertIn('change_points',json.loads(self.pending('D-9243').read_text())['details']['en'])
        self.assertEqual(old,old_path.read_bytes())


class SyntheticMergeSource(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / 'bin').mkdir()
        (self.root / 'bin/fm-decide.sh').write_text('exit 23\n')
        script = '. "$1/tests/lib/project-storage.sh"; merge_source_fixture "$2"'
        subprocess.run(['bash', '-c', 'ROOT="$1"; ' + script, '_', str(ROOT), str(self.root)],
                       env=dict(os.environ, HERDR_ENV='1'), check=True, capture_output=True)
        self.real_git = shutil.which('git')
        self.git = str(self.root / 'fixture-tools/git')
        self.source = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:design/tasks/T-242.json'

    def test_exact_synthetic_read_and_authored_source(self):
        result = subprocess.run([self.git, '-C', str(self.root), 'show', self.source], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('T-242', json.loads(result.stdout)['id'])
        self.assertEqual(['-C', str(self.root), 'show', self.source],
                         (self.root / '.fixture-git-argv').read_bytes().decode().split('\0')[:-1])
        authored = '{"id":"T-242","acceptance":["Authored source."]}\n'
        (self.root / '.fixture-source.json').write_text(authored)
        result = subprocess.run([self.git, '-C', str(self.root), 'show', self.source], capture_output=True, text=True)
        self.assertEqual(authored, result.stdout)

    def test_nonmatching_requests_delegate_exactly_to_real_git(self):
        other = self.root / 'other' / self.root.name
        other.mkdir(parents=True)
        cases = [('-C', str(other), 'show', self.source),
                 ('-C', str(self.root), 'show', self.source.replace('T-242', '../T-242')),
                 ('-C', str(self.root), 'show', self.source.replace('T-242', 'T-x')),
                 ('-C', str(self.root), 'show', self.source, 'extra'),
                 ('-C', str(self.root), 'show', self.source.replace('aaaa', 'bbbb', 1)),
                 ('-C', str(self.root), 'rev-parse', '--is-inside-work-tree'),
                 ('show', self.source)]
        for args in cases:
            with self.subTest(args=args):
                got = subprocess.run([self.git, *args], cwd=self.root, capture_output=True)
                want = subprocess.run([self.real_git, *args], cwd=self.root, capture_output=True)
                self.assertEqual((want.returncode, want.stdout, want.stderr),
                                 (got.returncode, got.stdout, got.stderr))

    def test_external_preparation_preserves_existing_and_authored_source(self):
        tasks = self.root / 'private-tasks'
        (self.root / 'bin/fm-config.sh').write_text(
            'fm_storage_init() { FM_EXTERNAL=1; FM_TASKS_DIR=' + shlex.quote(str(tasks)) + '; }\n')
        authored = '{"id":"T-242","acceptance":["Private authored source."]}\n'
        (self.root / '.fixture-source.json').write_text(authored)
        args = ['bash', str(self.root / 'bin/fm-decide.sh'), '--request', 'D-123',
                '--task', 'T-242', '--kind', 'merge', '--project', 'private']
        result = subprocess.run(args, capture_output=True)
        self.assertEqual(23, result.returncode)
        self.assertEqual(authored, (tasks / 'T-242.json').read_text())
        (tasks / 'T-242.json').write_text('Existing private source.\n')
        subprocess.run(args, capture_output=True)
        self.assertEqual('Existing private source.\n', (tasks / 'T-242.json').read_text())

    def test_wrapper_preserves_exit_and_disables_inherited_notifications(self):
        (self.root / 'bin/fm-decide-real.sh').write_text(
            'printf "%s\\n" "$HERDR_ENV" "$@"; printf "fixture stderr\\n" >&2; exit 23\n')
        result = subprocess.run(['bash', str(self.root / 'bin/fm-decide.sh'), '--sentinel', 'value'],
                                env=dict(os.environ, HERDR_ENV='1'), capture_output=True, text=True)
        self.assertEqual(23, result.returncode)
        self.assertEqual('0\n--sentinel\nvalue\n', result.stdout)
        self.assertEqual('fixture stderr\n', result.stderr)


class NamedTestResult(unittest.TextTestResult):
    """Expose behavioral outcomes in the fail-first collector's line format."""
    def startTest(self, test):
        self._fm_failed = False
        self._fm_skipped = False
        super().startTest(test)

    def addFailure(self, test, err):
        self._fm_failed = True
        super().addFailure(test, err)

    def addError(self, test, err):
        self._fm_failed = True
        super().addError(test, err)

    def addSubTest(self, test, subtest, err):
        if err is not None:
            self._fm_failed = True
        super().addSubTest(test, subtest, err)

    def addSkip(self, test, reason):
        self._fm_skipped = True
        super().addSkip(test, reason)

    def stopTest(self, test):
        super().stopTest(test)
        if not self._fm_skipped:
            name = '%s.%s' % (type(test).__name__, test._testMethodName)
            sys.stdout.write('    %-52s %s\n' % (name, 'FAIL' if self._fm_failed else 'ok'))
            sys.stdout.flush()


if __name__ == '__main__':
    producer = '--producer' in sys.argv
    if producer: sys.argv.remove('--producer')
    cases = (StockRequests, SyntheticMergeSource) if producer else (CardRefs, ExecutableRefs, SyntheticMergeSource)
    loader = unittest.TestLoader()
    suite = unittest.TestSuite(loader.loadTestsFromTestCase(case) for case in cases)
    result = unittest.TextTestRunner(verbosity=2, resultclass=NamedTestResult).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
