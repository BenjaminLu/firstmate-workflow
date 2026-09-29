#!/usr/bin/env bash
# The OS half of a crew round's permission policy (T-105, T-117). An adapter
# turns the policy into its CLI's own flags; this turns the same policy into
# an OS sandbox and runs the CLI inside it, so what a round may do does not
# rest on one vendor's flags meaning what they say.
#
#   fm-sandbox.sh os      -> darwin or linux when this host has a sandbox, else nothing
#   fm-sandbox.sh covers  --policy=<file>
#       -> the policy dimensions the sandbox enforces here, one line; nothing
#          when there is no sandbox to run
#   fm-sandbox.sh profile --policy=<file> --root=<dir> [--tmp=<dir>] [--write=<dir>]... [--vendor=<name>]
#                         [--proxy-port=<n>] [--listening=<port,...>|unknown]
#       -> macOS: the sandbox-exec profile; Linux: the bwrap arguments, one per line
#   fm-sandbox.sh decide  --policy=<file> [--vendor=<name>] <host>
#       -> allow or deny, and why: the rule the round's proxy applies
#   fm-sandbox.sh login-source --policy=<file> --vendor=<name>
#       -> one line on stdout, `tier=<primary|fallback> source=<source>`: the
#          tier is `fallback` only when a vendor's `fallback` login tier
#          answered because every source of its primary one was missing
#          (T-126: claude's own crew token vs. the operator's interactive
#          login); the source is where the login would come from
#          (keychain:<service>, secret:<service>, file:<path>, env:<name>,
#          auth:<path>), never the login itself. exit 77 when the operator
#          is not logged in to it, or a login that exists fails to read
#   fm-sandbox.sh run     --policy=<file> --root=<dir> [--tmp=<dir>] [--write=<dir>]... [--vendor=<name>]
#                         [--blocked=<file>] [--started=<file>] [--ctl=<dir>] -- <command> [args...]
#   fm-sandbox.sh plain   --policy=<file> [--tmp=<dir>] [--vendor=<name>] [--started=<file>] [--ctl=<dir>]
#                         -- <command> [args...]
#       -> the environment scrub, the ulimits and the vendor's login only:
#          the operator's escape hatch, FM_CREW_UNSANDBOXED (design 13.1)
#
# --tmp is the round's own temp directory, its TMPDIR and a write root;
# `run` makes one when none is given. The caller's TMPDIR is never a root:
# every round and every run-mode review checkout shares it. HOME,
# XDG_CACHE_HOME, XDG_CONFIG_HOME and XDG_DATA_HOME are set under it too
# (T-128), so ordinary code - mktemp, ~/.cache, a toolchain's XDG defaults -
# takes its ordinary path rather than falling back into one nothing tests.
#
# --ctl is where `run` keeps its own files - the profile, the proxy's port
# or socket, the vendor's login - out of the round's reach but for the
# login: an adapter passes the control directory it made beside the round's
# temp directory. Without it, the caller's TMPDIR. A directory that would
# fall inside a write root refuses the round.
#
# --started names a file that holds "started" once the sandbox is up and
# the command is about to be exec'd, written from inside it. It is emptied
# right after the options, before anything can fail. Without that
# line, the exit code is this script's or the sandbox binary's, not the
# command's: the adapter counts the vendor unavailable rather than calling
# a round that never ran a failed attempt.
#
# The dimensions are the policy's: write, read, network, sockets, env,
# repo-config, refuse, ulimit. Before a round, the adapter asks `covers` and
# adds what its own flags enforce; a dimension neither covers refuses the
# round, and the fallback chain moves on. Nothing here degrades to running
# the command unconfined: `run` without a sandbox exits 69. `plain` is
# unconfined by design and is reached only through the operator's hatch.
#
# macOS runs sandbox-exec with a generated profile: reads denied by default
# but for the write roots, the toolchain and the vendor's own auth; writes
# only to the write roots and the vendor's own session state and temp
# directory; no network but the round's own proxy, which is how a named
# registry can be allowed at all (a profile names addresses, not hosts), and
# which records every host it refuses to --blocked so the round can report
# it; loopback only on ports the round opens itself - never the board's
# (FM_PORT, 4173) nor one that was listening when the round started, which
# `run` tries behind the profile before the round and tightens to the proxy
# alone when the kernel lets one through (design 13.1);
# LaunchServices refused, so no browser opens; and no mach service that
# hands out a secret (the keychain, the pasteboard, the account stores),
# which no file rule can cover. Linux runs bwrap, which mounts only what the
# policy lets the round read and gives it a /tmp and a network namespace of
# its own: loopback there is the round's alone, and the one way out is the
# same proxy, over a unix socket bound into the namespace. So both
# platforms cover every dimension, and on both the proxy is what names a
# refused host.
#
# The vendor's login (T-117). Where the operator's login is kept out of the
# round's reach - claude's lives in the macOS keychain, with gh's token and
# git's - it is read here, outside the sandbox, from exactly the items and
# files the policy names for that vendor (vendors.<name>.login), and handed
# in as a variable: claude's access token as CLAUDE_CODE_OAUTH_TOKEN, and
# cursor-agent's API key, which the operator keeps for the crew in an item
# or file of fm's own, as CURSOR_API_KEY. cursor-agent reads `agent login`'s
# token through the keychain API, which nothing inside a round can answer
# without the keychain itself. Where the login is a file (codex, gemini),
# no round reads it in place: fm writes a copy with its refresh token
# emptied into the round's own temp directory, where the adapter points the
# CLI. Only an access token or an API key is handed in, never a refresh
# token. A vendor whose login is not there refuses the round with 77 before
# the sandbox starts, which the adapter counts as unavailable.
#
# Off macOS a crew token names no keychain, so a `secret` item is tried
# instead (T-126 round 2): libsecret through secret-tool(1), the same shape
# as the keychain - service and account, never a search - read only when
# the tool is on the operator's PATH; absent, it is skipped, not refused,
# and the file tier is tried next.
#
# What neither can name: a connection that ignores the proxy variables is
# refused by the OS, which sees an address or nothing at all, not a host.
#
# FM_SANDBOX_OS and FM_SANDBOX_TOOL name the platform and the sandbox binary,
# FM_KEYCHAIN_TOOL the security(1) that reads the operator's keychain,
# FM_SECRET_TOOL the secret-tool(1) that reads a libsecret item (T-126,
# Linux's rough equivalent of the keychain) for the suite, which cannot run
# a real one on every runner; when it is unset, secret-tool is looked up on
# PATH.
#
# Flags are --name=value: this script takes no `shift 2`.
set -uo pipefail
# Standard input is the round's prompt. It is kept on fd 3 for the one
# command that is handed it; nothing else here reads it.
exec 3<&0
exec < /dev/null

say() { printf 'fm-sandbox: %s\n' "$*" >&2; }

# fm_herdr_emit_status, best-effort only: fm-sandbox.sh runs standalone in
# every other mode, so a missing or unreadable fm-config.sh degrades the
# board warning below, not the round.
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
# shellcheck source=bin/fm-config.sh
[ -r "$_fm_lib" ] && . "$_fm_lib"

# A login fallback (T-126) is worth a line on the board, not only in the
# round's log: `login`'s stderr already lands there through whichever
# adapter piped it in, but the crew is not meant to have to read a
# transcript to learn its round is one login refresh away from dying.
# fm-sandbox.sh runs outside the round, on the caller's own identity
# (fm_identity exports FM_ROOT, FM_TASK, FM_ACTOR and FM_ROLE before any
# adapter starts), so it can say so itself; best effort only, since
# fm-canary.sh's own probe rounds set none of these and are meant to stay
# off the board. The role is the run's own, never guessed: without FM_ROLE
# the warning is skipped, since fm_herdr_emit_status would default it to
# worker and a reviewer round would show on the board as a worker.
#
# Posted through fm_herdr_emit_status (bin/fm-config.sh), never a direct
# `fm-emit.sh --actor "$FM_ACTOR" --task ...` call here: tests/traps.test.sh
# boards a crewman for every script that emits under an actor of its own
# and has no `trap finished EXIT` to say when that actor leaves. This
# script is a helper an adapter's round calls many times over, never the
# one thing that owns a round's whole lifecycle - that is fm-worker.sh's
# and fm-review.sh's own `trap finished EXIT` - so it must not look like a
# lifecycle emitter to that sweep, the same reason fm_herdr_emit_status
# itself uses equals-form opts against fm-herdr.py rather than a bare
# `fm-emit.sh --actor` (see the comment there).
fm_sandbox_board_warn() {   # fm_sandbox_board_warn <vendor> <en>
  local vendor="$1" en="$2" root tw
  root="${FM_ROOT:-}"
  [ -n "$root" ] && [ -n "${FM_TASK:-}" ] && [ -n "${FM_ACTOR:-}" ] && [ -n "${FM_ROLE:-}" ] || return 0
  declare -F fm_herdr_emit_status >/dev/null 2>&1 || return 0
  tw="${vendor} 沒有自己的 crew token，改用操作者本人的互動式登入；該登入刷新時，本回合可能因此中斷"
  fm_herdr_emit_status "$root" "$FM_ACTOR" "$FM_TASK" "$en" "$tw" "$FM_ROLE" >/dev/null 2>&1 </dev/null || true
}

host_os() {
  local os="${FM_SANDBOX_OS:-}"
  [ -n "$os" ] || os="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  case "$os" in darwin|linux) printf '%s\n' "$os" ;; esac
}
# the sandbox binary, or nothing when this host cannot run one
host_tool() {
  local os tool
  os="$(host_os)"; [ -n "$os" ] || return 0
  tool="${FM_SANDBOX_TOOL:-}"
  if [ -z "$tool" ]; then
    case "$os" in darwin) tool=sandbox-exec ;; linux) tool=bwrap ;; esac
  fi
  command -v python3 >/dev/null 2>&1 || return 0
  command -v "$tool" 2>/dev/null || true
}

# The policy's reading, the profiles, the login and the proxy, in one
# place, so the rule the proxy applies is the rule `decide` prints.
IFS= read -r -d '' SB_PY <<'PY'
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
    git_own = own_git(roots[0]) if roots else None
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
    for r in roots:
        a += ['--bind', r, r]
    # the tree's own link to git (T-128), read-only over the read-write bind
    # above: whatever else a round deletes, git run in this tree still works
    git_own = own_git(roots[0]) if roots else None
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
# quiet step down to a weaker login.
FOUND, MISSING, FAILED = 'found', 'missing', 'failed'


def read_timeout():
    """Seconds one keychain or secret-tool read may take; the suite shortens
    it to prove a hung read refuses the round."""
    try:
        return max(1, int(os.environ.get('FM_LOGIN_READ_TIMEOUT') or 30))
    except ValueError:
        return 30


def tool_read(what, argv, missing, slow=''):
    """-> (outcome, value or why). <missing>(returncode, stderr) says whether
    a non-zero exit is the tool's own "no such item"; a tool that is not
    installed at all has no item either. Every read is time-bounded."""
    try:
        got = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                             timeout=read_timeout())
    except subprocess.TimeoutExpired:
        return FAILED, 'reading %s timed out%s' % (what, slow)
    except FileNotFoundError:
        return MISSING, None
    except OSError as e:
        return FAILED, '%s could not be read (%s)' % (what, e.strerror or e)
    if got.returncode != 0:
        if missing(got.returncode, got.stderr or ''):
            return MISSING, None
        err = (got.stderr or '').strip().splitlines()
        return FAILED, '%s could not be read (exit %d%s)' % (what, got.returncode,
                                                           ': ' + err[-1] if err else '')
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
    and says nothing; an error (no D-Bus session, a locked collection) exits
    1 too but says why on stderr, and is a failed read. secret-tool not
    installed is no item. Unless FM_SECRET_TOOL names one, it is looked up
    on the operator's PATH - this process's, before the round's is scrubbed."""
    tool = os.environ.get('FM_SECRET_TOOL') or shutil.which('secret-tool') or ''
    if not tool:
        return MISSING, None
    return tool_read("the secret-tool item '%s'" % service,
                     [tool, 'lookup', 'service', service, 'account', account],
                     lambda rc, err: rc == 1 and not err.strip())


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
    to a weaker login (T-126 round 7)."""
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
    found = None
    for what, source, item, read in sources:
        tried.append(what)
        outcome, value = read()
        if outcome == FAILED:
            return None, value, None, False
        if outcome == FOUND:
            found = (source, value, item)
            break
    if not found:
        why = 'no %s' % ' and no '.join(tried or ['login named'])
        return None, why + ('; ' + spec['hint'] if spec.get('hint') else ''), None, True
    source, value, item = found
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
    for name in spec.get('given', []):
        if os.environ.get(name):
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
    (T-126). Exit 77 when the operator is not logged in to <vendor>."""
    spec = p['vendors'].get(vendor, {}).get('login') or {}
    if not spec:
        return
    source, token, _, warn = login_of(p, vendor, os_)
    if source is None:
        print('fm-sandbox: %s is not logged in: %s' % (vendor, token), file=sys.stderr)
        sys.exit(77)
    if token is None:
        return
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
PY

# Inside bwrap's network namespace, the first thing that runs: it serves
# the round's loopback as the proxy the round's commands are pointed at,
# relays each connection to the real proxy's socket outside, then becomes
# the round's command. The server is a child that leaves when the command
# does, and holds none of the command's descriptors open.
#   python3 -c "$FWD_PY" <socket> <command> [args...]
IFS= read -r -d '' FWD_PY <<'PY'
import os, select, socket, sys, threading

sock_path, cmd = sys.argv[1], sys.argv[2:]
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.bind(('127.0.0.1', 0))
server.listen(64)
url = 'http://127.0.0.1:%d' % server.getsockname()[1]
for name in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'):
    os.environ[name] = url
parent = os.getpid()
if os.fork() == 0:
    null = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(null, fd)
    for fd in range(3, 1024):
        if fd != server.fileno():
            try:
                os.close(fd)
            except OSError:
                pass

    def relay(client):
        try:
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            upstream.connect(sock_path)
            while True:
                ready, _, _ = select.select([client, upstream], [], [], 600)
                if not ready:
                    return
                for s in ready:
                    data = s.recv(65536)
                    if not data:
                        return
                    (upstream if s is client else client).sendall(data)
        except OSError:
            pass
        finally:
            client.close()

    server.settimeout(1)
    while os.getppid() == parent:
        try:
            client, _ = server.accept()
        except socket.timeout:
            continue
        client.settimeout(None)
        threading.Thread(target=relay, args=(client,), daemon=True).start()
    os._exit(0)
server.close()
os.execvp(cmd[0], cmd)
PY

# The last thing before the round's command, inside the sandbox: it says on
# fd 4 that the sandbox started and got this far, so a failure before this
# line - the proxy, the profile, the sandbox binary itself - is told apart
# from the command's own exit code.
# shellcheck disable=SC2016  # expanded by the inner shell
SHIM='printf "started\n" >&4; exec 4>&-; exec "$@"'

# Run behind the round's own profile before the round (macOS): it says
# `checked` once it is running there, then each of the ports it is given
# that it could connect to on loopback.
#   python3 -c "$LOOP_PY" fm-loopback-check <port>...
IFS= read -r -d '' LOOP_PY <<'PY'
import socket, sys
print('checked', flush=True)
for port in sys.argv[2:]:
    for family, address in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
        try:
            s = socket.socket(family, socket.SOCK_STREAM)
        except OSError:
            continue
        s.settimeout(2)
        try:
            s.connect((address, int(port)))
        except OSError:
            continue
        finally:
            s.close()
        print(port, flush=True)
        break
PY

# loopback_reached <port>...: the ports a command behind $work/profile could
# connect to, comma-separated; status 1 when the check never ran behind it
loopback_reached() {
  local got
  got="$("$tool" -f "$work/profile" "$(command -v python3)" -c "$LOOP_PY" fm-loopback-check "$@" 2>/dev/null)"
  [ "${got%%$'\n'*}" = checked ] || return 1
  printf '%s\n' "$got" | sed 1d | paste -sd, -
}

# --- the option loop: every flag is --name=value --------------------------
cmd="${1-}"; [ $# -gt 0 ] && shift
policy=''; root=''; vendor=''; blocked=''; port=''; tmp=''; listening=''; started=''; ctl=''
writes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --policy=*) policy="${1#*=}"; shift ;;
    --ctl=*) ctl="${1#*=}"; shift ;;
    --started=*) started="${1#*=}"; shift ;;
    --root=*) root="${1#*=}"; shift ;;
    --tmp=*) tmp="${1#*=}"; shift ;;
    --listening=*) listening="${1#*=}"; shift ;;
    --write=*) writes+=("${1#*=}"); shift ;;
    --vendor=*) vendor="${1#*=}"; shift ;;
    --blocked=*) blocked="${1#*=}"; shift ;;
    --proxy-port=*) port="${1#*=}"; shift ;;
    --) shift
        break ;;
    --*) say "unknown argument $1"; exit 64 ;;
    *) break ;;
  esac
done
# --started is emptied before anything else can fail: a line left from an
# earlier round would say this one got as far as its command when it did not
if [ -n "$started" ]; then
  : > "$started" || { say "cannot write $started"; exit 70; }
fi
required() { [ -n "$2" ] || { say "$cmd needs --$1=<value>"; exit 64; }; }

# the dimensions the sandbox covers on this host for this policy
covers() {
  [ -n "$(host_tool)" ] || return 0
  # both: the network is the round's proxy and nothing else, so git push, gh
  # and a browser reach nothing; Herdr's and every other unix socket are
  # outside what the round may reach
  case "$(host_os)" in darwin|linux) echo "write read network sockets env repo-config refuse ulimit" ;; esac
}

case "$cmd" in
  os)
    [ -z "$(host_tool)" ] || host_os
    exit 0 ;;
  covers)
    required policy "$policy"
    python3 -c "$SB_PY" hosts "$policy" >/dev/null || exit 65
    covers; exit 0 ;;
  decide)
    required policy "$policy"
    [ $# -eq 1 ] || { say "decide takes one host"; exit 64; }
    python3 -c "$SB_PY" decide "$policy" "$vendor" "$1"; exit $? ;;
  login-source)
    required policy "$policy"; required vendor "$vendor"
    python3 -c "$SB_PY" login-source "$policy" "$vendor" "$(host_os)"; exit $? ;;
  profile)
    required policy "$policy"; required root "$root"
    os="$(host_os)"; [ -n "$os" ] || { say "no sandbox profile for this platform"; exit 69; }
    python3 -c "$SB_PY" profile "$policy" "$os" "$root" "$tmp" "$vendor" "${port:-0}" "$listening" '' \
      ${writes[@]+"${writes[@]}"}
    exit $? ;;
  run|plain) ;;
  *) echo "usage: fm-sandbox.sh os|covers|profile|decide|login-source|run|plain --policy=<file> ..." >&2; exit 64 ;;
esac

required policy "$policy"
[ $# -gt 0 ] || { say "$cmd needs a command after --"; exit 64; }
os="$(host_os)"
if [ "$cmd" = run ]; then
  required root "$root"
  tool="$(host_tool)"
  [ -n "$tool" ] || { say "no OS sandbox on this host; refusing to run the round unconfined"; exit 69; }
  root="$(cd "$root" 2>/dev/null && pwd -P)" || { say "no directory at $root"; exit 64; }
fi

# the environment scrub: named credentials and whole families of them. And
# one mark the round cannot lose: FM_IN_ROUND, which is how fm-worker.sh
# and fm-review.sh started inside a round refuse the operator's hatch.
scrub=(env)
while IFS= read -r v; do
  [ -n "$v" ] && scrub+=(-u "$v")
done < <(python3 -c "$SB_PY" scrub "$policy") || exit 65
read -r procs cpu < <(python3 -c "$SB_PY" limits "$policy") || exit 65
scrub+=(FM_IN_ROUND=1)

work=''; proxy_pid=''
cleanup() {
  [ -z "$proxy_pid" ] || kill "$proxy_pid" 2>/dev/null
  [ -z "$work" ] || rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# fm-sandbox's own files - the proxy's port or socket, the profile, the
# vendor's login - are not the round's. They go under --ctl, which an
# adapter makes beside the round's temp directory and outside every write
# root; without one, under the caller's TMPDIR. Never a fixed /tmp: a
# confined caller - a run-mode reviewer, a worker running the suites - may
# not write there. Whichever it is, a directory inside a root the round may
# write is refused.
make_work() {
  local parent="${ctl:-${TMPDIR:-/tmp}}" w
  work="$(mktemp -d "${parent%/}/fm-sb.XXXXXX")" || {
    say "cannot make the sandbox's own directory under $parent"; exit 70; }
  work="$(cd "$work" && pwd -P)"
  for w in "$root" "$tmp" ${writes[@]+"${writes[@]}"}; do
    [ -n "$w" ] && w="$(cd "$w" 2>/dev/null && pwd -P)" || continue
    case "$work/" in "${w%/}"/*)
      say "the sandbox's own directory $work is inside $w, which the round may write; pass --ctl=<dir> outside it"
      exit 70 ;;
    esac
  done
}

launcher=(); inner=(); secret_env=()
if [ "$cmd" = run ] || [ -n "$vendor" ]; then make_work; fi
# The vendor's login, read here, outside the round, from exactly what the
# policy names for it. Not logged in refuses the round (77) before the
# sandbox starts, so the adapter counts the vendor unavailable.
if [ -n "$vendor" ]; then
  # a login file's copy goes in the round's own temp directory, so the
  # round has one before the login is read
  if [ -z "$tmp" ]; then tmp="$work/tmp"; mkdir -p "$tmp" || exit 70; fi
  python3 -c "$SB_PY" login "$policy" "$vendor" "${os:-none}" "$work/login" "$tmp" || exit $?
  if [ -s "$work/login/warn" ]; then
    warn_text="$(cat "$work/login/warn")"; rm -f "$work/login/warn"
    say "$warn_text"
    fm_sandbox_board_warn "$vendor" "$warn_text"
  fi
  if [ -s "$work/login/env" ]; then
    # exported, not put on a command line, where ps would show it
    while IFS='=' read -r n v; do
      [ -n "$n" ] && secret_env+=("$n=$v")
    done < "$work/login/env"
    rm -f "$work/login/env"
  fi
fi
if [ "$cmd" = run ]; then
  # The proxy runs outside the sandbox and is the round's only way out: the
  # declared registries, the vendor's own service, and nothing else. Every
  # host it refuses is written to --blocked, which is how a round names the
  # host it was stopped at. On macOS it listens on loopback, the one port
  # the profile lets the round reach; on Linux on a unix socket bound into
  # the round's own network namespace.
  sock=''; [ "$os" = darwin ] || sock="$work/proxy.sock"
  # AF_UNIX paths stop at 108 bytes on Linux
  [ "${#sock}" -le 100 ] || {
    say "the proxy's socket path $sock is too long for AF_UNIX; pass a shorter --ctl"; exit 70; }
  # nothing of the caller's is held open by it: a proxy left behind by a
  # killed round must not keep the adapter's transcript pipe from closing
  python3 -c "$SB_PY" proxy "$policy" "$vendor" "$work/port" "${blocked:-}" "$sock" >/dev/null 2>&1 3<&- &
  proxy_pid=$!
  i=0
  while [ ! -s "$work/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  port="$(cat "$work/port" 2>/dev/null)"
  case "$port" in ''|*[!0-9]*) say "the round's proxy did not start"; exit 70 ;; esac
  # loopback goes straight to the port, where the profile (macOS) or the
  # namespace (Linux) decides: the round's own servers yes, the board and
  # older listeners no
  loop='localhost,127.0.0.1,::1'
  scrub+=(NO_PROXY="$loop" no_proxy="$loop" NODE_USE_ENV_PROXY=1)
  if [ "$os" = darwin ]; then
    url="http://127.0.0.1:$port"
    scrub+=(HTTP_PROXY="$url" HTTPS_PROXY="$url" http_proxy="$url" https_proxy="$url"
            ALL_PROXY="$url" all_proxy="$url")
    # the keychain is out of reach, so TLS roots come from the system's file
    # for a tool that would have asked it for them
    [ -n "${SSL_CERT_FILE:-}" ] || [ ! -f /etc/ssl/cert.pem ] || scrub+=(SSL_CERT_FILE=/etc/ssl/cert.pem)
  else
    # FWD_PY sets the proxy variables to the port it serves in the namespace
    inner=("$(command -v python3)" -c "$FWD_PY" "$sock")
  fi
  # the round's temp directory is its own, never the caller's: that is
  # shared with every other round and holds run-mode review checkouts
  if [ -z "$tmp" ]; then tmp="$work/tmp"; mkdir -p "$tmp" || exit 70; fi
  # What was listening on loopback before the round: those ports stay out of
  # its reach, and anything it opens itself is its own. Unreadable, only the
  # proxy is reachable.
  if [ "$os" = darwin ]; then
    # macOS keeps netstat in /usr/sbin, which a caller's PATH may not hold
    ns="$(command -v netstat 2>/dev/null || echo /usr/sbin/netstat)"
    if listing="$("$ns" -an -p tcp 2>/dev/null)"; then
      listening="$(awk '$NF == "LISTEN" { n = split($4, a, "."); print a[n] }' <<< "$listing" \
        | grep -E '^[0-9]+$' | sort -un | paste -sd, -)"
    else
      listening=unknown
      say "cannot list loopback listeners; the round reaches no loopback port but its proxy"
    fi
  fi
  make_profile() {
    python3 -c "$SB_PY" profile "$policy" "$os" "$root" "$tmp" "$vendor" "$port" "$listening" "$sock" \
      ${writes[@]+"${writes[@]}"} > "$work/profile" || exit 65
  }
  make_profile
  # The profile's per-port loopback denials are a rule the kernel applies,
  # not one fm can read back, and the canary on 2026-09-26 found a round
  # reaching the board through them. So the profile is tried before the
  # round, on every port that was listening but the proxy's: a connection
  # the profile lets through means the round would get it too. Then the
  # round is given no loopback but its proxy - its own servers go with it,
  # which it says - and a profile that still lets one through refuses the
  # round. A check that could not run inside the profile tightens it too.
  check=()
  if [ "$os" = darwin ] && [ "$listening" != unknown ]; then
    IFS=, read -r -a listed_ports <<< "$listening"
    for n in ${listed_ports[@]+"${listed_ports[@]}"}; do [ "$n" = "$port" ] || check+=("$n"); done
    if [ "${#check[@]}" -gt 0 ]; then
      board="${FM_PORT:-4173}"
      if ! reached="$(loopback_reached "${check[@]}")"; then
        say "cannot try the profile's loopback denials on this host, so they are not relied on"
        listening=unknown; make_profile
      elif [ -n "$reached" ]; then
        say "the profile's loopback denials do not hold on this host: a round could reach port(s) $reached, which were listening before it (the board's is $board)"
        listening=unknown; make_profile
        if reached="$(loopback_reached "${check[@]}")" && [ -n "$reached" ]; then
          say "and even that profile lets a round reach port(s) $reached; refusing the round"
          exit 70
        fi
      fi
    fi
  fi
  # Which loopback profile the round got, always, in one line: the canary
  # prints it per vendor, so what a round could reach is never inferred
  # from what it did not say (2026-09-26).
  if [ "$os" = darwin ]; then
    if [ "$listening" = unknown ]; then
      say "loopback: the round's profile allows it no port but its proxy's ($port), its own servers' included"
    else
      say "loopback: the round's profile allows its proxy's port ($port) and ports it opens itself; tried behind it and closed to it: ${check[*]:-nothing else was listening}"
    fi
  fi
  if [ "$os" = darwin ]; then
    launcher=("$tool" -f "$work/profile")
  else
    launcher=("$tool")
    while IFS= read -r a; do launcher+=("$a"); done < "$work/profile"
  fi
fi

# The ulimits. The process limit counts every process the user owns, the
# operator's own session included, so the round is given room for `procs`
# more than are running now - a bare `procs` below that count would stop it
# forking at all - clamped to the hard limit rather than failing to set.
# Linux counts threads against it as well. A count that cannot be taken
# refuses the round: guessing low stops it forking, guessing high is no
# limit. The count is taken here, before bwrap's own pid namespace.
# macOS's own mktemp(1) ignores $TMPDIR for a bare call or -t: mkdtemp(3)
# there asks confstr(_CS_DARWIN_USER_TEMP_DIR) instead, a directory outside
# every root a round may write, so the real tool is refused there rather
# than creating under the round's own temp directory. Round 6 traced a
# review round's own destroyed checkout to this: a suite's fixture read
# that refusal's empty result as "no FM_ROOT given" and ran the whole gate
# against the real tree instead (bin/ci.sh and tests/ci.test.sh, this same
# task); an earlier round traced a worker's lost worktree to the same
# refusal laundered a different way, through a self-resolving cd
# (tests/lib.sh's safe_tmpdir). An explicit template is the one form that
# already worked, so a stand-in ahead of the real tool on the round's PATH
# only ever turns the two ignored forms into that one; anything it does not
# fully recognise - an explicit template, -p, or an unknown flag - it hands
# straight to the real /usr/bin/mktemp, unchanged. GNU's own mktemp, which
# Linux gets under bwrap, already honours TMPDIR: nothing is added to its
# PATH there.
if [ "$cmd" = run ] && [ "$os" = darwin ] && [ -n "$tmp" ]; then
  fmbin="$tmp/.fm-mktemp"
  mkdir -p "$fmbin" || { say "cannot make $fmbin"; exit 70; }
  cat > "$fmbin/mktemp" <<'MKTEMP'
#!/bin/sh
# A stand-in for macOS's own mktemp(1) on a round's PATH (bin/fm-sandbox.sh,
# T-123): see the comment where this is installed for why.
real=/usr/bin/mktemp
route=transform
want=0
for a in "$@"; do
  if [ "$want" = 1 ]; then want=0; continue; fi
  case "$a" in
    -d) ;;
    -t) want=1 ;;
    -q|-u) ;;
    *) route=passthrough ;;
  esac
done
if [ "$route" = passthrough ]; then
  exec "$real" "$@"
fi
dir=''
prefix=tmp
extra=''
want=0
for a in "$@"; do
  if [ "$want" = 1 ]; then prefix="$a"; want=0; continue; fi
  case "$a" in
    -d) dir=-d ;;
    -t) want=1 ;;
    -q|-u) extra="$extra $a" ;;
  esac
done
exec "$real" $dir $extra "${TMPDIR:-/tmp}/$prefix.XXXXXXXXXX"
MKTEMP
  chmod +x "$fmbin/mktemp" || { say "cannot make $fmbin/mktemp executable"; exit 70; }
  scrub+=(PATH="$fmbin:$PATH")
fi

# A normal environment (T-128). Bare `mktemp -d` and `mktemp -t` resolve
# under TMPDIR - via the stand-in above on macOS, directly on Linux; `~/.cache`,
# `npm`/`bun`/`pip` and every XDG-following tool resolve under HOME or
# XDG_CACHE_HOME/XDG_DATA_HOME - all inside the round's own temp directory, a
# write root, so ordinary code takes its ordinary path instead of an
# untested one. Set here, in the one place both `run` and `plain` pass
# through, so the guarantee holds whatever the caller or the operator's
# shell set them to - the same reasoning as FM_ROUND_CACHES in
# bin/adapters/_lib.sh, which points the toolchain's own caches here too.
#
# XDG_CONFIG_HOME is the one exception, left exactly as the caller had it
# (T-128 review round 4): a vendor's own config directory is already an
# existing, separate contract - CLAUDE_CONFIG_DIR, CODEX_HOME, gemini's own
# HOME - each pointed at the round's own directory by its adapter, not by a
# generic XDG variable here. cursor-agent has no config-directory variable
# of its own at all (its login is CURSOR_API_KEY); overriding XDG_CONFIG_HOME
# here would move it off wherever the caller's environment already put it,
# which tests/adapter-contract.test.sh's "cursor-agent is handed no
# XDG_CONFIG_HOME of fm's" asserts against directly. HOME still moves, so
# `~/.config` (the XDG default when XDG_CONFIG_HOME is unset) already moves
# with it for anything that falls back to that default.
if [ -n "$tmp" ]; then
  home="$tmp/home"
  mkdir -p "$home" "$tmp/cache/xdg" "$home/.config" "$home/.local/share" || exit 70
  scrub+=(TMPDIR="$tmp" TMP="$tmp" TEMP="$tmp" HOME="$home"
          XDG_CACHE_HOME="$tmp/cache/xdg" XDG_DATA_HOME="$home/.local/share")
fi
if [ "$(uname -s)" = Linux ]; then listed="$(ps -L -U "$(id -u)" -o lwp= 2>/dev/null)"
else listed="$(ps -U "$(id -u)" -o pid= 2>/dev/null)"; fi || listed=''
used="$(grep -c '[0-9]' <<< "$listed")"
# ps itself and this shell are two of them, so fewer is a count that failed
[ "$used" -ge 2 ] || {
  say "cannot count this user's processes (ps failed or saw none); refusing the round rather than setting a process limit that would stop it forking"
  exit 70; }
procs=$((used + procs))
# --started: the file the shim writes "started" to from inside the sandbox.
# It is outside every write root, so the round cannot write it itself.
shim=()
[ -z "$started" ] || shim=(/bin/sh -c "$SHIM" fm-round)
(
  hard="$(ulimit -Hu 2>/dev/null)"
  case "$hard" in ''|unlimited) ;; *) [ "$procs" -le "$hard" ] || procs="$hard" ;; esac
  hard="$(ulimit -Ht 2>/dev/null)"
  case "$hard" in ''|unlimited) ;; *) [ "$cpu" -le "$hard" ] || cpu="$hard" ;; esac
  ulimit -u "$procs" 2>/dev/null || { say "cannot set the process limit to $procs"; exit 70; }
  ulimit -t "$cpu" 2>/dev/null || { say "cannot set the CPU limit to $cpu seconds"; exit 70; }
  # The limits as set, for the round to read: macOS may enforce a lower
  # process limit than it was given (kern.maxprocperuid) and reports that
  # one back, so `ulimit -u` inside says what the kernel did, not fm.
  scrub+=(SANDBOX_ROUND_LIMITS="procs=$procs cpu=$cpu")
  for kv in ${secret_env[@]+"${secret_env[@]}"}; do export "${kv?}"; done
  [ -z "$started" ] || exec 4>>"$started"
  exec ${launcher[@]+"${launcher[@]}"} ${inner[@]+"${inner[@]}"} "${scrub[@]}" ${shim[@]+"${shim[@]}"} "$@" <&3
)
exit $?
