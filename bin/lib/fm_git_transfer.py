"""Prepare one frozen engine transfer before Git clears inherited config."""
import os
from pathlib import Path
import shlex
import subprocess
import sys

OPTIONS = '-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4'


def config_prefix(argv):
    if not argv or Path(argv[0]).name != 'git':
        raise ValueError('fm-git-transfer: invalid Git invocation')
    i = 1
    while i < len(argv) and argv[i].startswith('-'):
        option = argv[i]
        if option in ('-C', '-c', '--git-dir', '--work-tree', '--namespace', '--config-env'):
            if i + 1 >= len(argv):
                raise ValueError('fm-git-transfer: invalid Git prefix')
            i += 2
        elif (option.startswith(('-C', '-c')) and len(option) > 2) or option.startswith(('--git-dir=', '--work-tree=', '--namespace=', '--config-env=')):
            i += 1
        elif option in ('--bare', '--no-pager', '--paginate', '--no-replace-objects', '--literal-pathspecs',
                        '--glob-pathspecs', '--noglob-pathspecs', '--icase-pathspecs', '--no-optional-locks'):
            i += 1
        else:
            raise ValueError('fm-git-transfer: unsupported Git prefix')
    if i >= len(argv) or argv[i] not in ('fetch', 'push', 'clone', 'ls-remote'):
        raise ValueError('fm-git-transfer: network Git operation required')
    return list(argv[:i])


def prepare(argv, cwd=None, env=None, code_root=None):
    """Return exact argv and a child-only environment; never modify the caller."""
    argv = list(argv)
    prefix = config_prefix(argv)
    child = dict(os.environ if env is None else env)
    query_prefix = list(prefix)
    def configuration(key):
        return subprocess.run([*query_prefix, 'config', '--get', key], cwd=cwd,
                              env=child, stdin=subprocess.DEVNULL, capture_output=True,
                              timeout=120)

    code = Path(code_root or child.get('FM_CODE_ROOT') or Path(__file__).resolve().parents[2])
    helper = code / 'bin/lib/fm-ssh-transfer.sh'
    if not helper.is_file() or not (code / 'bin/lib/fm_git_transfer.py').is_file():
        raise ValueError('fm-git-transfer: frozen transport unavailable')
    if child.get('FM_SSH_TRANSFER_ACTIVE') == '1':
        raise ValueError('fm-git-transfer: configuration unavailable')
    if argv[len(prefix)] == 'clone':
        # Git alone selects a clone's SSH program, variant and options. Remove
        # only firstmate machinery; operator overrides pass through unchanged.
        if ('FM_SSH_GENERATED_COMMAND' in child and
                child.get('GIT_SSH_COMMAND') == child['FM_SSH_GENERATED_COMMAND']):
            child.pop('GIT_SSH_COMMAND')
        for key in [key for key in child if key.startswith('FM_SSH_')]:
            child.pop(key)
        return argv, child
    owned = ('GIT_SSH_COMMAND' in child and 'FM_SSH_GENERATED_COMMAND' in child
             and child['GIT_SSH_COMMAND'] == child['FM_SSH_GENERATED_COMMAND'])
    if 'GIT_SSH_COMMAND' in child and not owned:
        base = child['GIT_SSH_COMMAND']
    elif 'GIT_SSH' in child:
        # Generated equality conveys ownership, never operator precedence.
        if owned:
            child.pop('GIT_SSH_COMMAND', None)
        child.pop('FM_SSH_GENERATED_COMMAND', None)
        return argv, child
    else:
        try:
            result = configuration('core.sshCommand')
        except (OSError, subprocess.SubprocessError) as error:
            raise ValueError('fm-git-transfer: configuration unavailable') from None
        if result.returncode == 1:
            base = 'ssh'
        elif result.returncode == 0:
            base = result.stdout.decode(errors='surrogateescape').rstrip('\n')
        else:
            raise ValueError('fm-git-transfer: configuration unavailable')
        if owned and base == child['FM_SSH_GENERATED_COMMAND']:
            raise ValueError('fm-git-transfer: configuration unavailable')
    # Git identifies recognized executable basenames before attempting -G.
    # Replacing that basename with our helper must not change this decision.
    # Preserve unknown-command discovery and all explicit variant values.
    configured = child.get('GIT_SSH_VARIANT')
    if 'GIT_SSH_VARIANT' not in child:
        try:
            variant = configuration('ssh.variant')
        except (OSError, subprocess.SubprocessError):
            raise ValueError('fm-git-transfer: configuration unavailable') from None
        if variant.returncode not in (0, 1):
            raise ValueError('fm-git-transfer: configuration unavailable')
        configured = variant.stdout.decode(errors='surrogateescape').rstrip('\n') if variant.returncode == 0 else None
    if configured is not None and configured != 'auto':
        child['GIT_SSH_VARIANT'] = configured
    else:
        try:
            words = shlex.split(base)
        except ValueError:
            words = []
        name = Path(words[0]).name.lower() if words else ''
        if name.endswith('.exe'):
            name = name[:-4]
        recognized = {'ssh': 'ssh', 'plink': 'plink',
                      'tortoiseplink': 'tortoiseplink'}
        if name in recognized:
            child['GIT_SSH_VARIANT'] = recognized[name]
    # OpenSSH options only for the resolved ssh variant; plink, putty, simple
    # and programs Git would probe with -G reject them.
    if child.get('GIT_SSH_VARIANT') == 'ssh' and 'ServerAliveInterval' not in base:
        base += ' ' + OPTIONS
    child['FM_SSH_TRANSFER_COMMAND'] = base
    child['GIT_SSH_COMMAND'] = shlex.quote(str(helper))
    child.pop('FM_SSH_GENERATED_COMMAND', None)
    return argv, child


def main():
    try:
        argv, env = prepare(sys.argv[1:], code_root=Path(__file__).resolve().parents[2])
        os.execvpe(argv[0], argv, env)
    except (ValueError, OSError, KeyError, TypeError, IndexError, AttributeError, subprocess.SubprocessError):
        print('fm-git-transfer: configuration unavailable', file=sys.stderr)
        return 128


if __name__ == '__main__':
    sys.exit(main())
