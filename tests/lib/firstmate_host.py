"""T-174 integration fixtures: no vendor sessions or ambient settings."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='fm-host-') as temporary:
    root = Path(temporary) / 'engine'
    root.mkdir()
    shutil.copytree(ROOT / 'bin', root / 'bin')
    home = Path(temporary) / 'home'
    home.mkdir()
    stubs = Path(temporary) / 'stubs'
    stubs.mkdir()
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('FM_', 'HERDR_', 'CLAUDE', 'CODEX', 'XDG_'))}
    env.update(HOME=str(home), CODEX_HOME=str(home / '.codex'),
               PATH=str(stubs) + os.pathsep + env['PATH'], HERDR_ENV='0',
               FIRSTMATE_CI_SESSION='1', FM_ROOT=str(root))
    for cli, version in [('claude', '2.1.80 (Claude Code)'), ('codex', 'codex-cli 0.116.0')]:
        script = stubs / cli
        script.write_text('#!/bin/sh\n[ "$1" = --version ] || exit 64\nprintf "%s\\n" "' + version + '"\n')
        script.chmod(0o755)
    config = root / 'config.yaml'
    base = ('vendor: opposite-of-host\nreviewer:\n  vendor: claude\n'
            'models:\n  claude: configured-worker-model\n'
            'fallback:\n  - claude\n  - codex\n  - cursor-agent\n  - gemini\n')
    config.write_text(base)
    state = root / 'state/session'
    state.mkdir(parents=True)
    record = state / 'host.json'

    def shell(code, **extra):
        result = subprocess.run(['bash', '-c', '. "$1/bin/fm-config.sh"; ' + code,
                                 'fixture', str(root)], cwd=root, env=dict(env, **extra),
                                text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        return result

    def host(value):
        record.write_text(json.dumps({'harness': value}))

    for harness, chain in [('claude', 'codex\nclaude\ncursor-agent\ngemini'),
                           ('codex', 'claude\ncodex\ncursor-agent\ngemini')]:
        host(harness)
        result = shell('fm_vendor_chain worker', FM_HARNESS='cursor')
        assert result.stdout.strip() == chain, (harness, result)
        assert shell('fm_role_vendor worker').stdout.strip() == chain.splitlines()[0]
    for harness in [None, 'cursor']:
        host(harness)
        result = shell('fm_vendor_chain worker')
        assert result.stdout.strip() == 'claude\ncodex\ncursor-agent\ngemini', result
        assert 'fallback' in result.stderr and 'opposite-of-host' in result.stderr, result
    record.unlink()
    assert 'fallback' in shell('fm_vendor_chain worker').stderr
    host('codex')
    assert shell('fm_vendor_chain worker gemini').stdout.strip() == 'gemini'
    config.write_text(base.replace('vendor: opposite-of-host', 'vendor: codex', 1))
    assert shell('fm_role_vendor worker').stdout.strip() == 'codex'
    config.write_text(base.replace('vendor: opposite-of-host', 'vendor: gemini', 1) +
                      'worker:\n  vendor: opposite-of-host\n')
    assert shell('fm_role_vendor worker').stdout.strip() == 'claude'
    config.unlink()
    assert shell('set -o pipefail; fm_vendor_chain worker').stdout.strip() == 'mock'
    config.write_text(base)
    assert shell('fm_vendor_chain reviewer').stdout.strip() == 'claude\ncodex\ncursor-agent\ngemini'
    host('claude')
    adapters = root / 'fake-adapters'
    adapters.mkdir()
    prompt = root / 'prompt'
    prompt.write_text('fixture')
    for vendor, status in [('codex', 2), ('claude', 2), ('cursor-agent', 0), ('gemini', 0)]:
        file = adapters / (vendor + '.sh')
        file.write_text('#!/bin/sh\nprintf "%s\\n" "' + vendor + '" >> "$4"\nexit ' + str(status) + '\n')
        file.chmod(0o755)
    shell('fm_run_chain "$1/fake-adapters" "$(fm_vendor_chain worker)" "$1/prompt" "$1" "$1/chain.log"')
    assert (root / 'chain.log').read_text().splitlines() == ['codex', 'claude', 'cursor-agent']
    (adapters / 'codex.sh').write_text('#!/bin/sh\nprintf "codex\\n" >> "$4"\nexit 1\n')
    (root / 'chain.log').unlink()
    shell('fm_run_chain "$1/fake-adapters" "$(fm_vendor_chain worker)" "$1/prompt" "$1" "$1/chain.log"; [ "$?" = 1 ]')
    assert (root / 'chain.log').read_text().splitlines() == ['codex']
    host('codex')
    # A dispatch child has unrelated harness environment and the selected
    # project's state. It must still use that project's recorded firstmate.
    private = Path(temporary) / 'private/state'
    (private / 'session').mkdir(parents=True)
    (private / 'session/host.json').write_text('{"harness":"claude"}')
    assert shell('fm_role_vendor worker', FM_STATE_DIR=str(private),
                 FM_HARNESS='codex').stdout.strip() == 'codex'
    assert shell('fm_role_vendor worker', FM_STATE_DIR=str(private),
                 FM_SESSION_HOST_STATE=str(root / 'state'),
                 FM_HARNESS='claude').stdout.strip() == 'claude'
    run = root / 'run'
    run.mkdir()
    (run / 'identity.json').write_text('{"role":"worker","name":"imani"}')
    shell('fm_record_vendor_resolution worker ""', FM_RUN_DIR=str(run))
    identity = json.loads((run / 'identity.json').read_text())
    assert identity['vendor_resolution'] == {
        'host': 'codex', 'rule': 'opposite-of-host', 'vendor': 'claude'}
    shell('fm_record_vendor_resolution worker gemini', FM_RUN_DIR=str(run))
    assert json.loads((run / 'identity.json').read_text())['vendor_resolution']['rule'] == 'explicit'

    host(None)
    shell('fm_record_vendor_resolution worker ""; fm_log_vendor_resolution "$FM_RUN_DIR/worker.log"',
          FM_RUN_DIR=str(run))
    assert 'configured fallback head' in (run / 'worker.log').read_text()

    # Exercise start/status wiring while replacing only their unrelated service
    # effects. The real host collector, detector and settings readers run.
    herdr = root / 'bin/fm-herdr.py'
    # Keep the module's complete import surface for storage/registry readers;
    # suppress only the session command's unrelated service effects.
    herdr.write_text(herdr.read_text().replace(
        "if __name__ == '__main__':",
        "if __name__ == '__main__' and sys.argv[1] != 'session':"))
    (root / 'bin/fm-doctor.sh').write_text('#!/bin/sh\nexit 0\n')
    (home / '.claude').mkdir()
    (home / '.claude/settings.json').write_text('{"model":"opus"}')
    (home / '.codex').mkdir()
    (home / '.codex/config.toml').write_text('model = "gpt-6-astra"\n')
    for mode, harness, model, version in [
        ('start', 'claude', 'opus', '2.1.80 (Claude Code)'),
        ('status', 'codex', 'gpt-6-astra', 'codex-cli 0.116.0')]:
        result = subprocess.run(['bash', '-c',
            'export FM_ENTRY_PID=$$ FM_ENTRY_SCRIPT=fm-session.sh; exec bash "$1/bin/fm-session.sh" "$2" --repo "$1"',
            'fixture', str(root), mode], env=dict(env, FM_HARNESS=harness, CLAUDECODE='1'),
            capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        observed = json.loads(record.read_text())
        assert (observed['harness'], observed['model'], observed['cli_version']) == (harness, model, version), observed
        assert observed['confirmed'] is True and observed['source'] == 'env'
        assert observed['session']['pid'] == 1
        assert observed['written_by']['pid'] > 0
        assert len(observed['written_by']['parent_command']) <= 200
        assert observed['model_source'].endswith('settings.json:model' if harness == 'claude' else 'config.toml:model')
    # External sessions write beside their existing private session records.
    config.write_text(base + 'projects:\n  outside:\n    github: fixture/outside\n'
                      '    base: main\n    required_check: ci\n')
    external_home = Path(temporary) / 'fm-home'
    result = subprocess.run(['bash', '-c',
        'export FM_ENTRY_PID=$$ FM_ENTRY_SCRIPT=fm-session.sh; exec bash "$1/bin/fm-session.sh" status --repo "$1" --project outside',
        'fixture', str(root)], env=dict(env, FM_HARNESS='claude', FM_HOME=str(external_home)),
        capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    external_record = external_home / 'projects/outside/state/session/host.json'
    assert json.loads(external_record.read_text())['harness'] == 'claude'
    assert not (external_home / 'projects/outside/repo/state/session/host.json').exists()
    config.write_text(base)
    # Collection is informational: missing code, a missing detector import,
    # and a crashing collector must not block either session entry point.
    collector = root / 'bin/lib/fm_host.py'
    detector = root / 'bin/lib/fm_hooks.py'
    collector_source, detector_source = collector.read_text(), detector.read_text()
    for failure in ('missing-collector', 'missing-detector', 'crashing-collector'):
        for mode in ('start', 'status'):
            for previous in (None, 'claude'):
                if previous is None:
                    record.unlink(missing_ok=True)
                else:
                    host(previous)
                before = record.read_bytes() if record.exists() else None
                if failure == 'missing-collector':
                    collector.unlink()
                elif failure == 'missing-detector':
                    detector.unlink()
                else:
                    collector.write_text('raise RuntimeError("collector fixture failure")\n')
                try:
                    result = subprocess.run(['bash', '-c',
                        'export FM_ENTRY_PID=$$ FM_ENTRY_SCRIPT=fm-session.sh; '
                        'exec bash "$1/bin/fm-session.sh" "$2" --repo "$1"',
                        'fixture', str(root), mode], env=dict(env, FM_HARNESS='claude'),
                        capture_output=True, text=True)
                    assert result.returncode == 0, (failure, mode, result.stderr)
                    assert 'host refresh failed' in result.stderr, result.stderr
                    if previous:
                        assert record.read_bytes() == before, (failure, mode)
                        assert 'keeping the recorded host claude' in result.stderr
                    else:
                        assert json.loads(record.read_text()) == {
                            'harness': None, 'cli_version': None, 'model': None, 'model_source': None}
                finally:
                    collector.write_text(collector_source)
                    detector.write_text(detector_source)
    # Round contexts must not refresh, even with a positive different host.
    for guard in ('FM_IN_ROUND', 'FM_RUN_DIR'):
        host('claude')
        before = record.read_bytes()
        result = shell('export FM_ENTRY_PID=$$ FM_ENTRY_SCRIPT=fm-session.sh; '
                       'exec bash "$1/bin/fm-session.sh" status --repo "$1"',
                       FM_HARNESS='codex', **{guard: str(run)})
        assert record.read_bytes() == before, guard
        assert result.stdout == '', result.stdout

    # Unknown detection is deterministic and belongs to a different session.
    detector.write_text(detector_source.replace('def detect_source():',
        'def detect_source():\n    return None, None\n\ndef unused_detect_source():'))
    legacy = dict(harness='claude', cli_version='fixture version', model='opus', model_source='fixture')
    record.write_text(json.dumps(legacy))
    result = shell('export FM_ENTRY_PID=$$ FM_ENTRY_SCRIPT=fm-session.sh; '
                   'exec bash "$1/bin/fm-session.sh" status --repo "$1"', FM_SESSION_PID=str(os.getpid()))
    unconfirmed = json.loads(record.read_text())
    assert unconfirmed['confirmed'] is False and unconfirmed['harness'] == 'claude'
    assert 'firstmate host record is unconfirmed: it says claude' in result.stderr
    assert 'FM_HARNESS=<claude|codex> bin/fm-session.sh status' in result.stderr
    result = shell('fm_role_vendor worker')
    assert result.stdout.strip() == 'codex'
    assert 'recorded host claude is unconfirmed since ' + unconfirmed['unconfirmed_since'] in result.stderr
    record.write_text(json.dumps(legacy))
    result = shell('fm_role_vendor worker')
    assert result.stdout.strip() == 'codex' and 'unconfirmed' not in result.stderr

    # Matching session identity must preserve even noncanonical JSON bytes.
    import subprocess as sp
    session = dict(pid=os.getpid(), started=sp.check_output(
        ['ps', '-p', str(os.getpid()), '-o', 'lstart='], text=True).strip())
    record.write_text(json.dumps(dict(legacy, session=session), indent=4) + '\n\n')
    before = record.read_bytes()
    shell('export FM_ENTRY_PID=$$ FM_ENTRY_SCRIPT=fm-session.sh; '
          'exec bash "$1/bin/fm-session.sh" status --repo "$1"', FM_SESSION_PID=str(os.getpid()))
    assert record.read_bytes() == before
    detector.write_text(detector_source)

    # No harness-owned model: no config.yaml guess. Unknown detector is
    # controlled here, rather than depending on this machine's process tree.
    sys.path.insert(0, str(root / 'bin/lib'))
    import fm_host
    import fm_hooks
    from unittest.mock import patch
    original_env = os.environ.copy()
    os.environ.clear()
    os.environ.update(env)
    try:
        with patch.object(fm_hooks.life, 'session_owner', return_value=123), \
             patch.object(fm_hooks.life, '_parent_of', return_value=(1, 'codex')):
            assert fm_hooks.detect_source() == ('codex', 'owner')
            assert fm_hooks.detect() == 'codex'
            os.environ['FM_HARNESS'] = 'claude'
            assert fm_hooks.detect_source() == ('claude', 'env')
            del os.environ['FM_HARNESS']
        with patch.object(fm_hooks.life, 'session_owner', side_effect=RuntimeError('no session')):
            assert fm_hooks.detect_source() == (None, None)
            assert fm_host.collect(root)['session'] is None
            os.environ['CLAUDECODE'] = '1'
            assert fm_hooks.detect_source() == ('claude', 'claudecode')
            del os.environ['CLAUDECODE']
        old = dict(legacy, session={'pid': 10, 'started': 'old'}, source='owner',
                   written_by={'pid': 11, 'parent_command': 'claude'})
        unknown = dict(harness=None, source=None, session={'pid': 20, 'started': 'new'},
                       written_by={'pid': 21, 'parent_command': 'shell'})
        positive = dict(unknown, harness='codex', source='env')
        assert fm_host.decide(old, positive) == dict(positive, confirmed=True)
        assert fm_host.decide(legacy, positive)['confirmed'] is True
        for previous in (None, {'harness': None}):
            assert fm_host.decide(previous, unknown) == dict(unknown, confirmed=False)
        assert fm_host.decide(old, dict(unknown, session=old['session'])) is None
        for previous in (old, legacy):
            changed = fm_host.decide(previous, unknown)
            assert changed['confirmed'] is False
            assert all(changed[k] == previous[k] for k in previous)
            assert changed['last_unknown'] == {k: unknown[k] for k in ('session', 'written_by')}
            assert changed['unconfirmed_since']
            again = fm_host.decide(changed, dict(unknown, session=None))
            assert again['unconfirmed_since'] == changed['unconfirmed_since']
            assert again['harness'] == 'claude'
        fm_host.detect_source = lambda: (None, None)
        assert fm_host.collect(root)['harness'] is None
        fm_host.detect_source = lambda: ('codex', 'env')
        (home / '.codex/config.toml').unlink()
        assert fm_host.collect(root)['model'] is None
    finally:
        os.environ.clear()
        os.environ.update(original_env)
# Instruction-only checks establish structure, not model compliance.
for name in ['README.md', 'design/design.md', 'skills/firstmate/SKILL.md']:
    prose = (ROOT / name).read_text()
    assert 'opposite-of-host' in prose and 'session/host.json' in prose, name
skill = (ROOT / 'skills/firstmate/SKILL.md').read_text()
assert 'projects.<name>.project' in skill
assert 'Design excerpts have a 48000' not in skill and 'pinned/' in skill
assert 'fm_prompt_design()' not in (ROOT / 'bin/fm-config.sh').read_text()
assert 'vendor: opposite-of-host' in (ROOT / 'config.yaml').read_text()
print('firstmate host fixtures passed')
