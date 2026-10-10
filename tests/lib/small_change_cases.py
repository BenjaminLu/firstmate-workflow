"""T-277 small-change records; invoked by tests/small-change.test.sh.

Fail-first cases plant records by hand and drive entry points that exist on
the base: `fm_spec_pins.py scope`, `fm_prompt_context.py pin` and the
autopilot merge path. Classes named *Interface exercise the new command and
module; they are interface tests, not fail-first evidence. Classes named
*Regression pin behaviour the base already has; with no store they compare
the head against a copy of the head's `bin/` tree without
`bin/lib/fm_small_change.py`, as the copy fixtures run it. Only the migration
case runs the base commit's own `bin/`, read from git.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

# Never notify a live Herdr from a fixture that raises cards.
os.environ['HERDR_ENV'] = '0'

ROOT = Path(sys.argv[1])
sys.path.insert(0, str(ROOT / 'tests/lib'))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import autopilot_loop as fixture  # pops the root argument
import autopilot_merge_path as merge_path
from ste_cases import card
from fm_spec_pins import Pins
import fm_lifeline
from fm_merge_details import CAUTION

A, PR, HEAD, BASE, CHECKS = fixture.A, fixture.PR, fixture.HEAD, fixture.BASE, fixture.CHECKS
REASON = {'en': 'The suite needs one more case.', 'zh-TW': '測試套件需要多一個案例。'}
TITLE = 'Gates recieve the file'
ACCEPTANCE = ['The gate must recieve teh file.', 'Second line stays.', 'Third line stays.']
DELETE = object()


def run(*argv, **kwargs):
    return subprocess.run([str(a) for a in argv], capture_output=True, text=True, **kwargs)


def git(root, *args):
    result = run('git', '-C', root, *args)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.strip()


def clean_env(**extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
    env['HERDR_ENV'] = '0'
    env.update({k: str(v) for k, v in extra.items()})
    return env


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pin_sha(pin):
    return hashlib.sha256(json.dumps(pin, sort_keys=True).encode('utf-8')).hexdigest()


# The approved T-277 pin's target base: the newest main commit before T-277.
# Used only once the resolved base already carries T-277, after it merges.
PRE_T277 = 'a118b065d7931b2e72b34b0a0907f5c37bc806aa'


def fetched(sha):
    if run('git', '-C', ROOT, 'cat-file', '-e', sha + '^{commit}').returncode:
        git(ROOT, 'fetch', '--no-tags', '--depth=1', 'origin', sha)
    return sha


def base_commit():
    """The commit this branch merges onto, fetched when the checkout lacks it."""
    merged = run('git', '-C', ROOT, 'merge-base', 'HEAD', 'origin/main')
    if merged.returncode == 0:
        sha = merged.stdout.strip()
    else:
        # CI's depth-1 checkout is GitHub's pull request merge commit, without
        # origin/main. Its first parent is the base; the raw object names that
        # parent even when the parent itself was not fetched.
        header = git(ROOT, 'cat-file', '-p', 'HEAD').split('\n\n', 1)[0]
        parents = [line.split()[1] for line in header.splitlines() if line.startswith('parent ')]
        if len(parents) != 2:
            raise AssertionError('no base commit: origin/main is missing and HEAD is not a merge commit')
        sha = parents[0]
    fetched(sha)
    if run('git', '-C', ROOT, 'cat-file', '-e', sha + ':bin/lib/fm_small_change.py').returncode == 0:
        sha = fetched(PRE_T277)
    return sha


class Engine:
    """A self engine with a registry, a committed task and its first pin."""

    def make_engine(self, root, task, spec=None, files=None):
        self.root, self.task = Path(root), task
        self.project = 'alpha'
        if not (self.root / '.git').exists():
            git(self.root, 'init', '-q')
        git(self.root, 'symbolic-ref', 'HEAD', 'refs/heads/main')
        git(self.root, 'config', 'user.email', 'fixture@example.test')
        git(self.root, 'config', 'user.name', 'fixture')
        (self.root / '.git/info').mkdir(exist_ok=True)
        with (self.root / '.git/info/exclude').open('a') as stream:
            stream.write('/state/\n')
        tasks = self.root / 'design/tasks'
        tasks.mkdir(parents=True, exist_ok=True)
        self.spec_path = tasks / (task + '.json')
        self.spec = spec or dict(id=task, title=TITLE, acceptance=list(ACCEPTANCE),
                                 scope=['src/**', 'design/tasks/' + task + '.json'])
        self.spec_path.write_text(json.dumps(self.spec))
        (self.root / 'design/design.md').write_text('approved design\n')
        home = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, home, True)
        (self.root / 'config.yaml').write_text(
            f'home: {home}\ndefault_project: alpha\nprojects:\n  alpha:\n    repo: .\n'
            '    github: owner/alpha\n    base: main\n    required_check: ci\nproject:\n  check: true\n')
        added = ['design', 'config.yaml']
        for path, content in (files or {}).items():
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text(content)
            added.append(path)
        git(self.root, 'add', *added)
        git(self.root, 'commit', '-qm', 'approved base')
        self.state = self.root / 'state'
        self.state.mkdir(exist_ok=True)
        self.greenlit = dict(type='greenlit', ts='2026-10-03T00:00:00Z', actor='captain',
                             task=task, project='alpha')
        self.restore_approval()
        self.penv = dict(FM_ENGINE_ROOT=str(self.root), FM_TARGET_ROOT=str(self.root),
                         FM_STATE_DIR=str(self.state), FM_PROJECT='alpha', FM_EXTERNAL='0',
                         FM_TASKS_DIR=str(tasks), FM_DESIGN=str(self.root / 'design/design.md'))
        self.pin = Pins(self.penv, task).create()
        self.store = self.state / 'small-changes' / task

    def restore_approval(self):
        with (self.state / 'events.jsonl').open('a') as stream:
            stream.write(json.dumps(self.greenlit) + '\n')

    def pin_file(self, version):
        return json.loads((self.state / 'pins' / self.task / f'{version}.json').read_text())

    def record(self, n, previous, version=1, **changes):
        record = dict(schema=1, project='alpha', task=self.task, number=n, pin_version=version,
                      pin_sha256=pin_sha(self.pin_file(version)), kind='paths', reason=dict(REASON),
                      origin=dict(kind='worker-ask', ref='round 1 ask'), author='firstmate',
                      created='2026-10-09T16:00:00Z', previous_sha256=previous,
                      paths=['tests/a.test.sh'])
        if changes.get('kind') == 'erratum':
            record.pop('paths')
        for key, value in changes.items():
            if value is DELETE:
                record.pop(key, None)
            else:
                record[key] = value
        return record

    def erratum(self, n, previous, before, after, index=0, version=1, **changes):
        field = 'title' if index is None else 'acceptance'
        return self.record(n, previous, version, kind='erratum',
                           erratum=dict(field=field, index=index, before=before, after=after),
                           reason=dict(en='Fix a typo.', **{'zh-TW': '修正錯字。'}), **changes)

    def plant(self, *changes_list):
        """Write records in order, chaining previous_sha256 unless a case overrides it."""
        self.store.mkdir(parents=True, exist_ok=True)
        previous = None
        for n, item in enumerate(changes_list, 1):
            if callable(item):
                item = item(n, previous)
            data = item if isinstance(item, bytes) else (json.dumps(item, indent=2, ensure_ascii=False) + '\n').encode()
            (self.store / f'{n}.json').write_bytes(data)
            previous = sha(data)
        return previous

    def paths_record(self, **changes):
        return lambda n, previous: self.record(n, previous, **changes)

    def sha12(self, n):
        return sha((self.store / f'{n}.json').read_bytes())[:12]

    def cli(self, *args, **extra):
        return run('bash', ROOT / 'bin/fm-project.sh', 'small-change', '--repo', self.root,
                   '--project', 'alpha', '--task', self.task, *args, env=clean_env(**extra))

    def create(self, *args, origin='worker-ask', **extra):
        argv = ['--origin', origin, '--ref', 'round 1 ask', '--reason-en', REASON['en'],
                '--reason-tw', REASON['zh-TW'], *args]
        return self.cli(*argv, **extra)

    def decision(self, ident, ts):
        (self.state / 'decisions').mkdir(exist_ok=True)
        (self.state / 'decisions' / (ident + '.json')).write_text(json.dumps(dict(
            id=ident, project='alpha', task=self.task, chosen='A', kind='choice', ts=ts)))
        with (self.state / 'events.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(type='decision_made', ts=ts, actor='captain', project='alpha',
                                         task=self.task, data=dict(decision=ident, chosen='A'))) + '\n')

    def repin(self, spec, ident='D-2', ts='2026-10-03T00:02:00Z'):
        self.spec_path.write_text(json.dumps(spec))
        git(self.root, 'commit', '-qam', 'amended spec')
        self.decision(ident, ts)
        return Pins(self.penv, self.task).create(decision=ident)


class GateEngine(Engine):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name).resolve()  # pinned/ refuses symlinked parents such as /var
        (self.tmp / 'engine').mkdir()
        self.make_engine(self.tmp / 'engine', 'T-X', files={
            'tests/a.test.sh': ''.join(f'a{i}\n' for i in range(15)),
            'docs/b.md': ''.join(f'b{i}\n' for i in range(15))})

    def change(self, files):
        """Rebuild branch work from main with these file contents (None deletes)."""
        git(self.root, 'checkout', '-q', '-B', 'work', 'main')
        for path, content in files.items():
            target = self.root / path
            if content is None:
                target.unlink()
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(content, bytes):
                target.write_bytes(content)
            else:
                target.write_text(content)
        git(self.root, 'add', '-A')
        git(self.root, 'commit', '-qm', 'work', '--allow-empty')
        git(self.root, 'checkout', '-q', 'main')

    def grow(self, path, lines):
        base = (self.root / path).read_text()
        return base + ''.join(f'new{i}\n' for i in range(lines))

    def shrink(self, path, lines):
        return ''.join((self.root / path).read_text().splitlines(True)[lines:])

    def gate(self, script=None, **extra):
        env = clean_env(**self.penv, **extra)
        if script is not None:
            # The copy's own lib, never the head's: a head module on the path would
            # silently turn the baseline back into the head.
            env['PYTHONPATH'] = str(Path(script).parent)
        return run(sys.executable, script or ROOT / 'bin/lib/fm_spec_pins.py', 'scope', '--task', self.task,
                   '--head', 'work', '--base', 'main', env=env)

    def prompt(self, role, script=None, **extra):
        pin = run(sys.executable, ROOT / 'bin/lib/fm_spec_pins.py', 'resolve', '--task', self.task,
                  env=clean_env(**self.penv))
        self.assertEqual(pin.returncode, 0, pin.stderr)
        env = clean_env(**self.penv, FM_PINNED_DIR=self.tmp / 'run' / 'pinned', **extra)
        if script is not None:
            env['PYTHONPATH'] = str(ROOT / 'bin/lib')
        return run(sys.executable, script or ROOT / 'bin/lib/fm_prompt_context.py', 'pin', role,
                   input=pin.stdout, env=env)

    def base_copy(self, name):
        # Not the git base: the head's own bin/ without fm_small_change.py, as
        # the copy fixtures run it. Equal output shows the head never needs the
        # new module when no store exists.
        folder = self.tmp / 'no-small-change'
        if not folder.exists():
            shutil.copytree(ROOT / 'bin', folder / 'bin',
                            ignore=shutil.ignore_patterns('fm_small_change.py', '__pycache__'))
        return folder / 'bin/lib' / name

    def old_code_copy(self):
        # The base commit's bin/ (git archive), with its fm_spec_pins.py read by
        # git show: frozen pre-T-277 gate code, and the code a revert restores.
        sha = base_commit()
        folder = self.tmp / 'old-code'
        if not folder.exists():
            folder.mkdir()
            archive = subprocess.run(['git', '-C', str(ROOT), 'archive', sha, 'bin'], capture_output=True)
            self.assertEqual(archive.returncode, 0, archive.stderr)
            tar = subprocess.run(['tar', '-x', '-C', str(folder)], input=archive.stdout, capture_output=True)
            self.assertEqual(tar.returncode, 0, tar.stderr)
            shown = subprocess.run(['git', '-C', str(ROOT), 'show', sha + ':bin/lib/fm_spec_pins.py'],
                                   capture_output=True)
            self.assertEqual(shown.returncode, 0, shown.stderr)
            (folder / 'bin/lib/fm_spec_pins.py').write_bytes(shown.stdout)
            self.assertFalse((folder / 'bin/lib/fm_small_change.py').exists(), 'base must predate T-277')
        return folder / 'bin/lib/fm_spec_pins.py'

    def assert_refused(self, needle, result=None):
        result = result or self.gate()
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertIn(needle, result.stderr)


class Gate3(GateEngine, unittest.TestCase):
    def test_gate_accepts_test_file_listed_in_planted_valid_record(self):
        # Fail-first: the base refuses with "out of scope: tests/a.test.sh".
        self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 5)})
        self.assert_refused('out of scope: tests/a.test.sh')
        self.plant(self.paths_record())
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), self.pin)

    def test_unrecorded_path_and_fm_path_stay_refused_with_a_record(self):
        self.plant(self.paths_record())
        self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 1), 'tests/other.sh': 'x\n'})
        self.assert_refused('out of scope: tests/other.sh')
        self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 1), 'tests/.fm-say.md': 'x\n'})
        self.assert_refused('forbidden .fm-* path: tests/.fm-say.md')

    def test_budget_counts_total_lines_across_record_paths(self):
        self.plant(self.paths_record(paths=['tests/a.test.sh', 'docs/b.md']))
        for files, code, needle in (
                ({'tests/a.test.sh': self.grow('tests/a.test.sh', 12), 'docs/b.md': self.grow('docs/b.md', 8)}, 0, ''),
                ({'tests/a.test.sh': self.grow('tests/a.test.sh', 11), 'docs/b.md': self.grow('docs/b.md', 10)}, 65,
                 'small-change budget exceeded: +21 -0 (limit +20 -20)'),
                ({'tests/a.test.sh': self.shrink('tests/a.test.sh', 10), 'docs/b.md': self.shrink('docs/b.md', 10)}, 0, ''),
                ({'tests/a.test.sh': self.shrink('tests/a.test.sh', 11), 'docs/b.md': self.shrink('docs/b.md', 10)}, 65,
                 'small-change budget exceeded: +0 -21 (limit +20 -20)')):
            with self.subTest(needle=needle or 'within budget'):
                self.change(files)
                result = self.gate()
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertIn(needle, result.stderr)

    def test_binary_record_path_is_refused(self):
        self.plant(self.paths_record(paths=['tests/blob.bin']))
        self.change({'tests/blob.bin': b'\0\1\2binary\0'})
        self.assert_refused('small-change path is binary: tests/blob.bin')

    def invalid(self, *items, needle='invalid small-change record'):
        self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 2)})
        self.plant(*items)
        self.assert_refused(needle)

    def test_gate_refuses_invalid_records(self):
        cases = {
            'bin path': dict(paths=['bin/fm-gate.sh']),
            'glob path': dict(paths=['tests/*.sh']),
            'already in scope': dict(paths=['src/a.py']),
            'six paths': dict(paths=[f'tests/{i}.sh' for i in range(6)]),
            'long path': dict(paths=['tests/' + 'x' * 200]),
            'fm path': dict(paths=['tests/.fm-say.md']),
            'extra key': dict(extra='x'),
            'missing key': dict(author=DELETE),
            'wrong project': dict(project='beta'),
            'wrong task': dict(task='T-Y'),
            'number string': dict(number='1'),
            'number boolean': dict(number=True),
            'pin_version string': dict(pin_version='1'),
            'pin_version boolean': dict(pin_version=True),
            'malformed created': dict(created='2026-10-09 16:00'),
            'local created': dict(created='2026-10-09T16:00:00'),
            'unknown origin': dict(origin=dict(kind='worker', ref='x')),
            'empty origin ref': dict(origin=dict(kind='firstmate', ref='')),
            'pin_version above latest': dict(pin_version=2),
            'pin_sha256 matches no version': dict(pin_sha256='f' * 64),
            'author': dict(author='worker'),
            'reason shape': dict(reason=dict(en='x')),
            'schema': dict(schema=2),
        }
        for name, changes in cases.items():
            with self.subTest(name=name):
                shutil.rmtree(self.store, ignore_errors=True)
                if name == 'pin_version above latest':
                    changes = dict(changes, pin_sha256=pin_sha(self.pin))
                self.invalid(lambda n, p, c=changes: self.record(n, p, **c))

    def test_gate_refuses_invalid_errata(self):
        cases = {
            'title erratum with integer index': lambda n, p: self.record(n, p, kind='erratum', erratum=dict(
                field='title', index=0, before=TITLE, after='Gates receive the file')),
            'acceptance null index': lambda n, p: self.record(n, p, kind='erratum', erratum=dict(
                field='acceptance', index=None, before=ACCEPTANCE[0], after='The gate must receive teh file.')),
            'acceptance boolean index': lambda n, p: self.record(n, p, kind='erratum', erratum=dict(
                field='acceptance', index=False, before=ACCEPTANCE[0], after='The gate must receive teh file.')),
            'acceptance negative index': lambda n, p: self.record(n, p, kind='erratum', erratum=dict(
                field='acceptance', index=-1, before=ACCEPTANCE[2], after='Third line stayz.')),
            'acceptance out of range': lambda n, p: self.record(n, p, kind='erratum', erratum=dict(
                field='acceptance', index=3, before='x', after='y')),
            'stale before': lambda n, p: self.erratum(n, p, 'The gate must recieve the file.',
                                                      'The gate must receive the file.'),
            'meaning change': lambda n, p: self.erratum(n, p, ACCEPTANCE[0], 'The gate may recieve teh file.'),
        }
        for name, item in cases.items():
            with self.subTest(name=name):
                shutil.rmtree(self.store, ignore_errors=True)
                self.invalid(item)

    def test_gate_refuses_broken_store_structure(self):
        good = self.paths_record()
        cases = {
            'fourth record for one pin': ([good] * 4, 'more than 3 records'),
            'numbering gap': (None, 'numbering gap'),
            'file name disagrees with number': ([self.paths_record(number=2)], 'number does not match'),
            'broken previous chain': ([good, self.paths_record(previous_sha256='0' * 64)], 'previous_sha256'),
            'first record with previous': ([self.paths_record(previous_sha256='0' * 64)], 'previous_sha256'),
        }
        for name, (items, needle) in cases.items():
            with self.subTest(name=name):
                shutil.rmtree(self.store, ignore_errors=True)
                if items is None:
                    self.plant(good)
                    (self.store / '1.json').rename(self.store / '2.json')
                    self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 2)})
                    self.assert_refused(needle)
                else:
                    self.invalid(*items, needle=needle)

    def test_gate_refuses_symlinked_store_parts(self):
        elsewhere = self.tmp / 'elsewhere'
        for name in ('record file', 'record directory', 'lock file'):
            with self.subTest(name=name):
                shutil.rmtree(self.store, ignore_errors=True)
                if self.store.is_symlink():
                    self.store.unlink()
                shutil.rmtree(elsewhere, ignore_errors=True)
                elsewhere.mkdir()
                self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 2)})
                self.plant(self.paths_record())
                if name == 'record file':
                    shutil.move(self.store / '1.json', elsewhere / '1.json')
                    (self.store / '1.json').symlink_to(elsewhere / '1.json')
                elif name == 'record directory':
                    shutil.rmtree(elsewhere)
                    shutil.move(self.store, elsewhere)
                    self.store.symlink_to(elsewhere, target_is_directory=True)
                else:
                    (elsewhere / 'lock').write_text('')
                    (self.store / '.lock').symlink_to(elsewhere / 'lock')
                self.assert_refused('symlink')

    def test_two_errata_chain_in_record_order(self):
        first = 'The gate must receive teh file.'
        final = 'The gate must receive the file.'
        self.plant(lambda n, p: self.erratum(n, p, ACCEPTANCE[0], first),
                   lambda n, p: self.erratum(n, p, first, final))
        self.change({'src/a.py': 'x\n'})
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        shutil.rmtree(self.store)
        self.plant(lambda n, p: self.erratum(n, p, ACCEPTANCE[0], first),
                   lambda n, p: self.erratum(n, p, ACCEPTANCE[0], 'The gate must recieve the file.'))
        self.assert_refused('erratum before is not the current wording')

    def test_repin_returns_task_to_new_pinned_scope(self):
        self.plant(self.paths_record())
        self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 2)})
        self.assertEqual(self.gate().returncode, 0)
        self.repin(dict(self.spec, scope=self.spec['scope'] + ['lib/**']))
        self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 2)})
        self.assert_refused('out of scope: tests/a.test.sh')

    def test_folded_repin_keeps_old_records_valid_and_restarts_limit(self):
        fixed = 'The gate must receive teh file.'
        self.plant(self.paths_record(),
                   lambda n, p: self.erratum(n, p, ACCEPTANCE[0], fixed))
        folded = dict(self.spec, scope=self.spec['scope'] + ['tests/a.test.sh'],
                      acceptance=[fixed] + ACCEPTANCE[1:])
        second = self.repin(folded)
        self.assertEqual(second['version'], 2)
        self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 40)})
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        new = [lambda n, p, path=path: self.record(n, p, version=2, paths=[path])
               for path in ('tests/b.sh', 'tests/c.sh', 'docs/d.md')]
        shutil.rmtree(self.store)
        self.plant(self.paths_record(), lambda n, p: self.erratum(n, p, ACCEPTANCE[0], fixed), *new)
        self.change({'tests/b.sh': 'b\n', 'tests/c.sh': 'c\n', 'docs/d.md': 'd\n'})
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        for extra, needle in (
                (lambda n, p: self.record(n, p, version=2, paths=['tests/e.sh']), 'more than 3 records'),
                (lambda n, p: self.record(n, p, version=2, pin_sha256=pin_sha(self.pin), paths=['tests/e.sh']),
                 'pin_sha256 does not match')):
            with self.subTest(needle=needle):
                shutil.rmtree(self.store)
                items = [self.paths_record(), lambda n, p: self.erratum(n, p, ACCEPTANCE[0], fixed)]
                items += new if needle == 'more than 3 records' else []
                self.plant(*items, extra)
                self.assert_refused(needle)


class Prompts(GateEngine, unittest.TestCase):
    def test_worker_and_reviewer_prompts_show_records(self):
        # Fail-first: the base prints no small-changes section.
        fixed = 'The gate must receive teh file.'
        final = 'The gate must receive the file.'
        self.plant(self.paths_record(), lambda n, p: self.erratum(n, p, ACCEPTANCE[0], fixed),
                   lambda n, p: self.erratum(n, p, fixed, final))
        for role in ('worker', 'reviewer'):
            with self.subTest(role=role):
                result = self.prompt(role)
                self.assertEqual(result.returncode, 0, result.stderr)
                out = result.stdout
                self.assertIn('\n# Small changes recorded for this pin\n', out)
                start = out.index('# Small changes recorded for this pin')
                self.assertLess(out.index('# Design section anchors'), start)
                self.assertLess(start, out.index('# Approved CONVENTIONS.md'))
                section = out[start:out.index('# Approved CONVENTIONS.md')]
                self.assertIn(f'Record 1 (sha256 {self.sha12(1)})', section)
                self.assertIn('`tests/a.test.sh`', section)
                self.assertIn('in addition to the scope list', section)
                self.assertIn('+20 -20', section)
                self.assertIn(REASON['en'], section)
                self.assertIn('acceptance:0', section)
                self.assertIn('Corrected wording: ' + final, section)
                self.assertLess(section.index('Corrected wording: ' + fixed), section.index('Corrected wording: ' + final))
                self.assertIn('The corrected wording is the meaning; the pinned bytes are unchanged.', section)
                line = f'SMALL-CHANGE-CHECKED:T-X 1 {self.sha12(1)}'
                self.assertEqual(line in section, role == 'reviewer')

    def test_records_for_an_older_pin_leave_the_prompt_unchanged(self):
        self.plant(self.paths_record())
        self.repin(dict(self.spec, scope=self.spec['scope'] + ['lib/**']))
        result = self.prompt('worker')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('# Small changes', result.stdout)


class PromptRegression(GateEngine, unittest.TestCase):
    """Regression: without records the prompt is byte-for-byte the prompt of the head's
    bin/ copied without fm_small_change.py (base_copy), so no record code runs."""

    def test_no_store_and_empty_store_match_base_output(self):
        base = self.base_copy('fm_prompt_context.py')
        expected = self.prompt('reviewer', script=base)
        self.assertEqual(expected.returncode, 0, expected.stderr)
        self.assertEqual(self.prompt('reviewer').stdout, expected.stdout)
        self.store.mkdir(parents=True)
        self.assertEqual(self.prompt('reviewer').stdout, expected.stdout)
        self.assertEqual(self.prompt('worker').stdout, self.prompt('worker', script=base).stdout)


class GateRegression(GateEngine, unittest.TestCase):
    """Regression: gate 3 without a record store gives exactly the output of the head's
    bin/ copied without fm_small_change.py (base_copy), and today's refusal text."""

    def test_without_store_matches_base(self):
        base = self.base_copy('fm_spec_pins.py')
        for files in ({'tests/a.test.sh': self.grow('tests/a.test.sh', 1)},
                      {'src/.fm-say.md': 'x\n'}, {'src/a.py': 'x\n'}):
            with self.subTest(files=list(files)):
                self.change(files)
                new, old = self.gate(), self.gate(script=base)
                self.assertEqual((new.returncode, new.stdout, new.stderr), (old.returncode, old.stdout, old.stderr))
        self.change({'tests/a.test.sh': 'x\n'})
        self.assertEqual(self.gate().stderr, 'fm-pin: out of scope: tests/a.test.sh\n')

    def test_copied_pin_module_without_new_module_keeps_working(self):
        # Copy fixtures such as tests/lib/autopilot_entrypoints.py copy pins without fm_small_change.
        lib = self.base_copy('fm_spec_pins.py').parent
        self.assertFalse((lib / 'fm_small_change.py').exists())
        self.change({'src/a.py': 'x\n'})
        result = run(sys.executable, lib / 'fm_spec_pins.py', 'scope', '--task', 'T-X', '--head', 'work',
                     '--base', 'main', env=clean_env(**self.penv))
        self.assertEqual(result.returncode, 0, result.stderr)
        result = run(sys.executable, lib / 'fm_spec_pins.py', 'resolve', '--task', 'T-X', env=clean_env(**self.penv))
        self.assertEqual(json.loads(result.stdout), self.pin)

    def test_verdict_readers_ignore_checked_lines(self):
        from fm_evidence import criteria, protocol
        body = '1. **open** Fix the case.\n2. **done** Keep the name.\nCRITERIA-COMPLETE:T-X\nREJECT:T-X'
        marked = 'SMALL-CHANGE-CHECKED:T-X 1 0123456789ab\nSMALL-CHANGE-CHECKED:T-X 2 ba9876543210\n\n' + body
        self.assertEqual(criteria(marked, 'T-X'), criteria(body, 'T-X'))
        records = lambda text: [dict(kind='verdict', verdict='REJECT', text=text)]
        self.assertEqual(protocol(records(marked), 'T-X'), protocol(records(body), 'T-X'))
        self.assertEqual(len(criteria(marked, 'T-X')), 2)


class CommandInterface(GateEngine, unittest.TestCase):
    """Interface tests: the subcommand does not exist on the base."""

    def test_writes_and_prints_each_kind(self):
        events = (self.state / 'events.jsonl').read_bytes()
        result = self.create('--path', 'tests/a.test.sh', '--path', 'docs/new.md')
        self.assertEqual(result.returncode, 0, result.stderr)
        printed = json.loads(result.stdout)
        stored = json.loads((self.store / '1.json').read_text())
        self.assertEqual(printed, stored)
        self.assertEqual(stored['paths'], ['tests/a.test.sh', 'docs/new.md'])
        self.assertEqual((stored['pin_version'], stored['pin_sha256']), (1, pin_sha(self.pin)))
        self.assertEqual(stored['author'], 'firstmate')
        self.assertIsNone(stored['previous_sha256'])
        result = self.cli('--origin', 'firstmate', '--ref', 'own reading', '--reason-en', 'Fix a typo.',
                          '--reason-tw', '修正錯字。', '--erratum', 'title', '--after', 'Gates receive the file')
        self.assertEqual(result.returncode, 0, result.stderr)
        erratum = json.loads(result.stdout)
        self.assertEqual(erratum['erratum'], dict(field='title', index=None, before=TITLE,
                                                  after='Gates receive the file'))
        self.assertEqual(erratum['previous_sha256'], sha((self.store / '1.json').read_bytes()))
        result = self.cli('--origin', 'review-finding', '--ref', 'round 2', '--reason-en', 'Fix a typo.',
                          '--reason-tw', '修正錯字。', '--erratum', 'acceptance:0', '--after',
                          'The gate must receive teh file.')
        self.assertEqual(result.returncode, 0, result.stderr)
        # No event and no card.
        self.assertEqual((self.state / 'events.jsonl').read_bytes(), events)
        self.assertFalse((self.state / 'pending').exists())
        self.assertEqual(json.loads(self.spec_path.read_text()), self.spec)
        self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 3)})
        self.assertEqual(self.gate().returncode, 0)

    def test_malformed_arguments_exit_64(self):
        good = ['--origin', 'firstmate', '--ref', 'r', '--reason-en', REASON['en'], '--reason-tw', REASON['zh-TW']]
        for name, argv in {
                'unknown option': good + ['--path', 'tests/x.sh', '--force', 'yes'],
                'missing origin': good[2:] + ['--path', 'tests/x.sh'],
                'missing reason-en': good[:4] + good[6:] + ['--path', 'tests/x.sh'],
                'both path and erratum': good + ['--path', 'tests/x.sh', '--erratum', 'title', '--after', 'x'],
                'neither': good,
                'unknown origin kind': ['--origin', 'captain'] + good[2:] + ['--path', 'tests/x.sh']}.items():
            with self.subTest(name=name):
                self.assertEqual(self.cli(*argv).returncode, 64)
        result = run('bash', ROOT / 'bin/fm-project.sh', 'small-change', '--repo', self.root,
                     *good, '--path', 'tests/x.sh', env=clean_env())
        self.assertEqual(result.returncode, 64, 'missing --task')
        # The shell picks storage from exact option names; Python must refuse
        # every form the shell would read differently, before storage init.
        task = ['--task', self.task]
        for name, argv in {
                'missing project': task + good + ['--path', 'tests/a.test.sh'],
                'abbreviated project': ['--proj', 'alpha'] + task + good + ['--path', 'tests/a.test.sh'],
                'abbreviated reason-en': ['--project', 'alpha'] + task + good[:4] + ['--reason-e', 'x']
                + good[6:] + ['--path', 'tests/a.test.sh'],
                'abbreviated path': ['--project', 'alpha'] + task + good + ['--pa', 'tests/a.test.sh'],
                'joined value': ['--project=alpha'] + task + good + ['--path', 'tests/a.test.sh']}.items():
            with self.subTest(name=name):
                result = run('bash', ROOT / 'bin/fm-project.sh', 'small-change', '--repo', self.root, *argv,
                             env=clean_env())
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertFalse(self.store.exists())
        result = self.create('--path', 'tests/x.sh', FM_EXTERNAL='1')
        self.assertEqual(result.returncode, 64)
        self.assertIn('small-change tier is self-project only; use the full process', result.stderr)
        self.assertFalse(self.store.exists())

    def test_refusals_exit_65(self):
        result = self.create('--path', 'tests/x.sh', FM_IN_ROUND='1')
        self.assertEqual(result.returncode, 65)
        for name, argv in {
                'bin path': ['--path', 'bin/fm-gate.sh'], 'glob': ['--path', 'tests/*.sh'],
                'in scope': ['--path', 'src/a.py'], 'dotdot': ['--path', 'tests/../bin/x'],
                'leading slash': ['--path', '/tests/x'], 'fm part': ['--path', 'tests/.fm-x'],
                'design': ['--path', 'design/tasks/T-Y.json'], 'long': ['--path', 'tests/' + 'x' * 200],
                'six paths': [a for i in range(6) for a in ('--path', f'tests/{i}.sh')],
                'meaning erratum': ['--erratum', 'acceptance:0', '--after', 'The gate must not recieve teh file.'],
                'four words': ['--erratum', 'acceptance:0', '--after', 'Teh gaet mustt recieve the file.'],
                'out of range': ['--erratum', 'acceptance:7', '--after', 'x']}.items():
            with self.subTest(name=name):
                result = self.create(*argv)
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertEqual(len(result.stderr.strip().splitlines()), 1)
        for name, en, tw in (('long en', 'a' * 201, REASON['zh-TW']), ('long tw', REASON['en'], '字' * 121),
                             ('STE en', 'It will ensure some coverage.', REASON['zh-TW']),
                             ('STE tw', REASON['en'], '這個案例將會被檢查。')):
            with self.subTest(name=name):
                result = self.cli('--origin', 'firstmate', '--ref', 'r', '--reason-en', en, '--reason-tw', tw,
                                  '--path', 'tests/x.sh')
                self.assertEqual(result.returncode, 65, result.stderr)
        self.assertFalse(list(self.store.glob('*.json')) if self.store.exists() else [])
        for n in range(3):
            self.assertEqual(self.create('--path', f'tests/{n}.sh').returncode, 0)
        fourth = self.create('--path', 'tests/3.sh')
        self.assertEqual(fourth.returncode, 65)
        self.assertIn('use the full process', fourth.stderr)

    def test_pending_merge_card_refuses(self):
        (self.state / 'pending').mkdir()
        (self.state / 'pending/D-alpha-TX-1.json').write_text(json.dumps(dict(
            id='D-alpha-TX-1', kind='merge', task='T-X', project='alpha')))
        result = self.create('--path', 'tests/x.sh')
        self.assertEqual(result.returncode, 65)
        self.assertIn('a merge card is pending; let the captain answer it first', result.stderr)
        self.assertFalse(self.store.exists())


class TypoGuardInterface(unittest.TestCase):
    """Interface tests: the module does not exist on the base."""

    def test_guard(self):
        from fm_small_change import typo_refusal
        for before, after in (('We recieve it.', 'We receive it.'), ('teh file', 'the file')):
            self.assertEqual(typo_refusal(before, after), '', (before, after))
        for name, before, after in (
                ('number', 'Keep 3 items.', 'Keep 4 items.'),
                ('path', 'Read bin/a now.', 'Read bin/b now.'),
                ('code span', 'Run `fm-gate` now.', 'Run `fm-gaet` now.'),
                ('task ID', 'See T-ab here.', 'See T-ac here.'),
                ('hash', 'Commit deadbeef here.', 'Commit deadbeee here.'),
                ('prefix', 'A valid case.', 'A invalid case.'),
                ('suffix', 'The use case.', 'The user case.'),
                ('meaning word', 'It must pass.', 'It may pass.'),
                ('add not', 'It passes.', 'It not passes.'),
                ('remove not', 'It does not pass.', 'It does pass.'),
                ('word count', 'One two.', 'One two three.'),
                ('whitespace', 'One two.', 'One  two.'),
                ('four words', 'teh gaet recieve teh', 'the gate receive the')):
            with self.subTest(name=name):
                self.assertNotEqual(typo_refusal(before, after), '')


class Migration(GateEngine, unittest.TestCase):
    def test_existing_task_gains_record_without_repin_and_base_code_ignores_it(self):
        from fm_evidence import Store
        store = Store(self.state, 'alpha', 'T-X', external=False)
        store.append('spec-preflight', 1, 'reviewer-preflight', 'c' * 40, '1. Clear spec.\nSPEC-OK:T-X',
                     spec_sha256=sha(self.spec_path.read_bytes()), verdict='SPEC-OK',
                     provenance={'level': 'legacy', 'vendor': 'claude'})
        store.append('verdict', 1, 'reviewer', 'c' * 40, 'APPROVE:T-X', verdict='APPROVE',
                     provenance={'level': 'legacy'})
        self.decision('D-1', '2026-10-03T00:01:00Z')
        watched = [self.state / 'pins/T-X/1.json', self.state / 'decisions/D-1.json',
                   *sorted(store.directory.glob('*.json'))]
        before = {p: p.read_bytes() for p in watched}
        result = self.create('--path', 'tests/a.test.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 4)})
        self.assertEqual(self.gate().returncode, 0)
        self.assertEqual({p: p.read_bytes() for p in watched}, before)
        self.assertEqual(sorted(p.name for p in (self.state / 'pins/T-X').glob('*.json')), ['1.json'])
        records = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.store.iterdir()}
        old = self.gate(script=self.old_code_copy())
        self.assertEqual(old.returncode, 65)
        self.assertIn('out of scope: tests/a.test.sh', old.stderr)
        self.assertEqual({p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.store.iterdir()}, records)


class ExternalIsolation(GateEngine, unittest.TestCase):
    SENTINEL = 'PRIVATE-T277-SENTINEL'

    def external_pin(self):
        home = self.tmp / 'private/projects/client'
        self.xstate = home / 'state'
        (home / 'tasks').mkdir(parents=True)
        self.xstate.mkdir()
        (home / 'tasks/T-X.json').write_text('{"id":"T-X","scope":["src/**"]}')
        (home / 'design.md').write_text('private design')
        (home / 'CONVENTIONS.md').write_text('private conventions')
        (self.xstate / 'config.yaml').write_text('project:\n  check: private-check\n')
        (self.xstate / 'decisions').mkdir()
        (self.xstate / 'decisions/D-1.json').write_text(json.dumps(dict(
            id='D-1', project='client', task='T-X', chosen='A', kind='choice', ts='2026-10-03T00:01:00Z')))
        (self.xstate / 'events.jsonl').write_text(json.dumps(dict(
            type='decision_made', ts='2026-10-03T00:01:00Z', actor='captain', project='client', task='T-X',
            data=dict(decision='D-1', chosen='A'))) + '\n')
        (self.xstate / 'ready').mkdir()
        (self.xstate / 'ready/T-X.json').write_text(json.dumps(dict(
            task='T-X', decision='D-1', episode='@-1/-1', judged_at='2026-10-03T00:00:00Z')))
        self.xenv = dict(self.penv, FM_EXTERNAL='1', FM_PROJECT='client', FM_STATE_DIR=str(self.xstate),
                         FM_TASKS_DIR=str(home / 'tasks'), FM_DESIGN=str(home / 'design.md'))
        Pins(self.xenv, 'T-X').create()

    def external_records(self):
        # Valid for the external pin: its real digest and a previous_sha256 chain.
        digest = pin_sha(json.loads((self.xstate / 'pins/T-X/1.json').read_text()))
        records, previous = [], None
        for n, path in enumerate(('tests/a.test.sh', 'docs/b.md'), 1):
            data = (json.dumps(dict(
                schema=1, project='client', task='T-X', number=n, pin_version=1, pin_sha256=digest,
                kind='paths', reason=dict(en=self.SENTINEL, **{'zh-TW': self.SENTINEL}),
                origin=dict(kind='firstmate', ref=self.SENTINEL), author='firstmate',
                created='2026-10-09T16:00:00Z', previous_sha256=previous, paths=[path]),
                indent=2) + '\n').encode()
            records.append(data)
            previous = sha(data)
        return records

    def test_external_fixture_records_are_valid_for_their_pin(self):
        # The fixture's valid form passes every store check against the
        # external pin chain, called directly; no reader ever does this.
        self.external_pin()
        store = self.xstate / 'small-changes/T-X'
        store.mkdir(parents=True)
        for n, data in enumerate(self.external_records(), 1):
            (store / f'{n}.json').write_bytes(data)
        import fm_small_change
        chain = Pins(self.xenv, 'T-X').chain()
        entries = fm_small_change.bound(fm_small_change.load(self.xstate, 'client', 'T-X', chain), chain[-1])
        self.assertEqual([r['paths'] for r, _ in entries], [['tests/a.test.sh'], ['docs/b.md']])

    def snapshot(self, root):
        found = {}
        for path in sorted(Path(root).rglob('*')):
            info = os.lstat(path)
            found[str(path)] = (info.st_mtime_ns, path.read_bytes() if path.is_file() and not path.is_symlink() else None)
        return found

    def test_external_readers_never_touch_store(self):
        self.external_pin()
        store = self.xstate / 'small-changes/T-X'
        private = self.tmp / 'private-elsewhere'
        valid = self.external_records()
        self.change({'tests/a.test.sh': self.grow('tests/a.test.sh', 1)})
        for form in ('valid', 'corrupt', 'symlink'):
            with self.subTest(form=form):
                if store.is_symlink():
                    store.unlink()
                shutil.rmtree(store, ignore_errors=True)
                shutil.rmtree(private, ignore_errors=True)
                target = private if form == 'symlink' else store
                target.mkdir(parents=True)
                if form == 'corrupt':
                    (target / '1.json').write_text('{' + self.SENTINEL)
                else:
                    for n, data in enumerate(valid, 1):
                        (target / f'{n}.json').write_bytes(data)
                if form == 'symlink':
                    store.parent.mkdir(exist_ok=True)
                    store.symlink_to(private, target_is_directory=True)
                before = self.snapshot(self.xstate / 'small-changes'), self.snapshot(private) if private.exists() else {}
                result = run(sys.executable, ROOT / 'bin/lib/fm_spec_pins.py', 'scope', '--task', 'T-X',
                             '--head', 'work', '--base', 'main', env=clean_env(**self.xenv))
                self.assertEqual((result.returncode, result.stderr), (65, 'fm-pin: out of scope: tests/a.test.sh\n'))
                pin = run(sys.executable, ROOT / 'bin/lib/fm_spec_pins.py', 'resolve', '--task', 'T-X',
                          env=clean_env(**self.xenv)).stdout
                for role in ('worker', 'reviewer'):
                    shutil.rmtree(self.tmp / 'xrun', ignore_errors=True)
                    out = run(sys.executable, ROOT / 'bin/lib/fm_prompt_context.py', 'pin', role, input=pin,
                              env=clean_env(**self.xenv, FM_PINNED_DIR=self.tmp / 'xrun/pinned'))
                    self.assertEqual(out.returncode, 0, out.stderr)
                    self.assertNotIn(self.SENTINEL, out.stdout)
                    self.assertNotIn('# Small changes', out.stdout)
                after = self.snapshot(self.xstate / 'small-changes'), self.snapshot(private) if private.exists() else {}
                self.assertEqual(after, before)


class MergeCard(Engine, unittest.TestCase):
    """The autopilot merge path, through tests/lib/autopilot_merge_path.py fixtures."""
    record_job = merge_path.MergePath.record_job
    command = fixture.LoopTests.command
    probe = fixture.LoopTests.probe
    branch_setup = fixture.BranchFixture.branch_setup
    branch_probe = fixture.BranchFixture.branch_probe
    gate_result = fixture.LoopTests.gate_result
    gates = fixture.LoopTests.gates
    dispatch = merge_path.MergePath.dispatch
    built_path = merge_path.MergePath.built_path
    card_requests = merge_path.MergePath.requests
    failed_history = fixture.LoopTests.failed_history
    current_ready = fixture.LoopTests.current_ready
    replacement_details = fixture.LoopTests.replacement_details
    complete_gate_receipt = fixture.LoopTests.complete_gate_receipt
    ordinary_fingerprint = fixture.LoopTests.ordinary_fingerprint

    def setUp(self):
        fixture.LoopTests.setUp(self)
        self.ctx['tasks'] = str(self.root / 'design/tasks')
        self.make_engine(self.root, 'T-001')

    def merge_details(self, ident='D-alpha-T001-1', notes=None, questions=None):
        details = card()
        details['en']['title'] = 'MERGE CARD — merge PR #12: The check passes.'
        details['zh-TW']['title'] = '【合併卡】合併 PR #12：檢查通過。'
        for lang, text in (('en', 'The check passes.'), ('zh-TW', '檢查通過。')):
            if notes:
                details[lang]['notes'] = [dict(kind='caution', text=text)] * notes
            if questions:
                details[lang]['questions'] = [dict(kind='fact', text=text)] * questions
        path = self.state / 'decision-details' / (ident + '.json')
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(details, ensure_ascii=False) + '\n')
        return path

    def add_record(self):
        # Planted by hand, bound to the current pin, so on the base these cases
        # fail at the disclosure assertion, not at the missing command.
        version = max(int(p.stem) for p in (self.state / 'pins' / self.task).glob('*.json'))
        self.plant(self.paths_record(version=version))
        return self.sha12(1)

    def requested(self, index=0):
        request = self.card_requests()[index]
        return Path(request[request.index('--details') + 1])

    def assert_disclosed(self, path, status_en, status_tw, base_notes, base_questions, cautions=1):
        details = json.loads(path.read_text())
        for lang, status, question in (('en', status_en, 'Do you accept the small changes listed in the notes?'),
                                       ('zh-TW', status_tw, '你接受備註列出的小改動嗎？')):
            loc = details[lang]
            # A card built from the dispatch card, with no reviewed merge card,
            # carries the "Not reviewed for readability" caution (T-270);
            # authored details carry none.
            found = sum(1 for n in loc['notes'] if n['text'] == CAUTION[lang])
            self.assertEqual(found, cautions)
            self.assertEqual(len(loc['notes']), base_notes + cautions + 1)
            self.assertEqual(len(loc['questions']), base_questions + 1)
            note = loc['notes'][-1]
            self.assertEqual(note['kind'], 'caution')
            self.assertIn('tests/a.test.sh', note['text'])
            self.assertIn(REASON[lang], note['text'])
            self.assertIn(status, note['text'])
            if lang == 'en':
                self.assertIn('Small change 1 (paths)', note['text'])
                self.assertEqual(status == 'checked by the review', 'not checked by the review' not in note['text'])
            self.assertEqual(loc['questions'][-1]['text'], question)
        self.assertEqual(len(details['en']['notes']), len(details['zh-TW']['notes']))
        self.assertEqual(len(details['en']['questions']), len(details['zh-TW']['questions']))
        from fm_ste import check_details
        self.assertTrue(check_details(details, 'merge')['ok'])

    def test_merge_card_discloses_record_in_both_locales(self):
        # Fail-first: the base requests the built details without disclosure.
        self.dispatch()
        sha12 = self.add_record()
        self.gate_result(0)
        self.assertEqual(self.requested(), self.built_path())
        self.assert_disclosed(self.built_path(), 'not checked by the review', '審查未確認', 1, 1)
        shutil.rmtree(self.state / 'pending')
        self.pilot.verdict = lambda task: dict(verdict='APPROVE', head=HEAD, text=f'SMALL-CHANGE-CHECKED:T-001 1 {sha12}\nAPPROVE:T-001')
        self.gate_result(0)
        self.assert_disclosed(self.requested(1), 'checked by the review', '審查已確認', 1, 1)

    def test_checked_only_for_exact_standalone_line_on_gated_head(self):
        self.dispatch()
        sha12 = self.add_record()
        exact = f'SMALL-CHANGE-CHECKED:T-001 1 {sha12}'
        variants = {
            'wrong task': dict(text=f'SMALL-CHANGE-CHECKED:T-002 1 {sha12}'),
            'wrong number': dict(text=f'SMALL-CHANGE-CHECKED:T-001 2 {sha12}'),
            'wrong hash': dict(text='SMALL-CHANGE-CHECKED:T-001 1 000000000000'),
            'quoted': dict(text='> ' + exact),
            'fenced': dict(text='```\n' + exact + '\n```'),
            'inline': dict(text='I wrote ' + exact + ' here.'),
            'older head': dict(text=exact, head=BASE),
            'reject': dict(text=exact, verdict='REJECT'),
        }
        for name, change in variants.items():
            with self.subTest(name=name):
                shutil.rmtree(self.state / 'pending', ignore_errors=True)
                verdict = {'verdict': 'APPROVE', 'head': HEAD, **change}
                verdict['text'] += '\nAPPROVE:T-001'
                self.pilot.verdict = lambda task, v=verdict: v
                count = len(self.card_requests())
                self.gate_result(0)
                self.assertEqual(len(self.card_requests()), count + 1)
                self.assert_disclosed(self.requested(-1), 'not checked by the review', '審查未確認', 1, 1)

    def test_authored_details_stay_unchanged_and_copy_is_requested(self):
        authored = self.merge_details()
        original = authored.read_bytes()
        self.add_record()
        self.gate_result(0)
        self.assertEqual(authored.read_bytes(), original)
        self.assertEqual(self.requested(), self.built_path())
        self.assert_disclosed(self.built_path(), 'not checked by the review', '審查未確認', 1, 1, cautions=0)

    def test_disclosure_that_does_not_fit_raises_details_attention(self):
        for name, kwargs, failure in (('12 notes', dict(notes=12), 'en.notes: expected 1-12 items'),
                                      ('6 questions', dict(questions=6), 'en.questions: expected 1-6 items')):
            with self.subTest(name=name):
                shutil.rmtree(self.store, ignore_errors=True)
                self.pilot.data['wakes'].clear()
                authored = self.merge_details(**kwargs)
                original = authored.read_bytes()
                self.add_record()
                self.gate_result(0)
                self.assertEqual(self.card_requests(), [])
                self.assertFalse((self.state / 'pending').exists())
                self.assertEqual(authored.read_bytes(), original)
                lines = [w['line'] for w in self.pilot.data['wakes'].values()]
                self.assertIn('T-001 ready: merge card details needed (D-alpha-T001-1): '
                              'small-change disclosure does not fit: ' + failure, lines)

    def test_no_records_request_is_unchanged(self):
        # Regression: without a store the request and built details match the base.
        self.dispatch()
        self.gate_result(0)
        from fm_merge_details import build
        self.assertEqual(json.loads(self.built_path().read_text()), build(self.state, 'alpha', 'T-001', 12))
        request = self.card_requests()[0]
        self.assertEqual(request, self.script_request(self.built_path()))
        self.assertFalse(self.store.exists())

    def script_request(self, details):
        return self.pilot.script('fm-decide.sh', '--request', 'D-alpha-T001-1', '--task', 'T-001',
                                 '--project', 'alpha', '--kind', 'merge', '--pr', 12, '--expected-head', HEAD,
                                 '--details', details)

    def test_interleaving_is_disclosed_or_refused_never_unseen(self):
        self.dispatch()
        stub = self.pilot.command
        waiting = []

        def request_while_command_waits(argv, **kwargs):
            if '--request' in argv and not waiting:
                # Owned by this process through a lifeline keeper (T-151): the
                # keeper ends the command if this test process dies, and returns
                # the command's exit code.
                proc = fm_lifeline.start(['bash', str(ROOT / 'bin/fm-project.sh'), 'small-change', '--repo',
                                          str(self.root), '--project', 'alpha', '--task', 'T-001',
                                          '--origin', 'worker-ask', '--ref', 'r', '--reason-en', REASON['en'],
                                          '--reason-tw', REASON['zh-TW'], '--path', 'tests/a.test.sh'],
                                         env=clean_env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                self.addCleanup(proc.wait)
                self.addCleanup(proc.terminate)
                waiting.append(proc)
                with self.assertRaises(subprocess.TimeoutExpired, msg='the command must wait for merge-turn.lock'):
                    proc.wait(timeout=3)
            return stub(argv, **kwargs)

        self.pilot.command = request_while_command_waits
        self.gate_result(0)
        _, stderr = waiting[0].communicate(timeout=120)
        self.assertEqual(waiting[0].returncode, 65, stderr)
        self.assertIn('a merge card is pending; let the captain answer it first', stderr)
        self.assertFalse(list(self.store.glob('*.json')) if self.store.exists() else [])
        # The other order: a record published first is disclosed on the card.
        shutil.rmtree(self.state / 'pending')
        self.add_record()
        self.gate_result(0)
        self.assert_disclosed(self.requested(-1), 'not checked by the review', '審查未確認', 1, 1)

    def test_command_refuses_while_approved_merge_runs_or_merged(self):
        path = self.state / 'decisions/D-alpha-T001-1.json'
        path.parent.mkdir(exist_ok=True)
        for outcome in ('running', 'merged', None):
            with self.subTest(outcome=outcome):
                record = dict(id=path.stem, kind='merge', task='T-001', project='alpha', chosen='A', pr=12)
                if outcome:
                    record['merge'] = outcome
                path.write_text(json.dumps(record))
                result = self.create('--path', 'tests/a.test.sh')
                self.assertEqual(result.returncode, 65)
                self.assertIn('the captain already approved a merge for this task', result.stderr)
        self.assertFalse(self.store.exists())

    def restart(self):
        old = self.pilot
        old.save()
        self.pilot = A.Pilot(self.ctx)
        for name in ('api', 'authoritative_head', 'command', 'start_job', 'probe', 'read_head_spec',
                     'emit', 'verdict', 'busy'):
            setattr(self.pilot, name, getattr(old, name))

    def test_answered_hold_or_fix_stays_held_after_record(self):
        other = copy.deepcopy(PR); other['head']['sha'] = 'c' * 40
        for chosen in ('B', 'C'):
            with self.subTest(chosen=chosen):
                shutil.rmtree(self.store, ignore_errors=True)
                self.calls.clear()
                path = self.state / 'decisions/D-alpha-T001-1.json'
                path.parent.mkdir(exist_ok=True)
                path.write_text(json.dumps(dict(id=path.stem, identity='decision:' + path.stem, kind='merge',
                                                task='T-001', project='alpha', chosen=chosen, pr=12,
                                                expected_head=HEAD)))
                self.assertEqual(self.create('--path', 'tests/a.test.sh').returncode, 0)
                for pr in (PR, other):
                    self.pilot.advance(pr, CHECKS, [])
                self.restart()
                for pr in (PR, other):
                    self.pilot.advance(pr, CHECKS, [])
                self.assertEqual(self.gates(), [])
                self.assertEqual(self.card_requests(), [])
                self.assertFalse((self.state / 'pending').exists())

    def test_failed_merge_record_holds_same_head_and_new_head_card_discloses(self):
        shutil.rmtree(self.state / 'decisions', ignore_errors=True)
        self.failed_history()
        self.restore_approval()  # failed_history rewrites the event file
        self.assertEqual(self.create('--path', 'tests/a.test.sh').returncode, 0)
        same = copy.deepcopy(PR); same['head']['sha'] = 'd' * 40
        self.pilot.advance(same, CHECKS, [])
        self.assertEqual(self.gates(), [])
        self.assertTrue(any('same failed head' in w['line'] for w in self.pilot.data['wakes'].values()))
        self.merge_details('D-alpha-T001-2')
        self.complete_gate_receipt()
        self.assertEqual(len(self.requests), 1)
        request = self.requests[0]
        path = Path(request[request.index('--details') + 1])
        self.assertEqual(path, self.state / 'decision-details-built/D-alpha-T001-2.json')
        self.assert_disclosed(path, 'not checked by the review', '審查未確認', 1, 1, cautions=0)

    def test_record_after_gate_failure_starts_new_gate_on_same_head(self):
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.gates()), 1)
        # Regression: with no store the fingerprint is exactly the base one.
        self.assertEqual(self.pilot.data['advanced']['12']['fingerprint'], self.ordinary_fingerprint())
        self.gate_result(3)
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.gates()), 1)
        self.add_record()
        # Fail-first: the base fingerprint ignores the record and runs no gate.
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.gates()), 2)
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.gates()), 2)

    def test_fingerprint_element_is_digest_of_record_bytes_in_number_order(self):
        self.plant(self.paths_record(), self.paths_record(paths=['docs/b.md']))
        first, second = ((self.store / f'{n}.json').read_bytes() for n in (1, 2))
        self.pilot.advance(PR, CHECKS, [])
        details = {p.name: json.loads(p.read_text())
                   for p in (self.state / 'decision-details').glob('D-alpha-T001-*.json')}
        expected = A.key([12, HEAD, BASE, self.pilot.settled_checks(PR, CHECKS, []), None, details, 0,
                          hashlib.sha256(first + second).hexdigest()])
        self.assertEqual(self.pilot.data['advanced']['12']['fingerprint'], expected)

    MERGE_SENTINEL = 'PRIVATE-T277-MERGE-SENTINEL'

    def external_merge(self, form):
        sentinel = self.MERGE_SENTINEL
        self.ctx['external'] = True
        self.pilot.task = lambda pr: 'T-001'
        elsewhere = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, elsewhere, True)
        private = elsewhere / 'store'
        if form == 'corrupt':
            self.store.mkdir(parents=True)
            (self.store / '1.json').write_text('{' + sentinel)
        else:
            # Valid for the current pin: real digest and previous_sha256 chain.
            reason = dict(en=sentinel, **{'zh-TW': sentinel})
            self.plant(self.paths_record(reason=reason, origin=dict(kind='firstmate', ref=sentinel)),
                       self.paths_record(paths=['docs/b.md'], reason=reason))
            if form == 'symlink':
                shutil.move(self.store, private)
                self.store.symlink_to(private, target_is_directory=True)
        watched = [self.store, *self.store.iterdir()] + ([private, *private.iterdir()] if form == 'symlink' else [])
        snapshot = lambda: {str(p): (os.lstat(p).st_mtime_ns, p.read_bytes() if p.is_file() and not p.is_symlink()
                                     else None) for p in watched}
        before = snapshot()
        authored = self.merge_details()
        with patch.dict(sys.modules, {'fm_small_change': None}):
            self.pilot.advance(PR, CHECKS, [])
            self.gate_result(0)
        self.assertEqual(len(self.card_requests()), 1)
        self.assertEqual(self.requested(), authored)
        for text in (json.dumps(self.pilot.data), json.dumps([c for c in self.calls if c[0] in ('command', 'emit')]),
                     *(p.read_text() for p in (self.state / 'pending').glob('*.json'))):
            self.assertNotIn(sentinel, text)
        self.assertEqual(snapshot(), before)

    def test_external_merge_path_never_reads_valid_store(self):
        self.external_merge('valid')

    def test_external_merge_path_never_reads_corrupt_store(self):
        self.external_merge('corrupt')

    def test_external_merge_path_never_reads_symlinked_store(self):
        self.external_merge('symlink')


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
    result = unittest.main(exit=False, testRunner=unittest.TextTestRunner(
        verbosity=2, resultclass=NamedTestResult)).result
    sys.exit(0 if result.wasSuccessful() else 1)
