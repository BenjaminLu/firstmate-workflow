"""Behavioral diff-reference assertions; helper import failures are setup errors."""
import importlib.util
from pathlib import Path
import hashlib
import sys
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_card_refs as refs


class CardRefs(unittest.TestCase):
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

    def test_missing_files_paths_and_repository_identity(self):
        with self.assertRaisesRegex(ValueError, 'absent'):
            refs.point_code([], ['missing'])
        for path in ('/a', '../a', 'a/./b', 'a//b', 'a\x00b'):
            with self.subTest(path=path), self.assertRaises(ValueError): refs.repository_path(path)
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


if __name__ == '__main__': unittest.main()
