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
    herdr.rename(root / 'bin/herdr-original.py')
    herdr.write_text('import runpy, sys\nfrom pathlib import Path\n'
                     'if __name__ == "__main__" and sys.argv[1] != "session":\n'
                     '    runpy.run_path(str(Path(__file__).with_name("herdr-original.py")), run_name="__main__")\n')
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
    # No harness-owned model: no config.yaml guess. Unknown detector is
    # controlled here, rather than depending on this machine's process tree.
    sys.path.insert(0, str(root / 'bin/lib'))
    import fm_host
    original_env = os.environ.copy()
    os.environ.clear()
    os.environ.update(env)
    try:
        fm_host.detect = lambda: None
        assert fm_host.collect(root)['harness'] is None
        fm_host.detect = lambda: 'codex'
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
