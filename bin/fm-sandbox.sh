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
#                         [--proxy-port=<n>] [--listening=<port,...>|unknown] [--login=<dir>]
#       -> macOS: the sandbox-exec profile; Linux: the bwrap arguments, one per line
#   fm-sandbox.sh decide  --policy=<file> [--vendor=<name>] <host>
#       -> allow or deny, and why: the rule the round's proxy applies
#   fm-sandbox.sh login-source --policy=<file> --vendor=<name>
#       -> where the vendor's login would come from (keychain:<service>,
#          file:<path>, env:<name>, auth:<path>), never the login itself;
#          exit 77 when the operator is not logged in to it
#   fm-sandbox.sh run     --policy=<file> --root=<dir> [--tmp=<dir>] [--write=<dir>]... [--vendor=<name>]
#                         [--blocked=<file>] [--started=<file>] [--ctl=<dir>] -- <command> [args...]
#   fm-sandbox.sh plain   --policy=<file> [--tmp=<dir>] [--vendor=<name>] [--started=<file>] [--ctl=<dir>]
#                         -- <command> [args...]
#       -> the environment scrub, the ulimits and the vendor's login only:
#          the operator's escape hatch, FM_CREW_UNSANDBOXED (design 13.1)
#
# --tmp is the round's own temp directory, its TMPDIR and a write root;
# `run` makes one when none is given. The caller's TMPDIR is never a root:
# every round and every run-mode review checkout shares it.
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
# (FM_PORT, 4173) nor one that was listening when the round started;
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
# round's reach - claude's and cursor-agent's live in the macOS keychain,
# with gh's token and git's - it is read here, outside the sandbox, from
# exactly the items and files the policy names for that vendor
# (vendors.<name>.login), and handed in: as a variable (claude's
# CLAUDE_CODE_OAUTH_TOKEN), or served by a stand-in for security(1) first
# on the round's PATH that knows that one item and says every other is not
# there (cursor-agent). Only an access token is handed in, never a refresh
# token. A vendor whose login is not there refuses the round with 77 before
# the sandbox starts, which the adapter counts as unavailable.
#
# What neither can name: a connection that ignores the proxy variables is
# refused by the OS, which sees an address or nothing at all, not a host.
#
# FM_SANDBOX_OS and FM_SANDBOX_TOOL name the platform and the sandbox binary,
# FM_KEYCHAIN_TOOL the security(1) that reads the operator's keychain, for
# the suite, which cannot run a real one on every runner.
#
# Flags are --name=value: this script takes no `shift 2`.
set -uo pipefail
# Standard input is the round's prompt. It is kept on fd 3 for the one
# command that is handed it; nothing else here reads it.
exec 3<&0
exec < /dev/null

say() { printf 'fm-sandbox: %s\n' "$*" >&2; }

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
import json, os, re, select, socket, subprocess, sys, threading, time

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
# what security(1) says when an item is not there, and exits with
NOT_FOUND = 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.'


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


def darwin(p, roots, reads, own, port, listening, login):
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
    if login:
        lines += [';; the vendor\'s own login, read by fm outside the round, and nothing else of the keychain',
                  '(allow file-read* %s)' % sub([login])]
    lines += [';; the round\'s own roots, even under a never-readable directory',
              '(allow file-read* file-write* %s)' % sub(roots)]
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


def keychain_read(service, account):
    """One generic-password item, by service and account, from the
    operator's keychain: never a search, never another item."""
    tool = os.environ.get('FM_KEYCHAIN_TOOL') or '/usr/bin/security'
    try:
        got = subprocess.run([tool, 'find-generic-password', '-s', service, '-a', account, '-w'],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        print("fm-sandbox: reading the keychain item '%s' timed out; macOS may be asking the operator "
              "to allow it" % service, file=sys.stderr)
        return None
    except OSError:
        return None
    if got.returncode != 0:
        return None
    return got.stdout.rstrip('\n') or None


def login_of(p, vendor, os_):
    """-> (source, token, item) or (None, why, None). The operator's login
    for <vendor>, read here, outside the round."""
    own = p['vendors'].get(vendor, {})
    spec = own.get('login') or {}
    if not spec:
        for a in own.get('auth', []):
            if os.path.isfile(a):
                return 'auth:' + a, None, None
        return None, 'no login file (%s)' % (', '.join(own.get('auth', [])) or 'none named'), None
    for name in spec.get('given', []):
        if os.environ.get(name):
            return 'env:' + name, None, None
    tried = []
    found = []
    if os_ == 'darwin':
        for item in spec.get('keychain', []):
            tried.append("keychain item '%s'" % item['service'])
            value = keychain_read(item['service'], item['account'])
            if value:
                found.append(('keychain:' + item['service'], value, item))
                break
    if not found:
        for path in spec.get('file', []):
            tried.append(path)
            try:
                value = open(path).read().strip()
            except OSError:
                continue
            if value:
                found.append(('file:' + path, value, None))
                break
    if not found:
        return None, 'no %s' % ' and no '.join(tried or ['login named']), None
    source, value, item = found[0]
    token, doc = dig(value, spec.get('field'))
    if not isinstance(token, str) or not token:
        return None, '%s holds no %s' % (source, spec.get('field') or 'token'), None
    ends = expiry(doc, spec.get('expires'))
    if ends is not None and ends < (time.time() + 60) * 1000:
        return None, '%s has expired; start %s once outside a round to refresh it' % (source, vendor), None
    if '\n' in token:
        return None, '%s is not one line' % source, None
    return source, token, item


SHIM = r'''#!/bin/sh
# fm-sandbox's stand-in for security(1) in a crew round (T-117). The
# keychain is out of the round's reach; this serves the one login fm read
# for the round's own vendor, and says every other item is not there. What
# the round writes is never the operator's keychain: it is let go.
cmd="${1-}"; [ $# -gt 0 ] && shift
svc=''; acct=''; show=''
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc="${2-}"; [ $# -gt 1 ] && shift ;;
    -a) acct="${2-}"; [ $# -gt 1 ] && shift ;;
    -w) show=w ;;
    -g) show=g ;;
  esac
  shift
done
case "$cmd" in
  find-generic-password) ;;
  add-generic-password|delete-generic-password) exit 0 ;;
  *) echo "security: this crew round has no keychain" >&2; exit 1 ;;
esac
case "$svc|$acct" in
%(cases)s
  *) echo "%(not_found)s" >&2; exit 44 ;;
esac
if [ "$show" = w ]; then cat "$f"; echo; exit 0; fi
printf 'keychain: "fm-round"\nclass: "genp"\nattributes:\n    "acct"<blob>="%%s"\n    "svce"<blob>="%%s"\n' "$acct" "$svc"
if [ "$show" = g ]; then { printf 'password: "'; cat "$f"; printf '"\n'; } >&2; fi
exit 0
'''


def sh_quote(text):
    if "'" in text or '\n' in text:
        sys.exit("fm-sandbox: %r cannot be named in the round's keychain stand-in" % text)
    return "'%s'" % text


def login(p, vendor, os_, where, sandboxed):
    """Hand the vendor's login in: <where>/env holds NAME=VALUE for the
    launcher to export; <where>/bin/security serves a keychain item. Exit
    77 when the operator is not logged in to <vendor>."""
    spec = p['vendors'].get(vendor, {}).get('login') or {}
    if not spec:
        return
    source, token, item = login_of(p, vendor, os_)
    if source is None:
        print('fm-sandbox: %s is not logged in: %s' % (vendor, token), file=sys.stderr)
        sys.exit(77)
    if token is None:
        return
    to = spec.get('to', '')
    os.makedirs(where, mode=0o700, exist_ok=True)
    if to.startswith('env:'):
        fd = os.open(os.path.join(where, 'env'), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write('%s=%s\n' % (to[len('env:'):], token))
    elif to == 'keychain' and item and sandboxed:
        os.makedirs(os.path.join(where, 'bin'), mode=0o700, exist_ok=True)
        path = os.path.join(where, 'item-0')
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(token)
        key = sh_quote('%s|%s' % (item['service'], item['account']))
        bare = sh_quote('%s|' % item['service'])
        cases = "  %s|%s) f=%s ;;" % (key, bare, sh_quote(path))
        shim = os.path.join(where, 'bin', 'security')
        with open(shim, 'w') as f:
            f.write(SHIM % dict(cases=cases, not_found=NOT_FOUND))
        os.chmod(shim, 0o700)


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
        source, why, _ = login_of(p, sys.argv[3], sys.argv[4])
        if source is None:
            print('fm-sandbox: %s is not logged in: %s' % (sys.argv[3], why), file=sys.stderr)
            sys.exit(77)
        print(source)
        return
    if mode == 'login':
        # login <vendor> <os> <dir> <sandboxed: 1|0>
        login(p, sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6] == '1')
        return
    # profile <os> <root> <tmp> <vendor> <port> <listening> <socket> <login> [write...]
    os_, root, tmp, vendor, port, listening, sock, login_dir = sys.argv[3:11]
    roots = roots_of(p, real(root), real(tmp) if tmp else '', sys.argv[11:])
    reads = [r for r in p['read'] if r] + gitdirs(real(root))
    own = p['vendors'].get(vendor, {})
    if os_ == 'darwin':
        ports = None if listening == 'unknown' else [int(x) for x in listening.split(',') if x]
        sys.stdout.write(darwin(p, roots, reads, own, port, ports, real(login_dir) if login_dir else ''))
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

# --- the option loop: every flag is --name=value --------------------------
cmd="${1-}"; [ $# -gt 0 ] && shift
policy=''; root=''; vendor=''; blocked=''; port=''; tmp=''; listening=''; started=''; ctl=''; login_dir=''
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
    --login=*) login_dir="${1#*=}"; shift ;;
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
      "$login_dir" ${writes[@]+"${writes[@]}"}
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
  sandboxed=0; [ "$cmd" = run ] && sandboxed=1
  python3 -c "$SB_PY" login "$policy" "$vendor" "${os:-none}" "$work/login" "$sandboxed" || exit $?
  if [ -s "$work/login/env" ]; then
    # exported, not put on a command line, where ps would show it
    while IFS='=' read -r n v; do
      [ -n "$n" ] && secret_env+=("$n=$v")
    done < "$work/login/env"
    rm -f "$work/login/env"
  fi
  # the keychain stand-in, first on the round's PATH, and the one thing of
  # fm-sandbox's own the profile lets the round read. It is made only when
  # the item came from the macOS keychain, so bwrap never needs it bound.
  if [ -x "$work/login/bin/security" ]; then
    scrub+=(PATH="$work/login/bin:$PATH")
    login_dir="$work/login"
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
  python3 -c "$SB_PY" profile "$policy" "$os" "$root" "$tmp" "$vendor" "$port" "$listening" "$sock" \
    "$login_dir" ${writes[@]+"${writes[@]}"} > "$work/profile" || exit 65
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
[ -z "$tmp" ] || scrub+=(TMPDIR="$tmp" TMP="$tmp" TEMP="$tmp")
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
rc=$?
exit "$rc"
