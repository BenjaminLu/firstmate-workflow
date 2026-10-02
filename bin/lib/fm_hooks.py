#!/usr/bin/env python3
"""Installing the hooks that wake firstmate (T-137).

No harness config is committed. This writes, or removes, exactly our hook
entries in each harness's local, uncommitted config for one checkout:

  claude  .claude/settings.local.json   Stop (the turn-end guard, and the
                                        asyncRewake arm), UserPromptSubmit
  codex   .codex/hooks.json             SessionStart, Stop (the guard), UserPromptSubmit
  cursor  .cursor/hooks.json            stop (the guard, bounded by loop_limit)

It merges into what is there, changes nothing the second time, says what
it changed, and uninstall takes away only what install put. `hooks` in the
fm command line and `fm-session.sh start` (with --detect: the harness this
session runs in, and never in a crew round) both run this file directly.

  fm_hooks.py install|uninstall [--harness claude|codex|cursor] [--repo DIR] [--detect]
"""
import json
import os
import shlex
import sys
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
# no __pycache__ in bin/lib: the tree stays exactly what was committed
sys.dont_write_bytecode = True
import fm_lifeline as life  # noqa: E402
import fm_watch as watch  # noqa: E402

HARNESSES = watch.HARNESSES


def hook_config(root, harness):
    """(the local config's path under root, {event: [entries]})."""
    q = shlex.quote
    arm_cmd = q(str(Path(root) / 'bin/fm-watch-arm.sh'))
    guard_cmd = q(str(Path(root) / 'bin/fm-turnend-guard.sh'))
    if harness == 'claude':
        return '.claude/settings.local.json', {
            'Stop': [{'hooks': [
                {'type': 'command', 'command': f'{guard_cmd} --hook claude', 'timeout': 30},
                {'type': 'command', 'command': f'{arm_cmd} --hook claude', 'asyncRewake': True,
                 'timeout': watch.CLAUDE_TIMEOUT}]}],
            'UserPromptSubmit': [{'hooks': [
                {'type': 'command', 'command': f'{arm_cmd} --turn-start claude', 'timeout': 30}]}]}
    if harness == 'codex':
        return '.codex/hooks.json', {
            'SessionStart': [{'hooks': [
                {'type': 'command', 'command': f'{arm_cmd} --session-start codex', 'timeout': 60}]}],
            'Stop': [{'hooks': [{'type': 'command', 'command': f'{guard_cmd} --hook codex', 'timeout': 60}]}],
            'UserPromptSubmit': [{'hooks': [
                {'type': 'command', 'command': f'{arm_cmd} --turn-start codex', 'timeout': 30}]}]}
    if harness == 'cursor':
        return '.cursor/hooks.json', {
            'stop': [{'command': f'{guard_cmd} --hook cursor', 'timeout': 60, 'loop_limit': 5}]}
    raise ValueError(f'no such harness: {harness} (claude, codex, cursor)')


def _strip(entries, root, harness):
    """entries without ours: a Claude/Codex group keeps its other hooks and
    goes when it held only ours; a Cursor entry is one command."""
    def ours(command):
        try:
            args = shlex.split(command)
        except (ValueError, TypeError):
            return False
        return (len(args) == 3 and args[0] in
                (str(Path(root) / 'bin/fm-watch-arm.sh'), str(Path(root) / 'bin/fm-turnend-guard.sh'))
                and args[1] in ('--hook', '--turn-start', '--session-start') and args[2] == harness)
    kept = []
    for entry in entries if isinstance(entries, list) else []:
        if not isinstance(entry, dict):
            kept.append(entry)
            continue
        if isinstance(entry.get('hooks'), list):
            inner = [h for h in entry['hooks'] if not (isinstance(h, dict) and ours(h.get('command', '')))]
            if inner or not entry['hooks']:
                kept.append(dict(entry, hooks=inner))
        elif not ours(entry.get('command', '')):
            kept.append(entry)
    return kept


def hooks_change(root, harness, install):
    """Install or uninstall ours in one harness's local config; returns
    what it did, in one line."""
    root = Path(root).resolve()
    rel, entries = hook_config(root, harness)
    path = root / rel
    if install and not (root / 'bin/fm-watch-arm.sh').is_file():
        raise ValueError(f'{root} carries no bin/fm-watch-arm.sh to point the hooks at')
    data = {}
    if path.exists():
        data = json.loads(path.read_text() or '{}')
        if not isinstance(data, dict):
            raise ValueError(f'{rel} is not a JSON object; left as it is')
    before = json.dumps(data, sort_keys=True)
    hooks = data.get('hooks', {})
    if not isinstance(hooks, dict) or any(not isinstance(v, list) for v in hooks.values()):
        raise ValueError(f'{rel}: invalid hooks structure; left as it is')
    changed = []
    for event in sorted(set(hooks) | set(entries)):
        old = hooks.get(event, [])
        new = _strip(old, root, harness) + (entries.get(event, []) if install else [])
        if new != old:
            changed.append(event)
        if new:
            hooks[event] = new
        else:
            hooks.pop(event, None)
    if hooks:
        data['hooks'] = hooks
        if harness == 'cursor':
            data.setdefault('version', 1)
    else:
        data.pop('hooks', None)
        if harness == 'cursor' and set(data) == {'version'}:
            data = {}
    if harness == 'codex':
        layer = root / '.codex/config.toml'
        owned = '# firstmate: project hook discovery layer (T-164)\n'
        if install and not layer.exists():
            layer.parent.mkdir(parents=True, exist_ok=True)
            watch.save(layer, owned)
        elif not install and layer.is_file() and layer.read_text() == owned:
            layer.unlink()
    if json.dumps(data, sort_keys=True) == before:
        return f'{rel}: nothing to change ({"already installed" if install else "none of ours"})'
    if data:
        path.parent.mkdir(parents=True, exist_ok=True)
        watch.save(path, json.dumps(data, indent=2) + '\n')
    else:
        path.unlink()
        try:
            path.parent.rmdir()     # only when nothing else is in it
        except OSError:
            pass
    return f'{rel}: {"installed" if install else "removed"} {", ".join(changed)}'


def detect():
    """The harness this session runs in: FM_HARNESS, else the name of the
    session's own process (bin/lib/fm_lifeline.py's session_owner), else
    CLAUDECODE=1, which Claude Code sets for every command it runs (its
    process can be named `node`)."""
    given = os.environ.get('FM_HARNESS', '')
    if given:
        return given
    try:
        _, name = life._parent_of(life.session_owner())
    except (RuntimeError, ValueError, OSError):
        name = ''
    for harness in HARNESSES:
        if harness in (name or '').lower():
            return harness
    return 'claude' if os.environ.get('CLAUDECODE') == '1' else None


def codex_capability(root):
    """Read-only CLI capability probe; never starts a vendor session."""
    try:
        version = subprocess.run(['codex', '--version'], cwd=root, capture_output=True,
                                 text=True, timeout=10, check=True).stdout.strip()
        result = subprocess.run(['codex', 'features', 'list'], cwd=root, capture_output=True,
                                text=True, timeout=10, check=True)
    except (OSError, subprocess.SubprocessError):
        return 'unknown', 'unavailable'
    for line in result.stdout.splitlines():
        fields = line.split()
        if fields and fields[0] == 'hooks' and fields[-1] in ('true', 'false'):
            return ('enabled' if fields[-1] == 'true' else 'disabled'), version
    return 'unsupported', version


def codex_status(root, evidence=None, feature='unknown', client='unknown'):
    """Interpret an operator-exported hooks/list result, never manufacture trust.

    This is evidence from that client at collection time, not a live query or
    proof that a running conversation reloaded the definitions. No credential
    or global configuration file is read or changed here.
    """
    root = Path(root).resolve()
    source, entries = hook_config(root, 'codex')
    expected = [(event[0].lower() + event[1:], group) for event, groups in entries.items() for group in groups]
    observed, issues = [], []
    if evidence is not None:
        if not isinstance(evidence, dict) or not isinstance(evidence.get('data'), list):
            raise ValueError('expected the result object from Codex hooks/list')
        for entry in evidence['data']:
            if not isinstance(entry, dict) or entry.get('cwd') != str(root):
                continue
            issues.extend(entry.get('errors') or [])
            issues.extend(entry.get('warnings') or [])
            observed.extend(entry.get('hooks') or [])
    matches = []
    complete = True
    for event, group in expected:
        handler = group['hooks'][0]
        found = [h for h in observed if isinstance(h, dict)
                       and h.get('sourcePath') == str(root / source) and h.get('source') == 'project'
                       and h.get('eventName') == event and h.get('handlerType') == 'command'
                       and h.get('command') == handler['command'] and not h.get('async', False)
                       and h.get('timeoutSec') == handler['timeout']
                       and h.get('matcher') in (None, '', '*') and h.get('currentHash')]
        complete = complete and len(found) == 1
        matches.extend(found)
    loading = ('unverified' if evidence is None else
               'observed' if complete and not issues else 'missing-or-different')
    trusts = {h.get('trustStatus', 'unknown') for h in matches}
    trust = next(iter(trusts)) if len(trusts) == 1 else 'mixed-or-unknown'
    enabled = bool(matches) and all(h.get('enabled') is True for h in matches)
    supported = client in ('cli', 'app-server') and feature != 'unsupported'
    step = ('In the target client, open /hooks; check this repository source and review/trust every current definition. '
            'Modified hashes require re-review. If project hooks are missing or disabled, inspect effective '
            'features.hooks and allow_managed_hooks_only policy; an administrator must resolve managed refusal. '
            'Restart/resume after installation if the source is absent; '
            'this tool cannot hot-reload a conversation. Export hooks/list with cwds naming this repository '
            'and pass its result as --evidence FILE. Then run the disposable smoke in docs/verification/supervision.md.')
    if feature == 'disabled':
        step = ('Hooks are disabled. Inspect effective features.hooks and requirements.toml; '
                'a managed-policy refusal requires the administrator, not an override. '
                'Enable hooks only through supported operator configuration if policy permits. ') + step
    if not supported:
        step = 'Client hook support is unknown or unsupported; verify the target CLI/app-server capability. ' + step
    return dict(source=str(root / source), client=client, feature=feature, loading=loading,
                trust=trust, handlers_enabled=enabled, issues=issues,
                ready=supported and feature == 'enabled' and loading == 'observed' and trust == 'trusted' and enabled,
                evidence_scope='supplied hooks/list snapshot; not live-session or delivery verification',
                delivery='unverified', idle_push='unsupported by documented background hook semantics', next_step=step)


def guidance(root, vendors):
    """Doctor's read-only operator policy. Local files are not runtime evidence."""
    root = Path(root).resolve()
    if watch.standing_down(root):
        return
    print('== Necessary agent hooks ==')
    detected = detect()
    names = list(dict.fromkeys(vendors + ([detected] if detected else [])))
    for vendor in names:
        harness = 'cursor' if vendor == 'cursor-agent' else vendor
        if harness not in HARNESSES:
            print(f'  ! {vendor}: hook integration unsupported/unverified by firstmate; '
                  'use the stock foreground watch/manual-turn fallback below.')
            continue
        rel, expected = hook_config(root, harness)
        path = root / rel
        config, disabled = 'missing', False
        if path.exists():
            try:
                data = json.loads(path.read_text())
                if not isinstance(data, dict):
                    raise ValueError('configuration must be an object')
                entries = data['hooks']
                if not isinstance(entries, dict):
                    raise ValueError('hooks must be an object')
                # Groups may also contain custom hooks; compare our complete handlers.
                complete = True
                for event, groups in expected.items():
                    actual = entries.get(event, [])
                    if not isinstance(actual, list):
                        raise ValueError('event must be an array')
                    for group in groups:
                        if harness == 'cursor':
                            complete &= group in actual
                        else:
                            complete &= any(isinstance(g, dict) and isinstance(g.get('hooks'), list) and
                                all(h in g.get('hooks', []) for h in group['hooks']) and
                                g.get('matcher') in (None, '', '*') for g in actual)
                config = 'installed' if complete else 'missing-or-different'
                disabled = data.get('disableAllHooks') is True
            except (OSError, ValueError, KeyError, TypeError):
                config = 'unreadable'
        print(f'  ! {vendor}: source={path}; configuration={config}; '
              f'loading=unverified; enablement={"locally-disabled" if disabled else "unverified"}; '
              'authorization=unverified; capability=unverified-in-target; delivery=unverified')
        command = shlex.join(['python3', str(root / 'bin/lib/fm_hooks.py'), 'install',
                              '--harness', harness, '--repo', str(root)])
        print(f'    Install/update firstmate-owned definitions: {command}')
        if harness == 'codex':
            print('    Codex CLI/app-server only: inspect this actual project source in native /hooks; '
                  'review/trust the current SessionStart, UserPromptSubmit and Stop definitions; '
                  'changed hashes require re-review. Restart/resume if the source is absent. '
                  'Check effective features.hooks and allow_managed_hooks_only/requirements.toml; '
                  'project trust alone is insufficient. Run fm hooks status --harness codex '
                  'with target hooks/list evidence to distinguish loading, feature policy and exact-definition trust.')
        elif harness == 'claude':
            print('    Claude Code: review local settings and project trust in the native client; '
                  'use /hooks to inspect Stop and UserPromptSubmit and their settings source. '
                  'This is a hook browser, not Codex hash authorization. Check effective disableAllHooks '
                  'and managed allowManagedHooksOnly; honor native project/security approval prompts. '
                  'Settings normally reload automatically; restart if these definitions are absent. '
                  'Verify asyncRewake support in the target version before relying on background delivery.')
        else:
            print('    Cursor: review this project in a trusted workspace; inspect stop in Customize > Hooks '
                  'and the Hooks output channel. Config normally reloads on save; restart Cursor if absent. '
                  'Check enterprise/team policy with the administrator. Cursor CLI or other surfaces remain '
                  'unverified until their actual hook events and continuation are observed.')
    print('    Preserve custom/global configuration and explicit disablement; managed-policy refusal needs '
          'the administrator. Installation never grants authorization or proves readiness. No trust bypass.')
    print('    Until verified, use stock foreground watch: bin/fm-watch-arm.sh --max-wait 3000; '
          'if unavailable, on each manual turn run bin/fm-session.sh status. '
          'Record real events, model-visible wake identity/continuation and owner cleanup per '
          'docs/verification/supervision.md; queue/ack files are not delivery receipts. '
          'No extra session, idle push, or automatic hot reload is promised.')


USAGE = 'usage: fm_hooks.py install|uninstall|status [--harness claude|codex|cursor] [--repo DIR] [--detect] [--client cli|app-server] [--evidence FILE]'


def main(argv):
    if not argv or argv[0] not in ('install', 'uninstall', 'status', 'guidance'):
        print(USAGE, file=sys.stderr)
        return 64
    try:
        got = watch.options(argv[1:], {'--detect'}, {'--repo', '--harness', '--evidence', '--client', '--vendors'})
        root = watch.root_of(got)
        if argv[0] == 'guidance':
            guidance(root, got.get('--vendors', '').split())
            return 0
        if argv[0] == 'status':
            if got.get('--harness', 'codex') != 'codex':
                raise ValueError('status currently supports --harness codex only')
            evidence = json.loads(Path(got['--evidence']).read_text()) if '--evidence' in got else None
            feature, version = codex_capability(root)
            report = codex_status(root, evidence=evidence, feature=feature, client=got.get('--client', 'cli'))
            report['version'] = version
            print(json.dumps(report, indent=2))
            return 0 if report['ready'] else 1
        why = watch.standing_down(root) if '--detect' in got else None
        if why:
            print(f'fm hooks: not installed: {why}', file=sys.stderr)
            return 0
        harness = got.get('--harness') or (detect() if '--detect' in got else None)
        if '--detect' in got and not harness:
            print('fm hooks: no harness detected; run bin/lib/fm_hooks.py install --harness claude|codex|cursor',
                  file=sys.stderr)
            return 0
        for name in [harness] if harness else list(HARNESSES):
            print('fm hooks: ' + hooks_change(root, name, argv[0] == 'install'))
            if name == 'codex' and argv[0] == 'install':
                print('fm hooks: Codex files configured; loading, feature policy, exact-definition trust and delivery are not verified. '
                      'Restart or resume in this repository; use /hooks to review the source and trust each current definition. '
                      'Run fm hooks status --harness codex for diagnostics. No idle push is promised.')
        return 0
    except ValueError as error:
        print(f'fm hooks: {error}', file=sys.stderr)
        return 64
    except OSError as error:
        print(f'fm hooks: {error}', file=sys.stderr)
        return 70


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
