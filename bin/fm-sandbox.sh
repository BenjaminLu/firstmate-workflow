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
#   fm-sandbox.sh login-env --policy=<file> --vendor=<name> --tmp=<dir> --ctl=<dir>
#       -> the login a round would be handed, resolved exactly as `run`
#          resolves it: <ctl>/env (mode 600) holds every NAME=VALUE the round
#          gets, a `given` variable it would inherit included, and a login
#          file's copy goes under <tmp> where `run` puts it. Prints the
#          login-source line; exit 77 as `run` refuses. For fm-auth-probe.sh
#          (T-121), which asks the vendor about this login and no other.
#   --shed=<NAME> (repeatable; login-source, login-env, run, plain): a
#          variable the round goes without (T-121: one that would outrank
#          its login, unless config.yaml's billing: chose it). It never
#          counts as a `given` login and never reaches the round.
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
# it may neither connect to nor bind nor accept on, and which `run` tries
# behind the profile before the round and tightens to the proxy alone when
# the kernel lets one through (design 13.1, T-153);
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
# and the file tier is tried next. A secret-tool that cannot reach its
# store (no D-Bus session, a hung bus) is passed over for the file too, but
# refuses the round if the file is not there either, never falling back.
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
# sq <text> -> it, single-quoted for a /bin/sh script this writes
sq() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

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
SB_MODULE="$(dirname "${BASH_SOURCE[0]}")/lib/fm_sandbox_policy.py"

# The two in-sandbox helpers cannot read the engine's lib directory.
# Encode their frozen source before confinement, retaining the original -c
# argument positions and a real filename in tracebacks. Shell values reach
# the encoder as arguments, never as interpolated Python source.
INLINE_MODULE="$(dirname "${BASH_SOURCE[0]}")/lib/fm_sandbox_inline.py"

# Inside bwrap's network namespace, the first thing that runs: it serves
# the round's loopback as the proxy the round's commands are pointed at,
# relays each connection to the real proxy's socket outside, then becomes
# the round's command. The server is a child that leaves when the command
# does, and holds none of the command's descriptors open.
#   python3 -c "$FWD_PY" <socket> <command> [args...]
FWD_MODULE="$(dirname "${BASH_SOURCE[0]}")/lib/fm_sandbox_forward.py"
FWD_PY="$(python3 "$INLINE_MODULE" "$FWD_MODULE")" || exit 70

# The last thing before the round's command, inside the sandbox: it says on
# fd 4 that the sandbox started and got this far, so a failure before this
# line - the proxy, the profile, the sandbox binary itself - is told apart
# from the command's own exit code.
# shellcheck disable=SC2016  # expanded by the inner shell
SHIM='printf "started\n" >&4; exec 4>&-; exec "$@"'

# Run behind the round's own profile before the round (macOS): it says
# `checked` once it is running there, then each of the ports it is given
# that it could connect to on loopback, and each `bind:<port>` it could
# bind there.
#   python3 -c "$LOOP_PY" fm-loopback-check <port>|bind:<port>...
LOOP_MODULE="$(dirname "${BASH_SOURCE[0]}")/lib/fm_sandbox_loopback.py"
LOOP_PY="$(python3 "$INLINE_MODULE" "$LOOP_MODULE")" || exit 70

# loopback_said <reached>: what loopback_reached found, in words
loopback_said() {
  local conn bound
  conn="$(tr , '\n' <<< "$1" | grep -v '^bind:' | paste -sd, -)"
  bound="$(tr , '\n' <<< "$1" | sed -n 's/^bind://p' | paste -sd, -)"
  [ -z "$conn" ] || printf 'port(s) %s, which were listening before it' "$conn"
  [ -z "$conn" ] || [ -z "$bound" ] || printf ', and '
  [ -z "$bound" ] || printf "a bind of the board's port %s, which nothing held" "$bound"
}

# loopback_reached <port>|bind:<port>...: the ports a command behind
# $work/profile could connect to, and the bind:<port> it could bind,
# comma-separated; status 1 when the check never ran behind it
loopback_reached() {
  local got
  got="$("$tool" -f "$work/profile" "$(command -v python3)" -c "$LOOP_PY" fm-loopback-check "$@" 2>/dev/null)"
  [ "${got%%$'\n'*}" = checked ] || return 1
  printf '%s\n' "$got" | sed 1d | paste -sd, -
}

# --- the option loop: every flag is --name=value --------------------------
cmd="${1-}"; [ $# -gt 0 ] && shift
policy=''; root=''; vendor=''; blocked=''; port=''; tmp=''; listening=''; started=''; ctl=''
writes=(); shed=()
while [ $# -gt 0 ]; do
  case "$1" in
    --policy=*) policy="${1#*=}"; shift ;;
    --shed=*) shed+=("${1#*=}"); shift ;;
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
    python3 -- "$SB_MODULE" hosts "$policy" >/dev/null || exit 65
    covers; exit 0 ;;
  decide)
    required policy "$policy"
    [ $# -eq 1 ] || { say "decide takes one host"; exit 64; }
    python3 -- "$SB_MODULE" decide "$policy" "$vendor" "$1"; exit $? ;;
  login-source)
    required policy "$policy"; required vendor "$vendor"
    FM_SANDBOX_SHED="${shed[*]-}" python3 -- "$SB_MODULE" login-source "$policy" "$vendor" "$(host_os)"; exit $? ;;
  login-env)
    required policy "$policy"; required vendor "$vendor"; required tmp "$tmp"; required ctl "$ctl"
    os="$(host_os)"
    FM_SANDBOX_SHED="${shed[*]-}" python3 -- "$SB_MODULE" login-env "$policy" "$vendor" "${os:-none}" \
      "$ctl" "$tmp" || exit $?
    if [ -s "$ctl/warn" ]; then say "$(cat "$ctl/warn")"; rm -f "$ctl/warn"; fi
    exit 0 ;;
  profile)
    required policy "$policy"; required root "$root"
    os="$(host_os)"; [ -n "$os" ] || { say "no sandbox profile for this platform"; exit 69; }
    python3 -- "$SB_MODULE" profile "$policy" "$os" "$root" "$tmp" "$vendor" "${port:-0}" "$listening" '' \
      ${writes[@]+"${writes[@]}"}
    exit $? ;;
  run|plain) ;;
  *) echo "usage: fm-sandbox.sh os|covers|profile|decide|login-source|login-env|run|plain --policy=<file> ..." >&2; exit 64 ;;
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
done < <(python3 -- "$SB_MODULE" scrub "$policy") || exit 65
# what the round sheds (--shed, T-121) never reaches it, whatever the
# adapter's own `env -u` does: login_of did not count it as a login either
for v in ${shed[@]+"${shed[@]}"}; do scrub+=(-u "$v"); done
read -r procs cpu < <(python3 -- "$SB_MODULE" limits "$policy") || exit 65
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
  FM_SANDBOX_SHED="${shed[*]-}" python3 -- "$SB_MODULE" login "$policy" "$vendor" "${os:-none}" "$work/login" "$tmp" || exit $?
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
  python3 -- "$SB_MODULE" proxy "$policy" "$vendor" "$work/port" "${blocked:-}" "$sock" >/dev/null 2>&1 3<&- &
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
      # the separator is the regex /[.]/, never the string ".": mawk (Linux's
      # default awk) reads a one-character string as a regex, and "." then
      # splits on every character and no port is read (T-153)
      listening="$(awk '$NF == "LISTEN" { n = split($4, a, /[.]/); print a[n] }' <<< "$listing" \
        | grep -E '^[0-9]+$' | sort -un | paste -sd, -)"
    else
      listening=unknown
      say "cannot list loopback listeners; the round reaches no loopback port but its proxy"
    fi
    # Whether something holds the board's port is asked of the port itself,
    # by connecting to it here, outside the profile: a listing can miss it
    # (another netstat's format, a listener it does not show), and then the
    # round would try to bind a port that is held (T-153).
    held_board="${FM_PORT:-4173}"
    if [ "$listening" != unknown ]; then
      case ",$listening," in
        *",$held_board,"*) ;;
        *) if [ "$(python3 -c "$LOOP_PY" fm-loopback-check "$held_board" 2>/dev/null | sed 1d)" = "$held_board" ]; then
             listening="${listening:+$listening,}$held_board"
           fi ;;
      esac
    fi
  fi
  make_profile() {
    python3 -- "$SB_MODULE" profile "$policy" "$os" "$root" "$tmp" "$vendor" "$port" "$listening" "$sock" \
      ${writes[@]+"${writes[@]}"} > "$work/profile" || exit 65
  }
  make_profile
  # A profile's loopback rules are ones the kernel applies, not ones fm can
  # read back: the canary on 2026-09-26 found a round reaching the board
  # through a per-port denial. So the profile is tried before the round,
  # behind itself: it connects to every port that was listening but the
  # proxy's, and - while nothing holds the board's port - binds that port
  # (T-153: a suite's fixture board took 127.0.0.1:4173 while the
  # captain's board was down). Either getting through means the round's
  # would: it is given no loopback but its proxy instead - its own servers
  # go with it, which it says - and a profile that still lets one through
  # refuses the round. A check that could not run inside the profile
  # tightens it too. macOS only: its loopback is the host's. On Linux the
  # round has a network namespace of its own, so a bind there is the
  # round's and never the board's, and nothing is tried.
  check=(); probe=()
  board="${FM_PORT:-4173}"
  if [ "$os" = darwin ] && [ "$listening" != unknown ]; then
    IFS=, read -r -a listed_ports <<< "$listening"
    for n in ${listed_ports[@]+"${listed_ports[@]}"}; do [ "$n" = "$port" ] || check+=("$n"); done
    case ",$listening," in *",$board,"*) ;; *) probe=("bind:$board") ;; esac
    tried=(${check[@]+"${check[@]}"} ${probe[@]+"${probe[@]}"})
    if [ "${#tried[@]}" -gt 0 ]; then
      if ! reached="$(loopback_reached "${tried[@]}")"; then
        say "cannot try the profile's loopback denials on this host, so they are not relied on"
        listening=unknown; make_profile
      elif [ -n "$reached" ]; then
        say "the profile's loopback denials do not hold on this host: a round could reach $(loopback_said "$reached") (the board's is $board)"
        listening=unknown; make_profile
        if reached="$(loopback_reached "${tried[@]}")" && [ -n "$reached" ]; then
          say "and even that profile lets a round reach $(loopback_said "$reached"); refusing the round"
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
      say "loopback: the round's profile allows its proxy's port ($port) and ports it opens itself; tried behind it and closed to it: ${check[*]:-nothing else was listening}${probe[*]:+; and the port of the board, $board, not listening, cannot be bound}"
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
fi
round_path="$PATH"
[ -z "${fmbin:-}" ] || round_path="$fmbin:$PATH"

# Apple's xcrun shims (T-147). Where the first git, python3 or other
# developer tool on the round's PATH is one of them (fm_xcrun_shim), it
# cannot run inside the round: xcrun's cache is outside every write root,
# and an unaccepted Xcode licence stops it after that. So xcrun is asked
# here, outside the round, for the tool it would run, and a stand-in ahead
# of the shim runs that one directly - the same tool the shim would have
# run, with the same licence already accepted. Where xcrun has none to
# give, the stand-in says so plainly and exits 69 at once, instead of the
# round failing on a cache write and a licence prompt it cannot answer.
# macOS only: no shim exists anywhere else.
if [ "$cmd" = run ] && [ "$os" = darwin ] && [ -n "$tmp" ] && declare -F fm_xcrun_shim >/dev/null; then
  xbin="$tmp/.fm-xcrun"
  for xt in $FM_XCRUN_TOOLS; do
    xfound="$(fm_path_tool "$xt" "$round_path")" || continue
    fm_xcrun_shim "$xfound" || continue
    mkdir -p "$xbin" || { say "cannot make $xbin"; exit 70; }
    IFS=$'\t' read -r xhow xwhat < <(fm_xcrun_resolve "$xt")
    if [ "$xhow" = real ]; then
      say "$xt on the round's PATH is Apple's xcrun shim ($xfound); the round runs the $xt it names, $xwhat, directly"
      printf '#!/bin/sh\nexec %s "$@"\n' "$(sq "$xwhat")" > "$xbin/$xt"
    else
      xmsg="fm: $xt here is only Apple's Xcode shim ($xfound), which cannot run inside a crew round: $xwhat. Nothing inside the round can fix it; say so in your account of the round. The operator fixes it outside the round: $(fm_xcrun_fix "$xt")."
      # fm-doctor.sh checks git and python3 for a shim, and no other tool
      case "$xt" in git|python3) xmsg="${xmsg%.}; fm doctor reports it." ;; esac
      say "${xmsg#fm: }"
      printf '#!/bin/sh\necho %s >&2\nexit 69\n' "$(sq "$xmsg")" > "$xbin/$xt"
    fi
    chmod +x "$xbin/$xt" || { say "cannot make $xbin/$xt executable"; exit 70; }
  done
  [ ! -d "$xbin" ] || round_path="$xbin:$round_path"
fi
scrub+=(PATH="$round_path")

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
  # A shell's own temp files (T-147). codex runs every command through the
  # operator's login shell, and zsh writes a here-document's temp file
  # under TMPPREFIX, /tmp/zsh by default, not TMPDIR: the first codex round
  # stopped on `can't create temp file for here document`. bash, ksh and
  # dash already follow TMPDIR or use a pipe.
  #
  # And the operator's toolchain first on PATH, after the login profile. A
  # login shell runs the system's profile - on macOS /etc/zprofile and
  # /etc/profile, whose path_helper puts /usr/bin, Apple's xcrun shims,
  # ahead of every directory the operator added (Homebrew's, mise's) - so
  # `git` in a codex round was /usr/bin/git where the operator's own shell
  # finds their git. The round's HOME is its own, so its profile is fm's:
  # it puts back the PATH this script gives the round, SANDBOX_ROUND_PATH,
  # after the system's has run. ZDOTDIR is set so zsh reads it rather than
  # an operator's ZDOTDIR the round cannot read. Every vendor's shell gets
  # the same, whether it starts a login shell or not.
  scrub+=(TMPPREFIX="$tmp/zsh" ZDOTDIR="$home" SANDBOX_ROUND_PATH="$round_path")
  for rc in .zprofile .bash_profile .profile; do
    [ -e "$home/$rc" ] && continue
    printf '%s\n' \
      '# fm-sandbox.sh (T-147): the round'"'"'s PATH, back ahead of what the system'"'"'s login profile put first' \
      '[ -z "${SANDBOX_ROUND_PATH-}" ] || PATH="$SANDBOX_ROUND_PATH"' 'export PATH' > "$home/$rc" \
      || { say "cannot write $home/$rc"; exit 70; }
  done
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
