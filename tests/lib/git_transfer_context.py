"""Actual Git subprocess evidence for per-call preparation, never real network."""
import importlib.util
import inspect
import json
import os
os.environ['HERDR_ENV'] = '0'
from pathlib import Path
import shlex
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(sys.argv[1])
sys.path.insert(0, str(ROOT/'tests/lib'))
# ssh_transfer_lazy owns the disposable repositories, frozen legacy bytes and
# failing transport fixture. Import consumes the root argument once.
from ssh_transfer_lazy import LazySSH
sys.path.insert(0, str(ROOT/'bin/lib'))
from fm_autopilot import Pilot

OPTIONS = ['-o', 'ConnectTimeout=20', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4']


class Context(LazySSH):
    def invoke(self, env, prefix, mode='python'):
        self.log.unlink(missing_ok=True)
        argv = ['git', *prefix, 'ls-remote', 'ssh://example.invalid/repo']
        before = dict(env)
        if mode == 'shell':
            result = subprocess.run(['bash', '-c', '. "$1/bin/fm-config.sh"; shift; fm_git_transfer "$@"',
                                     '_', str(ROOT), *argv], env=env, cwd=self.home,
                                    capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
        else:
            module = ROOT/'bin/lib/fm_git_transfer.py'
            # Historical base still reaches actual Git. Its identity assertion
            # fails concretely rather than treating missing imports as proof.
            if module.exists():
                spec = importlib.util.spec_from_file_location('context_prepare', module)
                preparation = importlib.util.module_from_spec(spec); spec.loader.exec_module(preparation)
                argv, child = preparation.prepare(argv, cwd=self.home, env=env, code_root=ROOT)
            else:
                child = env
            pilot = object.__new__(Pilot)
            with patch.dict(os.environ, child, clear=True):
                # Real checked/probe execute Git on head and immutable historical
                # APIs. The historical path must fail an identity assertion,
                # rather than a new keyword/signature or missing-module error.
                with self.assertRaises(ValueError):
                    if 'env' in inspect.signature(Pilot.checked).parameters:
                        pilot.checked(argv, env=child)
                    else:
                        pilot.checked(argv)
        self.assertEqual(env, before, 'preparation must not mutate caller environment')
        return [json.loads(row) for row in self.calls() if row.startswith('[')]

    def test_original_variant_port_semantics(self):
        from fm_git_transfer import prepare
        argv = ['git', '-C', str(self.a), 'ls-remote', 'ssh://example.invalid:2222/repo']
        for command in ('ssh', 'ssh.exe', 'plink', 'plink.exe', 'tortoiseplink', 'tortoiseplink.exe', 'putty', 'unknown'):
            if command not in ('ssh',):
                self.script(command, (self.tools/'ssh').read_text())
            for selection in ('explicit', 'config', 'repository', 'count', 'parameters'):
                for variant in (None, 'auto', 'AUTO', 'unknown', 'ssh', 'simple', 'putty'):
                    with self.subTest(command=command, selection=selection, variant=variant):
                        env = dict(self.env)
                        if selection == 'explicit': env['GIT_SSH_COMMAND'] = command
                        else:
                            env.update(GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='core.sshCommand',
                                       GIT_CONFIG_VALUE_0=command)
                        call = list(argv)
                        if variant is not None:
                            if selection == 'config':
                                call[3:3] = ['-c', 'ssh.variant=' + variant]
                            elif selection == 'repository':
                                subprocess.run([self.git, '-C', str(self.a), 'config', 'ssh.variant', variant],
                                               env=self.env, check=True)
                            elif selection == 'count':
                                env.update(GIT_CONFIG_COUNT='2', GIT_CONFIG_KEY_1='ssh.variant',
                                           GIT_CONFIG_VALUE_1=variant)
                            elif selection == 'parameters':
                                env['GIT_CONFIG_PARAMETERS'] = "'ssh.variant=" + variant + "'"
                            else:
                                env['GIT_SSH_VARIANT'] = variant
                        if selection != 'repository' or variant is None:
                            subprocess.run([self.git, '-C', str(self.a), 'config', '--unset-all', 'ssh.variant'],
                                           env=self.env, capture_output=True)
                        before = dict(env)
                        observations = []
                        for prepared in (False, True):
                            self.log.unlink(missing_ok=True)
                            args, child = prepare(call, cwd=self.home, env=env, code_root=ROOT) if prepared else (call, env)
                            result = subprocess.run(args, env=child, cwd=self.home, capture_output=True, timeout=10)
                            rows = [json.loads(row) for row in self.calls() if row.startswith('[')]
                            observations.append((result, rows))
                        self.assertEqual(env, before)
                        original, wrapped = observations
                        self.assertNotEqual(wrapped[0].returncode, 0)
                        # OpenSSH options only for the resolved ssh variant.
                        openssh = variant == 'ssh' or (variant in (None, 'auto') and
                                                       command in ('ssh', 'ssh.exe'))
                        self.assertEqual([(OPTIONS if openssh else []) + r[1] for r in original[1]],
                                         [r[1] for r in wrapped[1]],
                                         'wrapper must preserve discovery and actual port arguments')
                        self.assertEqual(b"does not support setting port" in original[0].stderr,
                                         b"does not support setting port" in wrapped[0].stderr)

    def upload_pack_stub(self, name):
        """Local SSH stub: record argv and environment, then serve real upload-pack."""
        return self.script(name, """#!/usr/bin/env python3
import json, os, shlex, sys
with open(os.environ['SSH_LOG'], 'a') as f:
    f.write(json.dumps([os.path.basename(sys.argv[0]), sys.argv[1:], os.environ.get('GIT_SSH_VARIANT'),
        {key: value for key, value in os.environ.items()
         if key in ('GIT_SSH', 'GIT_SSH_COMMAND') or key.startswith('FM_SSH_')}])+'\\n')
if '-G' in sys.argv:
    sys.exit(255)
command = shlex.split(sys.argv[-1])
os.execv(os.environ['REAL_GIT'], [os.environ['REAL_GIT'], 'upload-pack', command[-1]])
""")

    def bare_remote(self, name):
        remote = self.home/name
        subprocess.run([self.git, 'init', '--bare', '-q', str(remote)], env=self.env, check=True)
        return remote

    def clone_rows(self, argv, env, prepared):
        from fm_git_transfer import prepare
        before = dict(env)
        destination = Path(argv[-1])
        self.log.unlink(missing_ok=True)
        if prepared:
            args, child = prepare(argv, cwd=self.home, env=env, code_root=ROOT)
            self.assertEqual(args, argv, 'clone arguments reach Git unchanged')
            self.assertFalse(destination.exists(), 'preparation never creates the destination')
            self.assertFalse(any(' config ' in row for row in self.calls()),
                             'clone preparation reads no configuration')
        else:
            args, child = argv, env
        result = subprocess.run(args, cwd=self.home, env=child, capture_output=True, timeout=30)
        self.assertEqual(env, before, 'clone preparation must not change parent environment')
        rows = [json.loads(row) for row in self.calls() if row.startswith('[')]
        return result, rows, child

    def test_clone_default_transport_is_git_owned(self):
        # Row 1: no operator override. Git starts its own ssh with its own args.
        self.upload_pack_stub('ssh')
        remote = self.bare_remote('clone-default-remote')
        url = 'ssh://example.invalid' + str(remote)
        sourced = self.source()
        self.assertEqual(sourced['GIT_SSH_COMMAND'], sourced['FM_SSH_GENERATED_COMMAND'])
        native = self.clone_rows(['git', 'clone', '-q', url, str(self.home/'native')], self.env, False)
        self.assertEqual(native[0].returncode, 0, native[0].stderr)
        result, rows, child = self.clone_rows(['git', 'clone', '-q', url, str(self.home/'prepared')],
                                              sourced, True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home/'prepared/.git').is_dir())
        self.assertNotIn('GIT_SSH_COMMAND', child, 'generated command removed from clone child')
        self.assertNotIn('GIT_SSH', child)
        self.assertEqual([key for key in child if key.startswith('FM_SSH_')], [])
        self.assertTrue(rows, 'clone must reach the local SSH stub')
        self.assertEqual([row[1] for row in rows], [row[1] for row in native[1]],
                         'clone transport receives Git own argument list')
        for row in rows:
            self.assertEqual(row[0], 'ssh')
            self.assertFalse(any('ConnectTimeout' in arg or 'ServerAlive' in arg for arg in row[1]),
                             'clone receives no firstmate options')
            self.assertEqual(row[3], {}, 'clone transport sees no firstmate SSH variables')
        # The named shell boundary behaves the same way.
        self.log.unlink(missing_ok=True)
        shell = subprocess.run(['bash', '-c', '. "$1/bin/fm-config.sh"; shift; fm_git_transfer "$@"', '_',
                                str(ROOT), 'git', 'clone', '-q', url, str(self.home/'shell')],
                               env=self.env, cwd=self.home, capture_output=True, timeout=30)
        self.assertEqual(shell.returncode, 0, shell.stderr)
        shell_rows = [json.loads(row) for row in self.calls() if row.startswith('[')]
        self.assertEqual([row[1] for row in shell_rows], [row[1] for row in native[1]])
        self.assertTrue(all(row[3] == {} for row in shell_rows), shell_rows)
        # Unknown Git prefix options still fail closed before any transport.
        from fm_git_transfer import prepare
        self.log.unlink(missing_ok=True)
        with self.assertRaises(ValueError):
            prepare(['git', '--unknown', 'clone', url, str(self.home/'refused')],
                    cwd=self.home, env=sourced, code_root=ROOT)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.home/'refused').exists())

    def test_clone_operator_override_reaches_git_unchanged(self):
        # Row 2: the operator's own GIT_SSH or GIT_SSH_COMMAND is Git's to use.
        stub = self.upload_pack_stub('operator-ssh')
        remote = self.bare_remote('clone-operator-remote')
        url = 'ssh://example.invalid' + str(remote)
        for label, override in (('executable', {'GIT_SSH': str(stub)}),
                                ('command', {'GIT_SSH_COMMAND': "'" + str(stub) + "' -i 'operator key'"})):
            with self.subTest(override=label):
                sourced = self.source(dict(self.env, **override))
                self.assertNotIn('FM_SSH_GENERATED_COMMAND', sourced)
                operator = {key: sourced[key] for key in ('GIT_SSH', 'GIT_SSH_COMMAND') if key in sourced}
                native = self.clone_rows(['git', 'clone', '-q', url, str(self.home/('native-' + label))],
                                         sourced, False)
                self.assertEqual(native[0].returncode, 0, native[0].stderr)
                result, rows, child = self.clone_rows(
                    ['git', 'clone', '-q', url, str(self.home/('prepared-' + label))], sourced, True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual({key: child[key] for key in ('GIT_SSH', 'GIT_SSH_COMMAND') if key in child},
                                 operator, 'operator variable reaches Git unchanged')
                self.assertEqual([key for key in child if key.startswith('FM_SSH_')], [])
                self.assertTrue(rows)
                self.assertTrue(all(row[0] == 'operator-ssh' for row in rows), rows)
                self.assertEqual([row[1] for row in rows], [row[1] for row in native[1]],
                                 'operator program receives Git arguments')
                self.assertTrue(all(row[3] == operator for row in rows), rows)

    def network_rows(self, verb, env, prefix=()):
        self.log.unlink(missing_ok=True)
        before = dict(env)
        argv = ['git', '-C', str(self.c), *prefix, verb, 'ssh://example.invalid/repo']
        if verb == 'push':
            argv.append('HEAD:refs/heads/transfer')
        result = subprocess.run(['python3', str(ROOT/'bin/lib/fm_git_transfer.py'), *argv],
                                env=env, cwd=self.home, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0, 'failing stub keeps the transfer failed')
        self.assertEqual(env, before)
        return [json.loads(row) for row in self.calls() if row.startswith('[')]

    def test_fetch_and_push_options_follow_resolved_variant(self):
        # Row 3: options only when the resolved variant is OpenSSH.
        self.c = self.repo('c')
        subprocess.run([self.git, '-C', str(self.c), '-c', 'user.name=t', '-c', 'user.email=t@t',
                        'commit', '-q', '--allow-empty', '-m', 'base'], env=self.env, check=True)
        sourced = self.source()
        configured = ('-c', 'core.sshCommand=two')
        cases = [('default', sourced, (), 'ssh', True),
                 ('config-ssh', sourced, (*configured, '-c', 'ssh.variant=ssh'), 'two', True),
                 ('environment-ssh', dict(sourced, GIT_SSH_VARIANT='ssh'), configured, 'two', True)]
        for variant in ('simple', 'plink', 'putty', 'tortoiseplink'):
            cases.append(('config-' + variant, sourced,
                          (*configured, '-c', 'ssh.variant=' + variant), 'two', False))
        cases.append(('auto-unrecognized', sourced, configured, 'two', False))
        cases.append(('explicit-auto-unrecognized', dict(sourced, GIT_SSH_VARIANT='auto'),
                      configured, 'two', False))
        for verb in ('fetch', 'push'):
            for label, env, prefix, name, bounded in cases:
                with self.subTest(verb=verb, variant=label):
                    rows = self.network_rows(verb, env, prefix)
                    if bounded:
                        self.bounded(rows, name)
                    else:
                        self.unbounded(rows, name)
                    if label.endswith('unrecognized'):
                        self.assertIn('-G', rows[0][1], 'unrecognized program keeps Git discovery')

    def test_prepared_calls_leave_parent_and_frozen_code_unchanged(self):
        # Row 4: parent environment and frozen snapshot stay unchanged.
        import hashlib
        import shutil
        from fm_git_transfer import prepare
        frozen = self.home/'frozen-code'
        shutil.copytree(ROOT/'bin', frozen/'bin')
        def digest():
            return {str(p.relative_to(frozen)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in frozen.rglob('*') if p.is_file()}
        before_code = digest()
        env = self.source(dict(self.env, FM_CODE_ROOT=str(frozen)), frozen)
        before = dict(env)
        for argv in (['git', '-C', str(self.a), 'fetch', 'ssh://example.invalid/repo'],
                     ['git', 'clone', 'ssh://example.invalid/repo', str(self.home/'frozen-clone')]):
            args, child = prepare(argv, cwd=self.home, env=env, code_root=frozen)
            self.assertEqual(args, argv)
            self.assertEqual(env, before)
            if 'clone' in argv:
                self.assertNotIn('GIT_SSH_COMMAND', child)
            else:
                self.assertEqual(shlex.split(child['GIT_SSH_COMMAND']),
                                 [str(frozen/'bin/lib/fm-ssh-transfer.sh')])
            subprocess.run(args, cwd=self.home, env=child, capture_output=True, timeout=10)
        self.assertEqual(env, before)
        self.assertEqual(digest(), before_code, 'frozen code snapshot unchanged')
        self.assertFalse((self.home/'frozen-clone').exists(), 'Git owns failed-clone cleanup')

    def test_owned_command_yields_to_late_executable(self):
        from fm_git_transfer import prepare
        owned = self.source()
        env = dict(owned, GIT_SSH=str(self.tools/'two'))
        before = dict(env)
        argv, child = prepare(['git', 'ls-remote', 'ssh://example.invalid/repo'], env=env, code_root=ROOT)
        self.assertNotIn('GIT_SSH_COMMAND', child, 'generated command must yield to operator executable')
        self.assertNotIn('FM_SSH_GENERATED_COMMAND', child)
        self.assertEqual(child['GIT_SSH'], env['GIT_SSH'])
        self.assertEqual(env, before)
        for repeat in range(2):
            env = self.source(env)
            self.assertNotIn('GIT_SSH_COMMAND', env, 'source ownership transition must yield')
            self.assertNotIn('FM_SSH_GENERATED_COMMAND', env)
        rows = self.transfer(env)
        self.assertTrue(rows)
        self.assertTrue(all(row[0] == 'two' for row in rows))
        changed = dict(owned, GIT_SSH=str(self.tools/'two'), GIT_SSH_COMMAND='one')
        self.unbounded(self.transfer(changed), 'one')
        marker = dict(self.env, FM_SSH_GENERATED_COMMAND='stale', GIT_SSH=str(self.tools/'two'))
        self.assertNotIn('GIT_SSH_COMMAND', self.source(marker))

    def test_real_binding_transfer_keeps_prepared_identity(self):
        import fm_binding
        env = dict(self.source(), GIT_CONFIG_COUNT='1',
                   GIT_CONFIG_KEY_0='core.sshCommand', GIT_CONFIG_VALUE_0='two')
        self.log.unlink(missing_ok=True)
        before = dict(env)
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaises(ValueError):
                fm_binding.transfer(self.a, 'ls-remote', 'ssh://example.invalid/repo')
            self.assertEqual(dict(os.environ), before)
        calls = [json.loads(row) for row in self.calls() if row.startswith('[')]
        self.assertTrue(calls, 'binding.transfer must reach actual Git SSH transport')
        self.assertEqual(calls[-1][0], 'two', 'binding runner retains prepared child identity')

    def test_shell_and_real_pilot_contexts_after_source(self):
        sourced = self.source()
        contexts = [
            (dict(sourced, GIT_DIR=str(self.b/'.git')), [], 'two'),
            (dict(sourced, GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='core.sshCommand',
                  GIT_CONFIG_VALUE_0='two'), ['-C', str(self.a)], 'two'),
            (dict(sourced, GIT_CONFIG_PARAMETERS="'core.sshCommand=one -i \"parameter identity\"'"),
             ['-C', str(self.b)], 'one'),
            (dict(sourced, GIT_DIR=str(self.b/'.git'), GIT_CONFIG_COUNT='1',
                  GIT_CONFIG_KEY_0='core.sshCommand', GIT_CONFIG_VALUE_0='one'), [], 'one'),
            (dict(sourced, CONFIG_COMMAND='two'), ['-C', str(self.a), '--config-env=core.sshCommand=CONFIG_COMMAND'], 'two'),
            (sourced, ['-C', str(self.b), '-c', 'core.sshCommand=one -i "option identity"'], 'one'),
        ]
        for mode in ('shell', 'python'):
            for env, prefix, name in contexts:
                with self.subTest(mode=mode, prefix=prefix, identity=name):
                    rows = self.invoke(dict(env, GIT_SSH_VARIANT='ssh'), prefix, mode)
                    self.bounded(rows, name)
                    self.assertFalse(any('-G' in row[1] for row in rows))
                    self.assertTrue(all(row[2] == 'ssh' for row in rows))
        # Same sourced ownership, changed inherited config: no source/PID cache.
        for name in ('two', 'one', 'two'):
            self.bounded(self.invoke(dict(sourced, GIT_CONFIG_COUNT='1', GIT_SSH_VARIANT='ssh',
                         GIT_CONFIG_KEY_0='core.sshCommand', GIT_CONFIG_VALUE_0=name),
                         ['-C', str(self.a)]), name)

    def test_actual_git_strips_config_but_prepared_command_keeps_identity(self):
        observer = self.script('observe', '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['SSH_LOG'], 'a') as f:
    f.write(json.dumps(['observe', sys.argv[1:], os.environ.get('GIT_SSH_VARIANT'),
        {key: os.environ.get(key) for key in ('GIT_DIR', 'GIT_CONFIG_COUNT',
         'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')}])+'\\n')
sys.exit(255)
''')
        env = dict(self.source(), GIT_DIR=str(self.b/'.git'), GIT_CONFIG_COUNT='1',
                   GIT_CONFIG_KEY_0='core.sshCommand', GIT_CONFIG_VALUE_0=str(observer),
                   GIT_CONFIG_PARAMETERS="'user.name=strip-parameters-fixture'", GIT_SSH_VARIANT='ssh')
        rows = self.invoke(env, [])
        self.bounded(rows, 'observe')
        for row in rows:
            self.assertEqual({k: row[3][k] for k in ('GIT_DIR', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS')},
                             dict(GIT_DIR=None, GIT_CONFIG_COUNT=None, GIT_CONFIG_PARAMETERS=None),
                             'evidence must come from actual Git SSH child')
            self.assertEqual(row[3]['GIT_CONFIG_KEY_0'], 'core.sshCommand')
            self.assertEqual(row[3]['GIT_CONFIG_VALUE_0'], str(observer))
        # The old helper-only mechanism cannot retain this identity after Git's
        # environment stripping. This mutant queries inside the actual SSH child.
        mutant = self.script('late-helper', '''#!/bin/bash
base="$(git config --get core.sshCommand 2>/dev/null)" || base=ssh
exec /bin/sh -c "$base \\"\\$@\\"" "$base" "$@"
''')
        self.log.unlink()
        subprocess.run(['git', 'ls-remote', 'ssh://example.invalid/repo'], cwd=self.home,
                       env=dict(env, GIT_SSH_COMMAND=str(mutant)), capture_output=True, timeout=10)
        late = [json.loads(row) for row in self.calls() if row.startswith('[')]
        self.assertTrue(late, 'mutant must execute real transport, not fail to import')
        self.assertNotEqual(late[-1][0], 'observe', 'inside-helper query loses concrete intended identity')

    def test_preparation_failure_cleanup_preserves_primary_error(self):
        import fm_binding
        calls = []
        def runner(argv, *, env=None):
            calls.append((argv, env))
            raise ValueError('cleanup also failed')
        with patch.object(fm_binding, 'prepare', side_effect=ValueError('preparation refused')):
            with self.assertRaisesRegex(ValueError, '^preparation refused$'):
                fm_binding.fetch_ref(self.a, 'ssh://example.invalid/repo', 'HEAD', runner=runner)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0][3:5], ['update-ref', '-d'])
        self.assertIsNone(calls[0][1])

    def test_invalid_global_prefix_refuses_before_transport(self):
        from fm_git_transfer import prepare
        self.log.unlink(missing_ok=True)
        for argv in (['git', '--unknown', 'fetch', 'origin'], ['git', '-C']):
            with self.assertRaises(ValueError):
                prepare(argv, cwd=self.home, env=self.source(), code_root=ROOT)
        self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    # Run Context only: its inherited cases retain the complete legacy matrix.
    unittest.main(defaultTest='Context', verbosity=2)
