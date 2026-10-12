"""T-298 unit cases: ui globs, the designer skill's sources, the autopilot's
missing design round and the round budget. Run one case by its test name."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_design

HEAD = 'a' * 40
REGISTRY = """default_project: demo
projects:
  demo:
    repo: .
    github: owner/demo
    base: main
    required_check: ci
"""


class UiGlobs(unittest.TestCase):
    def config(self, text):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name) / 'config.yaml'
        path.write_text(text)
        return path

    def test_project_ui_globs_replace_the_defaults(self):
        path = self.config(REGISTRY + '    ui:\n      - "site/**"\n      - "**/*.page"\n')
        globs = fm_design.ui_globs(path, 'demo')
        self.assertEqual(globs, ['site/**', '**/*.page'])
        changed = ['src/a.html', 'web/b.css', 'site/x.txt', 'deep/c.page', 'bin/d.py']
        self.assertEqual(fm_design.ui_paths(changed, globs), ['site/x.txt', 'deep/c.page'])

    def test_defaults_without_a_project_list(self):
        path = self.config(REGISTRY)
        globs = fm_design.ui_globs(path, 'demo')
        self.assertEqual(globs, fm_design.DEFAULT_UI)
        changed = ['index.html', 'a/b/c.svelte', 'x.scss', 'README.md', 'bin/fm.sh']
        self.assertEqual(fm_design.ui_paths(changed, globs), ['index.html', 'a/b/c.svelte', 'x.scss'])

    def test_this_repository_adds_the_board(self):
        globs = fm_design.ui_globs(ROOT / 'config.yaml', 'firstmate-workflow')
        self.assertEqual(globs, fm_design.DEFAULT_UI + ['board/public/**'])
        self.assertEqual(fm_design.ui_paths(['board/public/board.js', 'board/server.ts'], globs),
                         ['board/public/board.js'])

    def test_a_malformed_ui_list_is_refused(self):
        path = self.config(REGISTRY + '    ui: "**/*.html"\n')
        with self.assertRaises(ValueError):
            fm_design.ui_globs(path, 'demo')

    def test_viewports_include_each_breakpoint_edge(self):
        css = '@media (min-width: 600px) {a{}} @media (max-width: 1000px) {b{}}'
        widths = [w for _, w, _ in fm_design.viewports('web', css)]
        self.assertEqual(widths, [320, 390, 599, 600, 768, 1000, 1001, 1440, 1920])
        apps = [name for name, _, _ in fm_design.viewports('app')]
        self.assertEqual(len(apps), 6)
        self.assertIn('tablet-landscape', apps)


class SkillSources(unittest.TestCase):
    def test_skill_header_lists_every_source_and_notice_exists(self):
        skill = (ROOT / 'skills/designer/SKILL.md').read_text()
        header = skill.split('\n---\n', 1)[0]
        rows = [line.strip()[2:] for line in header.splitlines() if line.strip().startswith('- ')]
        expected = {'pbakaus/impeccable': 'Apache-2.0', 'OneRedOak/claude-code-workflows': 'MIT',
                    'vercel-labs/web-interface-guidelines': 'MIT', 'ehmo/platform-design-skills': 'MIT',
                    'nextlevelbuilder/ui-ux-pro-max-skill': 'MIT', 'anthropics/skills': 'Apache-2.0'}
        found = {}
        for row in rows:
            cells = [cell.strip() for cell in row.split('|')]
            found[cells[0]] = cells
        self.assertEqual(sorted(found), sorted(expected))
        notice = (ROOT / 'skills/designer/NOTICE').read_text()
        for repo, license in expected.items():
            cells = found[repo]
            self.assertIn(license, cells, repo)
            commit = next((c for c in cells if c.startswith('commit:')), '')
            self.assertRegex(commit, r'^commit: [0-9a-f]{7,40}$', repo + ' names its commit')
            self.assertIn(repo, notice)
            self.assertIn(commit.split(' ', 1)[1], notice, repo + ' commit in NOTICE')
        self.assertIn('Apache License, Version 2.0', notice)
        self.assertIn('Permission is hereby granted, free of charge', notice)


class MissingRound(unittest.TestCase):
    """The autopilot starts whichever review gate 6 reports missing."""

    def pilot(self):
        import fm_autopilot as A
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = Path(folder.name).resolve()
        (root / 'state').mkdir(); (root / 'tasks').mkdir()
        ctx = dict(engine=str(root), state=str(root / 'state'), target=str(root), project='self',
                   repository='owner/repo', base='main', evidence_project='self', external=False,
                   tasks=str(root / 'tasks'))
        pilot = A.Pilot(ctx, clock=lambda: 1000)
        self.calls = []
        pilot.launch_review = lambda *a: self.calls.append('code')
        pilot.launch_design_review = lambda *a: self.calls.append('design')
        pilot.queue = lambda *a, **k: self.calls.append('wake')
        pilot.landed = lambda *a: False
        pilot.round_budget = lambda *a: dict(state='within')
        pilot.authoritative_head = lambda *a: HEAD
        pilot.policy = dict(pilot.policy, review='fm')
        return pilot

    def gate(self, output):
        pilot = self.pilot()
        pr = dict(number=7, head=dict(sha=HEAD, ref='t-001'), base=dict(sha='b' * 40, ref='main'))
        pilot._job_completed(dict(kind='gate', task='T-001', pr=pr, code=6, output=output, base='b' * 40, round=1))
        return self.calls

    def test_missing_design_round_started(self):
        self.assertEqual(self.gate('  lane code: ok\n  lane design: missing (no design review exists)\n'), ['design'])

    def test_both_missing_start_together(self):
        self.assertEqual(self.gate('  lane code: missing\n  lane design: missing (x)\n'), ['code', 'design'])

    def test_non_ui_starts_only_the_code_review(self):
        self.assertEqual(self.gate('  lane code: missing\n  lane design: not-needed (no path matches)\n'), ['code'])


class RoundBudget(unittest.TestCase):
    def test_design_reject_counts_a_round(self):
        from fm_evidence import Store
        from fm_round_budget import rounds
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        store = Store(folder.name, 'self', 'T-001', external=False)
        legacy = dict(provenance={'level': 'legacy'}, severity_protocol=1)
        store.append('verdict', 1, 'reviewer-ada-t001-r1', HEAD, 'APPROVE:T-001', verdict='APPROVE', **legacy)
        self.assertEqual([r['verdict'] for r in rounds(store)], ['APPROVE'])
        text = '1. [must-fix] page w390: header overlaps\nCRITERIA-COMPLETE:T-001\nREJECT:T-001'
        store.append('verdict', 1, 'reviewer-bo-ds-t001-r1', HEAD, text, verdict='REJECT', lane='design', **legacy)
        rows = rounds(store)
        self.assertEqual([(r['round'], r['verdict']) for r in rows], [(1, 'REJECT')])
        self.assertEqual(rows[0]['must'], [1])
        # the code lane stays the code reviewer's alone
        self.assertEqual([r['verdict'] for r in store.verdicts()], ['APPROVE'])
        self.assertEqual([r['verdict'] for r in store.verdicts('design')], ['REJECT'])
        self.assertIn('Local design review round 1', store.history())
        self.assertNotIn('header overlaps', store.history(True, 'code'))


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *sys.argv[1:]], verbosity=1)
