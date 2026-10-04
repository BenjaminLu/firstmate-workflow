# Frozen SB_PY from f2dccb400a464ec7df336b6b265f0086976b44cb.
# Reference only: do not update to match the implementation.
import json, os, re, select, shutil, socket, subprocess, sys, threading, time

GITHUB = ('github.com', 'github.io', 'github.dev', 'githubusercontent.com', 'githubassets.com',
          'githubapp.com', 'githubcopilot.com', 'ghcr.io', 'ghe.com')
# The macOS services that hand out a secret to whoever asks as the user:
# the keychain (gh's token, git's osxkeychain helper, every saved password,
# and the vendors' own logins - which fm reads outside the round and hands
# in, T-117), the pasteboard, the Internet Accounts and Apple ID stores,
# Kerberos tickets, and Touch ID prompts. The profile starts from (allow
# default), so each one is named; the rest of what is left open hands out
# no credential. A name beginning with ^ is a regex.
SECRET_SERVICES = ('com.apple.SecurityServer', r'^com\.apple\.securityd', r'^com\.apple\.secd',
                   'com.apple.security.agent', 'com.apple.security.authhost',
                   'com.apple.pasteboard.1', r'^com\.apple\.accountsd', r'^com\.apple\.ak\.',
                   'com.apple.GSSCred', 'org.h5l.kcm', 'com.apple.CoreAuthentication.daemon')


def load(path):
    try:
        with open(path) as f:
            p = json.load(f)
    except (OSError, ValueError) as error:
        sys.exit('fm-sandbox: cannot read the policy at %s: %s' % (path, error))
    for key in ('dimensions', 'write', 'read', 'never_read', 'network', 'env_scrub',
                'repo_config', 'procs', 'cpu', 'vendors'):
        if key not in p:
            sys.exit('fm-sandbox: the policy at %s has no %s' % (path, key))
    return p


def never(host):
    """GitHub and loopback, whatever the policy says: a hand-edited policy
    cannot reach them either."""
    h = host.lower().rstrip('.')
    if not re.match(r'[a-z0-9.:-]+$', h):
        return 'not a plain domain name'
    if h == 'localhost' or h.endswith('.localhost'):
        return 'loopback'
    if re.match(r'[0-9.]+$', h) or ':' in h:
        return 'an address'
    for d in GITHUB:
        if h == d or h.endswith('.' + d):
            return 'GitHub'
    return None


def decide(p, vendor, host):
    h = host.lower().rstrip('.')
    why = never(h)
    if why:
        return False, 'never: ' + why
    # the captain's known refusals (T-147), whatever a hand-edited network
    # or a vendor's own domains say
    for k in p.get('known_refused', []):
        if re.fullmatch(k['pattern'], h):
            return False, 'known: ' + k['what']
    if h in [x.lower() for x in p['network']]:
        return True, 'a declared registry'
    for d in p['vendors'].get(vendor, {}).get('hosts', []):
        if h == d or h.endswith('.' + d):
            return True, "the %s CLI's own service" % vendor
    return False, 'undeclared'


def sbpl(path):
    if any(c in path for c in '"\\\n'):
        sys.exit('fm-sandbox: %s cannot be written into a sandbox profile' % path)
    return '"%s"' % path


def real(path):
    return os.path.realpath(os.path.expanduser(path))


def gitdirs(root):
    """A worktree's .git is a file naming its git directory elsewhere; git
    run in the worktree has to read that directory and the common one."""
    dot = os.path.join(root, '.git')
    if not os.path.isfile(dot):
        return []
    try:
        line = open(dot).read().strip()
    except OSError:
        return []
    if not line.startswith('gitdir:'):
        return []
    gitdir = os.path.join(root, line[len('gitdir:'):].strip())
    out = [real(gitdir)]
    try:
        common = open(os.path.join(gitdir, 'commondir')).read().strip()
        out.append(real(os.path.join(gitdir, common)))
    except OSError:
        pass
    return out


def own_git(root):
    """The tree's own .git link file, a worktree's pointer to its git
    directory elsewhere, if it has one yet. Never the common .git or gitdir
    another worktree shares (gitdirs, above): this is the one entry inside
    the write root itself that write access must not reach (T-128), because
    it is the only thing standing between a deleted tree and one `git` in it
    can still read: gitdirs() keeps the object database and the admin dir
    readable, and this keeps this one path unwritable so nothing here can
    sever the link between them.

    Never a clone's own .git - there it is a whole directory holding the
    object database and the index, not a pointer elsewhere, and it must stay
    writable for ordinary git commands (checkout, add, commit) to work at
    all. A clone is a review checkout, disposable by design (T-128 review
    round 4): fm-review.sh retries a wrecked one with a fresh checkout
    instead of relying on write denial to protect it."""
    dot = os.path.join(root, '.git')
    return dot if os.path.isfile(dot) else None


def roots_of(p, root, tmp, extra):
    out = []
    for w in p['write']:
        if '{tmp}' in w and not tmp:
            continue
        w = w.replace('{root}', root).replace('{tmp}', tmp)
        out.append(real(w))
    out += [real(x) for x in extra]
    seen = []
    for r in out:
        if r not in seen:
            seen.append(r)
    return seen


def prefix(path):
    """A path and everything that begins with it: a directory's subtree, and
    the siblings a file is rewritten through (x.json.tmp.123, x.json.lock)."""
    sbpl(path)
    return '(regex #"^%s")' % re.sub(r'([.^$|?*+()\[\]{}])', r'\\\1', path)


def own_git_sbpl(path):
    """own_git's own path, exactly - never prefix(): that matches any sibling
    that merely starts with the same characters, and '.git' is a prefix of
    '.gitignore', '.gitattributes', '.gitmodules' and every name under
    '.github/' (T-128 review round 1). own_git only ever returns a
    worktree's link file, never a clone's whole .git directory, so a literal
    is always exact here."""
    return '(literal %s)' % sbpl(path)


def pinned_of():
    path = os.environ.get('FM_PINNED_DIR', '')
    if not path:
        return None
    if not os.path.isabs(path) or real(path) != path or os.path.basename(path) != 'pinned':
        raise ValueError('invalid pinned folder path')
    if not os.path.isdir(path):
        raise ValueError('missing pinned folder')
    info = os.stat(path)
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError('pinned folder must have current-user ownership and no group/other writes')
    names = set(os.listdir(path))
    # fm_prompt_context.materialize requires spec; legacy rounds may omit
    # any of the other three snapshots. Nothing else belongs in this grant.
    if 'spec.json' not in names or not names <= {'spec.json', 'design.md', 'contract.yaml', 'CONVENTIONS.md'}:
        raise ValueError('invalid pinned folder contents')
    for name in names:
        file = os.path.join(path, name)
        if os.path.islink(file) or not os.path.isfile(file) or os.stat(file).st_mode & 0o7777 != 0o444:
            raise ValueError('pinned file must be regular and mode 0444')
    run = os.environ.get('FM_RUN_DIR')
    if run and path != os.path.join(real(run), 'pinned'):
        raise ValueError('pinned folder does not belong to this round')
    return path


def pinned_state(path):
    # runs/<actor>/pinned; only the selected child is ever exposed.
    state = os.path.dirname(os.path.dirname(os.path.dirname(path)))
    return os.path.dirname(state) if os.environ.get('FM_EXTERNAL') == '1' else state


def darwin(p, roots, reads, own, port, listening):
    sub = lambda paths: ' '.join('(subpath %s)' % sbpl(x) for x in paths)
    auth, state, vtmp = own.get('auth', []), own.get('state', []), own.get('tmp', [])
    board = int(os.environ.get('FM_PORT') or 4173)
    lines = ['(version 1)', '(allow default)',
             ';; network: this round\'s own proxy, and loopback ports the round opens itself',
             '(deny network*)']
    # None: the listeners could not be read, so no loopback port is known to
    # be free of someone else's, and only the proxy is reachable
    if listening is not None:
        lines += ['(allow network-bind (local ip "localhost:*"))',
                  '(allow network-inbound (local ip "localhost:*"))',
                  '(allow network-outbound (remote ip "localhost:*"))',
                  ';; never the board, nor anything that was listening before the round started']
        for n in sorted(set([board] + listening)):
            lines.append('(deny network-outbound (remote ip "localhost:%d"))' % n)
    # The board's port, and every port listening when the round started, is
    # never bound or accepted on (T-153: a suite's fixture board took
    # 127.0.0.1:4173 while the captain's board was down). It follows the
    # allow above, which it carves out of, and is written whether or not the
    # listeners could be read, so no profile lacks the board's; with no
    # allow above it repeats what (deny network*) already says.
    lines.append(';; never bound or accepted on: the board, nor anything listening before the round started')
    for n in sorted(set([board] + (listening or []))):
        lines.append('(deny network-bind network-inbound (local ip "localhost:%d"))' % n)
    if port and int(port):
        lines.append('(allow network-outbound (remote ip "localhost:%d"))' % int(port))
    lines += [';; writes: the write roots only',
              '(deny file-write*)',
              '(allow file-write* %s (literal "/dev/null") (literal "/dev/zero") (regex #"^/dev/tty") '
              '(regex #"^/dev/fd/") (literal "/dev/dtracehelper"))' % sub(roots),
              ';; reads: denied but for the toolchain, the write roots and the vendor\'s own auth',
              '(deny file-read*)',
              '(allow file-read-metadata)',
              '(allow file-read* (literal "/") %s)' % sub(reads + roots),
              ]
    # A rule with no filter matches every path, so a list that is empty
    # writes no rule at all rather than an unconditional one.
    if p['never_read']:
        lines += [';; never readable, whatever else allows it',
                  '(deny file-read* file-write* %s)' % sub(p['never_read'])]
    pinned = pinned_of()
    if pinned:
        lines.append('(deny file-read* file-write* %s)' % sub([pinned_state(pinned)]))
    if auth:
        lines.append('(allow file-read* %s)' % ' '.join('(literal %s)' % sbpl(a) for a in auth))
    if state:
        lines += [';; the vendor\'s own session state, which its CLI writes as it runs',
                  '(allow file-read* file-write* %s)' % ' '.join(prefix(s) for s in state)]
    if vtmp:
        lines += [';; the directory the vendor\'s CLI keeps under /tmp whatever TMPDIR says',
                  '(allow file-read* file-write* %s)' % sub(vtmp)]
    lines += [';; the round\'s own roots, even under a never-readable directory',
              '(allow file-read* file-write* %s)' % sub(roots)]
    if pinned:
        lines += ['(allow file-read* %s)' % sub([pinned]),
                  '(deny file-write* %s)' % sub([pinned])]
    git_own = own_git(roots[0]) if roots else None
    if roots and p.get('review_git_readonly'):
        lines.append('(deny file-write* (subpath %s))' % sbpl(os.path.join(roots[0], '.git')))
    if git_own:
        lines += [';; the tree\'s own link to git (T-128) may not be deleted or rewritten from',
                  ';; inside it: whatever else a round deletes, git run in this tree still works',
                  '(deny file-write* %s)' % own_git_sbpl(git_own)]
    repo = [os.path.join(r, c) for r in roots[:1] for c in p['repo_config']]
    if repo:
        lines += [';; the repository\'s own agent configuration is not loaded',
                  '(deny file-read* file-write* %s)' % sub(repo)]
    lines += [';; no browser, no AppleScript: LaunchServices is out of reach',
              '(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd") '
              '(global-name "com.apple.coreservices.appleevents"))',
              ';; no secret a macOS service hands out: a file rule does not cover a credential',
              ';; served over mach, and gh and git keep their tokens in the keychain',
              '(deny mach-lookup %s)' % ' '.join(
                  '(global-name "%s")' % n if not n.startswith('^') else '(global-name-regex #"%s")' % n
                  for n in SECRET_SERVICES)]
    return '\n'.join(lines) + '\n'


def linux(p, roots, reads, own, sock):
    # /tmp is a fresh tmpfs of the round's own: what another round leaves
    # there is not in it, and a vendor's own directory under /tmp (own's
    # `tmp`) is made afresh in it. The network is a namespace of the
    # round's own: its loopback holds only what the round opens, so the
    # board and every host listener are out of reach, and its one way out
    # is the proxy's socket, bound in below and served on the round's
    # loopback by FWD_PY.
    a = ['--die-with-parent', '--new-session', '--unshare-pid', '--unshare-ipc', '--unshare-uts',
         '--unshare-net', '--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp']
    for r in reads:
        a += ['--ro-bind-try', r, r]
    for r in own.get('auth', []):
        a += ['--ro-bind-try', r, r]
    for r in own.get('state', []):
        a += ['--bind-try', r, r]
    pinned = pinned_of()
    if pinned:
        state = pinned_state(pinned)
        if any(state == r or state.startswith(r.rstrip('/') + '/') for r in reads):
            a += ['--tmpfs', state]
    for r in roots:
        a += ['--bind', r, r]
    # the tree's own link to git (T-128), read-only over the read-write bind
    # above: whatever else a round deletes, git run in this tree still works
    git_own = own_git(roots[0]) if roots else None
    if roots and p.get('review_git_readonly'):
        git_own = os.path.join(roots[0], '.git')
    if git_own:
        a += ['--ro-bind', git_own, git_own]
    bound = reads + roots
    under = lambda x: any(x == b or x.startswith(b.rstrip('/') + '/') for b in bound)
    hide = [n for n in p['never_read'] if under(n)]
    hide += [os.path.join(roots[0], c) for c in p['repo_config']]
    for n in hide:
        if os.path.isdir(n):
            a += ['--tmpfs', n]
        elif os.path.exists(n):
            a += ['--ro-bind', '/dev/null', n]
    if pinned:
        a += ['--ro-bind', pinned, pinned]
    if sock:
        a += ['--bind', sock, sock]
    a += ['--chdir', roots[0], '--']
    return '\n'.join(a) + '\n'


# --- the vendor's login (T-117) ---------------------------------------------
def dig(value, field):
    """<field> of a JSON value, dotted; a value that is not a JSON object is
    the token itself."""
    try:
        doc = json.loads(value)
    except ValueError:
        return value, None
    if not isinstance(doc, dict):
        return value, None
    out = doc
    for part in (field or '').split('.'):
        if not part:
            continue
        out = out.get(part) if isinstance(out, dict) else None
    return out, doc


def expiry(doc, field):
    if doc is None or not field:
        return None
    out = doc
    for part in field.split('.'):
        out = out.get(part) if isinstance(out, dict) else None
    return out if isinstance(out, (int, float)) else None


# A login read has three outcomes (T-126 round 7): found, missing, or
# failed. Only `missing` lets a caller try the next source, or a fallback
# tier: an item that exists but cannot be read refuses the round, never a
# quiet step down to a weaker login. A fourth, unreachable (T-126 round
# 10), is a store that cannot be asked at all - secret-tool with no D-Bus
# session, or a hung bus - which says nothing about whether the item is
# there: the lookup goes on to the tier's next source, but the tier is
# never absent, so it can never reach a fallback tier.
FOUND, MISSING, FAILED, UNREACHABLE = 'found', 'missing', 'failed', 'unreachable'
# what secret-tool says on stderr when the bus or the secret service itself
# cannot be reached, as opposed to an item or collection that failed
NO_BUS = re.compile(r'd-?bus|autolaunch|org\.freedesktop\.secrets', re.I)


def read_timeout():
    """Seconds one keychain or secret-tool read may take; the suite shortens
    it to prove a hung read refuses the round."""
    try:
        return max(1, int(os.environ.get('FM_LOGIN_READ_TIMEOUT') or 30))
    except ValueError:
        return 30


def tool_read(what, argv, missing, slow='', unreachable=None):
    """-> (outcome, value or why). <missing>(returncode, stderr) says whether
    a non-zero exit is the tool's own "no such item"; a tool that is not
    installed at all has no item either. <unreachable>(returncode, stderr),
    when given, says whether it is the store that could not be reached, and
    a timeout is then read the same way. Every read is time-bounded."""
    try:
        got = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                             timeout=read_timeout())
    except subprocess.TimeoutExpired:
        return (UNREACHABLE if unreachable else FAILED), 'reading %s timed out%s' % (what, slow)
    except FileNotFoundError:
        return MISSING, None
    except OSError as e:
        return FAILED, '%s could not be read (%s)' % (what, e.strerror or e)
    if got.returncode != 0:
        if missing(got.returncode, got.stderr or ''):
            return MISSING, None
        err = (got.stderr or '').strip().splitlines()
        said = ' (exit %d%s)' % (got.returncode, ': ' + err[-1] if err else '')
        if unreachable and unreachable(got.returncode, got.stderr or ''):
            return UNREACHABLE, '%s could not be reached%s' % (what, said)
        return FAILED, '%s could not be read%s' % (what, said)
    value = got.stdout.rstrip('\n')
    if not value:
        return FAILED, '%s is empty' % what
    return FOUND, value


def keychain_read(service, account):
    """One generic-password item, by service and account, from the
    operator's keychain: never a search, never another item. security(1)
    exits 44 when no such item exists; any other exit (36, "User interaction
    is not allowed"; a locked keychain) is an item that failed to read."""
    tool = os.environ.get('FM_KEYCHAIN_TOOL') or '/usr/bin/security'
    return tool_read("the keychain item '%s'" % service,
                     [tool, 'find-generic-password', '-s', service, '-a', account, '-w'],
                     lambda rc, _: rc == 44, '; macOS may be asking the operator to allow it')


def secret_read(service, account):
    """One libsecret item, by service and account, through secret-tool(1) -
    the keychain's rough equivalent off macOS (T-126 round 2). Never a
    search, never another item. secret-tool with no matching item exits 1
    and says nothing. One that says on stderr it cannot reach the bus or the
    secret service (no D-Bus session: headless, SSH, CI), or that times out
    on a hung bus, could not ask the store at all - unreachable, so the next
    crew source is tried (T-126 round 10). Any other error (a locked
    collection) exits 1 too but says why on stderr, and is a failed read.
    secret-tool not installed is no item. Unless FM_SECRET_TOOL names one,
    it is looked up on the operator's PATH - this process's, before the
    round's is scrubbed."""
    tool = os.environ.get('FM_SECRET_TOOL') or shutil.which('secret-tool') or ''
    if not tool:
        return MISSING, None
    return tool_read("the secret-tool item '%s'" % service,
                     [tool, 'lookup', 'service', service, 'account', account],
                     lambda rc, err: rc == 1 and not err.strip(),
                     unreachable=lambda rc, err: bool(NO_BUS.search(err)))


def file_read(path, private):
    """-> (outcome, value or why) for one login file. Only a file that is
    not there is missing; one that is there but cannot be read (a directory,
    mode 000, an I/O error), is empty, or is readable by others fails."""
    try:
        if private and os.stat(path).st_mode & 0o077:
            return FAILED, '%s can be read by others than the operator; chmod 600 it' % path
        with open(path) as f:
            value = f.read().strip()
    except FileNotFoundError:
        return MISSING, None
    except OSError as e:
        return FAILED, '%s could not be read (%s)' % (path, e.strerror or e)
    if not value:
        return FAILED, '%s is empty' % path
    return FOUND, value


def login_tier(vendor, spec, os_):
    """One tier of a vendor's login (a primary or `fallback` block) ->
    (source, token, item, absent). absent is True only when every source
    this tier names says its item is missing - no keychain item, no
    secret-tool item, no file - which is the one case a caller may try
    another tier for. Anything else (an item that exists but fails to read,
    a locked-down file, an expired or malformed token) is a specific refusal
    naming its source, nothing after it is read, and it is never downgraded
    to a weaker login (T-126 round 7). A store that cannot be reached is
    passed over for the tier's next source, with a line in the round's log
    when one answers, and a refusal naming it when none does - never absent
    (T-126 round 10)."""
    sources = []
    if os_ == 'darwin':
        for item in spec.get('keychain', []):
            sources.append(("keychain item '%s'" % item['service'], 'keychain:' + item['service'], item,
                            lambda i=item: keychain_read(i['service'], i['account'])))
    # libsecret, off macOS's own keychain (T-126 round 2): secret-tool not
    # installed is a missing item, not a refusal
    for item in spec.get('secret', []):
        sources.append(("secret-tool item '%s'" % item['service'], 'secret:' + item['service'], item,
                        lambda i=item: secret_read(i['service'], i['account'])))
    for path in spec.get('file', []):
        sources.append((path, 'file:' + path, None, lambda x=path: file_read(x, spec.get('private'))))
    tried = []
    unreached = []
    found = None
    for what, source, item, read in sources:
        tried.append(what)
        outcome, value = read()
        if outcome == FAILED:
            return None, value, None, False
        if outcome == UNREACHABLE:
            # the store could not be asked: the next source may answer,
            # but this tier is not absent (T-126 round 10)
            unreached.append(value)
            tried.pop()
            continue
        if outcome == FOUND:
            found = (source, value, item)
            break
    hint = '; ' + spec['hint'] if spec.get('hint') else ''
    if not found and unreached:
        return None, '%s, and no other source answered%s%s' % (
            '; '.join(unreached), ' (no %s)' % ' and no '.join(tried) if tried else '', hint), None, False
    if not found:
        why = 'no %s' % ' and no '.join(tried or ['login named'])
        return None, why + hint, None, True
    source, value, item = found
    for why in unreached:
        print('fm-sandbox: %s; using %s instead' % (why, source), file=sys.stderr)
    # `field` may name alternatives: codex's file holds an access token or
    # an API key
    fields = spec.get('field') or ''
    fields = fields if isinstance(fields, list) else [fields]
    token = doc = None
    for field in fields:
        token, doc = dig(value, field)
        if isinstance(token, str) and token:
            break
    if not isinstance(token, str) or not token:
        return None, '%s holds no %s' % (source, ' or '.join(f for f in fields if f) or 'token'), None, False
    ends = expiry(doc, spec.get('expires'))
    if ends is not None and ends < (time.time() + 60) * 1000:
        return None, '%s has expired; start %s once outside a round to refresh it' % (source, vendor), None, False
    if '\n' in token:
        return None, '%s is not one line' % source, None, False
    if source.startswith('file:') and spec.get('copy'):
        # the whole login file goes in, as a copy, less its refresh token
        return source, doc if doc is not None else value, item, False
    return source, token, item, False


def login_of(p, vendor, os_):
    """-> (source, token, item, warn) or (None, why, None, None). The
    operator's login for <vendor>, read here, outside the round. <warn> is
    a line to say, in the round's log and on the board, when a `fallback`
    tier answered because every source of the primary one was missing (T-126);
    never set when the primary tier was refused for a specific reason."""
    own = p['vendors'].get(vendor, {})
    spec = own.get('login') or {}
    if not spec:
        for a in own.get('auth', []):
            if os.path.isfile(a):
                return 'auth:' + a, None, None, None
        return None, 'no login file (%s)' % (', '.join(own.get('auth', [])) or 'none named'), None, None
    # A variable the round sheds (--shed, T-121) is no login of the round's:
    # counted as `given`, nothing would be read or handed in, and the
    # adapter's own `env -u` would then start the round with no credential.
    shed = set((os.environ.get('FM_SANDBOX_SHED') or '').split())
    for name in spec.get('given', []):
        if name not in shed and os.environ.get(name):
            return 'env:' + name, None, None, None
    source, token, item, absent = login_tier(vendor, spec, os_)
    fallback = spec.get('fallback')
    if source is None and absent and fallback:
        hint = spec.get('hint')
        suffix = ('; ' + hint) if hint else ''
        fsource, ftoken, fitem, _ = login_tier(vendor, fallback, os_)
        if fsource is not None:
            warn = ("%s has no crew token of its own; falling back to the operator's own interactive "
                    "login, which can be revoked when that login refreshes%s" % (vendor, suffix))
            return fsource, ftoken, fitem, warn
        # the fallback tier named something but refused it for its own,
        # specific reason (expired, malformed, locked-down) - that reason,
        # not the primary tier's generic "absent", is what the operator
        # needs to hear and act on. The primary tier's own hint (how to
        # make it a crew token in the first place) still belongs here: it
        # is the fix for every reason this branch is reached at all.
        return None, ftoken + suffix, None, None
    return source, token, item, None


REFRESH = re.compile(r'refresh_?token', re.I)


def without_refresh(doc, drop):
    """<doc> with every `drop` field emptied, or exit 65 if any field named
    like a refresh token still holds one: a vendor that moved its refresh
    token to a field the policy does not name is refused, not handed it."""
    for field in drop:
        parts = field.split('.')
        at = doc
        for part in parts[:-1]:
            at = at.get(part) if isinstance(at, dict) else None
        if isinstance(at, dict) and parts[-1] in at:
            at[parts[-1]] = ''

    def left(node, path):
        if isinstance(node, dict):
            for k, v in node.items():
                if REFRESH.search(k) and v:
                    return path + k
                found = left(v, path + k + '.')
                if found:
                    return found
        elif isinstance(node, list):
            for i, v in enumerate(node):
                found = left(v, '%s%d.' % (path, i))
                if found:
                    return found
        return None
    still = left(doc, '')
    if still:
        print('fm-sandbox: the login file still holds a refresh token (%s) the policy does not drop; '
              'refusing to hand it to the round' % still, file=sys.stderr)
        sys.exit(65)
    return doc


def login(p, vendor, os_, where, home):
    """Hand the vendor's login in: <where>/env holds NAME=VALUE for the
    launcher to export; a login file's copy, less its refresh token, goes to <home>/<copy>, in
    the round's own temp directory. <where>/warn holds a line to say, in
    the round's log and on the board, when a `fallback` tier answered
    (T-126). Exit 77 when the operator is not logged in to <vendor>.
    -> (source, warn): where the login came from, and the fallback line."""
    spec = p['vendors'].get(vendor, {}).get('login') or {}
    if not spec:
        return None, None
    source, token, _, warn = login_of(p, vendor, os_)
    if source is None:
        print('fm-sandbox: %s is not logged in: %s' % (vendor, token), file=sys.stderr)
        sys.exit(77)
    if token is None:
        return source, warn
    to = spec.get('to', '')
    os.makedirs(where, mode=0o700, exist_ok=True)
    if warn:
        fd = os.open(os.path.join(where, 'warn'), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(warn)
    if source.startswith('file:') and spec.get('copy'):
        rel = spec['copy']
        if not home or rel.startswith('/') or '..' in rel.split('/'):
            print("fm-sandbox: %s's login copy '%s' has no place in the round's temp directory"
                  % (vendor, rel), file=sys.stderr)
            sys.exit(65)
        doc = without_refresh(token, spec.get('drop', [])) if isinstance(token, dict) else token
        path = os.path.join(home, rel)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(json.dumps(doc) if isinstance(doc, dict) else doc)
    elif to.startswith('env:'):
        fd = os.open(os.path.join(where, 'env'), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write('%s=%s\n' % (to[len('env:'):], token))
    return source, warn


def proxy(p, vendor, portfile, blocked, sock):
    # macOS: a loopback port the profile lets the round reach. Linux: a unix
    # socket bound into the round's own network namespace.
    if sock:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(sock)
    else:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(('127.0.0.1', 0))
    server.listen(64)
    lock, seen = threading.Lock(), set()

    def refuse(client, host):
        with lock:
            if blocked and host not in seen:
                seen.add(host)
                with open(blocked, 'a') as f:
                    f.write(host + '\n')
        try:
            client.sendall(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
        finally:
            client.close()

    def relay(a, b):
        try:
            while True:
                ready, _, _ = select.select([a, b], [], [], 600)
                if not ready:
                    return
                for s in ready:
                    data = s.recv(65536)
                    if not data:
                        return
                    (b if s is a else a).sendall(data)
        finally:
            a.close(); b.close()

    def handle(client):
        try:
            data = b''
            while b'\r\n\r\n' not in data:
                chunk = client.recv(65536)
                if not chunk or len(data) > 65536:
                    client.close(); return
                data += chunk
            head, rest = data.split(b'\r\n\r\n', 1)
            first, _, headers = head.partition(b'\r\n')
            method, target, version = first.decode('latin-1').split(' ', 2)
            if method == 'CONNECT':
                host, _, port = target.rpartition(':')
                path = None
            else:
                found = re.match(r'http://([^/:]+)(?::(\d+))?(/.*)?$', target)
                if not found:
                    return refuse(client, target)
                host, port, path = found.group(1), found.group(2) or '80', found.group(3) or '/'
            host = host.strip('[]').lower()
            allowed, _ = decide(p, vendor, host)
            if not allowed:
                return refuse(client, host)
            upstream = socket.create_connection((host, int(port)), timeout=30)
            upstream.settimeout(None)
            if path is None:
                client.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
            else:
                upstream.sendall(('%s %s %s\r\n' % (method, path, version)).encode('latin-1')
                                 + headers + b'\r\n\r\n')
            if rest:
                upstream.sendall(rest)
            relay(client, upstream)
        except Exception:
            client.close()

    with open(portfile + '.tmp', 'w') as f:
        f.write('0' if sock else str(server.getsockname()[1]))
    os.rename(portfile + '.tmp', portfile)
    while True:
        client, _ = server.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


def main():
    mode, policy_path = sys.argv[1], sys.argv[2]
    p = load(policy_path)
    if mode == 'decide':
        allowed, why = decide(p, sys.argv[3], sys.argv[4])
        print('%s %s' % ('allow' if allowed else 'deny', why))
        sys.exit(0 if allowed else 1)
    if mode == 'hosts':
        print(' '.join(p['network']))
        return
    if mode == 'scrub':
        # the names to unset, from this environment
        names = set(p['env_scrub']['names'])
        for name in os.environ:
            if name in names or any(name.startswith(x) for x in p['env_scrub']['prefixes']):
                print(name)
        return
    if mode == 'limits':
        print('%d %d' % (p['procs'], p['cpu']))
        return
    if mode == 'proxy':
        proxy(p, sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
        return
    if mode == 'login-source':
        source, why, _, warn = login_of(p, sys.argv[3], sys.argv[4])
        if source is None:
            print('fm-sandbox: %s is not logged in: %s' % (sys.argv[3], why), file=sys.stderr)
            sys.exit(77)
        # one machine-readable line on stdout (T-126 round 7): the tier
        # that answered - 'fallback' only when a `fallback` block answered
        # because the primary one was missing - then the source,
        # last because it may hold spaces. Never the login itself; anything
        # else goes to stderr, so a caller such as fm-canary.sh reads this
        # line alone.
        print('tier=%s source=%s' % ('fallback' if warn else 'primary', source))
        return
    if mode == 'login':
        # login <vendor> <os> <dir> <round tmp>
        login(p, sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
        return
    if mode == 'login-env':
        # login-env <vendor> <os> <dir> <round tmp>: the round's own `login`,
        # and a `given` variable the round would inherit written beside
        # what `login` hands in, so <dir>/env is every credential the round
        # gets and nothing else (T-121's probe). The tier line as
        # login-source prints it; never the login itself.
        try:
            os.remove(os.path.join(sys.argv[5], 'env'))
        except FileNotFoundError:
            pass
        source, warn = login(p, sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
        if source and source.startswith('env:'):
            name = source[len('env:'):]
            os.makedirs(sys.argv[5], mode=0o700, exist_ok=True)
            fd = os.open(os.path.join(sys.argv[5], 'env'), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, 'w') as f:
                f.write('%s=%s\n' % (name, os.environ[name]))
        print('tier=%s source=%s' % ('fallback' if warn else 'primary', source or 'none'))
        return
    # profile <os> <root> <tmp> <vendor> <port> <listening> <socket> [write...]
    os_, root, tmp, vendor, port, listening, sock = sys.argv[3:10]
    roots = roots_of(p, real(root), real(tmp) if tmp else '', sys.argv[10:])
    reads = [r for r in p['read'] if r] + gitdirs(real(root))
    own = p['vendors'].get(vendor, {})
    if os_ == 'darwin':
        ports = None if listening == 'unknown' else [int(x) for x in listening.split(',') if x]
        sys.stdout.write(darwin(p, roots, reads, own, port, ports))
    else:
        sys.stdout.write(linux(p, roots, reads, own, sock))


main()
