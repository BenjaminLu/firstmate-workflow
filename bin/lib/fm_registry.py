"""Registry helpers extracted from fm-config.sh."""

import sys


def registry():
    import getpass, importlib.util, json, os, re, sys, tempfile
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
    FIELDS = ('repo', 'github', 'base', 'required_check', 'design', 'tasks', 'project', 'policy', 'projection')
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
            if entry.get('projection', 'comments') not in ('comments', 'local'):
                refuse(name, 'projection', 'must be comments or local')
            for key in ('base', 'required_check'):
                if not entry.get(key): refuse(name, key, 'is required')
            for key in ('design', 'tasks'):
                value = entry.get(key)
                if value is None: continue
                if not value or value.startswith('/') or '..' in Path(value).parts:
                    refuse(name, key, "must be a path relative to the engine root, not '%s'" % value)
            if has_top and entry.get('repo') == '.' and 'project' in entry:
                refuse(name, 'project', 'is also declared by the top-level project: block; '
                       'declare exactly one self contract')
            if 'project' in entry: contract_of(name, entry['project'], None)
            if 'policy' in entry: policy_layer(entry['policy'], 'projects.%s.policy' % name)
        selves = [name for name in order if projects[name].get('repo') == '.']
        if len(selves) > 1:
            refuse(selves[1], 'repo', 'is . for %s as well; only one project is the engine itself' % selves[0])
        return default, projects, has_top


    # --- the crew's permission policy (T-105, T-117; see fm_policy above) -----
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
                  '~/.gemini', '~/.config/firstmate', '{state}']
    # Each vendor's home is never readable as a whole: it holds the operator's
    # settings, hooks, skills and MCP servers as well as the login. Its round
    # gets back only what it needs to start and sign in (design 13.1 names each
    # one and why):
    #
    #   auth   files readable only, in place. No vendor has one: every login
    #          file holds a refresh token, so fm reads it and hands in a copy
    #          without one (login.copy below)
    #   state  what the CLI writes as it runs - session files, logs, caches and
    #          the one config file it rewrites - readable and writable, each
    #          entry a prefix, so a file rewritten through x.tmp.123 or x.lock
    #          stays writable too. None of it is a credential or a setting.
    #   tmp    directories the CLI keeps under the system's /tmp whatever
    #          TMPDIR says, readable and writable. Only macOS needs them: on
    #          Linux the round's /tmp is a fresh one of its own.
    #   login  the login fm reads OUTSIDE the round and hands in, because the
    #          round cannot reach where the operator's login keeps it (T-117):
    #            keychain  generic-password items, by service and account,
    #                      read on macOS with security(1); the keychain itself
    #                      stays out of every round's reach
    #            secret    libsecret items, by service and account, read with
    #                      secret-tool(1) when it is on the operator's PATH -
    #                      the keychain's rough equivalent off macOS (T-126);
    #                      tried only when no keychain item answered, and
    #                      skipped, not refused, when secret-tool is absent
    #            file      files read when neither a keychain nor a secret
    #                      item is there
    #            private   the file must be the operator's alone (no group or
    #                      other bits), or it is no login
    #            field     the JSON field of the value that is the token; none,
    #                      and the whole value is
    #            expires   the JSON field saying when it expires, in ms; a
    #                      login past it is no login
    #            given     variables that, set in the operator's environment,
    #                      already carry a login, so nothing is read
    #            to        env:<NAME>, the token handed in as that variable
    #            hint      what the operator does once when there is no login,
    #                      said with the refusal
    #            copy     for a login read from a file: the path, under the
    #                      round's own temp directory, where fm writes that
    #                      file with `drop` emptied, for the adapter to point
    #                      the CLI at (T-117 round 2)
    #            drop      the JSON fields of that file that are its refresh
    #                      token, emptied in the copy
    #            fallback  a second tier, tried only when this one names
    #                      nothing at all - no keychain item, no file - never
    #                      when it is refused for a reason (a locked-down
    #                      file, an expired or malformed token, which stop the
    #                      round rather than quietly trying something weaker).
    #                      Its own keychain/file/field/expires/private, same
    #                      meaning; it shares this tier's `to`. Used, it warns
    #                      (T-126): claude's round has no crew token of its
    #                      own and so signs in with the operator's own
    #                      interactive login instead, which that operator's
    #                      own Claude sessions can revoke out from under a
    #                      round still holding it by refreshing their login -
    #                      exactly what killed T-125's worker and T-123's
    #                      reviewer on 2026-09-27.
    #          Only an access token is handed in, never a refresh token: a
    #          round that refreshed a login would rotate the operator's out
    #          from under them, and one that could not write the refreshed
    #          login back would leave the operator's spent. fm-sandbox.sh
    #          refuses a copy that still holds any refresh_token field.
    #   hosts  the vendor's own service: the whole CLI runs inside the OS
    #          sandbox, so its API has to be reachable through the round's proxy
    #
    # {uid} and {user} are the operator's.
    VENDORS = {
        # A round's claude has a config directory of its own (CLAUDE_CONFIG_DIR,
        # in the round's temp directory), so ~/.claude and ~/.claude.json are
        # not opened at all. Its login (T-126) is, in order: a
        # CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY already in the
        # operator's environment, used as is; else the crew's own long-lived
        # token, made once with `claude setup-token`
        # (https://code.claude.com/docs/en/authentication) and kept the way
        # T-117 keeps cursor-agent's Cursor key - a keychain item of fm's own
        # on macOS, a libsecret item of fm's own where secret-tool is present
        # (Linux, T-126 round 2), else a file only the operator can read; only
        # when none of those exists does it fall back to the access token of
        # the operator's own interactive login, with a warning (see `fallback`
        # above) that this can die when that login refreshes.
        'claude': dict(auth=[], state=[], tmp=['/tmp/claude-{uid}'],
                       login=dict(keychain=[dict(service='firstmate-claude-token', account='{user}')],
                                  secret=[dict(service='firstmate-claude-token', account='{user}')],
                                  file=['~/.config/firstmate/claude-token'], private=True,
                                  given=['CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY'],
                                  to='env:CLAUDE_CODE_OAUTH_TOKEN',
                                  hint='make a long-lived crew token (claude setup-token; one year, model '
                                       'requests only, https://code.claude.com/docs/en/authentication) and keep '
                                       'it for the crew once, outside any round: security add-generic-password '
                                       '-s firstmate-claude-token -a "$USER" -w on macOS (it asks for the token), '
                                       'secret-tool store --label=firstmate-claude-token service '
                                       'firstmate-claude-token account "$USER" on Linux with libsecret, or write '
                                       'it to ~/.config/firstmate/claude-token with mode 600; revoke it at '
                                       'claude.ai, Settings, Claude Code',
                                  fallback=dict(keychain=[dict(service='Claude Code-credentials', account='{user}')],
                                                file=['~/.claude/.credentials.json'],
                                                field='claudeAiOauth.accessToken',
                                                expires='claudeAiOauth.expiresAt')),
                       hosts=['anthropic.com', 'claude.ai']),
        # codex's login file holds its refresh token beside the access token.
        # The round's CODEX_HOME is its own, and holds a copy without it.
        'codex': dict(auth=[],
                      state=['~/.codex/sessions', '~/.codex/log', '~/.codex/history.jsonl',
                             '~/.codex/version.json', '~/.codex/models_cache.json'],
                      tmp=[],
                      login=dict(file=['~/.codex/auth.json'], field=['tokens.access_token', 'OPENAI_API_KEY'],
                                 drop=['tokens.refresh_token'], given=['CODEX_API_KEY'],
                                 copy='codex-home/auth.json'),
                      hosts=['openai.com', 'chatgpt.com']),
        # cursor-agent reads `agent login`'s token through the keychain API,
        # which no round reaches and nothing on the round's PATH can answer for
        # (the canary, 2026-09-26: a security(1) stand-in was never asked). So
        # its round signs in with a Cursor API key the operator makes once for
        # the crew, kept by fm outside every round - a keychain item of fm's own
        # on macOS, else a file only the operator can read - and handed in as
        # CURSOR_API_KEY, the variable cursor-agent documents. Neither `agent
        # login`'s items nor ~/.config/cursor are read, so no refresh token of
        # cursor's is anywhere near a round.
        'cursor-agent': dict(auth=[],
                             state=['~/.cursor/chats', '~/.cursor/projects', '~/.cursor/cli-config.json',
                                    '~/.cursor/statsig-cache.json'],
                             tmp=[],
                             login=dict(keychain=[dict(service='firstmate-cursor-api-key', account='{user}')],
                                        file=['~/.config/firstmate/cursor-api-key'], private=True,
                                        given=['CURSOR_API_KEY'], to='env:CURSOR_API_KEY',
                                        hint='make a Cursor API key (cursor.com, Settings, API keys) and keep it '
                                             'for the crew once, outside any round: '
                                             'security add-generic-password -s firstmate-cursor-api-key '
                                             '-a "$USER" -w (it asks for the key), or write it to '
                                             '~/.config/firstmate/cursor-api-key with mode 600'),
                             hosts=['cursor.sh', 'cursor.com']),
        # gemini's login file holds its refresh token too. The round's gemini
        # runs with a HOME of its own, whose .gemini holds a copy without it.
        'gemini': dict(auth=[],
                       state=['~/.gemini/tmp', '~/.gemini/history', '~/.gemini/google_accounts.json',
                              '~/.gemini/installation_id', '~/.gemini/user_id'],
                       tmp=[],
                       login=dict(file=['~/.gemini/oauth_creds.json'], field='access_token', expires='expiry_date',
                                  drop=['refresh_token'], given=['GEMINI_API_KEY', 'GOOGLE_API_KEY'],
                                  copy='gemini-home/.gemini/oauth_creds.json'),
                       hosts=['googleapis.com']),
    }
    REFUSE = ['git push', 'gh', 'herdr', 'browser', 'mcp']
    # FM_CREW_UNSANDBOXED and FM_ROUND_UNSANDBOXED are the operator's escape
    # hatch (design 13.1): never a round's, so a nested fm run inside one
    # cannot switch its own sandbox off
    SCRUB = dict(names=['GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN',
                        'SSH_AUTH_SOCK', 'SSH_AGENT_PID', 'GOOGLE_APPLICATION_CREDENTIALS',
                        'DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS', 'BROWSER',
                        'FM_CREW_UNSANDBOXED', 'FM_ROUND_UNSANDBOXED'],
                 prefixes=['AWS_', 'AZURE_', 'ARM_', 'CLOUDSDK_', 'GCLOUD_', 'DIGITALOCEAN_', 'HERDR_'])
    REPO_CONFIG = ['.claude', '.mcp.json', '.cursor', 'GEMINI.md']
    GITHUB_DOMAINS = ('github.com', 'github.io', 'github.dev', 'githubusercontent.com', 'githubassets.com',
                      'githubapp.com', 'githubcopilot.com', 'ghcr.io', 'ghe.com')
    # Hosts refused to every round, for every vendor, whatever a policy
    # declares, because the captain decided what they are (T-147, 2026-09-29).
    # Each is a full-match regex and what the host is. The list rides in the
    # policy as `known_refused`, so the round's proxy (bin/fm-sandbox.sh) and
    # the report of what it refused (fm_policy_report) read this one list.
    #   sdmntpr<region>.oaiusercontent.com is OpenAI's user file store: paths
    #   under files/, which the Codex SDK and ChatGPT's file features use. A
    #   round's model conversation does not need it - the codex round it was
    #   refused to on 2026-09-29 exited 0 and talked to the model - and it
    #   would be an upload channel out of the round.
    KNOWN_REFUSED = [
        dict(pattern=r'sdmntpr[a-z0-9-]*\.oaiusercontent\.com',
             what="OpenAI's user file store, which no round needs and which would be an upload channel "
                  "out of it (design 13.1, T-147)"),
    ]


    def known_refusal(host):
        """What <host> is, when it is one every round is refused, or None."""
        h = host.lower().rstrip('.')
        for k in KNOWN_REFUSED:
            if re.fullmatch(k['pattern'], h):
                return k['what']
        return None


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
        what = known_refusal(h)
        if what:
            return 'is %s; it is refused for every vendor' % what
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


    def operator(text):
        return text.replace('{uid}', str(os.getuid())).replace('{user}', getpass.getuser())


    def expand(path, engine):
        return os.path.realpath(os.path.expanduser(operator(path).replace('{state}', str(engine / 'state'))))


    def vendor_of(d, engine):
        login = dict(d['login'])
        if login:
            login['keychain'] = [dict(service=k['service'], account=operator(k['account']))
                                 for k in login.get('keychain', [])]
            login['secret'] = [dict(service=k['service'], account=operator(k['account']))
                               for k in login.get('secret', [])]
            login['file'] = [expand(p, engine) for p in login.get('file', [])]
            if login.get('fallback'):
                fallback = dict(login['fallback'])
                fallback['keychain'] = [dict(service=k['service'], account=operator(k['account']))
                                        for k in fallback.get('keychain', [])]
                fallback['secret'] = [dict(service=k['service'], account=operator(k['account']))
                                      for k in fallback.get('secret', [])]
                fallback['file'] = [expand(p, engine) for p in fallback.get('file', [])]
                login['fallback'] = fallback
        return dict(auth=[expand(p, engine) for p in d['auth']],
                    state=[expand(p, engine) for p in d['state']],
                    tmp=[expand(p, engine) for p in d['tmp']],
                    login=login, hosts=d['hosts'])


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
            never_read=[expand(p, engine) for p in got['never_read']] + (
                [field(projects, name, 'state', config)]
                if name and projects and registered(projects, name).get('repo') != '.' else []),
            network=got.get('network', '').split(),
            known_refused=KNOWN_REFUSED,
            refuse=REFUSE, sockets='none', env_scrub=SCRUB, repo_config=REPO_CONFIG,
            procs=int(got['procs']), cpu=int(got['cpu']),
            vendors={v: vendor_of(d, engine) for v, d in VENDORS.items()})


    def registered(projects, name):
        if not NAME.match(name): refuse(name, 'name', 'must be [a-z0-9-], at most 24 characters')
        if name not in projects:
            refuse(name, 'name', 'is not registered in config.yaml (registered: %s)'
                   % (', '.join(projects) or 'none'))
        return projects[name]


    def field(projects, name, key, config):
        entry = registered(projects, name)
        engine = Path(config).resolve().parent
        if key in ('home', 'root', 'state', 'worktrees', 'design', 'tasks', 'conventions'):
            if entry.get('repo') == '.':
                paths = dict(home=str(engine), root=str(engine), state=str(engine / 'state'),
                             worktrees=str(engine / 'state/worktrees'),
                             design=entry.get('design') or 'design/design.md',
                             tasks=entry.get('tasks') or 'design/tasks',
                             conventions=str(engine / 'CONVENTIONS.md'))
                return paths[key]
            path_module = Path(herdr_path).parent / 'lib/fm_project_paths.py'
            spec = importlib.util.spec_from_file_location('fm_project_paths', path_module)
            paths = importlib.util.module_from_spec(spec); spec.loader.exec_module(paths)
            configured = ''
            for raw in Path(config).read_text().splitlines():
                match = re.match(r'home:(?:\s+(.*))?$', raw)
                if match: configured = herdr._project_scalar(match.group(1) or '', 'home')
            home = paths.external_home(engine, name, configured)
            child = dict(home='', root='repo', state='state', worktrees='worktrees',
                         design='design.md', tasks='tasks', conventions='CONVENTIONS.md')[key]
            return str(home / child)
        if key == 'projection':
            return entry.get(key, 'comments' if entry.get('repo') == '.' else 'local')
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
            if entry.get('repo') == '.':
                try: rc = herdr.project_field(config, key)
                except ValueError as error:
                    refuse(name, 'project', str(error).replace('config.yaml ', ''))
            else:
                private = Path(field(projects, name, 'state', config)) / 'config.yaml'
                if private.is_file():
                    rc = herdr.project_field(private, key)
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


def main():
    command = sys.argv.pop(1)
    commands = {
        'registry': registry,
    }
    commands[command]()


if __name__ == "__main__":
    main()
