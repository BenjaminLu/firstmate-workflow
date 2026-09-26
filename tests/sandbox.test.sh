#!/usr/bin/env bash
# The crew's permission policy (T-105, T-117): one policy per role, resolved
# from config.yaml by fm_policy, and the OS half of enforcing it,
# bin/fm-sandbox.sh - the sandbox itself, and the vendor's login it reads
# outside the round and hands in. What each adapter's own flags make of the
# same policy is asserted in tests/adapter-contract.test.sh.
#
# No real sandbox runs here: a runner cannot be relied on to have one, and
# a macOS profile cannot be applied inside another. FM_SANDBOX_OS and
# FM_SANDBOX_TOOL name the platform and a stand-in that records what it was
# handed and runs the command, so what is asserted is exactly what the real
# tool would have been given; FM_KEYCHAIN_TOOL names a stand-in for the
# operator's keychain. bin/fm-canary.sh is what runs the real thing.
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
# a login already in this shell would be handed in instead of the stand-in's
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY CURSOR_API_KEY CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"
SB="$ROOT/bin/fm-sandbox.sh"

t="$(mktemp -d)"; t="$(cd "$t" && pwd -P)"
home="$(cd "$HOME" && pwd -P)"
# the operator's name as fm_policy reads it
me="$(python3 -c 'import getpass; print(getpass.getuser())')"
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
assert_eq '["{root}","{tmp}"]' "$(jq -c .write "$w")" \
  "writes go to the worktree or checkout and the round's own temp directory - never the shared /tmp"
assert_eq "[]" "$(jq -c .network "$w")" "and no registry is reachable unless one is declared"
# git's own credential stores (T-117): design 13.1 names ~/.git-credentials
# and ~/.netrc as how git's credentials stay out of reach, and ~/.gnupg
# holds the signing keys
for never in "$home/.ssh" "$home/.config/gh" "$home/.aws" "$home/.claude" "$home/.claude.json" "$home/.codex" \
             "$home/.cursor" "$home/.gemini" "$home/.config/herdr" "$t/state" \
             "$home/.git-credentials" "$home/.netrc" "$home/.gnupg" "$home/.config/firstmate"; do
  assert_eq "true" "$(jq --arg p "$never" '.never_read | index($p) != null' "$w")" \
    "never readable: ${never#"$home"/}"
done
for op in "git push" gh herdr browser mcp; do
  assert_eq "true" "$(jq --arg op "$op" '.refuse | index($op) != null' "$w")" "refused: $op"
done
for name in GH_TOKEN GITHUB_TOKEN SSH_AUTH_SOCK GOOGLE_APPLICATION_CREDENTIALS FM_CREW_UNSANDBOXED FM_ROUND_UNSANDBOXED; do
  assert_eq "true" "$(jq --arg n "$name" '.env_scrub.names | index($n) != null' "$w")" "scrubbed: $name"
done
assert_eq "true" "$(jq '.env_scrub.prefixes | index("AWS_") != null and index("AZURE_") != null' "$w")" \
  "and every AWS_ and AZURE_ variable"
assert_eq '[".claude",".mcp.json",".cursor","GEMINI.md"]' "$(jq -c .repo_config "$w")" \
  "the repository's own agent configuration is not loaded"
assert_eq "none" "$(jq -r .sockets "$w")" "no unix sockets"
assert_eq "2048 14400" "$(jq -r '"\(.procs) \(.cpu)"' "$w")" "and a process and CPU ulimit"
# Every vendor's login file holds a refresh token (T-117 round 2), so none
# is read in place: fm reads it and hands in its access token, or a copy
# with the refresh token emptied
assert_eq "[]" "$(jq -c '[.vendors[].auth[]]' "$w")" "no vendor's round reads its login file in place"
assert_eq "[]" "$(jq -c '[.vendors | to_entries[] | select((.value.login.file // []) | length > 0)
    | select((.value.login.copy // "") == "" and ((.value.login.to // "") | startswith("env:") | not)) | .key]' "$w")" \
  "every login read from a file goes in as a token or a copy, never as the file"
assert_eq "[]" "$(jq -c '[.vendors | to_entries[] | select(.value.login.copy) | select((.value.login.drop // []) | length == 0) | .key]' "$w")" \
  "and every copy names the refresh token it empties"
assert_eq "codex-home/auth.json tokens.refresh_token|gemini-home/.gemini/oauth_creds.json refresh_token" \
  "$(jq -r '[.vendors.codex, .vendors.gemini] | map("\(.login.copy) \(.login.drop | join(","))") | join("|")' "$w")" \
  "codex's and gemini's login files each go in as a copy, less the refresh token"
assert_eq '["codex","gemini"]' "$(jq -c '[.vendors | to_entries[] | select(.value.login.copy) | .key]' "$w")" \
  "and no other vendor's login goes in as a file"
# a vendor's session state is writable; its settings are not state
for v in codex cursor-agent gemini; do
  assert_ne "0" "$(jq --arg v "$v" '.vendors[$v].state | length' "$w")" "$v names the session state its CLI writes"
done
assert_eq "[]" "$(jq -c '[.vendors[] | (.state + .auth)[] | select(test("settings|config\\.toml|mcp\\.json|/skills|/hooks|CLAUDE\\.md|GEMINI\\.md"))]' "$w")" \
  "no vendor's settings, hooks, skills or MCP servers are among its auth or state"
# claude (T-117): a config directory of the round's own, so nothing of the
# operator's ~/.claude is opened; the one directory it keeps under /tmp
# whatever TMPDIR says; and its login read outside the round
assert_eq "[] []" "$(jq -r '"\(.vendors.claude.auth | tojson) \(.vendors.claude.state | tojson)"' "$w")" \
  "claude's round opens no file of the operator's ~/.claude or ~/.claude.json"
assert_eq "[\"$(cd /tmp && pwd -P)/claude-$(id -u)\"]" "$(jq -c .vendors.claude.tmp "$w")" \
  "claude's temp directory under /tmp is its one there, for this user"
assert_eq "[]" "$(jq -c '[.vendors | to_entries[] | select(.key != "claude") | .value.tmp[]]' "$w")" \
  "and no other vendor has one"
assert_eq "Claude Code-credentials $me env:CLAUDE_CODE_OAUTH_TOKEN claudeAiOauth.accessToken" \
  "$(jq -r '.vendors.claude.login | "\(.keychain[0].service) \(.keychain[0].account) \(.to) \(.field)"' "$w")" \
  "claude's login is its own keychain item, handed in as an access token"
assert_eq "$home/.claude/.credentials.json" "$(jq -r '.vendors.claude.login.file[0]' "$w")" \
  "or its credentials file where there is no keychain"
# cursor-agent reads `agent login`'s token through the keychain API, which
# no round reaches (the canary, 2026-09-26), so its round signs in with a
# Cursor API key the operator keeps for the crew in fm's own item or file
assert_eq "firstmate-cursor-api-key $me env:CURSOR_API_KEY" \
  "$(jq -r '.vendors."cursor-agent".login | "\(.keychain[0].service) \(.keychain[0].account) \(.to)"' "$w")" \
  "cursor-agent's login is the crew's Cursor API key, handed in as CURSOR_API_KEY"
assert_eq "[\"$home/.config/firstmate/cursor-api-key\"] true" \
  "$(jq -r '.vendors."cursor-agent".login | "\(.file | tojson) \(.private)"' "$w")" \
  "or a file of fm's that only the operator may read"
assert_eq "[]" "$(jq -c '[.vendors."cursor-agent".login | (.keychain // [])[].service, (.file // [])[] | select(test("cursor-access-token|cursor-refresh-token|\\.config/cursor"))]' "$w")" \
  "and never agent login's own items or files, which hold its refresh token"
assert_eq '[]' "$(jq -c '[.vendors[].login | select(.to) | .to | select(startswith("env:") | not)]' "$w")" \
  "every login read outside the round goes in as a variable or a copy, nothing served from inside it"
# no vendor's login is anyone else's: gh's token, git's credential helper
assert_eq "[]" "$(jq -c '[.vendors[].login.keychain // [] | .[].service | select(test("^gh:|github|git|refresh"; "i"))]' "$w")" \
  "no login names gh's, git's or a refresh token's keychain item"

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
# nor turn the sandbox off: the escape hatch is the operator's shell's, and
# a branch can change config.yaml
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
' 'policy:
  sandbox: off
' 'policy:
  unsandboxed: 1
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
# Builtins only, no fork: it runs under the round's process limit, which a
# test below sets below what the user already runs
cat > "$t/bin/sandbox-exec" <<S
#!/usr/bin/env bash
[ "\$1" = -f ] || exit 99
printf '%s\n' "\$2" > "$t/profile.path"
while IFS= read -r l; do printf '%s\n' "\$l"; done < "\$2" > "$t/profile.sb"
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
assert_eq "write read network sockets env repo-config refuse ulimit" "$(lin covers --policy="$P")" \
  "and on Linux, where the network is a namespace of the round's own"
assert_eq "darwin" "$(mac os)" "and says which platform it is"
assert_eq "" "$(FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/no-such-tool" "$SB" covers --policy="$P")" \
  "a host with no sandbox covers nothing"
assert_eq "" "$(FM_SANDBOX_OS=plan9 "$SB" covers --policy="$P")" "nor does a platform with none"
"$SB" covers --policy="$t/nope.json" >/dev/null 2>&1
assert_eq "65" "$?" "a policy that does not read covers nothing either"
"$SB" covers >/dev/null 2>&1
assert_eq "64" "$?" "and covers without a policy is a usage error"

# --- the macOS profile ----------------------------------------------------------
root="$t/tree"; mkdir -p "$root/.claude" "$t/round-a" "$t/round-b"
prof="$(mac profile --policy="$P" --root="$root" --tmp="$t/round-a" --vendor=codex --proxy-port=4242 \
  --listening=4242,5000 --write="$t/attempt")"
assert_contains "$prof" "(deny network*)" "the profile denies the network"
# loopback: the round's own ports, and neither the board nor what was already listening
assert_contains "$prof" '(allow network-bind (local ip "localhost:*"))' "a round may open loopback ports of its own"
assert_contains "$prof" '(allow network-outbound (remote ip "localhost:*"))' "and connect to them"
assert_contains "$prof" '(deny network-outbound (remote ip "localhost:4173"))' "but never to the board's port"
assert_contains "$prof" '(deny network-outbound (remote ip "localhost:5000"))' "nor to a listener older than the round"
assert_eq "" "$(grep 'allow network' <<< "$prof" | grep -v '"localhost:' || true)" \
  "and nothing but loopback is allowed directly"
n_deny="$(grep -n 'deny network-outbound (remote ip "localhost:5000")' <<< "$prof" | cut -d: -f1)"
n_proxy="$(grep -n 'allow network-outbound (remote ip "localhost:4242")' <<< "$prof" | tail -1 | cut -d: -f1)"
assert_eq "1" "$([ -n "$n_deny" ] && [ -n "$n_proxy" ] && [ "$n_proxy" -gt "$n_deny" ] && echo 1)" \
  "the round's own proxy stays reachable though it was listening first"
FM_PORT=4999 mac profile --policy="$P" --root="$root" --proxy-port=4242 --listening= > "$t/p2"
assert_contains "$(cat "$t/p2")" '(remote ip "localhost:4999")' "the board's port is FM_PORT when that is set"
unknown="$(mac profile --policy="$P" --root="$root" --proxy-port=4242 --listening=unknown)"
assert_eq '(allow network-outbound (remote ip "localhost:4242"))' "$(grep 'allow network' <<< "$unknown")" \
  "with the listeners unknown, the proxy is the only port reachable"
assert_contains "$prof" "(deny file-write*)" "writes are denied"
wline="$(grep '^(allow file-write\*' <<< "$prof")"
assert_contains "$wline" "(subpath \"$root\")" "but for the round's root"
assert_contains "$wline" "(subpath \"$t/round-a\")" "and the round's own temp directory"
assert_contains "$wline" "(subpath \"$t/attempt\")" "and a directory the adapter adds"
# the shared temp directory is every round's: another round's temp, a
# run-mode review checkout made there, fm-sandbox's own files
callertmp="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
for shared in "$callertmp" /tmp /private/tmp "$t/round-b"; do
  assert_lacks "$prof" "(subpath \"$shared\")" "no round is given $shared"
done
assert_contains "$prof" "(deny file-read*)" "reads are denied by default"
assert_contains "$(grep '^(allow file-read\* (literal "/")' <<< "$prof")" "(subpath \"/usr\")" "but for the toolchain"
nline="$(grep '^(deny file-read\* file-write\*' <<< "$prof" | head -1)"
assert_contains "$nline" "(subpath \"$home/.ssh\")" "\$HOME/.ssh is never readable"
assert_contains "$nline" "(subpath \"$home/.codex\")" "nor a vendor's home"
assert_contains "$nline" "(subpath \"$home/.config/gh\")" "nor gh's"
assert_contains "$nline" "(subpath \"$home/.git-credentials\")" "nor git's credential store"
assert_contains "$nline" "(subpath \"$home/.netrc\")" "nor ~/.netrc, which git and curl read credentials from"
assert_contains "$nline" "(subpath \"$home/.gnupg\")" "nor the signing keys in ~/.gnupg"
assert_lacks "$prof" "(literal \"$home/.codex/auth.json\")" "not even its own login file, which holds its refresh token"
assert_lacks "$(mac profile --policy="$P" --root="$root" --vendor=gemini)" "oauth_creds.json" \
  "nor gemini's"
# its session state is writable, or a real round cannot start; the rule
# comes after the vendor home's denial, which it would otherwise lose to
hq="$(printf '%s' "$home" | sed 's/[.^$|?*+()]/\\&/g')"
sline="$(grep -n '^(allow file-read\* file-write\* (regex' <<< "$prof" | head -1)"
assert_contains "$sline" "(regex #\"^$hq/\\.codex/sessions\")" "codex's round may write its session files"
assert_contains "$sline" "(regex #\"^$hq/\\.codex/history\\.jsonl\")" "and its history, with the siblings it is rewritten through"
assert_eq "1" "$([ -n "$sline" ] && [ "${sline%%:*}" -gt "$(grep -n "(subpath \"$home/.codex\")" <<< "$prof" | head -1 | cut -d: -f1)" ] && echo 1)" \
  "after the rule that keeps the rest of ~/.codex unreadable"
assert_lacks "$sline" "config.toml" "none of which is its settings"
assert_lacks "$(mac profile --policy="$P" --root="$root" --vendor=gemini)" "\\.codex/sessions" \
  "and another vendor's round is given none of it"
assert_contains "$prof" "(subpath \"$root/.claude\")" "the repository's .claude/ is out of reach"
assert_contains "$prof" "(subpath \"$root/.mcp.json\")" "and its .mcp.json"
assert_contains "$prof" "com.apple.coreservices.launchservicesd" "and no browser can be opened"
# a credential macOS serves over mach is not a path, so no file rule covers
# it: gh's token and git's osxkeychain helper live in the keychain
mline="$(grep '^(deny mach-lookup' <<< "$prof" | grep SecurityServer)"
assert_contains "$mline" '(global-name "com.apple.SecurityServer")' "the keychain is out of reach"
assert_contains "$mline" '(global-name-regex #"^com\.apple\.securityd")' "by either of its services"
assert_contains "$mline" '(global-name "com.apple.pasteboard.1")' "as is the pasteboard"
assert_contains "$mline" '(global-name-regex #"^com\.apple\.accountsd")' "the Internet Accounts store"
assert_contains "$mline" '(global-name "com.apple.GSSCred")' "and Kerberos tickets"
assert_lacks "$mline" "trustd" "while TLS trust evaluation stays reachable"
# the order is the rule: a later rule wins, so the floor comes after every allow
n_allow="$(grep -n '^(allow file-read\* (literal "/")' <<< "$prof" | cut -d: -f1)"
n_never="$(grep -n "$home/.ssh" <<< "$prof" | head -1 | cut -d: -f1)"
assert_eq "1" "$([ "$n_never" -gt "$n_allow" ] && echo 1)" "the never-readable rule comes after the toolchain's"
# claude's round (T-117): its own directory under /tmp, read and written;
# nothing of the operator's ~/.claude; and still no keychain
ctmp="$(cd /tmp && pwd -P)/claude-$(id -u)"
cprof="$(mac profile --policy="$P" --root="$root" --vendor=claude)"
assert_contains "$cprof" "(allow file-read* file-write* (subpath \"$ctmp\"))" \
  "claude's round may use the directory claude keeps under /tmp"
n_ctmp="$(grep -n "(subpath \"$ctmp\")" <<< "$cprof" | head -1 | cut -d: -f1)"
n_cnever="$(grep -n "$home/.ssh" <<< "$cprof" | head -1 | cut -d: -f1)"
assert_eq "1" "$([ -n "$n_ctmp" ] && [ -n "$n_cnever" ] && [ "$n_ctmp" -gt "$n_cnever" ] && echo 1)" \
  "after every deny it would lose to"
assert_lacks "$(mac profile --policy="$P" --root="$root" --vendor=codex)" "claude-$(id -u)" \
  "and no other vendor's round may"
assert_lacks "$cprof" "(regex #\"^$hq/\\.claude" "claude's round is given none of the operator's ~/.claude"
assert_lacks "$cprof" "(literal \"$home/.claude/.credentials.json\")" "not even its credentials file: fm reads that"
assert_contains "$(grep '^(deny mach-lookup' <<< "$cprof" | grep SecurityServer)" '(global-name "com.apple.SecurityServer")' \
  "the keychain itself is out of reach"
assert_eq "" "$(grep 'allow mach-lookup' <<< "$cprof" || true)" "nothing lets any mach service back in"
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
assert_eq "" "$(mac profile --policy="$P" --root="$root" | grep 'allow network' | grep -v '"localhost:' || true)" \
  "without a proxy nothing but loopback is reachable at all"

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
assert_contains "$args" "--tmpfs
/tmp
" "/tmp is a fresh one of the round's own"

# --- a worktree's git directory: read, never written (T-117) ----------------
# A worktree's .git is a file naming its git directory inside the
# repository's common .git, which holds every branch's objects and refs. A
# round reads it, so git log, diff and status work; it never writes it, so a
# round cannot commit, move a ref or rewrite another branch. Saving the
# branch is fm-worker.sh's alone (design 13.1), and its prompt says so.
mkdir -p "$t/repo.git/worktrees/wt" "$t/wt"
printf 'gitdir: %s\n' "$t/repo.git/worktrees/wt" > "$t/wt/.git"
printf '../..\n' > "$t/repo.git/worktrees/wt/commondir"
printf 'vendor: mock\n' > "$t/g.yaml"; fm_policy worker "" "$t/g.yaml" > "$t/g.json"
gprof="$(mac profile --policy="$t/g.json" --root="$t/wt" --tmp="$t/round-a")"
assert_contains "$(grep '^(allow file-read\* (literal "/")' <<< "$gprof")" "(subpath \"$t/repo.git\")" \
  "a worktree's common git directory is readable (macOS)"
assert_contains "$(grep '^(allow file-read\* (literal "/")' <<< "$gprof")" "(subpath \"$t/repo.git/worktrees/wt\")" \
  "and so is its own git directory"
assert_lacks "$(grep 'file-write' <<< "$gprof")" "$t/repo.git" "and neither is writable"
gargs="$(lin profile --policy="$t/g.json" --root="$t/wt" --tmp="$t/round-a")"
assert_contains "$gargs" "--ro-bind-try
$t/repo.git
$t/repo.git" "on Linux the common git directory is mounted read-only"
assert_lacks "$gargs" "--bind
$t/repo.git" "and never read-write"
n_tmpfs="$(grep -nx -- /tmp <<< "$args" | head -1 | cut -d: -f1)"
n_root="$(grep -nx -- "$root" <<< "$args" | head -1 | cut -d: -f1)"
assert_eq "1" "$([ -n "$n_tmpfs" ] && [ -n "$n_root" ] && [ "$n_tmpfs" -lt "$n_root" ] && echo 1)" \
  "mounted before the roots, so a root under /tmp is still bound over it"
assert_contains "$(lin profile --policy="$t/worker.json" --root="$root" --vendor=codex)" "--bind-try
$home/.codex/sessions
$home/.codex/sessions" "a vendor's session state is bound writable"
assert_lacks "$(lin profile --policy="$t/worker.json" --root="$root" --vendor=codex)" "$home/.codex/auth.json" \
  "and its login file is not bound at all"
assert_lacks "$(lin profile --policy="$t/worker.json" --root="$root" --vendor=claude)" "claude-$(id -u)" \
  "claude's directory under /tmp is made afresh in the round's own /tmp, not bound from the host's"
assert_contains "$args" "--unshare-net" "the network is a namespace of the round's own: no host listener, the board's included"
assert_lacks "$args" "proxy.sock" "and without a proxy it has no way out at all"

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
for name in ('GH_TOKEN', 'GITHUB_TOKEN', 'SSH_AUTH_SOCK', 'AWS_SECRET_ACCESS_KEY', 'HERDR_SOCKET', 'KEEP_ME',
             'FM_CREW_UNSANDBOXED', 'FM_ROUND_UNSANDBOXED', 'FM_IN_ROUND'):
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
printf 'TMPDIR=%s\nNO_PROXY=%s\n' "\$TMPDIR" "\${NO_PROXY:-}" > "$t/tmpdir"
python3 "$t/probe.py" "$t/ran"
exit 7
S
chmod +x "$t/cmd.sh"
# The process count is ps's, and the suite does not ask the machine running
# it for one: a reviewer's own sandbox may refuse ps. A stand-in answers.
mkdir -p "$t/psbin"
printf '#!/bin/sh\nprintf "1\\n2\\n3\\n"\n' > "$t/psbin/ps"
# and the listeners are netstat's, answered the way macOS's netstat does
cat > "$t/psbin/netstat" <<'S'
#!/bin/sh
printf 'Active Internet connections (including servers)\n'
printf 'Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)\n'
printf 'tcp4       0      0  127.0.0.1.5555         *.*                    LISTEN\n'
printf 'tcp4       0      0  10.0.0.2.52000         1.2.3.4.443            ESTABLISHED\n'
S
chmod +x "$t/psbin/ps" "$t/psbin/netstat"
# room to fork: the stand-in's count is 3, far below what the user runs
: > "$t/blocked"; rm -f "$t/ran" "$t/profile.sb" "$t/profile.path" "$t/started"
mkdir -p "$t/ctl"
pol worker 'policy:
  procs: 1000000
  cpu: 90
'
echo "the prompt" | GH_TOKEN=x GITHUB_TOKEN=x SSH_AUTH_SOCK=/x AWS_SECRET_ACCESS_KEY=x HERDR_SOCKET=/x KEEP_ME=kept \
  FM_CREW_UNSANDBOXED=1 FM_ROUND_UNSANDBOXED=1 \
  FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" PATH="$t/psbin:$PATH" \
  "$SB" run --policy="$t/worker.json" --root="$root" --blocked="$t/blocked" --started="$t/started" \
  --ctl="$t/ctl" -- "$t/cmd.sh"
assert_eq "7" "$?" "run exits with the command's own code"
assert_eq "started" "$(cat "$t/started" 2>/dev/null)" "and says, from inside the sandbox, that it got as far as the command"
# fm-sandbox's own files are under --ctl: not a fixed /tmp, which a
# confined caller cannot write, and in none of the round's write roots
ppath="$(cat "$t/profile.path" 2>/dev/null)"
assert_matches "$ppath" "^$t/ctl/fm-sb\\.[A-Za-z0-9]+/profile\$" "the profile is kept under --ctl"
assert_eq "" "$(ls -A "$t/ctl" 2>/dev/null)" "and removed when the round ends"
# the round's temp directory: its own, in the profile's write roots, and gone after
rtmp="$(sed -n 's/^TMPDIR=//p' "$t/tmpdir" 2>/dev/null)"
assert_ne "" "$rtmp" "the round is given a TMPDIR"
assert_ne "$callertmp" "$(cd "$rtmp" 2>/dev/null && pwd -P || echo "$rtmp")" "which is not the caller's shared one"
assert_contains "$(grep '^(allow file-write\*' "$t/profile.sb" 2>/dev/null)" "(subpath \"$rtmp\")" \
  "it is the round's write root for temp files"
assert_lacks "$(cat "$t/profile.sb" 2>/dev/null)" "(subpath \"$callertmp\")" "and the shared one is not"
assert_fail "test -e '$rtmp'" "and it is removed when the round ends"
assert_contains "$(cat "$t/tmpdir" 2>/dev/null)" "NO_PROXY=localhost,127.0.0.1,::1" \
  "loopback goes straight to the port, where the profile decides"
assert_contains "$(cat "$t/profile.sb" 2>/dev/null)" '(deny network-outbound (remote ip "localhost:4173"))' \
  "and the board's port is out of reach"
assert_contains "$(cat "$t/profile.sb" 2>/dev/null)" '(deny network-outbound (remote ip "localhost:5555"))' \
  "as is every port that was listening when the round started"
assert_ok "test -s '$t/profile.sb'" "the command ran behind the generated profile"
ran="$(cat "$t/ran" 2>/dev/null)"
assert_contains "$ran" "stdin=the prompt" "and was handed the prompt on stdin"
for name in GH_TOKEN GITHUB_TOKEN SSH_AUTH_SOCK AWS_SECRET_ACCESS_KEY HERDR_SOCKET FM_CREW_UNSANDBOXED FM_ROUND_UNSANDBOXED; do
  assert_contains "$ran" "$name=
" "$name never reaches the round"
done
assert_contains "$ran" "FM_IN_ROUND=1" "the round is marked as one, so fm inside it refuses the operator's hatch"
assert_contains "$ran" "KEEP_ME=kept" "while the rest of the environment does"
assert_contains "$ran" "proxy=set" "the round's traffic goes through its proxy"
assert_contains "$ran" "undeclared.example.org:443 HTTP/1.1 403" "which refuses an undeclared host"
assert_contains "$ran" "github.com:443 HTTP/1.1 403" "and GitHub"
assert_eq "undeclared.example.org
github.com" "$(cat "$t/blocked")" "and names each refused host once, for the round to report"
port="$(sed -n 's/.*localhost:\([0-9]*\).*/\1/p' "$t/profile.sb")"
assert_matches "$port" '^[0-9]+$' "the profile lets the round reach only that proxy's port"

# --- the profile's loopback denials are tried before the round (T-117) ------
# The canary on 2026-09-26 found a claude round on macOS reaching the live
# board on 127.0.0.1:4173 through a profile that denied the port. So before
# a round fm-sandbox connects, behind the round's own profile, to every port
# that was listening but the proxy's. A connection that gets through means
# the round's would: it drops to a profile with no loopback but the proxy,
# and refuses the round if even that one lets it through. The stand-in
# plays the kernel: LO_MODE=holds honours the per-port denials, tight only
# the profile without loopback, broken never runs the check, open none.
lsn="$t/listener.port"; rm -f "$lsn"
python3 - "$lsn" >/dev/null 2>&1 <<'PY' &
import os, socket, sys
s = socket.socket(); s.bind(('127.0.0.1', 0)); s.listen(8)
with open(sys.argv[1] + '.tmp', 'w') as f:
    f.write(str(s.getsockname()[1]))
os.rename(sys.argv[1] + '.tmp', sys.argv[1])
while True:
    c, _ = s.accept(); c.close()
PY
lsn_pid=$!
i=0; while [ ! -s "$lsn" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
lport="$(cat "$lsn" 2>/dev/null)"
assert_matches "$lport" '^[0-9]+$' "a listener older than the round is up"
mkdir -p "$t/lobin"; cp "$t/psbin/ps" "$t/lobin/ps"
cat > "$t/lobin/netstat" <<S
#!/bin/sh
printf 'Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)\n'
printf 'tcp4       0      0  127.0.0.1.$lport         *.*                    LISTEN\n'
S
chmod +x "$t/lobin/netstat"
cat > "$t/bin/sandbox-exec-lo" <<S
#!/usr/bin/env bash
[ "\$1" = -f ] || exit 99
prof="\$2"; shift 2
while IFS= read -r l; do printf '%s\n' "\$l"; done < "\$prof" > "$t/lo.profile.sb"
case " \$* " in
  *" fm-loopback-check "*)
    printf '%s\n' "\$*" >> "$t/lo.checks"
    wild=0; grep -qF '(allow network-outbound (remote ip "localhost:*"))' "\$prof" && wild=1
    case "\${LO_MODE:-open}:\$wild" in
      holds:*|tight:0) echo checked; exit 0 ;;
      broken:*) exit 1 ;;
    esac ;;
esac
exec "\$@"
S
printf '#!/bin/sh\nexit 7\n' > "$t/seven.sh"
chmod +x "$t/bin/sandbox-exec-lo" "$t/seven.sh"
pol worker 'vendor: mock
policy:
  procs: 1000000
'
lo_round() {   # lo_round <mode> -> exit code; stderr in $t/lo.err
  rm -f "$t/lo.profile.sb" "$t/lo.checks"
  LO_MODE="$1" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec-lo" PATH="$t/lobin:$PATH" \
    "$SB" run --policy="$t/worker.json" --root="$root" --ctl="$t/ctl" -- "$t/seven.sh" </dev/null 2>"$t/lo.err"
  echo $?
}
wild='(allow network-outbound (remote ip "localhost:*"))'
assert_eq "7" "$(lo_round holds)" "denials that hold: the round runs"
assert_contains "$(cat "$t/lo.checks" 2>/dev/null)" "fm-loopback-check $lport" \
  "after the profile was tried on the port that was listening"
assert_contains "$(cat "$t/lo.profile.sb" 2>/dev/null)" "$wild" "and it keeps loopback ports of its own"
# which loopback profile the round got is said every time, so the canary
# never infers it from a note that is not there (2026-09-26)
assert_contains "$(cat "$t/lo.err")" "loopback: the round's profile allows its proxy's port" \
  "which it says"
assert_contains "$(grep 'loopback: ' "$t/lo.err")" "closed to it: $lport" "naming the ports tried and closed to it"
lo_proxy="$(sed -n 's/.*allow network-outbound (remote ip "localhost:\([0-9][0-9]*\)").*/\1/p' "$t/lo.profile.sb" | tail -1)"
assert_lacks " $(cat "$t/lo.checks" 2>/dev/null) " " $lo_proxy " "the round's own proxy is not tried: it is meant to be reached"
assert_eq "7" "$(lo_round tight)" "denials that do not hold: the round still runs"
assert_contains "$(cat "$t/lo.err")" "do not hold" "and says so"
assert_contains "$(cat "$t/lo.err")" "$lport" "naming the port it could reach"
assert_contains "$(cat "$t/lo.err")" "loopback: the round's profile allows it no port but its proxy's" \
  "and that the profile it got allows no loopback but the proxy"
assert_lacks "$(cat "$t/lo.profile.sb" 2>/dev/null)" "$wild" "behind a profile with no loopback of its own"
assert_contains "$(cat "$t/lo.profile.sb" 2>/dev/null)" '(allow network-outbound (remote ip "localhost:' \
  "but its proxy"
assert_eq "2" "$(grep -c "fm-loopback-check" "$t/lo.checks" 2>/dev/null)" "which was tried as well"
assert_eq "70" "$(lo_round open)" "a profile that lets a listener through even without loopback refuses the round"
assert_contains "$(cat "$t/lo.err")" "refusing the round" "and says so"
assert_eq "7" "$(lo_round broken)" "a check that could not run behind the profile: the round runs"
assert_contains "$(cat "$t/lo.err")" "cannot try the profile's loopback denials" "and says so"
assert_contains "$(cat "$t/lo.err")" "loopback: the round's profile allows it no port but its proxy's" \
  "and which profile it got"
assert_lacks "$(cat "$t/lo.profile.sb" 2>/dev/null)" "$wild" "with no loopback but its proxy"
kill "$lsn_pid" 2>/dev/null; wait "$lsn_pid" 2>/dev/null
# the policy the cases below were written against
pol worker 'policy:
  procs: 1000000
  cpu: 90
'

# Linux: the same scrub, behind bwrap, in a network namespace of the
# round's own whose only way out is the same proxy - so a refused host is
# named there too. The stand-in shares the host's network; what it proves
# is that the round's traffic reaches the proxy through the socket bwrap
# binds in, and the proxy names what it refused.
rm -f "$t/ran" "$t/bwrap.args"; : > "$t/blocked"
echo "the prompt" | GH_TOKEN=x FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$t/bin/bwrap" PATH="$t/psbin:$PATH" \
  "$SB" run --policy="$t/worker.json" --root="$root" --blocked="$t/blocked" --ctl="$t/ctl" -- "$t/cmd.sh"
assert_eq "7" "$?" "under bwrap too"
assert_ok "test -s '$t/bwrap.args'" "the command ran behind bwrap"
bargs="$(cat "$t/bwrap.args" 2>/dev/null)"
assert_contains "$bargs" "--unshare-net" "with no network of the host's"
sockp="$(grep -m1 '/proxy\.sock$' <<< "$bargs")"
assert_matches "$sockp" '/fm-sb\.[A-Za-z0-9]+/proxy\.sock$' "but the proxy's socket"
assert_matches "$sockp" "^$t/ctl/fm-sb\\." "which is under --ctl, not a fixed /tmp"
rtmp_l="$(sed -n 's/^TMPDIR=//p' "$t/tmpdir" 2>/dev/null)"
case "$sockp" in "$root"/*|"${rtmp_l:-/nonexistent}"/*) under=yes ;; *) under=no ;; esac
assert_eq "no" "$under" "and in neither the root nor the round's temp directory"
assert_contains "$bargs" "--bind
$sockp
$sockp" "bound into the round"
lran="$(cat "$t/ran" 2>/dev/null)"
assert_contains "$lran" "GH_TOKEN=
" "with the same scrub"
assert_contains "$lran" "FM_IN_ROUND=1" "and the same mark"
assert_contains "$lran" "proxy=set" "the round's traffic goes to the proxy, served on its own loopback"
assert_contains "$lran" "undeclared.example.org:443 HTTP/1.1 403" "which refuses an undeclared host"
assert_contains "$lran" "github.com:443 HTTP/1.1 403" "and GitHub"
assert_eq "undeclared.example.org
github.com" "$(cat "$t/blocked")" "and names each refused host once, on Linux as on macOS"

# Without --ctl the caller's TMPDIR holds them, never a fixed /tmp; and a
# TMPDIR that is itself a write root - an adapter's round temp - is refused
# rather than handing the round the profile and the proxy's socket.
mkdir -p "$t/caller-tmp" "$t/round-c"
rm -f "$t/bwrap.args"
TMPDIR="$t/caller-tmp" FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$t/bin/bwrap" PATH="$t/psbin:$PATH" \
  "$SB" run --policy="$t/worker.json" --root="$root" -- "$t/cmd.sh" </dev/null >/dev/null 2>&1
assert_eq "7" "$?" "without --ctl the round still runs"
assert_matches "$(grep -m1 '/proxy\.sock$' "$t/bwrap.args" 2>/dev/null)" "^$t/caller-tmp/fm-sb\\." \
  "with the sandbox's own files under the caller's TMPDIR"
for mode_os in darwin linux; do
  rm -f "$t/tmpdir"
  tool="$t/bin/sandbox-exec"; [ "$mode_os" = linux ] && tool="$t/bin/bwrap"
  out="$(TMPDIR="$t/round-c" FM_SANDBOX_OS="$mode_os" FM_SANDBOX_TOOL="$tool" PATH="$t/psbin:$PATH" \
    "$SB" run --policy="$t/worker.json" --root="$root" --tmp="$t/round-c" -- "$t/cmd.sh" </dev/null 2>&1)"
  assert_eq "70" "$?" "$mode_os: a TMPDIR that is the round's own temp is refused as the sandbox's directory"
  assert_contains "$out" "which the round may write" "and says why ($mode_os)"
  assert_fail "test -e '$t/tmpdir'" "and the command never starts ($mode_os)"
  assert_eq "" "$(ls -A "$t/round-c" 2>/dev/null)" "and nothing is left in it ($mode_os)"
done

# --- the vendor's login (T-117) -----------------------------------------------
# On macOS claude's login is in the keychain, with gh's token and git's,
# and the round reaches none of it. fm reads the vendor's own item outside
# the round - that item and no other - and hands it in as a variable:
# claude's access token as CLAUDE_CODE_OAUTH_TOKEN, and the crew's Cursor
# API key as CURSOR_API_KEY. The operator's keychain here is a stand-in: it
# holds claude's login, the crew's Cursor key, cursor-agent's own `agent
# login` items and gh's token, and records every item asked for.
mkdir -p "$t/kc"
future=$(( ($(date +%s) + 3600) * 1000 ))
printf '{"claudeAiOauth":{"accessToken":"at-claude","refreshToken":"rt-claude-secret","expiresAt":%s}}' \
  "$future" > "$t/kc/claude"
cat > "$t/kc/security" <<S
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$t/kc/calls"
s=''; while [ \$# -gt 0 ]; do [ "\$1" = -s ] && s="\${2-}"; shift; done
case "\$s" in
  'Claude Code-credentials') cat "$t/kc/claude" ;;
  firstmate-cursor-api-key) printf 'key-cursor-crew\n' ;;
  cursor-access-token) printf 'at-cursor\n' ;;
  cursor-refresh-token) printf 'rt-cursor-secret\n' ;;
  gh:github.com) printf 'gho_ghsecret\n' ;;
  *) echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44 ;;
esac
S
chmod +x "$t/kc/security"
# What the round sees of its login. It asks no keychain itself: the
# stand-in sandbox enforces nothing, and on a Mac the security(1) it would
# find is the real one, holding the real tokens. That the round cannot
# reach the keychain is the profile's mach-lookup denial, asserted above.
cat > "$t/login.sh" <<'S'
#!/usr/bin/env bash
out="$1"
{ printf 'token=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  printf 'cursorkey=%s\n' "${CURSOR_API_KEY:-}"
  printf 'path=%s\n' "$PATH"
  # every login copy fm put in the round's own temp directory, and what it holds
  find "${TMPDIR:-/nonexistent}" -type f -name '*.json' -print -exec cat {} \; 2>/dev/null; echo
  env
} > "$out"
S
chmod +x "$t/login.sh"
# a PATH holding only what the command needs
lpath="$t/psbin:/usr/bin:/bin"
command -v python3 >/dev/null && lpath="$t/psbin:$(dirname "$(command -v python3)"):/usr/bin:/bin"
kc() {   # kc <mode> <os> <vendor> [env...] -> exit code; the round's view in $t/login.out
  local mode="$1" os_="$2" v="$3" tool="$t/bin/sandbox-exec"
  shift 3
  [ "$os_" = linux ] && tool="$t/bin/bwrap"
  rm -f "$t/login.out" "$t/profile.sb" "$t/kc/calls"; echo stale > "$t/started"
  env FM_SANDBOX_OS="$os_" FM_SANDBOX_TOOL="$tool" FM_KEYCHAIN_TOOL="$t/kc/security" PATH="$lpath" "$@" \
    "$SB" "$mode" --policy="$t/worker.json" --root="$root" --vendor="$v" --ctl="$t/ctl" --started="$t/started" \
    -- "$t/login.sh" "$t/login.out" </dev/null >/dev/null 2>"$t/login.err"
  echo $?
}
pol worker 'vendor: mock
'
# claude: its own item's access token, as a variable, and never the refresh token
assert_eq "0" "$(kc run darwin claude)" "claude's round starts on macOS with the operator's own login"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "token=at-claude" "handed in as CLAUDE_CODE_OAUTH_TOKEN, the access token only"
assert_lacks "$lo" "rt-claude-secret" "the refresh token never enters the round"
assert_eq "find-generic-password -s Claude Code-credentials -a $me -w" "$(cat "$t/kc/calls" 2>/dev/null)" \
  "and fm read one item of the keychain: claude's"
assert_eq "" "$(ls -A "$t/ctl" 2>/dev/null)" "nothing of the login is left behind"
# cursor-agent (round 6): the canary on 2026-09-26 showed cursor-agent never
# asking a security(1) on its PATH for `agent login`'s token - it reads the
# keychain through the API, which no round reaches - so its round signs in
# with the crew's Cursor API key, read by fm from fm's own item and handed
# in as CURSOR_API_KEY. cursor's own login items, their refresh token and
# gh's token are never read, and nothing on the round's PATH or in its
# profile answers for the keychain.
assert_eq "0" "$(kc run darwin cursor-agent)" "cursor-agent's round starts on macOS with the crew's Cursor API key"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "cursorkey=key-cursor-crew" "handed in as CURSOR_API_KEY"
assert_lacks "$lo" "at-cursor" "never agent login's own access token"
assert_lacks "$lo" "rt-cursor-secret" "nor its refresh token"
assert_lacks "$lo" "gho_ghsecret" "nor gh's token"
assert_eq "find-generic-password -s firstmate-cursor-api-key -a $me -w" "$(cat "$t/kc/calls" 2>/dev/null)" \
  "fm read one item of the keychain: the crew's key, never cursor's own login nor gh's"
assert_lacks "$(sed -n 's/^path=//p' <<< "$lo")" "$t/ctl" "nothing of fm's is put on the round's PATH"
# with no --tmp the round's own temp directory is fm-sb.*/tmp, and that one
# is the round's; nothing else of fm-sandbox's directory may be named
assert_eq "" "$(grep -o "\"$t/ctl/fm-sb\.[^\"]*\"" "$t/profile.sb" 2>/dev/null | grep -v '/tmp"$')" \
  "nor made readable in its profile"
assert_contains "$(cat "$t/profile.sb" 2>/dev/null)" "(subpath \"$t/ctl/fm-sb." \
  "(the round's own temp directory is the one path under it the profile names)"
assert_contains "$(grep '^(deny mach-lookup' "$t/profile.sb" 2>/dev/null | grep SecurityServer)" \
  '(global-name "com.apple.SecurityServer")' "and the keychain stays out of its reach"
assert_eq "" "$(ls -A "$t/ctl" 2>/dev/null)" "and nothing of the login is left behind"
assert_eq "0" "$(kc run darwin cursor-agent CURSOR_API_KEY=key-from-env)" "a CURSOR_API_KEY already set is used"
assert_contains "$(cat "$t/login.out" 2>/dev/null)" "cursorkey=key-from-env" "as it is"
assert_eq "" "$(cat "$t/kc/calls" 2>/dev/null)" "and the keychain is not read for it"
# a login already in the operator's environment is used as it is
assert_eq "0" "$(kc run darwin claude CLAUDE_CODE_OAUTH_TOKEN=from-env)" "a CLAUDE_CODE_OAUTH_TOKEN already set is used"
assert_contains "$(cat "$t/login.out" 2>/dev/null)" "token=from-env" "as it is"
assert_eq "" "$(cat "$t/kc/calls" 2>/dev/null)" "and the keychain is not read"
# expired, or no login at all: refused before the sandbox starts, which the
# adapter counts as the vendor unavailable
past=$(( ($(date +%s) - 60) * 1000 ))
cp "$t/kc/claude" "$t/kc/claude.good"
printf '{"claudeAiOauth":{"accessToken":"at-old","refreshToken":"rt","expiresAt":%s}}' "$past" > "$t/kc/claude"
assert_eq "77" "$(kc run darwin claude)" "an expired claude login refuses the round"
assert_contains "$(cat "$t/login.err")" "has expired" "and says so"
assert_fail "test -e '$t/login.out'" "and the command never starts"
assert_eq "" "$(cat "$t/started" 2>/dev/null)" "and --started says it did not"
cp "$t/kc/claude.good" "$t/kc/claude"
# a home with nothing in it, so no login file of this runner's is found
mkdir -p "$t/nohome"
( export HOME="$t/nohome"
  pol worker 'vendor: mock
'
  cp "$t/worker.json" "$t/nohome.json" )
for v in claude codex cursor-agent gemini; do
  assert_eq "77" "$(kc run darwin "$v" FM_KEYCHAIN_TOOL="$t/no-such-security")" "$v with no login anywhere refuses the round"
  assert_contains "$(cat "$t/login.err")" "$v is not logged in" "and says so"
  assert_fail "test -e '$t/login.out'" "and the command never starts ($v)"
done
# the one step the operator takes for cursor-agent is said with the refusal
assert_eq "77" "$(kc run darwin cursor-agent FM_KEYCHAIN_TOOL="$t/no-such-security")" "no crew Cursor key refuses cursor-agent's round"
assert_contains "$(cat "$t/login.err")" "security add-generic-password -s firstmate-cursor-api-key" \
  "and says how to keep one for the crew"
# Linux: no keychain; claude's credentials file, read by fm, not the round
mkdir -p "$t/lhome/.claude" "$t/lhome/.codex" "$t/lhome/.gemini" "$t/lhome/.config/cursor" "$t/lhome/.config/firstmate"
cp "$t/kc/claude" "$t/lhome/.claude/.credentials.json"
# codex's and gemini's login files, each with its refresh token; agent
# login's file, which cursor-agent's round never reads; and the crew's
# Cursor key in fm's own file
printf '{"OPENAI_API_KEY":null,"tokens":{"id_token":"id-codex","access_token":"at-codex","refresh_token":"rt-codex-secret","account_id":"acct"},"last_refresh":"2026-09-26T00:00:00Z"}' \
  > "$t/lhome/.codex/auth.json"
printf '{"access_token":"at-gemini","refresh_token":"rt-gemini-secret","token_type":"Bearer","expiry_date":%s}' \
  "$future" > "$t/lhome/.gemini/oauth_creds.json"
printf '{"accessToken":"at-cursor-file","refreshToken":"rt-cursor-secret"}' > "$t/lhome/.config/cursor/auth.json"
printf 'key-cursor-file\n' > "$t/lhome/.config/firstmate/cursor-api-key"
chmod 644 "$t/lhome/.config/firstmate/cursor-api-key"
( export HOME="$t/lhome"
  pol worker 'vendor: mock
' )
assert_eq "0" "$(kc run linux claude)" "on Linux claude's round starts with its credentials file's login"
assert_contains "$(cat "$t/login.out" 2>/dev/null)" "token=at-claude" "its access token handed in the same way"
assert_eq "" "$(cat "$t/kc/calls" 2>/dev/null)" "and no keychain asked"
assert_lacks "$(cat "$t/bwrap.args" 2>/dev/null)" "$t/lhome/.claude" "and the file itself not mounted in the round"
# cursor-agent off macOS: the crew's key from fm's file, which must be the
# operator's alone; agent login's own file is never read
assert_eq "77" "$(kc run linux cursor-agent)" "a crew Cursor key file others can read refuses the round"
assert_contains "$(cat "$t/login.err")" "chmod 600" "and says what to do"
assert_fail "test -e '$t/login.out'" "and the command never starts"
chmod 600 "$t/lhome/.config/firstmate/cursor-api-key"
assert_eq "0" "$(kc run linux cursor-agent)" "with the file the operator's alone, cursor-agent's round starts on Linux"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "cursorkey=key-cursor-file" "the key handed in as CURSOR_API_KEY"
assert_lacks "$lo" "at-cursor-file" "never agent login's token"
assert_lacks "$lo" "rt-cursor-secret" "nor its refresh token"
assert_lacks "$(cat "$t/bwrap.args" 2>/dev/null)" "$t/lhome/.config" "and neither file is bound in the round"
# codex and gemini (T-117 round 2): the login file holds a refresh token,
# so the round never reads it. fm does, and writes a copy with the refresh
# token emptied into the round's own temp directory, where the adapter
# points the CLI. A round that could refresh the operator's login, but not
# write the result back, would spend it.
for lf in "codex linux at-codex rt-codex-secret codex-home/auth.json .codex/auth.json" \
          "codex darwin at-codex rt-codex-secret codex-home/auth.json .codex/auth.json" \
          "gemini linux at-gemini rt-gemini-secret gemini-home/.gemini/oauth_creds.json .gemini/oauth_creds.json" \
          "gemini darwin at-gemini rt-gemini-secret gemini-home/.gemini/oauth_creds.json .gemini/oauth_creds.json"; do
  read -r lf_v lf_os lf_at lf_rt lf_copy lf_file <<< "$lf"
  rm -f "$t/bwrap.args"
  assert_eq "0" "$(kc run "$lf_os" "$lf_v")" "$lf_v's round starts on $lf_os with its login file's login"
  lo="$(cat "$t/login.out" 2>/dev/null)"
  assert_matches "$(grep -m1 "/$lf_copy\$" <<< "$lo")" "^$t/ctl/fm-sb\\.[A-Za-z0-9]+/tmp/$lf_copy\$" \
    "a copy in the round's own temp directory ($lf_v, $lf_os)"
  assert_contains "$lo" "$lf_at" "holding the access token ($lf_v, $lf_os)"
  assert_lacks "$lo" "$lf_rt" "and never the refresh token ($lf_v, $lf_os)"
  assert_eq "" "$(cat "$t/kc/calls" 2>/dev/null)" "no keychain item read for it ($lf_v, $lf_os)"
  assert_lacks "$(grep -v '^(deny' "$t/profile.sb" "$t/bwrap.args" 2>/dev/null)" "$t/lhome/$lf_file" \
    "and the operator's file is neither readable nor bound in the round ($lf_v, $lf_os)"
done
assert_contains "$(cat "$t/lhome/.codex/auth.json")" "rt-codex-secret" "the operator's own file is left as it was"
# the copy is the round's, not a trace of the operator's: gone with the round
assert_eq "" "$(ls -A "$t/ctl" 2>/dev/null)" "and the copy goes with the round"
# a refresh token under a name the policy does not drop is refused, not handed in
cp "$t/lhome/.gemini/oauth_creds.json" "$t/gemini.good"
printf '{"access_token":"at-gemini","refresh_token":"","refreshToken":"rt-moved-secret","expiry_date":%s}' \
  "$future" > "$t/lhome/.gemini/oauth_creds.json"
assert_eq "65" "$(kc run linux gemini)" "a login file still holding a refresh token under another name refuses the round"
assert_contains "$(cat "$t/login.err")" "refreshToken" "and names the field"
assert_fail "test -e '$t/login.out'" "and the command never starts"
# an expired gemini login is no login: it is refreshed outside a round or not at all
printf '{"access_token":"at-gemini","refresh_token":"rt","expiry_date":%s}' "$past" > "$t/lhome/.gemini/oauth_creds.json"
assert_eq "77" "$(kc run linux gemini)" "an expired gemini login refuses the round"
assert_contains "$(cat "$t/login.err")" "has expired" "and says so"
cp "$t/gemini.good" "$t/lhome/.gemini/oauth_creds.json"
# an API key already in the operator's environment is used as it is, and no file read
assert_eq "0" "$(kc run linux codex CODEX_API_KEY=from-env)" "a CODEX_API_KEY already set is used"
assert_lacks "$(cat "$t/login.out" 2>/dev/null)" "at-codex" "and codex's login file is not copied in"
# login-source: where a login would come from, never the login
pol worker 'vendor: mock
'
src="$(FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" FM_KEYCHAIN_TOOL="$t/kc/security" \
  "$SB" login-source --policy="$t/worker.json" --vendor=claude 2>&1)"
assert_eq "keychain:Claude Code-credentials" "$src" "login-source names where claude's login is"
assert_lacks "$src" "at-claude" "and never prints it"
FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" FM_KEYCHAIN_TOOL="$t/no-such-security" \
  "$SB" login-source --policy="$t/nohome.json" --vendor=cursor-agent >/dev/null 2>&1
assert_eq "77" "$?" "and says 77 when the operator is not logged in"
# plain, the operator's hatch: every vendor still gets its login
assert_eq "0" "$(kc plain darwin claude)" "under the hatch claude's round starts"
assert_contains "$(cat "$t/login.out" 2>/dev/null)" "token=at-claude" "with its login handed in"
assert_contains "$(cat "$t/login.out" 2>/dev/null)" "FM_IN_ROUND=1" "and marked a round"
assert_eq "0" "$(kc plain darwin cursor-agent)" "and cursor-agent's"
assert_contains "$(cat "$t/login.out" 2>/dev/null)" "cursorkey=key-cursor-crew" "with the crew's Cursor key"

# The limits, as fm-sandbox set them (SANDBOX_ROUND_LIMITS), and as the kernel
# reports them back. Expected values are the policy's and the stand-in's,
# not the host's: macOS may enforce a lower process limit than the one it
# was given, so only fm's own number is compared exactly. The command and
# the stand-in are builtins only, since 3 + 50 is far below what the user
# already runs and a fork would fail.
pol worker 'policy:
  procs: 50
  cpu: 90
'
# bash, not sh: dash, Ubuntu's sh, has no `ulimit -u`
limits_cmd=(/bin/bash -c 'printf "%s\n" "$SANDBOX_ROUND_LIMITS" > "$1"; ulimit -u >> "$1"; ulimit -t >> "$1"' sh)
for mode in run plain; do
  rm -f "$t/lim"
  FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" PATH="$t/psbin:$PATH" \
    "$SB" "$mode" --policy="$t/worker.json" --root="$root" -- "${limits_cmd[@]}" "$t/lim" </dev/null
  assert_eq "procs=53 cpu=90" "$(head -1 "$t/lim" 2>/dev/null)" \
    "$mode: the process limit is the policy's 50 more than the user runs, and the CPU limit the policy's"
  lu="$(sed -n 2p "$t/lim" 2>/dev/null)"
  assert_eq "1" "$([ -n "$lu" ] && [ "$lu" != unlimited ] && [ "$lu" -le 53 ] && echo 1)" \
    "$mode: and the kernel holds the round to it, or below ($lu)"
  assert_eq "90" "$(sed -n 3p "$t/lim" 2>/dev/null)" "$mode: CPU seconds as the policy says"
done
# clamped to the hard limit, which this test sets itself
pol worker 'policy:
  procs: 1000000
  cpu: 90
'
if (ulimit -u 2000) 2>/dev/null; then
  rm -f "$t/lim"
  ( ulimit -u 2000
    PATH="$t/psbin:$PATH" "$SB" plain --policy="$t/worker.json" -- "${limits_cmd[@]}" "$t/lim" </dev/null )
  assert_eq "procs=2000 cpu=90" "$(head -1 "$t/lim" 2>/dev/null)" "a limit above the hard one is clamped to it"
else
  printf '    %-52s%s\n' "a limit above the hard one is clamped to it" "skipped: this host's hard limit is below 2000"
fi

# no sandbox: the round does not run unconfined
rm -f "$t/ran"
FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/no-such-tool" \
  "$SB" run --policy="$t/worker.json" --root="$root" -- "$t/cmd.sh" </dev/null >/dev/null 2>&1
assert_eq "69" "$?" "run with no sandbox on the host refuses"
assert_fail "test -e '$t/ran'" "and the command never starts"

# plain: the operator's hatch - the scrub, the limits and the login only
rm -f "$t/ran"
echo "the prompt" | GH_TOKEN=x KEEP_ME=kept FM_CREW_UNSANDBOXED=1 PATH="$t/psbin:$PATH" \
  "$SB" plain --policy="$t/worker.json" --tmp="$t/round-a" -- \
  bash -c 'printf "%s\n" "$SANDBOX_ROUND_LIMITS"; printf "GH_TOKEN=%s KEEP_ME=%s TMPDIR=%s HATCH=%s IN=%s\n" "${GH_TOKEN:-}" "${KEEP_ME:-}" "$TMPDIR" "${FM_CREW_UNSANDBOXED:-}" "${FM_IN_ROUND:-}"; cat' \
  > "$t/plain" 2>&1
assert_matches "$(head -1 "$t/plain")" '^procs=[0-9]+ cpu=90$' "plain sets the limits"
assert_eq "GH_TOKEN= KEEP_ME=kept TMPDIR=$t/round-a HATCH= IN=1
the prompt" "$(tail -n +2 "$t/plain")" "scrubs the environment and the hatch, marks the round, gives it its own TMPDIR and hands on the prompt"

# --started: a sandbox that fails before the command leaves it empty, so
# the adapter can tell the launcher's exit code from the command's
cat > "$t/bin/broken-sandbox" <<'S'
#!/usr/bin/env bash
echo "sandbox-exec: sandbox_apply: Operation not permitted" >&2
exit 71
S
chmod +x "$t/bin/broken-sandbox"
rm -f "$t/ran" "$t/tmpdir"; echo stale > "$t/started"
FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/broken-sandbox" PATH="$t/psbin:$PATH" \
  "$SB" run --policy="$t/worker.json" --root="$root" --started="$t/started" -- "$t/cmd.sh" </dev/null >/dev/null 2>&1
assert_eq "71" "$?" "a sandbox that cannot start exits with its own code"
assert_eq "" "$(cat "$t/started" 2>/dev/null)" "and --started stays empty, a stale line cleared"
assert_fail "test -e '$t/tmpdir'" "and the command never ran"

# Every exit before the command empties a stale --started, not only the
# ones after the sandbox is built: the file is emptied right after the
# options. A python3 stand-in fails one of fm-sandbox's own steps.
mkdir -p "$t/pybin"
real_py="$(command -v python3)"
cat > "$t/pybin/python3" <<S
#!/usr/bin/env bash
[ "\${3:-}" = "\${FAIL_PY:-}" ] && exit 1
exec "$real_py" "\$@"
S
chmod +x "$t/pybin/python3"
stale_case() {   # stale_case <want> <why> <env...> -- <fm-sandbox args...>
  local want="$1" why="$2" envs=()
  shift 2
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rm -f "$t/tmpdir"; echo stale > "$t/started"
  env ${envs[@]+"${envs[@]}"} "$SB" "$@" --started="$t/started" -- "$t/cmd.sh" </dev/null >/dev/null 2>&1
  assert_eq "$want" "$?" "$why exits $want"
  assert_eq "" "$(cat "$t/started" 2>/dev/null)" "and a stale --started is emptied ($why)"
  assert_fail "test -e '$t/tmpdir'" "and the command never ran ($why)"
}
stale_case 69 "no sandbox tool" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/no-such-tool" \
  -- run --policy="$t/worker.json" --root="$root" --ctl="$t/ctl"
stale_case 65 "a policy that does not read" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" \
  PATH="$t/psbin:$PATH" -- run --policy="$t/no-such-policy.json" --root="$root" --ctl="$t/ctl"
stale_case 70 "the proxy failing to start" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" \
  FAIL_PY=proxy PATH="$t/pybin:$t/psbin:$PATH" -- run --policy="$t/worker.json" --root="$root" --ctl="$t/ctl"
stale_case 65 "the profile failing" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" \
  FAIL_PY=profile PATH="$t/pybin:$t/psbin:$PATH" -- run --policy="$t/worker.json" --root="$root" --ctl="$t/ctl"
stale_case 70 "an unwritable sandbox directory" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" \
  PATH="$t/psbin:$PATH" -- run --policy="$t/worker.json" --root="$root" --ctl="$t/no-such-ctl"
stale_case 71 "a broken sandbox binary" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/broken-sandbox" \
  PATH="$t/psbin:$PATH" -- run --policy="$t/worker.json" --root="$root" --ctl="$t/ctl"
stale_case 77 "a vendor not logged in" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" \
  FM_KEYCHAIN_TOOL="$t/no-such-security" HOME="$t/nohome" PATH="$t/psbin:$PATH" \
  -- run --policy="$t/nohome.json" --root="$root" --ctl="$t/ctl" --vendor=claude

# A process count that cannot be taken refuses the round. Guessing 0 set
# the limit to the policy's bare count, below what the user already runs,
# and the round could not fork at all.
printf '#!/bin/sh\necho "ps: operation not permitted" >&2\nexit 1\n' > "$t/psbin/ps"
printf '#!/bin/sh\nexit 0\n' > "$t/psbin/ps-empty"
# a new file, not a rewrite of the executable ps: without its own mode bit
# PATH walks past it to the machine's ps, and the case tests nothing
chmod +x "$t/psbin/ps-empty"
for why in failing empty; do
  [ "$why" = empty ] && mv "$t/psbin/ps-empty" "$t/psbin/ps"
  for mode in run plain; do
    rm -f "$t/ran" "$t/tmpdir"; echo stale > "$t/started"
    out="$(FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" PATH="$t/psbin:$PATH" \
      "$SB" "$mode" --policy="$t/worker.json" --root="$root" --ctl="$t/ctl" --started="$t/started" \
      -- "$t/cmd.sh" </dev/null 2>&1)"
    assert_eq "70" "$?" "$mode refuses the round when ps is $why"
    assert_contains "$out" "cannot count this user's processes" "and says why"
    assert_fail "test -e '$t/tmpdir'" "and the command never starts ($mode, ps $why)"
    assert_eq "" "$(cat "$t/started" 2>/dev/null)" "and a stale --started is emptied ($mode, ps $why)"
  done
done

rm -rf "$t"
finish
