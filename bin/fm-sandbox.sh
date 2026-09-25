#!/usr/bin/env bash
# The OS half of a crew round's permission policy (T-105). An adapter turns
# the policy into its CLI's own flags; this turns the same policy into an OS
# sandbox and runs the CLI inside it, so what a round may do does not rest
# on one vendor's flags meaning what they say.
#
#   fm-sandbox.sh os      -> darwin or linux when this host has a sandbox, else nothing
#   fm-sandbox.sh covers  --policy=<file>
#       -> the policy dimensions the sandbox enforces here, one line; nothing
#          when there is no sandbox to run
#   fm-sandbox.sh profile --policy=<file> --root=<dir> [--write=<dir>]... [--vendor=<name>] [--proxy-port=<n>]
#       -> macOS: the sandbox-exec profile; Linux: the bwrap arguments, one per line
#   fm-sandbox.sh decide  --policy=<file> [--vendor=<name>] <host>
#       -> allow or deny, and why: the rule the round's proxy applies
#   fm-sandbox.sh run     --policy=<file> --root=<dir> [--write=<dir>]... [--vendor=<name>]
#                         [--blocked=<file>] -- <command> [args...]
#   fm-sandbox.sh plain   --policy=<file> -- <command> [args...]
#       -> the environment scrub and the ulimits only: what an adapter's own
#          flags stand in for when this host has no sandbox
#
# The dimensions are the policy's: write, read, network, sockets, env,
# repo-config, refuse, ulimit. Before a round, the adapter asks `covers` and
# adds what its own flags enforce; a dimension neither covers refuses the
# round, and the fallback chain moves on. Nothing here degrades to running
# the command unconfined: `run` without a sandbox exits 69.
#
# macOS runs sandbox-exec with a generated profile: reads denied by default
# but for the write roots, the toolchain and the vendor's own auth; writes
# only to the write roots; no network but the round's own proxy, which is
# how a named registry can be allowed at all (a profile names addresses, not
# hosts), and which records every host it refuses to --blocked so the round
# can report it; LaunchServices refused, so no browser opens. Linux runs
# bwrap, which mounts only what the policy lets the round read; it cannot
# filter hosts, so it shares the network and leaves network, sockets and the
# refused operations to the adapter's own flags.
#
# FM_SANDBOX_OS and FM_SANDBOX_TOOL name the platform and the sandbox binary
# for the suite, which cannot run a real one on every runner.
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

# The policy's reading, the profiles and the proxy, in one place, so the
# rule the proxy applies is the rule `decide` prints.
IFS= read -r -d '' SB_PY <<'PY'
import json, os, re, select, socket, sys, threading

GITHUB = ('github.com', 'github.io', 'github.dev', 'githubusercontent.com', 'githubassets.com',
          'githubapp.com', 'githubcopilot.com', 'ghcr.io', 'ghe.com')


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
        w = w.replace('{root}', root).replace('{tmp}', tmp)
        out.append(real(w))
    out += [real(x) for x in extra]
    seen = []
    for r in out:
        if r not in seen:
            seen.append(r)
    return seen


def darwin(p, roots, reads, auth, port):
    sub = lambda paths: ' '.join('(subpath %s)' % sbpl(x) for x in paths)
    lines = ['(version 1)', '(allow default)',
             ';; network: nothing but this round\'s own proxy',
             '(deny network*)']
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
    lines += [';; the round\'s own roots, even under a never-readable directory',
              '(allow file-read* file-write* %s)' % sub(roots)]
    repo = [os.path.join(r, c) for r in roots[:1] for c in p['repo_config']]
    if repo:
        lines += [';; the repository\'s own agent configuration is not loaded',
                  '(deny file-read* file-write* %s)' % sub(repo)]
    lines += [';; no browser, no AppleScript: LaunchServices is out of reach',
              '(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd") '
              '(global-name "com.apple.coreservices.appleevents"))']
    return '\n'.join(lines) + '\n'


def linux(p, roots, reads, auth):
    a = ['--die-with-parent', '--new-session', '--unshare-pid', '--unshare-ipc', '--unshare-uts',
         '--proc', '/proc', '--dev', '/dev']
    for r in reads:
        a += ['--ro-bind-try', r, r]
    for r in auth:
        a += ['--ro-bind-try', r, r]
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
    a += ['--chdir', roots[0], '--']
    return '\n'.join(a) + '\n'


def proxy(p, vendor, portfile, blocked):
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
        f.write(str(server.getsockname()[1]))
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
        proxy(p, sys.argv[3], sys.argv[4], sys.argv[5])
        return
    # profile <os> <root> <tmp> <vendor> <port> [write...]
    os_, root, tmp, vendor, port = sys.argv[3:8]
    roots = roots_of(p, real(root), real(tmp), sys.argv[8:])
    reads = [r for r in p['read'] if r] + gitdirs(real(root))
    auth = p['vendors'].get(vendor, {}).get('auth', [])
    if os_ == 'darwin':
        sys.stdout.write(darwin(p, roots, reads, auth, port))
    else:
        sys.stdout.write(linux(p, roots, reads, auth))


main()
PY

# --- the option loop: every flag is --name=value --------------------------
cmd="${1-}"; [ $# -gt 0 ] && shift
policy=''; root=''; vendor=''; blocked=''; port=''; writes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --policy=*) policy="${1#*=}"; shift ;;
    --root=*) root="${1#*=}"; shift ;;
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
required() { [ -n "$2" ] || { say "$cmd needs --$1=<value>"; exit 64; }; }

# the dimensions the sandbox covers on this host for this policy
covers() {
  [ -n "$(host_tool)" ] || return 0
  case "$(host_os)" in
    darwin) echo "write read network sockets env repo-config refuse ulimit" ;;
    # bwrap cannot filter hosts, and a round whose CLI must reach its own
    # service shares the network: sockets and the refused operations go
    # through it, so those stay the adapter's
    linux)  echo "write read env repo-config ulimit" ;;
  esac
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
  profile)
    required policy "$policy"; required root "$root"
    os="$(host_os)"; [ -n "$os" ] || { say "no sandbox profile for this platform"; exit 69; }
    python3 -c "$SB_PY" profile "$policy" "$os" "$root" "${TMPDIR:-/tmp}" "$vendor" "${port:-0}" \
      ${writes[@]+"${writes[@]}"}
    exit $? ;;
  run|plain) ;;
  *) echo "usage: fm-sandbox.sh os|covers|profile|decide|run|plain --policy=<file> ..." >&2; exit 64 ;;
esac

required policy "$policy"
[ $# -gt 0 ] || { say "$cmd needs a command after --"; exit 64; }
if [ "$cmd" = run ]; then
  required root "$root"
  tool="$(host_tool)"
  [ -n "$tool" ] || { say "no OS sandbox on this host; refusing to run the round unconfined"; exit 69; }
  os="$(host_os)"
  root="$(cd "$root" 2>/dev/null && pwd -P)" || { say "no directory at $root"; exit 64; }
fi

# the environment scrub: named credentials and whole families of them
scrub=(env)
while IFS= read -r v; do
  [ -n "$v" ] && scrub+=(-u "$v")
done < <(python3 -c "$SB_PY" scrub "$policy") || exit 65
read -r procs cpu < <(python3 -c "$SB_PY" limits "$policy") || exit 65

work=''; proxy_pid=''
cleanup() {
  [ -z "$proxy_pid" ] || kill "$proxy_pid" 2>/dev/null
  [ -z "$work" ] || rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

launcher=()
if [ "$cmd" = run ]; then
  work="$(mktemp -d "${TMPDIR:-/tmp}/fm-sandbox.XXXXXX")" || exit 70
  # The proxy runs outside the sandbox and is the round's only way out: the
  # declared registries, the vendor's own service, and nothing else. On
  # Linux it is advisory - bwrap shares the network - but it still names
  # the hosts a round was refused.
  # nothing of the caller's is held open by it: a proxy left behind by a
  # killed round must not keep the adapter's transcript pipe from closing
  python3 -c "$SB_PY" proxy "$policy" "$vendor" "$work/port" "${blocked:-}" >/dev/null 2>&1 3<&- &
  proxy_pid=$!
  i=0
  while [ ! -s "$work/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  port="$(cat "$work/port" 2>/dev/null)"
  case "$port" in ''|*[!0-9]*) say "the round's proxy did not start"; exit 70 ;; esac
  url="http://127.0.0.1:$port"
  scrub+=(-u NO_PROXY -u no_proxy HTTP_PROXY="$url" HTTPS_PROXY="$url" http_proxy="$url"
          https_proxy="$url" ALL_PROXY="$url" all_proxy="$url" NODE_USE_ENV_PROXY=1)
  python3 -c "$SB_PY" profile "$policy" "$os" "$root" "${TMPDIR:-/tmp}" "$vendor" "$port" \
    ${writes[@]+"${writes[@]}"} > "$work/profile" || exit 65
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
# Linux counts threads against it as well.
used="$(if [ "$(uname -s)" = Linux ]; then ps -L -U "$(id -u)" -o lwp= 2>/dev/null
        else ps -U "$(id -u)" -o pid= 2>/dev/null; fi | wc -l | tr -d ' ')"
case "$used" in ''|*[!0-9]*) used=0 ;; esac
procs=$((used + procs))
(
  hard="$(ulimit -Hu 2>/dev/null)"
  case "$hard" in ''|unlimited) ;; *) [ "$procs" -le "$hard" ] || procs="$hard" ;; esac
  hard="$(ulimit -Ht 2>/dev/null)"
  case "$hard" in ''|unlimited) ;; *) [ "$cpu" -le "$hard" ] || cpu="$hard" ;; esac
  ulimit -u "$procs" 2>/dev/null || { say "cannot set the process limit to $procs"; exit 70; }
  ulimit -t "$cpu" 2>/dev/null || { say "cannot set the CPU limit to $cpu seconds"; exit 70; }
  exec ${launcher[@]+"${launcher[@]}"} "${scrub[@]}" "$@" <&3
)
rc=$?
exit "$rc"
