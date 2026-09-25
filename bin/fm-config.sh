# fm:sourced  # this file is sourced; see the repository lint's stdin stage
# fm:lint-source  # and it now HOLDS the option-loop corpus rule, so it
# quotes `shift 2` without having one; T-030 makes this marker per-line
# shellcheck shell=bash
# One reader for config.yaml. There were five copies of the same sed
# expression and every one of them kept the trailing comment, so
# "concurrency: 3  # workers in flight" arithmetic-errored the dispatcher the
# first time anyone ran it for real. One place to be wrong is the fix.
#
#   . bin/fm-config.sh
#   fm_cfg vendor                 -> claude
#   fm_cfg_in reviewer vendor     -> cursor-agent
#   fm_cfg_list fallback          -> one per line

_fm_clean() {   # strip an inline comment, surrounding quotes, and stray space
  sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' \
      -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

fm_default_repo() {
  if [ -n "${FM_ROOT:-}" ]; then
    printf '%s\n' "$FM_ROOT"
  elif _fm_pwd="$(pwd -P 2>/dev/null)"; then
    printf '%s\n' "$_fm_pwd"
  else
    printf '\n'
  fi
}

fm_cfg() {      # fm_cfg <key> [file]
  local f="${2:-config.yaml}"
  [ -f "$f" ] || return 1
  sed -n "s/^$1:[[:space:]]*//p" "$f" | head -1 | _fm_clean
}

fm_cfg_in() {   # fm_cfg_in <section> <key> [file]
  local f="${3:-config.yaml}"
  [ -f "$f" ] || return 1
  sed -n "/^$1:/,/^[^[:space:]#]/p" "$f" \
    | sed -n "s/^[[:space:]][[:space:]]*$2:[[:space:]]*//p" | head -1 | _fm_clean
}

fm_cfg_list() { # fm_cfg_list <section> [file]
  local f="${2:-config.yaml}"
  [ -f "$f" ] || return 1
  sed -n "/^$1:/,/^[^[:space:]#-]/p" "$f" \
    | sed -n 's/^[[:space:]]*-[[:space:]]*//p' | _fm_clean
}

_fm_code_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# The project contract: config.yaml's `project:` block, which the target
# project fills in so that nothing here has to know its toolchain.
#
#   fm_project setup|check|test [file]  -> the command, exactly as declared
#   fm_project tests|docs [file]        -> one glob per line
#   fm_project check_env [file]         -> NAME=value, each ending in NUL
#   fm_project keys [file]              -> the declared keys, one per line
#
# Values are opaque shell command strings. They are printed, never evaluated:
# quotes, `&&`, `$(...)` and `{file}` come back as written. An absent key
# prints nothing and succeeds; a malformed block, an unknown key or a `test`
# without `{file}` exits 65, because a typo that silently read as "nothing
# declared" would skip a stage and still look green. The parser is the one
# `fm-session.sh start` uses, so the two cannot disagree about the block.
fm_project() {  # fm_project <field> [file]
  python3 "$_fm_code_dir/fm-herdr.py" project "${2:-config.yaml}" "$1"
}

# The project registry (design section 15): config.yaml's `default_project`
# and `projects:` map. The directory holding config.yaml is the engine root.
#
#   fm_projects [file]                     -> registered names, one per line
#   fm_project_resolve [explicit] [file]   -> the project this run is for
#   fm_project_get <name> <field> [file]   -> repo github base required_check
#                                             design tasks, or root; tasks is
#                                             a directory (see fm_tasks)
#   fm_project_contract <name> <field> [file] -> as fm_project, for a project
#   fm_project_use [explicit] [file]       -> exports FM_PROJECT, FM_PROJECT_ROOT
#
# The project is named, never inferred: an explicit `--project` value wins,
# then FM_PROJECT, then default_project. Nothing here looks at the current
# directory, a git remote or a worktree - a run must not change project
# because a shell was somewhere else. `root` is the engine root for `repo: .`
# and state/projects/<name>/repo otherwise.
#
# Every lookup validates the whole registry first and exits 65 naming the
# project and the field: an unregistered or malformed name, a `repo` other
# than `.`, a `github` not shaped owner/repo, a missing base or
# required_check. A config.yaml with no `projects:` map registers nothing.
#
# The contract has one source during the transition to T-050: the self entry
# (`repo: .`) resolves to T-043's top-level `project:` block, whole, read by
# the same parser fm_project uses. A self entry carrying its own `project:`
# as well as the top-level block is refused, so the two cannot disagree.
fm_projects()         { _fm_registry "${1:-config.yaml}" names; }

# The crew's permission policy (T-105): what every crew round may do, per
# role, whichever vendor runs it. The operator's own CLI settings are not
# part of it - a worker used to inherit whatever the captain's machine
# allowed, and cursor-agent ran with -f and no sandbox at all.
#
#   fm_policy worker|reviewer [project] [file] -> the resolved policy, JSON
#
# config.yaml's `policy:` block holds it, and a project's own
# `projects.<name>.policy:` overrides it; both take the same keys, flat for
# both roles or under `worker:` / `reviewer:` for one:
#
#   network:     the registries the round's commands may reach (default
#                none); a later layer replaces an earlier one
#   read:        more paths readable besides the write roots and the
#                toolchain; added to, never replacing
#   never_read:  more paths no round may read; added to
#   procs, cpu:  the process and CPU-seconds ulimits
#
# What is not a key cannot be loosened by one: the write roots (the round's
# worktree or checkout, and a TMPDIR of its own), the never-readable floor
# (~/.ssh, ~/.config/gh, cloud credentials, every vendor's home but for its
# own auth and session state, fm's state/ and the other worktrees in it),
# the refused operations
# (git push, gh, herdr, browsers, MCP), no unix sockets, the environment
# scrub, and the repository's own .claude/, .mcp.json, .cursor/ and
# GEMINI.md staying unloaded. GitHub and loopback are never a registry: a
# network naming one is refused (65), as is any key or value that does not
# read. The project is named the way fm_project_resolve names it; with no
# project registered, only the top-level block applies. Before T-105 the
# reviewer's hosts were `reviewer: network:`, which still counts when no
# policy layer declares a network.
fm_policy() { _fm_registry "${3:-config.yaml}" policy "$1" "${2:-}"; }

# fm_policy_blocked <file> -> each host a round's proxy refused, once
fm_policy_blocked() { [ -s "${1:-}" ] || return 0; awk 'NF && !seen[$0]++' "$1"; }

# fm_policy_report <repo> <role> <task> <actor> <file> -> the refused hosts,
#   on one line, and one record of them appended to
#   state/policy/blocked-hosts.jsonl. A round is never given a host it was
#   refused: firstmate reads the record and raises a choice card to add it
#   to the project's `policy: network:`, and only the captain's answer
#   changes the policy.
fm_policy_report() {
  local hosts
  hosts="$(fm_policy_blocked "$5" | tr '\n' ' ' | sed 's/ $//')"
  [ -n "$hosts" ] || return 0
  mkdir -p "$1/state/policy" &&
    jq -cn --arg role "$2" --arg task "$3" --arg actor "$4" --arg hosts "$hosts" \
      --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{at:$at, task:$task, role:$role, actor:$actor, hosts:($hosts | split(" "))}' \
      >> "$1/state/policy/blocked-hosts.jsonl"
  printf '%s\n' "$hosts"
}
fm_project_resolve()  { _fm_registry "${2:-config.yaml}" resolve "${1:-}"; }
fm_project_get()      { _fm_registry "${3:-config.yaml}" field "$1" "$2"; }
fm_project_contract() { _fm_registry "${3:-config.yaml}" contract "$1" "$2"; }
fm_project_use() {
  local name root
  name="$(fm_project_resolve "${1:-}" "${2:-config.yaml}")" || return
  root="$(fm_project_get "$name" root "${2:-config.yaml}")" || return
  FM_PROJECT="$name"; FM_PROJECT_ROOT="$root"
  export FM_PROJECT FM_PROJECT_ROOT
}

_fm_registry() {  # _fm_registry <file> <mode> [args...]
  python3 - "$_fm_code_dir/fm-herdr.py" "$@" <<'PY'
import importlib.util, json, os, re, sys, tempfile
from pathlib import Path

herdr_path, config, mode, *args = sys.argv[1:]
# the one scalar and contract parser, fm_project's; needed only when there is a
# config to parse, so a tree with no config.yaml registers nothing without it
herdr = None
if Path(config).is_file():
    if not Path(herdr_path).is_file():
        print('fm-config: cannot read the registry: no fm-herdr.py beside fm-config.sh (%s)' % herdr_path,
              file=sys.stderr); sys.exit(65)
    spec = importlib.util.spec_from_file_location('fm_herdr', herdr_path)
    herdr = importlib.util.module_from_spec(spec); spec.loader.exec_module(herdr)
FIELDS = ('repo', 'github', 'base', 'required_check', 'design', 'tasks', 'project', 'policy')
NAME = re.compile(r'[a-z0-9-]{1,24}$')
GITHUB = re.compile(r'[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+$')


class Refused(Exception):
    pass


def refuse(name, field, why):
    raise Refused('project %s: %s %s' % (name, field, why))


def indent(line):
    return len(line) - len(line.lstrip(' '))


def top_block(lines, key):
    """The lines under a column-0 `key:`; None when the key is absent."""
    block, inside, found = [], False, None
    for raw in lines:
        if not inside:
            if re.match(re.escape(key) + r':\s*(#.*)?$', raw):
                inside, found = True, block
            continue
        if not raw.strip() or raw.lstrip().startswith('#'): continue
        if not raw[:1].isspace(): break
        block.append(raw.expandtabs(8))
    return found


def contract_of(name, lines, key):
    """An entry's nested project: block, read by fm_project's parser."""
    with tempfile.NamedTemporaryFile('w', suffix='.yaml') as block:
        block.write('project:\n' + ''.join(line + '\n' for line in lines))
        block.flush()
        try:
            return herdr.project_field(block.name, key) if key else herdr.project_contract(block.name)
        except ValueError as error:
            refuse(name, 'project', str(error).replace('config.yaml ', ''))


def load(path):
    path = Path(path)
    if not path.is_file(): return None, {}, False
    lines = path.read_text().splitlines()
    default = None
    for raw in lines:
        found = re.match(r'default_project:(?:\s+(.*))?$', raw)
        if found:
            default = herdr._project_scalar(found.group(1) or '', 'config.yaml default_project')
            break
    block = top_block(lines, 'projects') or []
    projects, order, i = {}, [], 0
    level = indent(block[0]) if block else 0
    while i < len(block):
        line = block[i]
        found = re.match(r'\s*([^\s:#][^:]*):\s*(#.*)?$', line)
        if indent(line) != level or not found:
            raise Refused('projects: cannot read line: ' + line.strip())
        name = found.group(1).strip()
        if not NAME.match(name):
            refuse(name, 'name', 'must be [a-z0-9-], at most 24 characters')
        if name in projects: refuse(name, 'name', 'is registered twice')
        entry, i = {}, i + 1
        children = []
        while i < len(block) and indent(block[i]) > level:
            children.append(block[i]); i += 1
        j = 0
        while j < len(children):
            line = children[j]; own = indent(line)
            found = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$', line)
            if not found: refuse(name, 'entry', 'cannot read line: ' + line.strip())
            key, value = found.group(1), (found.group(2) or '').strip()
            if key not in FIELDS: refuse(name, key, 'is not a registry field (known: ' + ', '.join(FIELDS) + ')')
            if key in entry: refuse(name, key, 'is given twice')
            nested = []
            j += 1
            while j < len(children) and indent(children[j]) > own:
                nested.append(children[j]); j += 1
            if key in ('project', 'policy'):
                if value and not value.startswith('#'): refuse(name, key, 'must be a block, as in T-043')
                entry[key] = nested
            else:
                if nested: refuse(name, key, 'must be a one-line value')
                entry[key] = herdr._project_scalar(value, 'config.yaml projects.%s.%s' % (name, key))
        projects[name] = entry; order.append(name)
    has_top = top_block(lines, 'project') is not None
    for name in order:
        entry = projects[name]
        if 'repo' in entry and entry['repo'] != '.':
            refuse(name, 'repo', "must be . or absent (a committed local path would publish it), not '%s'" % entry['repo'])
        if not GITHUB.match(entry.get('github', '')) or entry['github'].split('/')[1] in ('.', '..'):
            refuse(name, 'github', "must be shaped owner/repo, not '%s'" % entry.get('github', ''))
        for key in ('base', 'required_check'):
            if not entry.get(key): refuse(name, key, 'is required')
        for key in ('design', 'tasks'):
            value = entry.get(key)
            if value is None: continue
            if not value or value.startswith('/') or '..' in Path(value).parts:
                refuse(name, key, "must be a path relative to the engine root, not '%s'" % value)
        if has_top and entry.get('repo') == '.' and 'project' in entry:
            refuse(name, 'project', 'is also declared by the top-level project: block; '
                   'until T-050 the contract lives only there')
        if 'project' in entry: contract_of(name, entry['project'], None)
        if 'policy' in entry: policy_layer(entry['policy'], 'projects.%s.policy' % name)
    selves = [name for name in order if projects[name].get('repo') == '.']
    if len(selves) > 1:
        refuse(selves[1], 'repo', 'is . for %s as well; only one project is the engine itself' % selves[0])
    return default, projects, has_top


# --- the crew's permission policy (T-105; see fm_policy above) ------------
ROLES = ('worker', 'reviewer')
POLICY_KEYS = ('network', 'read', 'never_read', 'procs', 'cpu')
# every dimension a round is confined in; an adapter enforces some with its
# CLI's own flags and bin/fm-sandbox.sh the rest, or the adapter refuses
DIMENSIONS = ['write', 'read', 'network', 'sockets', 'env', 'repo-config', 'refuse', 'ulimit']
# readable besides the write roots: what running a toolchain needs, and no
# home directory as a whole
TOOLCHAIN = ['/usr', '/bin', '/sbin', '/opt', '/etc', '/private/etc', '/dev', '/System',
             '/Library/Developer', '/Library/Frameworks', '/Library/Java', '/Library/Apple',
             '/Applications/Xcode.app', '/private/var/db/timezone', '/private/var/select',
             '/lib', '/lib32', '/lib64', '/nix', '/snap',
             '~/.local/bin', '~/.local/share/claude', '~/.local/share/cursor-agent',
             '~/.bun/bin', '~/.nvm', '~/.volta', '~/.cargo/bin', '~/.rustup', '~/.pyenv',
             '~/.local/share/mise', '~/.deno/bin', '~/go/bin']
# never readable, whatever a layer adds to `read`. {state} is fm's state/,
# which holds every other worktree; the round's own worktree is a write
# root and stays reachable
NEVER_READ = ['~/.ssh', '~/.gnupg', '~/.netrc', '~/.git-credentials', '~/.config/gh',
              '~/.aws', '~/.azure', '~/.config/gcloud', '~/.docker', '~/.kube',
              '~/.npmrc', '~/.pypirc', '~/.config/herdr',
              '~/.claude', '~/.claude.json', '~/.codex', '~/.cursor', '~/.config/cursor',
              '~/.gemini', '{state}']
# Each vendor's home is never readable as a whole: it holds the operator's
# settings, hooks, skills and MCP servers as well as the login. Its round
# gets back two things. `auth` is the login, readable only. `state` is what
# the CLI writes as it runs - session files, logs, caches and the one config
# file it rewrites - readable and writable, each entry a prefix, so a file
# rewritten through x.tmp.123 or x.lock stays writable too. None of `state`
# is a credential or the operator's settings. `hosts` is the vendor's own
# service: the whole CLI runs inside the OS sandbox, so its API has to be
# reachable through the round's proxy.
VENDORS = {
    # macOS keeps claude's login in the keychain, reached over mach, not a file
    'claude': dict(auth=['~/.claude/.credentials.json'],
                   state=['~/.claude.json', '~/.claude/projects', '~/.claude/todos',
                          '~/.claude/shell-snapshots', '~/.claude/statsig', '~/.claude/session-env',
                          '~/.claude/debug', '~/.claude/file-history', '~/.claude/plans'],
                   hosts=['anthropic.com', 'claude.ai']),
    'codex': dict(auth=['~/.codex/auth.json'],
                  state=['~/.codex/sessions', '~/.codex/log', '~/.codex/history.jsonl',
                         '~/.codex/version.json', '~/.codex/models_cache.json'],
                  hosts=['openai.com', 'chatgpt.com']),
    'cursor-agent': dict(auth=['~/.config/cursor/auth.json'],
                         state=['~/.cursor/chats', '~/.cursor/projects', '~/.cursor/cli-config.json',
                                '~/.cursor/statsig-cache.json'],
                         hosts=['cursor.sh', 'cursor.com']),
    'gemini': dict(auth=['~/.gemini/oauth_creds.json'],
                   state=['~/.gemini/tmp', '~/.gemini/history', '~/.gemini/google_accounts.json',
                          '~/.gemini/installation_id', '~/.gemini/user_id'],
                   hosts=['googleapis.com']),
}
REFUSE = ['git push', 'gh', 'herdr', 'browser', 'mcp']
SCRUB = dict(names=['GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN',
                    'SSH_AUTH_SOCK', 'SSH_AGENT_PID', 'GOOGLE_APPLICATION_CREDENTIALS',
                    'DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS', 'BROWSER'],
             prefixes=['AWS_', 'AZURE_', 'ARM_', 'CLOUDSDK_', 'GCLOUD_', 'DIGITALOCEAN_', 'HERDR_'])
REPO_CONFIG = ['.claude', '.mcp.json', '.cursor', 'GEMINI.md']
GITHUB_DOMAINS = ('github.com', 'github.io', 'github.dev', 'githubusercontent.com', 'githubassets.com',
                  'githubapp.com', 'githubcopilot.com', 'ghcr.io', 'ghe.com')


def host_refusal(host):
    """Why a round may not reach <host>, or None. The same rule as
    fm_review_host_refusal in bin/adapters/_lib.sh, plus loopback: a plain
    domain name, never GitHub's, never localhost, never an address."""
    if not re.match(r'[A-Za-z0-9.-]+$', host) or host.startswith('.') or host.endswith('.') or '..' in host:
        return 'is not a plain domain name'
    h = host.lower()
    for d in GITHUB_DOMAINS:
        if h == d or h.endswith('.' + d):
            return 'is a GitHub host; a crew round may not reach GitHub'
    if h == 'localhost' or h.endswith('.localhost'):
        return 'is loopback; a crew round may not reach loopback'
    if re.match(r'[0-9.]+$', h):
        return 'is an address; a registry is named, and loopback is never one'
    return None


def policy_map(lines, where):
    """A nested block of `key: value` lines -> a dict; comments already gone."""
    out, i = {}, 0
    level = indent(lines[0]) if lines else 0
    while i < len(lines):
        line = lines[i]
        found = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$', line)
        if indent(line) != level or not found:
            raise Refused('%s: cannot read line: %s' % (where, line.strip()))
        key = found.group(1)
        value = re.sub(r'(^|\s)#.*$', '', found.group(2) or '').strip()
        if key in out: raise Refused('%s: %s is given twice' % (where, key))
        i += 1; kids = []
        while i < len(lines) and indent(lines[i]) > level:
            kids.append(lines[i]); i += 1
        if kids and value: raise Refused('%s: %s has a value and a block' % (where, key))
        out[key] = policy_map(kids, where + '.' + key) if kids else value
    return out


def policy_layer(lines, where):
    """One layer, checked: flat keys for both roles, a block per role."""
    layer = policy_map(lines or [], where)
    for key, value in layer.items():
        if key in ROLES:
            if not isinstance(value, dict):
                raise Refused('%s.%s: must be a block of policy keys' % (where, key))
            for sub, v in value.items():
                policy_value(sub, v, '%s.%s' % (where, key))
        else:
            policy_value(key, value, where)
    return layer


def policy_value(key, value, where):
    if key not in POLICY_KEYS:
        raise Refused('%s: %s is not a policy key (known: %s)' % (where, key, ', '.join(POLICY_KEYS)))
    if isinstance(value, dict):
        raise Refused('%s.%s: must be a one-line value' % (where, key))
    if key == 'network':
        for host in value.split():
            why = host_refusal(host)
            if why: raise Refused('%s.network: names %s, which %s' % (where, host, why))
    elif key in ('read', 'never_read'):
        for path in value.split():
            if not (path.startswith('/') or path == '~' or path.startswith('~/')) \
                    or any(c in path for c in '"\\()*?[]'):
                raise Refused("%s.%s: '%s' is not an absolute path a sandbox profile can hold"
                              % (where, key, path))
    elif not re.match(r'[1-9][0-9]*$', value):
        raise Refused("%s.%s: must be a positive whole number, not '%s'" % (where, key, value))


def expand(path, engine):
    return os.path.realpath(os.path.expanduser(path.replace('{state}', str(engine / 'state'))))


def resolve_policy(lines, projects, default, config, role, explicit):
    if role not in ROLES:
        raise Refused("policy: the role is worker or reviewer, not '%s'" % role)
    engine = Path(config).resolve().parent
    name = explicit or os.environ.get('FM_PROJECT', '') or default or ''
    layers = [policy_layer(top_block(lines, 'policy'), 'policy')]
    if name and projects:
        layers.append(policy_layer(registered(projects, name).get('policy', []),
                                   'projects.%s.policy' % name))
    got = dict(read=list(TOOLCHAIN), never_read=list(NEVER_READ), procs='2048', cpu='14400')
    for layer in layers:
        for scope in (layer, layer.get(role) or {}):
            for key, value in scope.items():
                if key in ROLES: continue
                if key in ('read', 'never_read'): got[key] += value.split()
                else: got[key] = value
    if 'network' not in got and role == 'reviewer':
        # the pre-T-105 place for the reviewer's hosts
        legacy = policy_map(top_block(lines, 'reviewer') or [], 'reviewer').get('network', '')
        if isinstance(legacy, str):
            for host in legacy.split():
                why = host_refusal(host)
                if why: raise Refused('reviewer.network: names %s, which %s' % (host, why))
            got['network'] = legacy
    return dict(
        role=role, project=name if projects else '', dimensions=DIMENSIONS,
        # {tmp} is the round's own temp directory, which fm-sandbox.sh
        # makes; never the shared one, and never /tmp
        write=['{root}', '{tmp}'],
        read=[expand(p, engine) for p in got['read']],
        never_read=[expand(p, engine) for p in got['never_read']],
        network=got.get('network', '').split(),
        refuse=REFUSE, sockets='none', env_scrub=SCRUB, repo_config=REPO_CONFIG,
        procs=int(got['procs']), cpu=int(got['cpu']),
        vendors={v: dict(auth=[expand(p, engine) for p in d['auth']],
                         state=[expand(p, engine) for p in d['state']], hosts=d['hosts'])
                 for v, d in VENDORS.items()})


def registered(projects, name):
    if not NAME.match(name): refuse(name, 'name', 'must be [a-z0-9-], at most 24 characters')
    if name not in projects:
        refuse(name, 'name', 'is not registered in config.yaml (registered: %s)'
               % (', '.join(projects) or 'none'))
    return projects[name]


def field(projects, name, key, config):
    entry = registered(projects, name)
    engine = Path(config).resolve().parent
    if key == 'root':
        return str(engine if entry.get('repo') == '.' else engine / 'state/projects' / name / 'repo')
    if key == 'design':
        return entry.get(key) or 'projects/%s/design.md' % name
    if key == 'tasks':
        # a directory, one file per task (T-090); a path in the old shape,
        # design/tasks.json, names the directory beside it
        value = entry.get(key) or 'projects/%s/tasks' % name
        return value[:-len('.json')] if value.endswith('.json') else value
    if key in ('repo', 'github', 'base', 'required_check'):
        return entry.get(key, '')
    refuse(name, key, 'is not a registry field')


try:
    default, projects, has_top = load(config)
    if mode == 'names':
        for name in projects: print(name)
    elif mode == 'resolve':
        explicit = args[0] if args else ''
        name = explicit or os.environ.get('FM_PROJECT', '') or default or ''
        if not name:
            raise Refused('no project named: pass --project, set FM_PROJECT or declare default_project')
        registered(projects, name); print(name)
    elif mode == 'field':
        print(field(projects, args[0], args[1], config))
    elif mode == 'contract':
        name, key = args
        entry = registered(projects, name)
        if entry.get('repo') == '.' and has_top:
            try: rc = herdr.project_field(config, key)
            except ValueError as error:
                refuse(name, 'project', str(error).replace('config.yaml ', ''))
        else:
            rc = contract_of(name, entry.get('project', []), key)
        sys.exit(rc)
    elif mode == 'policy':
        lines = Path(config).read_text().splitlines() if Path(config).is_file() else []
        print(json.dumps(resolve_policy(lines, projects, default, config, args[0], args[1] if len(args) > 1 else ''),
                         indent=1))
    else:
        raise Refused('unknown registry mode ' + mode)
except Refused as error:
    print('fm-config: ' + str(error), file=sys.stderr); sys.exit(65)
except ValueError as error:
    print('fm-config: ' + str(error), file=sys.stderr); sys.exit(65)
PY
}

# The task list (T-090): one file per task, design/tasks/<id>.json, holding
# that task's entry and nothing else. It was one array in design/tasks.json
# plus a hand-kept copy in design.md, so every pull request appended to the
# same two places and every merge made every other open one a conflict.
# Adding a task adds a file; revising one edits only its file. Every reader
# goes through these, the board included.
#
#   fm_tasks [dir] [rev]            -> every task, one compact JSON per line,
#                                      in id order, H-2 before H-10; all or
#                                      nothing: 1, with no list, when any
#                                      file does not read or the directory
#                                      is not there
#   fm_task <id> [dir] [rev]        -> that task's entry; 1 when it has none
#   fm_tasks_write <file> [dir]     -> one file per entry of a {"tasks":[...]},
#                                      an array, or a single task
#   fm_tasks_check [dir]            -> one problem per line; 1 when any
#
# <dir> defaults to design/tasks. <rev> reads a commit or branch instead of
# the working copy: the gate, the worker and the reviewer read the branch
# under test, which is how a task defined on its own branch is seen at all.
# A name starting with a dot (.DS_Store, a scratch directory) is not a task.
_fm_task_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; }

# One task file's text -> its entry on one line; 1 unless it is exactly
# one JSON object. An empty file is not an empty task.
_fm_task_line() { jq -cs 'if length == 1 and (.[0] | type) == "object" then .[0] else error("not one task") end' 2>/dev/null; }

fm_tasks() {
  local dir="${1:-design/tasks}" rev="${2:-}" f names out='' line
  if [ -n "$rev" ]; then
    names="$(git ls-tree --name-only --full-tree "$rev" -- "$dir/" 2>/dev/null)" \
      || { echo "fm-config: cannot read $dir/ on $rev" >&2; return 1; }
    [ -n "$names" ] || { echo "fm-config: $rev has no $dir/" >&2; return 1; }
  else
    [ -d "$dir" ] || { echo "fm-config: $dir is not a directory" >&2; return 1; }
    names="$(find "$dir" -maxdepth 1 -type f -name '*.json' ! -name '.*' 2>/dev/null)" \
      || { echo "fm-config: cannot list $dir" >&2; return 1; }
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "${f##*/}" in .*) continue ;; *.json) ;; *) continue ;; esac
    # read into a string first: `git show | jq` hides a show that failed
    # behind jq's success on empty input, and a task would just vanish
    if [ -n "$rev" ]; then
      line="$(git show "$rev:$f" 2>/dev/null)" && line="$(printf '%s' "$line" | _fm_task_line)"
    else
      line="$(_fm_task_line < "$f")"
    fi || { echo "fm-config: $f does not read as one task; no task list" >&2; return 1; }
    out="$out$line
"
  done <<< "$(printf '%s\n' "$names" | LC_ALL=C sort -V)"
  printf '%s' "$out"
}

# A branch opened before T-090 has no design/tasks/ but its own
# design/tasks.json: its entry there is the task as that branch says it,
# whether the task is new on the branch or revised there. So when the
# task has no file, its entry in <dir>.json - on the rev, or in a working
# copy still in the old layout - is read (and said so on stderr) rather
# than main's file, which would be another text, or nothing at all.
_fm_task_old() { jq --arg id "$1" '[.tasks[]? | select(.id == $id)] | if length == 1 then .[0] else empty end' 2>/dev/null; }
fm_task() {
  local id="${1:-}" dir="${2:-design/tasks}" rev="${3:-}" j
  _fm_task_id "$id" || return 1
  if [ -n "$rev" ]; then
    if ! j="$(git show "$rev:$dir/$id.json" 2>/dev/null)"; then
      j="$(git show "$rev:$dir.json" 2>/dev/null | _fm_task_old "$id")"
      [ -n "$j" ] || return 1
      echo "fm-config: $id is read from $rev's $dir.json, the old one-array list; bring the branch over: bin/fm.sh tasks split $id" >&2
    fi
  elif [ -f "$dir/$id.json" ]; then
    j="$(cat "$dir/$id.json" 2>/dev/null)" || return 1
  else
    j="$(_fm_task_old "$id" 2>/dev/null < "$dir.json")"
    [ -n "$j" ] || return 1
    echo "fm-config: $id is read from $dir.json, the old one-array list; bring it over: bin/fm.sh tasks split $id" >&2
  fi
  # a file whose id is another task's is not this task
  j="$(printf '%s' "$j" | jq --arg id "$id" 'select(type=="object" and .id==$id)' 2>/dev/null)"
  [ -n "$j" ] || return 1
  printf '%s\n' "$j"
}

fm_tasks_write() {
  local src="$1" dir="${2:-design/tasks}" all line id
  all="$(jq -c 'if type=="array" then .[] elif has("tasks") then .tasks[] else . end' "$src")" \
    || { echo "fm-config: $src is not a task list" >&2; return 65; }
  mkdir -p "$dir" || return 70
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="$(printf '%s' "$line" | jq -r '.id // empty')"
    _fm_task_id "$id" || { echo "fm-config: a task with no usable id: $line" >&2; return 65; }
    printf '%s' "$line" | jq . > "$dir/$id.json" || return 70
  done <<< "$all"
}

fm_tasks_check() {
  python3 - "${1:-design/tasks}" <<'PY'
import json, sys
from pathlib import Path

d = Path(sys.argv[1])
problems, tasks = [], {}
legacy = d.parent / (d.name + '.json')
if legacy.exists():
    problems.append('%s is still here: each entry belongs in its own file under %s/' % (legacy, d))
if not d.is_dir():
    problems.append('%s is not a directory' % d)
    files = []
else:
    files = sorted(d.iterdir())
for f in files:
    # .DS_Store, an interrupted --adopt's scratch: not a task, as fm_tasks says
    if f.name.startswith('.'):
        continue
    if f.suffix != '.json' or not f.is_file():
        problems.append('%s: not a task file (<id>.json)' % f.name); continue
    try:
        task = json.loads(f.read_text())
    except (OSError, ValueError) as error:
        problems.append('%s: does not parse: %s' % (f.name, error)); continue
    if not isinstance(task, dict) or task.get('id') != f.stem:
        problems.append('%s: its id is %s, not %s' % (f.name, json.dumps(task.get('id') if isinstance(task, dict) else None), f.stem))
        continue
    tasks[f.stem] = task
deps = {}
for name, task in tasks.items():
    wants = task.get('depends_on', [])
    if not isinstance(wants, list) or not all(isinstance(x, str) for x in wants):
        problems.append('%s: depends_on is not a list of ids' % name); wants = []
    for dep in wants:
        if dep not in tasks: problems.append('%s: depends on %s, which has no task file' % (name, dep))
    deps[name] = [dep for dep in wants if dep in tasks]
# a cycle is a task that waits, however indirectly, on itself: nothing in it
# can ever be dispatched. Each cycle is printed once, from its first task.
state, seen = {}, set()
def visit(node, path):
    state[node] = 'open'; path.append(node)
    for dep in deps[node]:
        if state.get(dep) == 'open':
            cycle = path[path.index(dep):] + [dep]
            key = frozenset(cycle)
            if key not in seen:
                seen.add(key); problems.append('a cycle: ' + ' -> '.join(cycle))
        elif dep not in state:
            visit(dep, path)
    path.pop(); state[node] = 'done'
for name in sorted(deps):
    if name not in state: visit(name, [])
for problem in problems: print(problem)
sys.exit(1 if problems else 0)
PY
}

# Freeze before doing work. A nested entrypoint uses the parent's frozen code,
# while a newly invoked session takes a new snapshot. Explicit roles win.
# Ignore SIGHUP so a background launch from an agent shell that exits does not
# orphan the caller-side wait for result.json / PR publish. Pane-child also
# ignores hangup and publishes last-result / close itself.
trap '' HUP
fm_freeze() {
  local script="$1"
  if [ "${FM_ENTRY_PID:-}" != "$$" ] || [ "${FM_ENTRY_SCRIPT:-}" != "${script##*/}" ]; then
    exec python3 "$_fm_code_dir/fm-herdr.py" launch "$_fm_code_dir/${script##*/}" "${@:2}"
  fi
}

fm_identity() {
  local role="$1" task="$2" alias="$3"
  # Recursion guards belong to one adapter invocation, never a new role run.
  unset FM_CONTEXT_READY FM_ATTEMPT_DIR FM_FINAL_PATH FM_CLI_EXIT FM_CHAIN_ATTEMPT
  # and a run-mode review's checkout belongs to that one round
  unset FM_RUN_REVIEW FM_REVIEW_CHECKOUT FM_REVIEW_NETWORK
  FM_RUN_DIR="$(python3 "${FM_CODE_ROOT:-$REPO}/bin/fm-herdr.py" allocate "$REPO" "$role" "$task" "$alias")" || return 70
  NAME="${FM_RUN_DIR##*/}"
  export FM_RUN_DIR FM_ROLE="$role" FM_TASK="$task" FM_ACTOR="$NAME" FM_ROOT="$REPO"
  printf '%s: canonical actor %s (requested alias: %s)\n' "$role" "$NAME" "${alias:-automatic}" >&2
  python3 - "$FM_RUN_DIR" "$$" "${FM_CODE_ROOT:-$REPO}" <<'PY'
import json, pathlib, sys
run, pid, code = sys.argv[1:]
p = pathlib.Path(run)
identity = json.loads((p / 'identity.json').read_text())
(p / 'process.json').write_text(json.dumps(dict(identity, pid=int(pid), token=code, snapshot=code)))
PY
}

fm_record_end() {
  python3 - "$FM_RUN_DIR" "$1" "${FM_CODE_ROOT:-$REPO}" "${FM_CHAIN_ATTEMPT:-}" "${FM_VENDOR_USED:-}" <<'PY'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location('managed', pathlib.Path(sys.argv[3]) / 'bin/fm-herdr.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
run = pathlib.Path(sys.argv[1])
identity = json.loads((run / 'identity.json').read_text())
last = run / 'last-result.json'
result = json.loads(last.read_text()) if last.exists() else {}
if not sys.argv[4] or result.get('chain_attempt') != sys.argv[4]:
    result = dict(status='unknown', chain_attempt=sys.argv[4], vendor=sys.argv[5])
module.save(run / 'orchestration-result.json', dict(identity, process_exit=int(sys.argv[2]), adapter_result=result))
PY
}

# The order vendors are tried in, and the running of that order. Both the
# worker and the reviewer need it and they must behave identically, so it
# lives here once rather than as a loop in each.
#
# fm_vendor_chain [role] [explicit]
#   An explicit --vendor is the whole chain: the caller asked for that engine,
#   not for whatever the config would fall back to.
fm_vendor_chain() {
  local role="${1:-}" explicit="${2:-}" head=''
  if [ -n "$explicit" ]; then printf '%s\n' "$explicit"; return 0; fi
  [ -n "$role" ] && head="$(fm_cfg_in "$role" vendor)"
  [ -n "$head" ] || head="$(fm_cfg vendor)"
  [ -n "$head" ] || head=mock
  # one run per vendor: a fallback list may name the head, or itself twice
  printf '%s\n' "$head"
  fm_cfg_list fallback | grep -vxF "$head" | awk '!seen[$0]++' || true
}

# fm_review_run_chain <adapters-dir> <chain>
#   The part of a reviewer chain that may take a run-mode round: an adapter
#   declares it can confine one with a `# fm:review-run` line, which it may
#   carry only if its CLI's own permission flags keep the engine inside the
#   checkout and away from push. The rest is dropped, and a head that cannot
#   is refused (1) rather than quietly replaced by a fallback. A name with no
#   adapter is kept, so fm_run_chain still reports a typo as a typo.
fm_review_run_chain() {
  local dir="$1" v first=1 kept='' names=()
  # split on blanks and newlines as the chain is, but never globbed: an
  # unquoted expansion would read a `*` as the file names around it
  read -r -d '' -a names <<<"$2" || true
  for v in ${names[@]+"${names[@]}"}; do
    if [ -x "$dir/$v.sh" ] && ! grep -q '^# fm:review-run' "$dir/$v.sh"; then
      [ "$first" = 1 ] && return 1
    else
      kept="${kept:+$kept
}$v"
    fi
    first=0
  done
  printf '%s\n' "$kept"
}

# fm_run_chain <adapters-dir> <chain> <prompt> <tree> <log> [evidence]
#   Returns the adapter's own exit code, or 2 if every vendor was unavailable.
#   Sets FM_VENDOR_USED and FM_VENDOR_SKIPPED so the caller can say what it did.
#
#   <evidence> is a command that answers "did that run produce work?". An
#   adapter decides "unavailable" by reading text, and text can lie in both
#   directions, so the caller gets the last word: a worker asks whether the
#   worktree changed, a reviewer whether the output carries a verdict marker.
#   Work beats a signature, and the chain stops there. FM_VENDOR_MISREAD names
#   the vendor this happened to, so the caller can say so.
#
#   FM_VENDOR_SPOKE is 1 when some attempt produced output of its own -
#   bytes appended to the log, or, in per-vendor mode only, a file in its
#   own directory. In shared mode the directory is the caller's artefact and
#   was not empty to begin with, so it cannot answer the question and is not
#   consulted. With
#   the return code it is the whole of what a caller needs: rc 2 with
#   nothing said is a vendor that was not there; rc 2 with something said is
#   an engine that ran badly. Neither caller may re-derive this by looking
#   at bytes itself - they disagreed when they did.
#
#   The head of the chain having no adapter is a typo in config.yaml, not an
#   outage: nothing is run at all, FM_VENDOR_UNKNOWN names it and 65 comes
#   straight back, so the caller's own exit 65 cannot discard work a later
#   vendor had already done.
#
#   <outmode> "per-vendor" gives each attempt its own directory under <tree>
#   and names it in FM_RUN_OUTDIR (in shared mode that is <tree> itself,
#   shared by every attempt); the default shares <tree>, which is what
#   a worker wants because the worktree IS the artefact. FM_RUN_LOG_OFF is
#   where this attempt's bytes start in the shared log, so an evidence
#   predicate can read its own output and no one else's.
# shellcheck disable=SC2034  # these are read by the callers, not here
fm_run_chain() {
  local dir="$1" chain="$2" prompt="$3" tree="$4" log="$5" evidence="${6:-}" \
        outmode="${7:-shared}" v rc=2 head='' out='' after=0
  # every output of this function, including the two that say where an
  # attempt's bytes are: leaving those set means a caller on the
  # configuration-error path reads the PREVIOUS call's attempt, which is the
  # exact confusion the offsets exist to prevent
  FM_VENDOR_USED=''; FM_VENDOR_SKIPPED=''; FM_VENDOR_MISREAD=''; FM_VENDOR_UNKNOWN=''
  FM_RUN_OUTDIR=''; FM_RUN_LOG_OFF=0; FM_VENDOR_SPOKE=0
  export FM_CHAIN_ATTEMPT=''
  # before anything runs. A typo at the head of the chain used to be found
  # after a real vendor had already worked, and the caller's exit 65 then
  # threw that work away.
  # unquoted on purpose: a chain arrives space-separated or newline-separated
  # and the head is the first word either way. SC2086 is info-level and the
  # gate runs at warning, so there is no directive here to go stale - the
  # adapters rely on the same deliberate splitting for FM_ADAPTER_ARGS.
  head="$(printf '%s\n' $chain | head -1)"
  if [ -n "$head" ] && [ ! -x "$dir/$head.sh" ]; then
    FM_VENDOR_UNKNOWN="$head"; return 65
  fi
  for v in $chain; do
    [ -x "$dir/$v.sh" ] || continue
    # each vendor reads only what it wrote. The chain shares one log, and a
    # vendor that dies half way through must not have its bytes read as the
    # next one's answer - so the caller is told where this attempt's output
    # begins, and where it went.
    FM_RUN_LOG_OFF="$(wc -c "$log" 2>/dev/null | awk '{print $1}')"
    [ -n "$FM_RUN_LOG_OFF" ] || FM_RUN_LOG_OFF=0
    if [ "$outmode" = "per-vendor" ]; then
      out="$tree/$v"; mkdir -p "$out"
    else
      out="$tree"
    fi
    FM_RUN_OUTDIR="$out"
    # Bind every receipt reader to this invocation, including custom fallbacks
    # that never create managed receipts. Keep previous receipts as evidence.
    FM_CHAIN_ATTEMPT="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')" || return 70
    export FM_CHAIN_ATTEMPT
    "$dir/$v.sh" run "$prompt" "$out" "$log"; rc=$?
    # did this vendor say anything of its own? The callers need to tell an
    # engine that ran badly from one that was not there, and this is the
    # only place that can answer it - an adapter's notice about a missing
    # CLI goes to stderr precisely so it does not count here.
    #
    # In shared mode the directory IS the artefact and is never empty, so
    # only the log slice can answer this; the per-vendor directory starts
    # empty and anything in it was written by this attempt. The meaning is
    # the same in both modes: bytes this attempt produced.
    after="$(wc -c "$log" 2>/dev/null | awk '{print $1}')"; [ -n "$after" ] || after=0
    [ "$after" != "$FM_RUN_LOG_OFF" ] && FM_VENDOR_SPOKE=1
    if [ "$outmode" = "per-vendor" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
      FM_VENDOR_SPOKE=1
    fi
    if [ "$rc" = 2 ] && [ -n "$evidence" ] && $evidence; then
      FM_VENDOR_USED="$v"; FM_VENDOR_MISREAD="$v"; return 0
    fi
    if [ "$rc" = 2 ]; then FM_VENDOR_SKIPPED="${FM_VENDOR_SKIPPED:+$FM_VENDOR_SKIPPED }$v"; continue; fi
    FM_VENDOR_USED="$v"; return "$rc"
  done
  return "$rc"
}

# `shift 2` with one argument left does not shift: it returns 1 and leaves
# $@ alone, so `while [ $# -gt 0 ]` spins on the same flag for ever -
# `bin/fm-emit.sh --type` was a busy loop rather than an error. Every
# flag that takes a value checks before it shifts, in the same case
# branch, and exits 64. The repository lint fails on a `shift 2` that has not
# checked, and tests/option-loop.test.sh runs every flag of every script
# with nothing after it - under an alarm, because a test for a hang that
# simply calls the script hangs the gate instead of failing it.
#
# The scripts that deliberately depend on nothing carry a two-line copy
# that points back here. How many there are is pinned in
# tests/option-loop.test.sh - by an assertion that greps for the local
# definition, which is new: the sentence claiming it was pinned was
# there a round before the assertion was. A count in a comment is only
# true on the day it is typed, and a claim that a count is checked
# somewhere else is worth no more than the check.
fm_need() { [ "$#" -ge 3 ] || { echo "$1: $2 needs a value" >&2; exit 64; }; }

# Commits that land on GitHub must use the operator's configured identity
# (user.name / user.email), not a synthetic firstmate@local that GitHub
# cannot link to an account. Override with FM_GIT_NAME / FM_GIT_EMAIL when
# a bot identity is intentional.
#
# The lookup asks the worktree being committed to, not the caller's cwd:
# fm-checkpoint --dir never cd's into the repo, so a cwd lookup saw only
# whatever identity happened to be ambient - the operator's own config at
# a terminal, and nothing at all on a CI runner, where a repo that does
# configure an identity locally was refused a commit anyway.
fm_git_name()  { printf '%s' "${FM_GIT_NAME:-$(git -C "${1:-.}" config user.name 2>/dev/null || true)}"; }
fm_git_email() { printf '%s' "${FM_GIT_EMAIL:-$(git -C "${1:-.}" config user.email 2>/dev/null || true)}"; }
fm_git_commit() {  # fm_git_commit <worktree> <message>
  local dir="$1" msg="$2" n e
  n="$(fm_git_name "$dir")"; e="$(fm_git_email "$dir")"
  if [ -z "$n" ] || [ -z "$e" ]; then
    echo "fm: set git user.name and user.email (or FM_GIT_NAME / FM_GIT_EMAIL) before committing" >&2
    return 70
  fi
  git -C "$dir" -c user.name="$n" -c user.email="$e" commit -q -m "$msg"
}

# Inside a user Herdr session, direct transport is a protocol violation —
# firstmate must use stock managed panes, not invent FM_TRANSPORT=direct
# or session wrappers. Tests that intentionally exercise in-process
# adapters under a fake HERDR_ENV set FM_ALLOW_DIRECT=1.
fm_refuse_herdr_bypass() {
  local who="${1:-fm}"
  if [ "${HERDR_ENV:-}" = 1 ] && [ "${FM_TRANSPORT:-herdr}" = direct ] && [ "${FM_ALLOW_DIRECT:-}" != 1 ]; then
    echo "$who: FM_TRANSPORT=direct is refused when HERDR_ENV=1; use stock managed Herdr (unset FM_TRANSPORT)" >&2
    return 70
  fi
  return 0
}

# --- what counts as a script, and what counts as a comment ---------------
#
# One definition, because there were four and three of them were the
# broken one. The gate lints an option loop; tests/option-loop.test.sh
# sweeps for a script the gate should have linted and did not. Two
# processes, so they cannot share a variable - but they can share these,
# and a sweep written out by hand at the call site is a sweep that drifts
# from the one it is supposed to be checking.
#
# The stripper cuts at a `#` that STARTS A WORD. `sed 's/#.*$//'` also
# cuts `${1#--}` and `"#"`, and a `shift 2` sharing a line with either
# then disappears - out of the lint, and out of the sweep that exists to
# notice the lint missing something, both blind the same way.
# Managed Herdr sessions refresh mid-run activity through the same crew_status
# path as fm-worker.sh / fm-review.sh (T-036).
# Equals-form long opts on purpose: traps.sweep_unarmed matches `--actor VALUE`
# (space form) on lifecycle scripts. This is a library helper, not an emitter
# that boards a crewman, so space-form would false-positive the unarmed sweep.
fm_herdr_emit_status() {  # fm_herdr_emit_status <root> <actor> <task> <en> <tw> [role [done total]]
  local root="$1" actor="$2" task="$3" en="$4" tw="$5" role="${6:-worker}"
  local done_n="${7-}" total_n="${8-}" py="${root}/bin/fm-herdr.py"
  command -v python3 >/dev/null 2>&1 || return 2
  [ -f "$py" ] || return 2
  if [ -n "$done_n" ] && [ -n "$total_n" ]; then
    python3 "$py" emit-status --root="$root" --actor="$actor" --task="$task" \
      --role="$role" --en="$en" --tw="$tw" --done="$done_n" --total="$total_n"
  else
    python3 "$py" emit-status --root="$root" --actor="$actor" --task="$task" \
      --role="$role" --en="$en" --tw="$tw"
  fi
}

fm_strip_comments() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$1"; }

# It descends: `bin/*.sh` misses a subdirectory, and bin/adapters has
# been there all along.
fm_shell_corpus() { find "${1:-bin}" -type f -name '*.sh' | sort; }

# A file declares itself a lint source when it quotes the shapes it
# forbids, rather than being on a list somewhere else.
fm_is_lint_source() { grep -q '^# fm:lint-source' "$1"; }

# Every script with an option loop, which is the corpus both the gate and
# the suite judge.
fm_loop_corpus() {   # fm_loop_corpus [dir]
  local f
  while IFS= read -r f; do
    fm_is_lint_source "$f" && continue
    # a here-string, not a pipe: grep -q leaves on the match, the
    # producer takes SIGPIPE, and under pipefail that reads as "no
    # match" - it dropped the two longest scripts on the runner
    grep -q 'shift 2' <<< "$(fm_strip_comments "$f")" || continue
    printf '%s\n' "$f"
  done < <(fm_shell_corpus "${1:-bin}")
}

# Which flags an option loop consumes a value for. This lived in
# tests/option-loop.test.sh, hand-rolled, which made it a THIRD idea of
# what a line of an option loop is in the file whose argument is that
# there must be one - and it was the idea the pinned counts are derived
# from. It reads comments off first (a flag named in a comment inside
# the loop used to invent one) and takes the whole case pattern rather
# than one flag from it, so `--x|--y)` is two.
fm_loop_flags() {   # fm_loop_flags <file>
  fm_strip_comments "$1" \
    | sed -n '/while .*$# -gt 0/,/^done/p' \
    | grep 'shift 2' \
    | sed 's/).*$//' \
    | grep -oE '\-\-[A-Za-z][A-Za-z0-9-]*' \
    | sort -u
}
