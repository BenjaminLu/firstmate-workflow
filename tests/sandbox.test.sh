#!/usr/bin/env bash
# The crew's permission policy (T-105): one policy per role, resolved from
# config.yaml by fm_policy, and the OS half of enforcing it, bin/fm-sandbox.sh.
# What each adapter's own flags make of the same policy is asserted in
# tests/adapter-contract.test.sh.
#
# No real sandbox runs here: a runner cannot be relied on to have one, and
# a macOS profile cannot be applied inside another. FM_SANDBOX_OS and
# FM_SANDBOX_TOOL name the platform and a stand-in that records what it was
# handed and runs the command, so what is asserted is exactly what the real
# tool would have been given. bin/fm-canary.sh is what runs the real thing.
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"
SB="$ROOT/bin/fm-sandbox.sh"

t="$(mktemp -d)"; t="$(cd "$t" && pwd -P)"
home="$(cd "$HOME" && pwd -P)"
pol() {   # pol <role> <config text> -> the policy file; its exit code too
  printf '%s' "$2" > "$t/config.yaml"
  fm_policy "$1" "" "$t/config.yaml" > "$t/$1.json"
}

# --- fm_policy: one policy per role ------------------------------------------
pol worker 'vendor: mock
'
assert_eq "0" "$?" "a config.yaml with no policy block still resolves one"
w="$t/worker.json"
assert_eq "worker" "$(jq -r .role "$w")" "for the role asked"
assert_eq "write read network sockets env repo-config refuse ulimit" "$(jq -r '.dimensions|join(" ")' "$w")" \
  "naming every dimension a round is confined in"
assert_eq '["{root}","{tmp}","/tmp"]' "$(jq -c .write "$w")" "writes go to the worktree or checkout and the temp directory"
assert_eq "[]" "$(jq -c .network "$w")" "and no registry is reachable unless one is declared"
for never in "$home/.ssh" "$home/.config/gh" "$home/.aws" "$home/.claude" "$home/.codex" \
             "$home/.cursor" "$home/.gemini" "$home/.config/herdr" "$t/state"; do
  assert_eq "true" "$(jq --arg p "$never" '.never_read | index($p) != null' "$w")" \
    "never readable: ${never#"$home"/}"
done
for op in "git push" gh herdr browser mcp; do
  assert_eq "true" "$(jq --arg op "$op" '.refuse | index($op) != null' "$w")" "refused: $op"
done
for name in GH_TOKEN GITHUB_TOKEN SSH_AUTH_SOCK GOOGLE_APPLICATION_CREDENTIALS; do
  assert_eq "true" "$(jq --arg n "$name" '.env_scrub.names | index($n) != null' "$w")" "scrubbed: $name"
done
assert_eq "true" "$(jq '.env_scrub.prefixes | index("AWS_") != null and index("AZURE_") != null' "$w")" \
  "and every AWS_ and AZURE_ variable"
assert_eq '[".claude",".mcp.json",".cursor","GEMINI.md"]' "$(jq -c .repo_config "$w")" \
  "the repository's own agent configuration is not loaded"
assert_eq "none" "$(jq -r .sockets "$w")" "no unix sockets"
assert_eq "2048 14400" "$(jq -r '"\(.procs) \(.cpu)"' "$w")" "and a process and CPU ulimit"
assert_eq "true" "$(jq --arg p "$home/.claude/.credentials.json" '.vendors.claude.auth | index($p) != null' "$w")" \
  "a vendor's own auth is named, for its own round to read"

# the layers: top-level, then the project, flat keys then the role's own
cfg='vendor: mock
reviewer:
  network: legacy.example.org
policy:
  network: top.example.org
  read: /opt/extra
  worker:
    procs: 900
  reviewer:
    cpu: 60
default_project: app
projects:
  app:
    repo: .
    github: o/app
    base: main
    required_check: ci
    policy:
      never_read: ~/private
      reviewer:
        network: registry.npmjs.org cdn.playwright.dev
'
pol worker "$cfg"; assert_eq "0" "$?" "a project override resolves"
assert_eq '["top.example.org"]' "$(jq -c .network "$t/worker.json")" "a worker takes the top-level network"
assert_eq "900 14400" "$(jq -r '"\(.procs) \(.cpu)"' "$t/worker.json")" "and its own role's limits"
assert_eq "true" "$(jq '.read | index("/opt/extra") != null and index("/usr") != null' "$t/worker.json")" \
  "a layer's read adds to the toolchain rather than replacing it"
assert_eq "true" "$(jq --arg p "$home/private" --arg s "$home/.ssh" \
  '.never_read | index($p) != null and index($s) != null' "$t/worker.json")" \
  "the project's never_read adds to the floor"
assert_eq "app" "$(jq -r .project "$t/worker.json")" "and the project is named"
pol reviewer "$cfg"
assert_eq '["registry.npmjs.org","cdn.playwright.dev"]' "$(jq -c .network "$t/reviewer.json")" \
  "the project's reviewer network replaces the top-level one for a reviewer"
assert_eq "2048 60" "$(jq -r '"\(.procs) \(.cpu)"' "$t/reviewer.json")" "and the reviewer keeps its own limits"
# the pre-T-105 place for the reviewer's hosts still counts, for a reviewer only
pol reviewer 'vendor: mock
reviewer:
  mode: run
  network: registry.npmjs.org   # what setup needs
'
assert_eq '["registry.npmjs.org"]' "$(jq -c .network "$t/reviewer.json")" "reviewer: network: still reaches a reviewer's policy"
pol worker 'vendor: mock
reviewer:
  network: registry.npmjs.org
'
assert_eq "[]" "$(jq -c .network "$t/worker.json")" "and never a worker's"

# what may never be declared: GitHub, loopback, anything not a plain name
for bad in github.com api.github.com raw.githubusercontent.com ghcr.io localhost dev.localhost \
           127.0.0.1 10.0.0.1 '*' '*.com'; do
  out="$(pol worker "policy:
  network: registry.npmjs.org $bad
" 2>&1)"
  assert_eq "65" "$?" "a network naming '$bad' is refused"
  assert_contains "$out" "names $bad, which" "and names it"
done
out="$(pol worker 'policy:
  network: localhost
' 2>&1)"
assert_contains "$out" "may not reach loopback" "loopback is said to be loopback"
out="$(pol worker 'policy:
  network: api.github.com
' 2>&1)"
assert_contains "$out" "may not reach GitHub" "and GitHub GitHub"
out="$(pol worker 'projects:
  app:
    repo: .
    github: o/app
    base: main
    required_check: ci
    policy:
      worker:
        network: 127.0.0.1
' 2>&1)"
assert_eq "65" "$?" "a project cannot declare loopback either"
for bad in 'policy:
  sockets: all
' 'policy:
  worker:
    write: /
' 'policy:
  procs: many
' 'policy:
  read: relative/path
' 'policy:
  read: /a(b)
' 'policy:
  worker: yes
'; do
  pol worker "$bad" >/dev/null 2>&1
  assert_eq "65" "$?" "a policy that does not read is refused: $(printf '%s' "$bad" | tr '\n' ' ')"
done
fm_policy captain "" "$t/config.yaml" >/dev/null 2>&1
assert_eq "65" "$?" "the roles are worker and reviewer"

# --- fm-sandbox.sh: what the OS layer covers ----------------------------------
pol worker 'vendor: mock
policy:
  network: registry.npmjs.org
'
P="$t/worker.json"
mkdir -p "$t/bin"
# the stand-ins: each records what it was handed and runs the command
cat > "$t/bin/sandbox-exec" <<S
#!/usr/bin/env bash
[ "\$1" = -f ] || exit 99
cp "\$2" "$t/profile.sb"
shift 2
exec "\$@"
S
cat > "$t/bin/bwrap" <<S
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$t/bwrap.args"
while [ \$# -gt 0 ] && [ "\$1" != -- ]; do shift; done
shift
exec "\$@"
S
chmod +x "$t/bin/sandbox-exec" "$t/bin/bwrap"
mac() { FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" "$SB" "$@"; }
lin() { FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$t/bin/bwrap" "$SB" "$@"; }

assert_eq "write read network sockets env repo-config refuse ulimit" "$(mac covers --policy="$P")" \
  "on macOS the sandbox covers every dimension"
assert_eq "write read env repo-config ulimit" "$(lin covers --policy="$P")" \
  "on Linux it leaves the network, sockets and refused operations to the adapter"
assert_eq "darwin" "$(mac os)" "and says which platform it is"
assert_eq "" "$(FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/no-such-tool" "$SB" covers --policy="$P")" \
  "a host with no sandbox covers nothing"
assert_eq "" "$(FM_SANDBOX_OS=plan9 "$SB" covers --policy="$P")" "nor does a platform with none"
"$SB" covers --policy="$t/nope.json" >/dev/null 2>&1
assert_eq "65" "$?" "a policy that does not read covers nothing either"
"$SB" covers >/dev/null 2>&1
assert_eq "64" "$?" "and covers without a policy is a usage error"

# --- the macOS profile ----------------------------------------------------------
root="$t/tree"; mkdir -p "$root/.claude"
prof="$(mac profile --policy="$P" --root="$root" --vendor=claude --proxy-port=4242 --write="$t/attempt")"
assert_contains "$prof" "(deny network*)" "the profile denies the network"
assert_eq '(allow network-outbound (remote ip "localhost:4242"))' "$(grep 'allow network' <<< "$prof")" \
  "and allows exactly one way out: the round's own proxy"
assert_contains "$prof" "(deny file-write*)" "writes are denied"
wline="$(grep '^(allow file-write\*' <<< "$prof")"
assert_contains "$wline" "(subpath \"$root\")" "but for the round's root"
assert_contains "$wline" "(subpath \"$(cd "${TMPDIR:-/tmp}" && pwd -P)\")" "and the temp directory"
assert_contains "$wline" "(subpath \"$t/attempt\")" "and a directory the adapter adds"
assert_contains "$prof" "(deny file-read*)" "reads are denied by default"
assert_contains "$(grep '^(allow file-read\* (literal "/")' <<< "$prof")" "(subpath \"/usr\")" "but for the toolchain"
nline="$(grep '^(deny file-read\* file-write\*' <<< "$prof" | head -1)"
assert_contains "$nline" "(subpath \"$home/.ssh\")" "~/.ssh is never readable"
assert_contains "$nline" "(subpath \"$home/.claude\")" "nor a vendor's home"
assert_contains "$prof" "(literal \"$home/.claude/.credentials.json\")" "but its own auth, for its own round"
assert_lacks "$(mac profile --policy="$P" --root="$root" --vendor=codex)" ".credentials.json" \
  "and not for another vendor's"
assert_contains "$prof" "(subpath \"$root/.claude\")" "the repository's .claude/ is out of reach"
assert_contains "$prof" "(subpath \"$root/.mcp.json\")" "and its .mcp.json"
assert_contains "$prof" "com.apple.coreservices.launchservicesd" "and no browser can be opened"
# the order is the rule: a later rule wins, so the floor comes after every allow
n_allow="$(grep -n '^(allow file-read\* (literal "/")' <<< "$prof" | cut -d: -f1)"
n_never="$(grep -n "$home/.ssh" <<< "$prof" | head -1 | cut -d: -f1)"
assert_eq "1" "$([ "$n_never" -gt "$n_allow" ] && echo 1)" "the never-readable rule comes after the toolchain's"
# a project that adds all of $HOME to read still cannot read ~/.ssh
pol worker 'policy:
  read: ~
'
wide="$(mac profile --policy="$t/worker.json" --root="$root")"
n_home="$(grep -n "(subpath \"$home\")" <<< "$wide" | head -1 | cut -d: -f1)"
n_ssh="$(grep -n "(subpath \"$home/.ssh\")" <<< "$wide" | head -1 | cut -d: -f1)"
assert_eq "1" "$([ -n "$n_home" ] && [ "$n_ssh" -gt "$n_home" ] && echo 1)" \
  "a layer that reads all of \$HOME is still refused ~/.ssh after it"
pol worker 'vendor: mock
policy:
  network: registry.npmjs.org
'
assert_lacks "$(mac profile --policy="$P" --root="$root")" "network-outbound" \
  "without a proxy nothing gets out at all"

# --- the Linux arguments --------------------------------------------------------
mkdir -p "$t/data/secret"
pol worker "policy:
  read: $t/data
  never_read: $t/data/secret
"
args="$(lin profile --policy="$t/worker.json" --root="$root")"
assert_contains "$args" "--ro-bind-try
/usr
/usr" "the toolchain is mounted read-only"
assert_contains "$args" "--bind
$root
$root" "the root read-write"
assert_contains "$args" "--tmpfs
$root/.claude" "the repository's .claude/ is hidden"
assert_contains "$args" "--tmpfs
$t/data/secret" "a never-readable path inside a readable one is hidden"
assert_lacks "$args" "$home/.ssh" "and ~/.ssh is simply not mounted"
assert_eq "--" "$(printf '%s\n' "$args" | tail -1)" "the command follows the arguments"
assert_lacks "$args" "--unshare-net" "the network is shared: the CLI has to reach its own service"

# --- decide: the rule the round's proxy applies --------------------------------
pol worker 'vendor: mock
policy:
  network: registry.npmjs.org
'
decide() { "$SB" decide --policy="$1" ${2:+--vendor="$2"} "$3" >/dev/null 2>&1; echo $?; }
assert_eq "0" "$(decide "$P" "" registry.npmjs.org)" "a declared registry is reachable"
assert_eq "1" "$(decide "$P" "" pypi.org)" "an undeclared host is not"
assert_eq "0" "$(decide "$P" claude api.anthropic.com)" "a vendor reaches its own service"
assert_eq "1" "$(decide "$P" codex api.anthropic.com)" "and not another vendor's"
# a hand-edited policy still cannot reach GitHub or loopback
jq '.network = ["github.com","api.github.com","localhost","127.0.0.1","registry.npmjs.org"]' "$P" > "$t/edited.json"
for never in github.com api.github.com objects.githubusercontent.com localhost 127.0.0.1 ::1; do
  assert_eq "1" "$(decide "$t/edited.json" "" "$never")" "$never is never reachable, whatever the policy says"
done
jq '.vendors.claude.hosts = ["github.com"]' "$P" > "$t/edited2.json"
assert_eq "1" "$(decide "$t/edited2.json" claude api.github.com)" "not even as a vendor's service"

# --- run: the command inside the sandbox ------------------------------------------
cat > "$t/probe.py" <<'PY'
import os, socket, sys
out = open(sys.argv[1], 'w')
out.write('stdin=%s\n' % sys.stdin.read().strip())
for name in ('GH_TOKEN', 'GITHUB_TOKEN', 'SSH_AUTH_SOCK', 'AWS_SECRET_ACCESS_KEY', 'HERDR_SOCKET', 'KEEP_ME'):
    out.write('%s=%s\n' % (name, os.environ.get(name, '')))
proxy = os.environ.get('HTTPS_PROXY', '')
out.write('proxy=%s\n' % ('set' if proxy else ''))
host, port = proxy.rsplit('/', 1)[-1].split(':')
for target in ('undeclared.example.org:443', 'github.com:443', 'undeclared.example.org:443'):
    s = socket.create_connection((host, int(port)))
    s.sendall(('CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n' % (target, target)).encode())
    out.write('%s %s\n' % (target, s.recv(64).split(b'\r\n')[0].decode()))
    s.close()
PY
cat > "$t/cmd.sh" <<S
#!/usr/bin/env bash
printf 'procs=%s cpu=%s\n' "\$(ulimit -u)" "\$(ulimit -t)" > "$t/limits"
python3 "$t/probe.py" "$t/ran"
exit 7
S
chmod +x "$t/cmd.sh"
: > "$t/blocked"; rm -f "$t/ran" "$t/profile.sb"
pol worker 'policy:
  procs: 300
  cpu: 90
'
echo "the prompt" | GH_TOKEN=x GITHUB_TOKEN=x SSH_AUTH_SOCK=/x AWS_SECRET_ACCESS_KEY=x HERDR_SOCKET=/x KEEP_ME=kept \
  FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" \
  "$SB" run --policy="$t/worker.json" --root="$root" --blocked="$t/blocked" -- "$t/cmd.sh"
assert_eq "7" "$?" "run exits with the command's own code"
assert_ok "test -s '$t/profile.sb'" "the command ran behind the generated profile"
ran="$(cat "$t/ran" 2>/dev/null)"
assert_contains "$ran" "stdin=the prompt" "and was handed the prompt on stdin"
for name in GH_TOKEN GITHUB_TOKEN SSH_AUTH_SOCK AWS_SECRET_ACCESS_KEY HERDR_SOCKET; do
  assert_contains "$ran" "$name=
" "$name never reaches the round"
done
assert_contains "$ran" "KEEP_ME=kept" "while the rest of the environment does"
assert_contains "$ran" "proxy=set" "the round's traffic goes through its proxy"
assert_contains "$ran" "undeclared.example.org:443 HTTP/1.1 403" "which refuses an undeclared host"
assert_contains "$ran" "github.com:443 HTTP/1.1 403" "and GitHub"
assert_eq "undeclared.example.org
github.com" "$(cat "$t/blocked")" "and names each refused host once, for the round to report"
# the process limit is room for the policy's count on top of what the user
# already runs, so only its being set is asserted; the CPU limit is exact
assert_matches "$(cat "$t/limits" 2>/dev/null)" '^procs=[0-9]+ cpu=90$' "the ulimits are the policy's"
port="$(sed -n 's/.*localhost:\([0-9]*\).*/\1/p' "$t/profile.sb")"
assert_matches "$port" '^[0-9]+$' "the profile lets the round reach only that proxy's port"

# Linux: the same scrub and limits, behind bwrap
rm -f "$t/ran" "$t/bwrap.args"
echo "the prompt" | GH_TOKEN=x FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$t/bin/bwrap" \
  "$SB" run --policy="$t/worker.json" --root="$root" -- "$t/cmd.sh"
assert_eq "7" "$?" "under bwrap too"
assert_ok "test -s '$t/bwrap.args'" "the command ran behind bwrap"
assert_contains "$(cat "$t/ran" 2>/dev/null)" "GH_TOKEN=
" "with the same scrub"

# no sandbox: the round does not run unconfined
rm -f "$t/ran"
FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/no-such-tool" \
  "$SB" run --policy="$t/worker.json" --root="$root" -- "$t/cmd.sh" </dev/null >/dev/null 2>&1
assert_eq "69" "$?" "run with no sandbox on the host refuses"
assert_fail "test -e '$t/ran'" "and the command never starts"

# plain: what an adapter's flags stand in for - the scrub and the limits only
rm -f "$t/ran" "$t/limits"
echo "the prompt" | GH_TOKEN=x KEEP_ME=kept "$SB" plain --policy="$t/worker.json" -- \
  bash -c 'printf "procs=%s\n" "$(ulimit -u)"; printf "GH_TOKEN=%s KEEP_ME=%s\n" "${GH_TOKEN:-}" "${KEEP_ME:-}"; cat' \
  > "$t/plain" 2>&1
assert_matches "$(head -1 "$t/plain")" '^procs=[0-9]+$' "plain sets the process limit"
assert_eq "GH_TOKEN= KEEP_ME=kept
the prompt" "$(tail -n +2 "$t/plain")" "scrubs the environment and hands on the prompt"

rm -rf "$t"
finish
