#!/usr/bin/env bash
# T-140 launcher regressions; tests/lib/crew_blocks.py executes real shell blocks.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 - "$ROOT" <<'PY'
import json, shlex, sys, tempfile, unittest
from pathlib import Path
sys.dont_write_bytecode=True
root=Path(sys.argv[1]); sys.path[:0]=[str(root/'tests/lib'),str(root/'bin/lib')]
from crew_blocks import section, function, shell
from fm_onboard import infer, approve
worker=root/'bin/fm-worker.sh'; reviewer=root/'bin/fm-review.sh'

class LauncherProjection(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.home=Path(self.tmp.name)
        evidence=dict(repository='owner/app',base='main',source='github',pulls=[],commits=[],
            repository_info={'allow_squash_merge':True,'allow_merge_commit':False,'allow_rebase_merge':False,'delete_branch_on_merge':False},protection={'status':'unknown'})
        approve(self.home,evidence,infer(evidence),dict(confirmed=True,policy_confirmed=True,
            captain='captain',intent='Private intent',product='Private product',required_checks=['ci'],
            contract={'check':'true'},review='external',post='summary'))
        (self.home/'note').write_text('PRIVATE report\n')
    def run_block(self,body,prefix=''):
        for name in ('calls','events'):
            (self.home/name).unlink(missing_ok=True)
        p=shell(root,self.home,body,prefix)
        self.assertEqual(p.returncode,0,p.stderr)
        return p
    def recorder(self,fail=False):
        return 'fm_external() { printf "%s\\n" "$*" >> "$work/calls"; '+('return 1;' if fail else 'echo linked-findings;')+' };\n'
    def test_no_pr_note_in_every_noncomment_mode_reaches_publication(self):
        retention=section(worker,'asked=0\n','# gh\'s own words')
        delivery=section(worker,'if [ "$projection" = comments ] && [ "$asked" = 1 ] && [ -z "$PR" ]', '\n# asking IS the work')
        for mode in ('local','summary','check','threads'):
            with self.subTest(mode=mode):
                (self.home/'note').write_text('PRIVATE report\n')
                p=self.run_block(retention+delivery+'echo publication-reached',
                    'projection='+mode+'; PR=""; held=""; rebuilt=0; round_number=1; NAME=worker; say="$work/note";\n'
                    'fm_evidence() { printf "%s\\n" "$*" >> "$work/retained"; };\n'
                    'keep_unsent() { exit 73; }; rebuild_publishes() { return 1; }; first_round_question() { return 1; };\n')
                self.assertIn('publication-reached',p.stdout)
                self.assertIn('--file '+str(self.home/'note'),(self.home/'retained').read_text())
    def test_post_note_projection_failure_is_warned_and_delivered(self):
        for mode in ('summary','check','threads','comments'):
            with self.subTest(mode=mode):
                p=self.run_block(function(worker,'note_landed')+function(worker,'post_note')+'post_note "$work/note" 9; result=$?; echo "$result:$spoke"',
                    'projection='+mode+'; spoke=0; rebuild_publishes() { return 1; };\n'+self.recorder(True)+
                    'fm_comment_projection() { echo comment >> "$work/calls"; return 1; };\n')
                self.assertEqual(p.stdout.strip().splitlines()[-1],'0:1')
                self.assertIn('projection_failed',(self.home/'events').read_text())
                self.assertIn('PRIVATE report','\n'.join(f.read_text() for f in (self.home/'state').rglob('*.md')))
                self.assertIn('comment' if mode=='comments' else 'project --pr 9 --head abc --stage worker',
                              (self.home/'calls').read_text())
    def test_external_transient_refusal_is_not_retried_or_looked_up(self):
        transient = ('GraphQL: Something went wrong while executing your query on 2026-10-04T17:11:07Z. '
                     'Please include `C81F:1B67BD:77CAE6:96A060:6AC288AB` when reporting this issue.')
        gh = self.home/'gh'
        gh.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "'+str(self.home/'calls')+'"\nexit 1\n')
        gh.chmod(0o755)
        p=self.run_block(function(worker,'note_landed')+function(worker,'post_note')+
            'post_note "$work/note" 9; echo "$spoke"',
            'projection=comments; spoke=0;\n'+self.recorder(True)+
            'fm_comment_projection() { echo comment >> "$work/calls"; cat "$3" > "$work/offered"; '
            'echo '+shlex.quote(transient)+' >&2; return 1; };\n')
        self.assertEqual(p.stdout.strip().splitlines()[-1], '1')
        self.assertEqual((self.home/'calls').read_text(), 'comment\n')
        self.assertEqual((self.home/'offered').read_bytes(), (self.home/'note').read_bytes())
        self.assertNotIn('worker_note_unsent', (self.home/'events').read_text())

    def test_external_private_note_failure_with_changes_stays_private(self):
        functions=''.join(function(worker,name) for name in
                          ('note_landed','post_note','save_unsent','keep_unsent','note_refused','note_unsent'))
        delivery=section(worker,'if [ "$projection" = comments ] && [ "$asked" = 1 ] && [ -z "$PR" ]', '\n# asking IS the work')
        p=shell(root,self.home,functions+delivery+'echo round-continued',
            'projection=comments; spoke=0; asked=1; held=""; rebuilt=0; say="$work/note";\n'
            'worker_changed_files() { return 0; }; fm_private_note() { return 1; };\n')
        self.assertEqual(p.returncode,73,p.stderr)
        self.assertNotIn('round-continued',p.stdout)
        self.assertFalse((self.home/'comments').exists())
        events=(self.home/'events').read_text()
        self.assertIn('worker_crashed',events)
        self.assertNotIn('worker_note_unsent',events)

    def test_self_comment_refusal_keeps_note_and_fails_round(self):
        functions=''.join(function(worker,name) for name in
                          ('note_landed','post_note','save_unsent','keep_unsent','note_refused','note_unsent'))
        delivery=section(worker,'if [ "$projection" = comments ] && [ "$asked" = 1 ] && [ -z "$PR" ]', '\n# asking IS the work')
        p=shell(root,self.home,functions+delivery+'echo round-continued',
            'FM_EXTERNAL=0; projection=comments; spoke=0; asked=1; held=""; rebuilt=0; say="$work/note";\n'
            'fm_comment_projection() { echo comment >> "$work/calls"; echo refused >&2; return 1; };\n')
        self.assertEqual(p.returncode,73,p.stderr)
        self.assertNotIn('round-continued',p.stdout)
        self.assertIn('#9 would not take the comment',p.stderr)
        self.assertIn('gh: refused',p.stderr)
        self.assertEqual((self.home/'calls').read_text(),'comment\n')
        kept=list((self.home/'state/unsent').glob('T-Z-*.md'))
        self.assertEqual(len(kept),1)
        self.assertEqual(kept[0].read_text(),'PRIVATE report\n')
        self.assertIn('worker_crashed',(self.home/'events').read_text())
    def test_tail_uses_published_head_and_failure_does_not_end_round(self):
        block=section(worker,'# Publication is complete:', '# the note refused above')
        for fail in (False,True):
            p=self.run_block(block+'echo round-continued',
                'projection=summary; num=19; git() { echo published-head; };\n'+self.recorder(fail))
            self.assertIn('round-continued',p.stdout)
            self.assertIn('project --pr 19 --head published-head --stage worker',(self.home/'calls').read_text())
            if fail: self.assertIn('projection_failed',(self.home/'events').read_text())
    def test_reviewer_external_prompt_and_unknown_fallback(self):
        block=section(reviewer,'{\n  # Either mode:', '{\n  printf \'\\n---\\n\\n# The diff')
        for fail in (False,True):
            self.run_block(block,'head_evidence() { echo head-evidence; };\n'+self.recorder(fail))
            evidence=(self.home/'evidence.md').read_text()
            self.assertIn('External reviewer evidence',evidence)
            self.assertIn('coverage is unknown' if fail else 'linked-findings',evidence)
            self.assertIn('collect --pr 9 --head abc --format prompt',(self.home/'calls').read_text())
    def test_reviewer_projection_is_optional_and_head_bound(self):
        block=section(reviewer,'if [ "$FM_EXTERNAL" = 1 ] && [ -n "$PR" ] && [ "$projection" != comments ]; then', 'case "$decided" in')
        for mode in ('local','summary','check','threads'):
            for fail in (False,True):
                p=self.run_block(block+'echo review-continued','projection='+mode+';\n'+self.recorder(fail))
                self.assertIn('review-continued',p.stdout)
                self.assertIn('project --pr 9 --head abc --stage reviewer',(self.home/'calls').read_text())
                if fail: self.assertIn('projection_failed',(self.home/'events').read_text())

unittest.main(argv=['external-review-launchers'],verbosity=2)
PY
assert_eq 0 "$?" 'external projection launcher delivery and call contracts'
finish
