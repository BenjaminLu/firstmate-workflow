#!/usr/bin/env bash
# Per-call fetch refs survive another review's fetch in the same repository.
set -euo pipefail
export HERDR_ENV=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(sys.argv[1]) / 'bin/lib'))
import fm_binding as binding
from fm_autopilot import Pilot

A, B, BASE = 'a' * 40, 'b' * 40, 'c' * 40


class GitStub:
    """Model refspec destinations and the shared pseudo-ref just as git does."""
    def __init__(self):
        self.refs = {'task-a^{commit}': A, 'task-b^{commit}': B, 'main^{commit}': BASE}
        self.sources = {'refs/pull/1/head': A, 'refs/pull/2/head': B, 'refs/heads/main': BASE}
        self.destinations = []
        self.after_fetch = None
        self.failure = None
        self.deleted = []

    def command(self, argv, *, env=None):
        assert argv[:3] == ['git', '-C', '/repo'], argv
        args = argv[3:]
        assert env == ({'FM_FIXTURE_TRANSFER': 'private'} if args[0] == 'fetch' else None), env
        if args[:1] == ['fetch']:
            assert args[:3] == ['fetch', '--no-tags', 'https://github.com/owner/repo.git'], args
            source, sep, dest = args[3].lstrip('+').partition(':')
            value = self.sources[source]
            self.refs['FETCH_HEAD'] = value
            if sep:
                assert args[3].startswith('+') and dest.startswith('refs/fm/fetch/'), args
                self.destinations.append(dest)
                self.refs[dest] = value
            if self.failure == 'fetch':
                raise ValueError('binding command failed: fetch refused')
            if self.after_fetch:
                callback, self.after_fetch = self.after_fetch, None
                callback()
            return b''
        if args[:1] == ['rev-parse']:
            if self.failure == 'read':
                raise ValueError('binding command failed: read refused')
            if self.failure == 'invalid':
                return b'not-a-sha\n'
            return (self.refs[args[1]] + '\n').encode()
        if args[:2] == ['update-ref', '-d']:
            self.deleted.append(args[2])
            self.refs.pop(args[2], None)
            return b''
        raise AssertionError(args)

    def private_refs(self):
        return [name for name in self.refs if name.startswith('refs/fm/fetch/')]


class PrivateFetch(unittest.TestCase):
    def setUp(self):
        preparation = patch.object(binding, 'prepare', side_effect=lambda argv, **kw:
                                   (argv, {'FM_FIXTURE_TRANSFER': 'private'}))
        preparation.start(); self.addCleanup(preparation.stop)

    def test_interleaved_authoritative_prs_keep_their_own_heads(self):
        stub = GitStub()
        results = {}
        def view(repository, pr):
            return dict(headRefOid={1: A, 2: B}[pr], baseRefOid=BASE, baseRefName='main', state='OPEN')
        def second_review():
            results['b'] = binding.authoritative('/repo', 'task-b', 'owner/repo', 2)
        stub.after_fetch = second_review
        errors = []
        with patch.object(binding, 'command', side_effect=stub.command), \
             patch.object(binding, 'remote_head', side_effect=view):
            try:
                results['a'] = binding.authoritative('/repo', 'task-a', 'owner/repo', 1)
            except ValueError as error:
                errors.append(str(error))
        self.assertEqual(errors, [], 'another review must not invalidate this PR head')
        self.assertEqual(results, {'a': A, 'b': B}, 'interleaved reviews must retain their own PR heads')
        self.assertEqual(stub.private_refs(), [])
        self.assertEqual(len(stub.destinations), 4)
        self.assertEqual(len(set(stub.destinations)), 4, 'every fetch, including the same base, needs a fresh ref')
        self.assertCountEqual(stub.deleted, stub.destinations)

    def test_private_refs_removed_after_success_and_errors(self):
        for failure in (None, 'fetch', 'read', 'invalid'):
            with self.subTest(failure=failure):
                stub = GitStub()
                stub.failure = failure
                with patch.object(binding, 'command', side_effect=stub.command):
                    if failure:
                        message = 'invalid full head SHA' if failure == 'invalid' else failure + ' refused'
                        with self.assertRaisesRegex(ValueError, message):
                            binding.fetch_ref('/repo', 'https://github.com/owner/repo.git', 'refs/pull/1/head')
                    else:
                        self.assertEqual(binding.fetch_ref('/repo', 'https://github.com/owner/repo.git',
                                                          'refs/pull/1/head'), A)
                self.assertEqual(stub.private_refs(), [], 'temporary fetch refs must be deleted even on error')
                self.assertEqual(stub.deleted, stub.destinations)
                self.assertEqual(len(stub.destinations), 1)

    def test_autopilot_uses_its_runner_and_preserves_fetch_error(self):
        pilot = object.__new__(Pilot)
        pilot.ctx = dict(target='/repo', repository='owner/repo')
        stub = GitStub()
        stub.failure = 'fetch'
        def command(argv, *, env=None):
            try:
                return stub.command(argv, env=env).decode()
            except ValueError as error:
                raise RuntimeError('autopilot fetch refused') from error
        pilot.command = command
        with self.assertRaisesRegex(RuntimeError, 'autopilot fetch refused'):
            pilot.prepare_head(dict(number=1, head=dict(sha=A)))
        self.assertEqual(len(stub.destinations), 1)
        self.assertEqual(stub.private_refs(), [])
        self.assertEqual(stub.deleted, stub.destinations)

unittest.main(argv=['private-fetch'])
PY
