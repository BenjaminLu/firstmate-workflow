"""T-270 plain writing: glossary, mechanical checks, check-plain, merge cards.

Labels: an "interface" test drives a new interface (fm_plain.py,
fm_ste.py check-plain); on the base it fails at import or argument parsing
and is not behavioural evidence. A "behavioural" test drives an entrypoint the
base already has (retain_verdict(), render(), the fm-review.sh comment block).
Shared fixtures: tests/lib/ste_cases.py, tests/lib/self_pr_authoring.py.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import types
import unittest

ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
sys.path.insert(0, str(ROOT / 'tests/lib'))
from ste_cases import card  # noqa: E402

GLOSSARY = {'schema': 1, 'terms': [
    {'id': 'gate', 'en': {'term': 'gate', 'aliases': ['gates'], 'text': 'A gate is one check.'},
     'zh-TW': {'term': '關卡', 'aliases': [], 'text': '關卡是一項檢查。'}},
    {'id': 'six-gates', 'en': {'term': 'six gates', 'aliases': [], 'text': 'The six gates are the checks.'},
     'zh-TW': {'term': '六道關卡', 'aliases': ['六關'], 'text': '六關是全部檢查。'}},
    {'id': 'board', 'en': {'term': 'board', 'aliases': ["captain's board"], 'text': 'The board is a page.'},
     'zh-TW': {'term': '看板', 'aliases': [], 'text': '看板是網頁。'}},
    {'id': 'pin', 'en': {'term': 'pin', 'aliases': ['pinned'], 'text': 'A pin is a frozen spec.'},
     'zh-TW': {'term': '固定版本', 'aliases': [], 'text': '固定版本是凍結的規格。'}},
]}


def plain():
    import fm_plain
    return fm_plain


class GlossaryMatching(unittest.TestCase):
    """Interface tests of bin/lib/fm_plain.py (extra, not behavioural)."""

    def ids(self, text, lang='en'):
        return plain().find_terms(text, lang, GLOSSARY)

    def test_en_whole_word_and_not_inside_a_longer_word(self):
        self.assertEqual(['board'], self.ids('Open the board now.'))
        self.assertEqual([], self.ids('Boarding starts at noon.'))
        self.assertEqual([], self.ids('The spinning top stopped.'), 'pin inside a longer word')

    def test_case_insensitive_and_alias(self):
        self.assertEqual(['board'], self.ids('The BOARD shows it.'))
        self.assertEqual(['pin'], self.ids('The pinned spec stays.'))
        self.assertEqual([], self.ids('The unpinnedx flag.'), 'an alias inside a longer word is no match')

    def test_zh_substring_and_absent_term(self):
        self.assertEqual(['board'], self.ids('請打開看板。', 'zh-TW'))
        self.assertEqual([], self.ids('請打開網頁。', 'zh-TW'))

    def test_longer_overlap_wins_and_shorter_alone_matches(self):
        self.assertEqual(['six-gates'], self.ids('All six gates pass.'))
        self.assertEqual(['six-gates'], self.ids('六道關卡全部通過。', 'zh-TW'))
        self.assertEqual(['gate'], self.ids('One gate failed.'))
        self.assertEqual(['gate'], self.ids('一個關卡失敗。', 'zh-TW'))

    def test_previously_excluded_fields_are_searched(self):
        fm = plain()
        for field, mutate in (
                ('intent', lambda loc: loc['intent'][0].update(text='The board shows it.')),
                ('done', lambda loc: loc['done'][0].update(text='The board shows it.')),
                ('door', lambda loc: loc.update(door=dict(kind='two-way', reason='The board shows it.', rollback='Undo.'))),
                ('node label', lambda loc: loc['after_nodes'][0].update(label='board'))):
            with self.subTest(field=field):
                details = card(); mutate(details['en'])
                problems = fm.check_card(details, GLOSSARY)
                self.assertTrue(any('unexplained-term "board"' in p for p in problems), problems)
                details['en']['glossary'] = ['board']
                self.assertEqual([], fm.check_card(details, GLOSSARY))

    def test_glossary_validation_refusals(self):
        fm = plain()
        def broken(mutate):
            data = copy.deepcopy(GLOSSARY); mutate(data); return data
        for name, mutate in (
                ('duplicate id', lambda d: d['terms'].append(copy.deepcopy(d['terms'][0]))),
                ('missing locale', lambda d: d['terms'][0].pop('zh-TW')),
                ('empty term', lambda d: d['terms'][0]['en'].update(term=' ')),
                ('empty text', lambda d: d['terms'][0]['en'].update(text='')),
                ('non-object locale', lambda d: d['terms'][0].update({'en': 'gate'})),
                ('non-list aliases', lambda d: d['terms'][0]['en'].update(aliases='gates')),
                ('bad id', lambda d: d['terms'][0].update(id='Gate'))):
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    fm.validate_glossary(broken(mutate))
        fm.validate_glossary(GLOSSARY)
        fm.validate_glossary(fm.load_glossary(ROOT))


class MechanicalChecks(unittest.TestCase):
    """Interface tests of the three mechanical checks (extra)."""

    def test_glued_numbers(self):
        fm = plain()
        self.assertEqual(['Main87df', 'All13', 'ts2672', '10MB'],
                         fm.glued('Main87df set All13 and ts2672 to 10MB.'))
        for text in ('The change (T-1003) kept 3 retries.', 'Card D-alpha-T001-1 waits.',
                     'Commit 87df0a1b9 and 87df0a1 landed.', 'Version v1.2 and 2.55 and v1.',
                     'Read bin/fm_ste.py and tests/e2e/x2.spec.ts.', 'Use `x86` here.',
                     'See https://example.test/a1b2 now.', 'APPROVE:T-12', 'SPEC-OK:T-12',
                     'EVIDENCE:T-1 abc123def', 'PR #12 and SHA-256.'):
            with self.subTest(text=text):
                self.assertEqual([], fm.glued(text))

    def test_slash_chains(self):
        fm = plain()
        self.assertEqual(['kindchoice/purposerepin/chosenA'],
                         fm.slashes('Set kindchoice/purposerepin/chosenA now.'))
        for text in ('Use and/or here.', 'Read bin/lib/fm_plain.py.', 'Edit design/tasks/T-1.json.',
                     'Open tests/e2e/lib now.', '`a/b/c` stays.'):
            with self.subTest(text=text):
                self.assertEqual([], fm.slashes(text))

    def test_unexplained_terms(self):
        fm = plain()
        self.assertEqual(['unexplained-term'],
                         [f['check'] for f in fm.lint('The board shows it.', 'en', GLOSSARY, [])])
        self.assertEqual([], fm.lint('The board shows it.', 'en', GLOSSARY, ['board']))

    def test_protected_tokens(self):
        fm = plain()
        self.assertEqual(fm.protected('Keep 3 in `a b` at bin/x.py:12 for T-1 and D-a-1 and abcdef12.'),
                         fm.protected('For T-1 and D-a-1 and abcdef12, keep 3 in `a b` at bin/x.py:12.'))
        self.assertNotEqual(fm.protected('Keep 3 retries.'), fm.protected('Keep retries.'))

    def test_every_hash_form_is_guarded_for_every_rewrite_kind(self):
        # A hash of seven or more hexadecimal characters is protected with no
        # digit required and in either case: abcdefa and ABC123DEF.
        fm = plain()
        kinds = (('spec', fm.spec_prose, lambda text: {'title': 'T', 'acceptance': [text]}),
                 ('card', fm.card_prose, lambda text: {'en': {'why': [{'kind': 'fact', 'text': text}]}}),
                 ('pr-authoring', fm.pr_prose, lambda text: {'problem': text}))
        for name, allowed, doc in kinds:
            for old, new in (('Revert abcdefa now.', 'Revert fedcbaf now.'),
                             ('Revert ABC123DEF now.', 'Revert ABC123AAA now.')):
                with self.subTest(kind=name, old=old):
                    with self.assertRaisesRegex(ValueError, 'protected tokens changed'):
                        fm.compare(doc(old), doc(new), allowed)
                    fm.compare(doc(old), doc(old.replace('Revert', 'Undo')), allowed)
            with self.subTest(kind=name, word='defaced'):
                # An ordinary word made only of a-f letters is a token too; a
                # rewrite that keeps it unchanged is not reported.
                fm.compare(doc('The defaced page stays.'), doc('The defaced page is kept.'), allowed)
                self.assertEqual([], fm.glued('The defaced page stays.'))

    def test_zh_cn_rendering_applies_rows_in_file_order(self):
        fm = plain()
        rows = [['船員名冊', '船员名册'], ['船員', '船员'], ['員', '员']]
        self.assertEqual('船员名册与船员和成员', fm.to_cn('船員名冊与船員和成員', rows))
        # Board semantics: an earlier short row runs before a later long one.
        self.assertEqual('船员名冊', fm.to_cn('船員名冊', [['船員', '船员'], ['船員名冊', '船员名册']]))


class CheckPlain(unittest.TestCase):
    """Interface tests of fm_ste.py check-plain."""

    def run_check(self, details):
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as out:
            json.dump(details, out)
        self.addCleanup(os.unlink, out.name)
        return subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_ste.py'), 'check-plain', out.name],
                              capture_output=True, text=True, timeout=30)

    def test_missing_plain_fields_and_unknown_id(self):
        for name, mutate in (('why', lambda d: d['en'].pop('why')), ('how', lambda d: d['zh-TW'].pop('how')),
                             ('glossary', lambda d: d['en'].pop('glossary')),
                             ('empty how', lambda d: d['en'].update(how=[])),
                             ('item shape', lambda d: d['en']['how'][0].update(extra=1)),
                             ('unknown id', lambda d: d['en'].update(glossary=['no-such-term']))):
            with self.subTest(name=name):
                details = card(); mutate(details)
                result = self.run_check(details)
                self.assertEqual(64, result.returncode, result.stderr)
        self.assertEqual(0, self.run_check(card()).returncode)

    def test_ste_failures_in_why_and_how_with_and_without_intent(self):
        for intent in (True, False):
            for field in ('why', 'how'):
                with self.subTest(intent=intent, field=field):
                    details = card()
                    if not intent:
                        for loc in details.values():
                            for key in ('intent', 'done', 'scope_in', 'scope_out', 'notes', 'questions',
                                        'before_nodes', 'after_nodes', 'change_table'):
                                loc.pop(key)
                    details['en'][field][0]['text'] = 'It will pass.'
                    result = self.run_check(details)
                    self.assertEqual(65, result.returncode, result.stderr)
                    self.assertIn('en ' + field + ': It will pass. -> R5', result.stderr)
                    report = json.loads(result.stdout)
                    self.assertFalse(report['ok'])

    def test_unexplained_term_refused_then_accepted_with_its_id(self):
        details = card()
        details['en']['how'][0]['text'] = 'The board shows the card.'
        result = self.run_check(details)
        self.assertEqual(65, result.returncode)
        self.assertIn('en.how: unexplained-term "board"', result.stderr)
        details['en']['glossary'] = ['board']
        self.assertEqual(0, self.run_check(details).returncode)


class MergeCardRetention(unittest.TestCase):
    """Behavioural: retain_verdict() exists on the base and ignores the block."""

    CARD = {'en': {'title': 'Show the card.', 'why': [], 'how': [], 'notes': [], 'glossary': []}}

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.run_dir = self.root / 'run'; self.run_dir.mkdir()
        self.head = 'a' * 40
        (self.run_dir / 'evidence-binding.json').write_text(json.dumps(dict(head=self.head, base='b' * 40, patch='p')))
        (self.run_dir / 'identity.json').write_text(json.dumps(dict(project='self', task='T-X', role='reviewer', round=1)))
        os.environ['FM_ACTOR'] = 'reviewer-fixture'

    def retain(self, answer):
        from fm_evidence import Store, retain_verdict
        final = self.root / 'final.txt'; final.write_text(answer)
        args = types.SimpleNamespace(run=str(self.run_dir), head=self.head, base='b' * 40, patch='p', round=1,
                                     vendor='legacy', file=str(final), attempt='one', code=str(ROOT))
        retain_verdict(Store(self.root / 'state', 'self', 'T-X', external=False), args)
        return Store(self.root / 'state', 'self', 'T-X', external=False).records()[-1]

    def block(self, value):
        return '```json fm-merge-card\n' + (value if isinstance(value, str) else json.dumps(value)) + '\n```\n'

    def test_present_block_is_retained_beside_the_unchanged_answer(self):
        answer = 'Looks right.\n' + self.block(self.CARD) + 'APPROVE:T-X\n'
        record = self.retain(answer)
        self.assertEqual(answer, record['text'])
        self.assertEqual('APPROVE', record['verdict'])
        self.assertEqual('present', record['merge_card_status'])
        self.assertEqual(self.CARD, record['merge_card'])

    def test_malformed_and_ignored_blocks(self):
        for name, answer, status in (
                ('duplicate', self.block(self.CARD) * 2 + 'APPROVE:T-X\n', 'malformed'),
                ('not an object', self.block('[1]') + 'APPROVE:T-X\n', 'malformed'),
                ('unclosed', 'APPROVE:T-X\n```json fm-merge-card\n{"en": {}}\n', 'malformed'),
                ('reject', '1. fix it\nCRITERIA-COMPLETE:T-X\n' + self.block(self.CARD) + 'REJECT:T-X\n', 'ignored'),
                ('absent', 'APPROVE:T-X\n', 'absent')):
            with self.subTest(name=name):
                self.setUp()
                record = self.retain(answer)
                self.assertEqual(status, record['merge_card_status'])
                self.assertIsNone(record['merge_card'])
                self.assertEqual(answer, record['text'])

    def test_readers_ignore_markers_inside_the_block(self):
        from fm_evidence import criteria, verdict_marker
        text = ('1. done fixed\nCRITERIA-COMPLETE:T-X\n```json fm-merge-card\nREJECT:T-X\n'
                '1. inside\nCRITERIA-COMPLETE:T-X\n```\nAPPROVE:T-X\n')
        self.assertEqual('APPROVE', verdict_marker(text, 'T-X'))
        self.assertEqual([(1, 'done fixed')], criteria(text, 'T-X'))

    def test_old_verdict_without_status_reads_as_absent(self):
        import fm_merge_details
        from fm_evidence import Store
        store = Store(self.root / 'state', 'self', 'T-X', external=False)
        old = store.append('verdict', 1, 'reviewer', self.head, 'APPROVE:T-X', verdict='APPROVE',
                           provenance=dict(level='legacy'))
        readiness = store.append('readiness', 1, 'firstmate', self.head, '', pr=9,
                                 verdict_signature=old['signature'])
        card_, reason = fm_merge_details.reviewed_card(self.root / 'state', 'self', 'T-X', 9, readiness,
                                                       self.head, self.root)
        self.assertIsNone(card_)
        self.assertEqual('the selected review has no usable merge card', reason)


class ReviewerComment(unittest.TestCase):
    """Behavioural: the fm-review.sh comment projection block, run as written."""

    def projection(self, verdict, external='0', review='fm'):
        source = (ROOT / 'bin/fm-review.sh').read_text()
        start = source.index('if [ -n "$PR" ] && [ "$projection" = comments ]; then')
        end = source.index('if [ "$FM_EXTERNAL" = 1 ] && [ -n "$PR" ] && [ "$projection" != comments ]; then')
        tmp = Path(tempfile.mkdtemp()); self.addCleanup(subprocess.run, ['rm', '-rf', str(tmp)])
        script = ('PR=9; projection=comments; TASK=T-X; evidence_ref=sig; R_HEAD=' + 'a' * 40 + '; decided=APPROVE\n'
                  f'FM_EXTERNAL={external}; project_review={review}; work={shlex.quote(str(tmp))}\n'
                  f'FM_STATE_DIR={shlex.quote(str(tmp / "state"))}; FM_CODE_ROOT={shlex.quote(str(ROOT))}\n'
                  'verdict="$(cat "$work/verdict")"\n'
                  'fm_comment_projection() { printf "%s" "$3" > "$work/posted"; }\n'
                  'emit() { :; }\n' + source[start:end])
        (tmp / 'verdict').write_text(verdict)
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=60)
        self.assertEqual(0, result.returncode, result.stderr)
        posted = (tmp / 'posted').read_text() if (tmp / 'posted').exists() else None
        log = tmp / 'state/runtime/plain-writing.jsonl'
        return posted, [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def test_comment_is_posted_with_markers_and_findings_reach_the_log(self):
        verdict = 'Checked All13 in kind/purpose/chosen.\nAPPROVE:T-X\n\nREVIEWED:T-X verdict=APPROVE'
        posted, log = self.projection(verdict)
        self.assertTrue(posted.startswith('EVIDENCE:T-X sig\n\n'), posted)
        # the explanation sits before the verdict so REVIEWED stays the comment's last line
        self.assertTrue(posted.rstrip('\n').endswith(verdict), posted)
        self.assertIn('The EVIDENCE line names the signed review record', posted)
        found = {(f['check'], f['match']) for row in log for f in row['findings']}
        self.assertIn(('glued-number', 'All13'), found)
        self.assertIn(('slash-chain', 'kind/purpose/chosen'), found)
        self.assertEqual({'reviewer-comment'}, {row['source'] for row in log})

    def test_merge_card_never_reaches_a_comment(self):
        sentinel = 'PRIVATE-SENTINEL-T270'
        block = '```json fm-merge-card\n{"en": {"title": "' + sentinel + '"}}\n```\n'
        for external in ('0', '1'):
            for name, verdict in (('one', 'Fine.\n' + block + 'APPROVE:T-X'),
                                  ('duplicate', 'Fine.\n' + block + block + 'APPROVE:T-X'),
                                  ('unclosed', 'Fine.\nAPPROVE:T-X\n' + block.rsplit('```', 1)[0])):
                with self.subTest(external=external, name=name):
                    posted, _ = self.projection(verdict, external)
                    self.assertNotIn(sentinel, posted)
                    self.assertNotIn('fm-merge-card', posted)
                    self.assertIn('Fine.', posted)
        posted, _ = self.projection('Fine.\n' + block + 'APPROVE:T-X', '1', 'external')
        self.assertIn('Firstmate local pre-check finished for T-X', posted)
        self.assertNotIn(sentinel, posted)


    def test_block_runs_alone_without_launcher_names(self):
        # The block needs no temporary file, REPO, FM_CODE_ROOT or
        # FM_STATE_DIR: a caller that cuts it out and runs it alone still posts.
        source = (ROOT / 'bin/fm-review.sh').read_text()
        start = source.index('if [ -n "$PR" ] && [ "$projection" = comments ]; then')
        end = source.index('if [ "$FM_EXTERNAL" = 1 ] && [ -n "$PR" ] && [ "$projection" != comments ]; then')
        tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, tmp, True)
        for name, verdict, want in (('plain', 'Fine.\nAPPROVE:T-X', 'Fine.'),
                                    ('merge card', 'Fine.\n```json fm-merge-card\n{}\n```\nAPPROVE:T-X', None)):
            with self.subTest(name=name):
                posted = tmp / 'posted'; posted.unlink(missing_ok=True)
                script = ('set -u; PR=9; projection=comments; TASK=T-X; evidence_ref=sig; R_HEAD=' + 'a' * 40
                          + '; decided=APPROVE; FM_EXTERNAL=0; project_review=fm\n'
                          + 'verdict=' + shlex.quote(verdict) + '\n'
                          + 'fm_comment_projection() { printf "%s" "$3" > ' + shlex.quote(str(posted)) + '; }\n'
                          + ('emit() { :; }\n' if want is None else '') + source[start:end])
                env = {k: v for k, v in os.environ.items() if k not in ('REPO', 'FM_CODE_ROOT', 'FM_STATE_DIR')}
                result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=60,
                                        cwd=tmp, env=env)
                self.assertEqual(0, result.returncode, result.stderr)
                if want is None:
                    self.assertFalse(posted.exists(), 'a merge card is never posted without its remover')
                else:
                    self.assertIn(want, posted.read_text())
                self.assertEqual(['posted'] if want else [], sorted(p.name for p in tmp.iterdir()),
                                 'the block writes no temporary file')


class FrozenCodeRoot(unittest.TestCase):
    """Behavioural (Change 19): frozen code reads i18n/ only from its own root.

    FM_ROOT points at a valid live checkout, which must never be read: each
    reader refuses (the advisory lint records the failure) naming the frozen
    file when that file is missing or unreadable.
    """

    def setUp(self):
        base = Path(tempfile.mkdtemp()).resolve(); self.addCleanup(shutil.rmtree, base, True)
        self.live, self.frozen, self.state = base / 'live', base / 'frozen', base / 'state'
        for tree in (self.live, self.frozen):
            shutil.copytree(ROOT / 'bin/lib', tree / 'bin/lib', ignore=shutil.ignore_patterns('__pycache__'))
            (tree / 'skills/firstmate').mkdir(parents=True)
            shutil.copy2(ROOT / 'skills/firstmate/plain-writing.md', tree / 'skills/firstmate/')
            shutil.copytree(ROOT / 'i18n', tree / 'i18n')
        self.env = dict(os.environ, FM_ROOT=str(self.live), FM_STATE_DIR=str(self.state))
        self.card = base / 'card.json'; self.card.write_text(json.dumps(card(), ensure_ascii=False))

    def frozen_python(self, code, *args):
        prelude = 'import json, sys\nsys.path.insert(0, sys.argv[1] + "/bin/lib")\n'
        return subprocess.run([sys.executable, '-c', prelude + code, str(self.frozen), *args],
                              env=self.env, capture_output=True, text=True, timeout=60)

    def readers(self):
        envelope = PullRequestBody().envelope()
        spec = json.dumps(dict(id='T-X', scope=['src/**'], acceptance=['works']))
        return {
            'check-plain': lambda: subprocess.run(
                [sys.executable, str(self.frozen / 'bin/lib/fm_ste.py'), 'check-plain', str(self.card)],
                env=self.env, capture_output=True, text=True, timeout=60),
            'pull-request rendering': lambda: self.frozen_python(
                'import fm_self_pr\nprint(fm_self_pr.render(json.loads(sys.argv[2]), {"id": "T-X", "acceptance": ["x"]},'
                ' "a" * 40, [])["body"])', json.dumps(envelope)),
            'spec preflight': lambda: self.frozen_python(
                'import fm_spec_preflight\nprint(fm_spec_preflight.prompt("T-X", sys.argv[2].encode(), "a" * 40,'
                ' code=sys.argv[1], card=open(sys.argv[3], "rb").read()))', spec, str(self.card)),
        }

    def broken(self, name, how):
        path = self.frozen / 'i18n' / name
        if how == 'missing':
            path.unlink()
        else:
            path.write_bytes(b'\xff\xfe\xfa not text')
        return str(path)

    def test_glossary_readers_refuse_naming_the_frozen_file(self):
        for how in ('missing', 'unreadable'):
            for reader, run in self.readers().items():
                with self.subTest(how=how, reader=reader):
                    self.setUp()
                    path = self.broken('glossary.json', how)
                    result = run()
                    self.assertNotEqual(0, result.returncode, result.stdout[:300])
                    self.assertIn(how + ' ' + path, result.stderr)
                    self.assertNotIn(str(self.live), result.stderr)

    def test_tw2cn_readers_refuse_naming_the_frozen_file(self):
        for how in ('missing', 'unreadable'):
            for reader, run in (('zh-CN rendering', lambda: self.frozen_python(
                                    'import fm_plain\nprint(fm_plain.to_cn("看板", fm_plain.tw2cn_rows()))')),
                                ('spec preflight', self.readers()['spec preflight'])):
                with self.subTest(how=how, reader=reader):
                    self.setUp()
                    path = self.broken('tw2cn.tsv', how)
                    result = run()
                    self.assertNotEqual(0, result.returncode, result.stdout[:300])
                    self.assertIn(how + ' ' + path, result.stderr)

    def test_advisory_lint_records_the_frozen_failure_and_never_blocks(self):
        for how in ('missing', 'unreadable'):
            with self.subTest(how=how, reader='fm_plain.py lint'):
                self.setUp()
                path = self.broken('glossary.json', how)
                log = self.state / 'plain.jsonl'
                result = subprocess.run([sys.executable, str(self.frozen / 'bin/lib/fm_plain.py'), 'lint', '-',
                                         '--source', 'worker-note', '--log', str(log)], input='The board.\n',
                                        env=self.env, capture_output=True, text=True, timeout=60)
                self.assertEqual(0, result.returncode, 'the post is never stopped')
                rows = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual('lint-failed', rows[0]['findings'][0]['check'])
                self.assertIn(how + ' ' + path, rows[0]['findings'][0]['match'])
            with self.subTest(how=how, reader='fm_external.advise'):
                self.setUp()
                path = self.broken('glossary.json', how)
                result = self.frozen_python(
                    'import types, fm_external\n'
                    'fm_external.advise(types.SimpleNamespace(state=__import__("pathlib").Path(sys.argv[2])),'
                    ' "external-reply", "The board.")', str(self.state))
                self.assertEqual(0, result.returncode, result.stderr)
                rows = [json.loads(line) for line in
                        (self.state / 'runtime/plain-writing.jsonl').read_text().splitlines()]
                self.assertEqual('lint-failed', rows[0]['findings'][0]['check'])
                self.assertIn(how + ' ' + path, rows[0]['findings'][0]['match'])

    def test_live_changes_after_the_snapshot_never_reach_frozen_code(self):
        (self.frozen / 'i18n/tw2cn.tsv').write_text('凍結\tFROZEN-ROW\n', encoding='utf-8')
        (self.live / 'i18n/tw2cn.tsv').write_text('凍結\tLIVE-ROW\n', encoding='utf-8')
        terms = json.loads((self.live / 'i18n/glossary.json').read_text())
        terms['terms'].append(dict(id='live-only', en=dict(term='zebra', aliases=[], text='A zebra is live.'),
                                   **{'zh-TW': dict(term='斑馬', aliases=[], text='斑馬是活的。')}))
        (self.live / 'i18n/glossary.json').write_text(json.dumps(terms, ensure_ascii=False))
        result = self.frozen_python('import fm_plain\nprint(fm_plain.to_cn("凍結", fm_plain.tw2cn_rows()))\n'
                                    'print(fm_plain.find_terms("The zebra.", "en", fm_plain.load_glossary()))')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(['FROZEN-ROW', '[]'], result.stdout.split('\n')[:2])
        details = card(); details['zh-TW']['title'] = '凍結看板'; self.card.write_text(json.dumps(details, ensure_ascii=False))
        result = self.readers()['spec preflight']()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('FROZEN-ROW', result.stdout)
        self.assertNotIn('LIVE-ROW', result.stdout)


class PullRequestBody(unittest.TestCase):
    """Behavioural: render() exists on the base without these sections."""

    def envelope(self, size='small', **draft):
        base = dict(subject='Show the plain card', size=size, problem='Readers could not judge the card.',
                    expected_result='Readers judge the card.', approach='Render the board glossary.',
                    intent_notes=[dict(index=0, note='Explain the card.')])
        base.update(draft)
        return dict(draft=base, mode='pin-backed', dispatch_reference=None, project='firstmate-workflow')

    def test_body_starts_with_why_and_how_and_ends_with_the_glossary(self):
        from fm_self_pr import render
        spec = dict(id='T-X', acceptance=['x'])
        for size in ('small', 'complex'):
            with self.subTest(size=size):
                body = render(self.envelope(size), spec, 'a' * 40, ['src/a.py'])['body']
                self.assertTrue(body.startswith('## Why\n\nReaders could not judge the card.\n\n## How\n\n'
                                                'Render the board glossary.\n\n'), body[:200])
                glossary = body[body.index('## Glossary'):]
                self.assertIn('- board: The board is the web page where the captain reads and answers cards.', glossary)
                self.assertIn('- six gates: ', glossary)
        question = render(self.envelope(), spec, 'a' * 40, None, question='scope')['body']
        self.assertTrue(question.startswith('## Why\n\nReaders could not judge the card.\n\nDraft awaiting'))
        self.assertNotIn('## How', question)
        self.assertIn('## Glossary', question)

    def test_new_draft_with_a_glued_number_is_refused_but_still_renders(self):
        import fm_self_pr
        envelope = self.envelope(problem='Readers saw All13 cards.')
        sources = {k: dict(sha256=hashlib.sha256(k.encode()).hexdigest(), absent=False)
                   for k in ('spec', 'design', 'contract', 'conventions')}
        draft = dict(envelope['draft'], schema=1, task='T-X', sources=sources)
        spec = dict(id='T-X', acceptance=['x'])
        fm_self_pr.validate(draft, spec, sources)
        with self.assertRaisesRegex(ValueError, 'glued-number "All13"'):
            fm_self_pr.validate(draft, spec, sources, prose_checks=True)
        self.assertIn('All13', fm_self_pr.render(envelope, spec, 'a' * 40, [])['body'])


def stock_publication():
    """tests/lib/self_pr_authoring.py's real pin and seal fixture (it reads its
    root from argv at import)."""
    saved = sys.argv[:]
    sys.argv.insert(1, str(ROOT))
    try:
        import self_pr_authoring
    finally:
        sys.argv[:] = saved
    return self_pr_authoring


class SealAfterRewrite(unittest.TestCase):
    """Change 14 integration: a preflight receipt with an accepted spec rewrite
    hands over a draft that seal() accepts against the rewritten approved spec.
    Uses the real retain(), pin creation and fm_self_pr.py seal."""

    def setUp(self):
        stock = stock_publication()
        self.pr = stock.pr
        for name in ('run_ok', 'git', 'seed_preflight', 'author', 'pin_create'):
            setattr(type(self), name, getattr(stock.StockPublication, name))
        stock.StockPublication.setUp(self)

    def preflight_then_seal(self, draft_rewrite):
        from fm_evidence import Store
        from fm_spec_preflight import retain
        task_file = self.repo / 'design/tasks/T-259.json'
        submitted_spec = task_file.read_bytes()
        submitted_draft = (self.state / 'pr-authoring/T-259.json').read_bytes()
        new_spec = dict(json.loads(submitted_spec), title='Self pull requests explain the approved intent and the observed scope')
        blocks = '```json fm-reworded-spec\n' + json.dumps(new_spec) + '\n```\n'
        if draft_rewrite:
            blocks += ('```json fm-reworded-pr-authoring\n'
                       + json.dumps(dict(self.draft, **draft_rewrite)) + '\n```\n')
        answer = ('Summary.\n' + blocks + '1. ok: the rewritten title and draft keep their meaning.\n'
                  'PREFLIGHT-COMPLETE:T-259\n\nSPEC-OK:T-259\n')
        record = retain(Store(self.state, self.evidence_project, 'T-259'), submitted_spec, 'a' * 40,
                        'reviewer-fixture', 2, answer, dict(level='legacy', vendor='claude'),
                        pr_authoring=submitted_draft)
        spec_entry, draft_entry = record['rewrite']['spec'], record['rewrite']['pr-authoring']
        self.assertEqual('accepted', spec_entry['status'], spec_entry)
        self.assertEqual('accepted', draft_entry['status'], draft_entry)
        # firstmate puts exactly the accepted bytes in the task file and the draft.
        task_file.write_bytes(spec_entry['text'].encode('utf-8'))
        self.git('add', 'design/tasks/T-259.json'); self.git('commit', '-qm', 'reviewed spec wording')
        self.git('push', '-q', 'origin', 'main')
        (self.state / 'pr-authoring/T-259.json').write_bytes(draft_entry['text'].encode('utf-8'))
        pin = self.pin_create()
        self.assertEqual(spec_entry['text'], pin['snapshots']['spec']['text'], 'the pin holds the rewritten spec')
        sealed = self.subprocess.run([sys.executable, str(self.repo / 'bin/lib/fm_self_pr.py'), 'seal', '--task', 'T-259'],
                                     env=self.pin_env, capture_output=True, text=True)
        self.assertEqual(0, sealed.returncode, sealed.stdout + sealed.stderr)
        envelope = json.loads(sealed.stdout)
        self.assertEqual(self.pr.source_digests(pin['snapshots']), envelope['sources'])
        self.assertEqual(hashlib.sha256(spec_entry['text'].encode('utf-8')).hexdigest(),
                         envelope['sources']['spec']['sha256'], 'seal() binds the rewritten spec')
        for key in ('design', 'contract', 'conventions'):
            self.assertEqual(self.draft['sources'][key], envelope['sources'][key], key + ' source entry stays')
        self.assertEqual([n['index'] for n in self.draft['intent_notes']],
                         [n['index'] for n in envelope['draft']['intent_notes']], 'acceptance indexes stay')
        return envelope

    def test_spec_and_draft_rewritten_together_seal(self):
        approach = 'Bind the authored prose to approved sources and render the exact-head context.'
        envelope = self.preflight_then_seal(dict(approach=approach))
        self.assertEqual(approach, envelope['draft']['approach'])
        self.assertEqual(self.draft['problem'], envelope['draft']['problem'])

    def test_spec_rewrite_with_unchanged_draft_prose_seals(self):
        envelope = self.preflight_then_seal(None)
        for field in ('subject', 'problem', 'expected_result', 'approach', 'intent_notes'):
            self.assertEqual(self.draft[field], envelope['draft'][field], field + ' prose stays')


if __name__ == '__main__':
    unittest.main(verbosity=2)
