#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
# shellcheck source=tests/lib/sandbox-os.sh
. "$ROOT/tests/lib/sandbox-os.sh"
# --- fm-sandbox.sh: what the OS layer covers ----------------------------------

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
prof="$(mac profile --policy="$P" --root="$root" --tmp="$t/round-a" --vendor=codex --proxy-port=4242 \
  --listening=4242,5000 --write="$t/attempt")"
assert_contains "$prof" "(deny network*)" "the profile denies the network"
# loopback: the round's own ports, and neither the board nor what was already listening
assert_contains "$prof" '(allow network-bind (local ip "localhost:*"))' "a round may open loopback ports of its own"
assert_contains "$prof" '(allow network-outbound (remote ip "localhost:*"))' "and connect to them"
assert_contains "$prof" '(deny network-outbound (remote ip "localhost:4173"))' "but never to the board's port"
assert_contains "$prof" '(deny network-outbound (remote ip "localhost:5000"))' "nor to a listener older than the round"
# T-153: nor bound or accepted on, which the outbound deny alone left open -
# a suite's fixture board took the captain's 127.0.0.1:4173 while it was down
assert_contains "$prof" '(deny network-bind network-inbound (local ip "localhost:4173"))' \
  "and the board's port can be neither bound nor accepted on"
assert_contains "$prof" '(deny network-bind network-inbound (local ip "localhost:5000"))' \
  "nor a listener's older than the round"
n_bind="$(grep -n 'allow network-bind (local ip "localhost:\*")' <<< "$prof" | cut -d: -f1)"
n_bdeny="$(grep -n 'deny network-bind network-inbound (local ip "localhost:4173")' <<< "$prof" | cut -d: -f1)"
assert_eq "1" "$([ -n "$n_bind" ] && [ -n "$n_bdeny" ] && [ "$n_bdeny" -gt "$n_bind" ] && echo 1)" \
  "the deny follows the loopback allow it carves the port out of"
assert_eq "" "$(grep 'allow network' <<< "$prof" | grep -v '"localhost:' || true)" \
  "and nothing but loopback is allowed directly"
n_deny="$(grep -n 'deny network-outbound (remote ip "localhost:5000")' <<< "$prof" | cut -d: -f1)"
n_proxy="$(grep -n 'allow network-outbound (remote ip "localhost:4242")' <<< "$prof" | tail -1 | cut -d: -f1)"
assert_eq "1" "$([ -n "$n_deny" ] && [ -n "$n_proxy" ] && [ "$n_proxy" -gt "$n_deny" ] && echo 1)" \
  "the round's own proxy stays reachable though it was listening first"
FM_PORT=4999 mac profile --policy="$P" --root="$root" --proxy-port=4242 --listening= > "$t/p2"
assert_contains "$(cat "$t/p2")" '(remote ip "localhost:4999")' "the board's port is FM_PORT when that is set"
assert_contains "$(cat "$t/p2")" '(deny network-bind network-inbound (local ip "localhost:4999"))' \
  "for binding as for connecting"
unknown="$(mac profile --policy="$P" --root="$root" --proxy-port=4242 --listening=unknown)"
assert_eq '(allow network-outbound (remote ip "localhost:4242"))' "$(grep 'allow network' <<< "$unknown")" \
  "with the listeners unknown, the proxy is the only port reachable"
assert_contains "$unknown" '(deny network-bind network-inbound (local ip "localhost:4173"))' \
  "and the board's port is denied by name there too, the listeners unknown (T-153)"
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

# --- the tree's own .git may not be deleted or rewritten from inside (T-128) --
# A round may write anywhere in its own root, including deleting the whole
# thing - that is what a worktree write root means. But the one path that
# would sever this tree's link to git, a worktree's .git link file, is denied
# write no matter what: whatever else a round destroys, git run in this tree
# still works, and fm-worker.sh's mirror restores the rest.
own_prof="$(mac profile --policy="$t/g.json" --root="$t/wt" --tmp="$t/round-a")"
# an exact literal, not a regex prefix (own_git_sbpl in bin/fm-sandbox.sh,
# T-128 review round 1): a worktree's .git is one file, and (literal ...)
# matches that path and nothing that merely starts with it, unlike the
# prefix() regex used elsewhere for a vendor's rewritten state files, which
# would also deny .gitignore, .gitattributes, .gitmodules and everything
# under .github/
assert_contains "$own_prof" "(deny file-write* (literal \"$t/wt/.git\"))" \
  "macOS denies writing the worktree's own .git (an exact literal deny, after the write-roots allow)"
n_allow="$(grep -n "(allow file-write\* .*subpath \"$t/wt\"" <<< "$own_prof" | tail -1 | cut -d: -f1)"
n_git_deny="$(grep -n "(deny file-write\* (literal \"$t/wt/.git\"))" <<< "$own_prof" | tail -1 | cut -d: -f1)"
assert_eq "1" "$([ -n "$n_allow" ] && [ -n "$n_git_deny" ] && [ "$n_git_deny" -gt "$n_allow" ] && echo 1)" \
  "the .git deny comes after the write-roots allow, so it is the one that applies (SBPL is last-match)"
own_args="$(lin profile --policy="$t/g.json" --root="$t/wt" --tmp="$t/round-a")"
assert_contains "$own_args" "--ro-bind
$t/wt/.git
$t/wt/.git" "on Linux the same path is bound read-only, over the round's own read-write root"
# a clone (run-mode review), whose .git is a whole directory holding the
# object database and the index: no deny rule at all (T-128 review round 4).
# Denying writes there as a subpath would also deny ordinary git commands
# (checkout, add, commit) that a review round runs routinely, since those
# write inside .git itself, not just delete or rewrite it. A clone is a
# review checkout, disposable by design: fm-review.sh's own retry (checkout_ok
# / rebuild_checkout) covers one a round destroys, in place of write denial.
mkdir -p "$t/clone/.git/objects"
cprof="$(mac profile --policy="$t/g.json" --root="$t/clone" --tmp="$t/round-a")"
assert_lacks "$cprof" "$t/clone/.git" "a clone's .git directory adds no deny rule of its own"
cargs="$(lin profile --policy="$t/g.json" --root="$t/clone" --tmp="$t/round-a")"
assert_lacks "$cargs" "--ro-bind
$t/clone/.git" "nor a read-only bind on Linux: it stays inside the round's ordinary read-write root"
# a root with no .git yet (a task branch not yet checked out anywhere real)
# names nothing to protect, and the profile is generated the same as before
mkdir -p "$t/nogit-root"
plain_prof="$(mac profile --policy="$t/g.json" --root="$t/nogit-root" --tmp="$t/round-a")"
assert_lacks "$plain_prof" "the tree's own link to git" "a root with no .git of its own adds no deny rule for one"

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
# OpenAI's user file store (T-147): refused to every vendor's round by the
# captain's decision, codex's included, and said to be a known refusal
for sd in sdmntprsouthcentralus.oaiusercontent.com sdmntprnortheu.oaiusercontent.com; do
  for v in codex claude ''; do
    assert_eq "1" "$(decide "$P" "$v" "$sd")" "$sd is refused to ${v:-a} round"
  done
done
assert_contains "$("$SB" decide --policy="$P" --vendor=codex sdmntprnortheu.oaiusercontent.com 2>&1)" \
  "OpenAI's user file store" "and the proxy says what it is"
jq '.network += ["sdmntprnortheu.oaiusercontent.com"] | .vendors.codex.hosts += ["oaiusercontent.com"]' "$P" > "$t/edited3.json"
assert_eq "1" "$(decide "$t/edited3.json" codex sdmntprnortheu.oaiusercontent.com)" \
  "whatever a hand-edited policy declares"
assert_eq "0" "$(decide "$t/edited3.json" codex files.oaiusercontent.com)" \
  "while the rest of that domain is as the policy says"

# --- run: the command inside the sandbox ------------------------------------------
pol worker 'policy:
  procs: 1000000
  cpu: 90
'
# an ambient XDG_CONFIG_HOME of the caller's, distinct from the round's own
# TMPDIR/HOME, so the assertion below can tell "left alone" from "moved"
callerconfig="$t/caller-config"; mkdir -p "$callerconfig"
echo "the prompt" | GH_TOKEN=x GITHUB_TOKEN=x SSH_AUTH_SOCK=/x AWS_SECRET_ACCESS_KEY=x HERDR_SOCKET=/x KEEP_ME=kept \
  FM_CREW_UNSANDBOXED=1 FM_ROUND_UNSANDBOXED=1 XDG_CONFIG_HOME="$callerconfig" \
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
# a normal environment besides (T-128): HOME, XDG_CACHE_HOME and
# XDG_DATA_HOME, all under the round's own TMPDIR, asserted here - a mocked
# sandbox-exec, so this runs on every host, not only where real_sandbox_ok's
# kernel-enforced block below can nest
rhome="$(sed -n 's/^HOME=//p' "$t/tmpdir" 2>/dev/null)"
assert_eq "$rtmp/home" "$rhome" "the round is given a HOME under its own TMPDIR"
assert_eq "$rtmp/cache/xdg" "$(sed -n 's/^XDG_CACHE_HOME=//p' "$t/tmpdir" 2>/dev/null)" \
  "and an XDG_CACHE_HOME there too"
assert_eq "$rhome/.local/share" "$(sed -n 's/^XDG_DATA_HOME=//p' "$t/tmpdir" 2>/dev/null)" \
  "and an XDG_DATA_HOME there too"
# XDG_CONFIG_HOME is the one exception (T-128 review round 4): a vendor's own
# config directory is already a separate, existing contract per adapter
# (CLAUDE_CONFIG_DIR, CODEX_HOME, gemini's own HOME); overriding it here too
# would move cursor-agent off wherever the caller already had it, which
# tests/adapter-contract.test.sh's "cursor-agent is handed no XDG_CONFIG_HOME
# of fm's" checks directly. So it passes through the caller's own value.
assert_eq "$callerconfig" "$(sed -n 's/^XDG_CONFIG_HOME=//p' "$t/tmpdir" 2>/dev/null)" \
  "the round is handed the caller's own XDG_CONFIG_HOME, not one of fm's"
# T-147: zsh writes a here-document under TMPPREFIX (/tmp/zsh by default),
# not TMPDIR; the round's is inside its own temp directory
assert_eq "$rtmp/zsh" "$(sed -n 's/^TMPPREFIX=//p' "$t/tmpdir" 2>/dev/null)" \
  "the round's zsh writes its here-documents under the round's own TMPDIR"
# and a login shell - codex runs every command through one - ends with the
# round's PATH, not the one the system's profile (macOS's path_helper)
# rebuilt with /usr/bin, Apple's xcrun shims, first: the round's HOME is its
# own, and its profile, read after the system's, puts the round's back
rpath="$(sed -n 's/^PATH=//p' "$t/tmpdir" 2>/dev/null)"
assert_ne "" "$rpath" "the round is given a PATH"
assert_eq "$rhome" "$(sed -n 's/^ZDOTDIR=//p' "$t/tmpdir" 2>/dev/null)" \
  "zsh reads its profile from the round's own HOME, never an operator's ZDOTDIR"
for rc in .zprofile .bash_profile .profile; do
  assert_eq "$rpath" "$(sed -n "s/^LOGIN $rc=//p" "$t/tmpdir" 2>/dev/null)" \
    "the round's $rc puts the round's PATH back after the system's login profile"
done
assert_fail "test -e '$rtmp'" "and it is removed when the round ends"
assert_fail "test -e '$rhome'" "HOME with it, being under the same TMPDIR"
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

# --- mktemp on the round's own PATH (T-123) ----------------------------------
# macOS's own mktemp ignores $TMPDIR for a bare call or -t (round 6's own
# reproduction: `mkdtemp failed on /var/folders/.../T/tmp.xxx`, outside every
# root a round may write, whatever TMPDIR says). fm-sandbox.sh puts a stand-in
# ahead of it on the round's own PATH: a bare call and -t both land under the
# round's own TMPDIR, where an explicit template already did.
# T-123 round 7: the hygiene lint now also bans a bare, template-less
# mktemp -d/-t anywhere in a suite - not only the shape that then cds into
# it - so this fixture's own two bare calls are threaded through mt/fd/ft
# rather than written whole, the same way the self-launder fixture above
# threads its cd; the third call already carries an explicit template and
# needs no such care.
mt=mktemp; fd=-d; ft=-t
cat > "$t/mkcmd.sh" <<S
#!/usr/bin/env bash
set -e
b="\$($mt $fd)"; printf '%s' "\$b" > "$t/mkbare"
[ -d "\$b" ] && printf ok > "$t/mkbare.exists" || printf no > "$t/mkbare.exists"
f="\$($mt $fd $ft fm-x)"; printf '%s' "\$f" > "$t/mktflag"
[ -d "\$f" ] && printf ok > "$t/mktflag.exists" || printf no > "$t/mktflag.exists"
$mt $fd "\$TMPDIR/fm-tmpl.XXXXXX" > "$t/mktmpl"
S
chmod +x "$t/mkcmd.sh"
rm -f "$t/mkbare" "$t/mktflag" "$t/mktmpl" "$t/mkbare.exists" "$t/mktflag.exists"
echo | FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" PATH="$t/psbin:$PATH" \
  "$SB" run --policy="$P" --root="$root" --ctl="$t/ctl" -- "$t/mkcmd.sh"
assert_eq "0" "$?" "a bare mktemp -d, mktemp -t, and an explicit template all succeed inside a round"
mkbare="$(cat "$t/mkbare" 2>/dev/null)"
mktflag="$(cat "$t/mktflag" 2>/dev/null)"
mktmpl="$(cat "$t/mktmpl" 2>/dev/null)"
assert_matches "$mkbare" "^$t/ctl/fm-sb\.[A-Za-z0-9]+/tmp/tmp\." \
  "a bare mktemp -d lands under the round's own TMPDIR, not the host's"
assert_matches "$mktflag" "^$t/ctl/fm-sb\.[A-Za-z0-9]+/tmp/fm-x\." \
  "and so does mktemp -t, under its own prefix"
assert_matches "$mktmpl" "^$t/ctl/fm-sb\.[A-Za-z0-9]+/tmp/fm-tmpl\." \
  "an explicit template is untouched, and already lands there too"
# checked from inside the round (T-123 round 9): fm-sandbox.sh's own exit
# trap removes the round's whole --ctl-nested work directory - the round's
# own tmp included - the moment "$SB run" returns (line ~508 above asserts
# exactly this is true of every round), so a test -d on the named path
# AFTER the round has already ended checks a directory gone by design, on
# every platform - not a Linux-only quirk. The round records what it saw
# of its own directory while it was still alive to look.
assert_eq "ok" "$(cat "$t/mkbare.exists" 2>/dev/null)" "and the directory the bare call named is real"
assert_eq "ok" "$(cat "$t/mktflag.exists" 2>/dev/null)" "so is the one -t named"

# Linux gets none of this: GNU's own mktemp already honours $TMPDIR, so
# bin/fm-sandbox.sh installs no stand-in on that side. This plays GNU's own
# tool (no bwrap runs here either) to show the round succeeds without one.
mkdir -p "$t/gnubin"
cat > "$t/gnubin/mktemp" <<'S'
#!/bin/sh
# Plays real GNU mktemp on this darwin test box: an explicit template is
# passed straight through, since it already works on the real
# /usr/bin/mktemp underneath this fake too, and only a bare call or -t is
# rebuilt under $TMPDIR - the same route/transform split as the real
# stand-in bin/fm-sandbox.sh installs for darwin. Without this split
# (T-123 round 14), this fake sat on fm-sandbox.sh's own PATH for the
# whole "$SB run" invocation and clobbered its own explicit-template
# mktemp call that builds the round's --ctl work directory, so the round
# ended up under the outer TMPDIR instead of under --ctl.
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
S
chmod +x "$t/gnubin/mktemp"
cat > "$t/mkcmd-lin.sh" <<S
#!/usr/bin/env bash
set -e
b="\$($mt $fd)"; printf '%s' "\$b" > "$t/mkbare-lin"
[ -d "\$b" ] && printf ok > "$t/mkbare-lin.exists" || printf no > "$t/mkbare-lin.exists"
f="\$($mt $fd $ft fm-x)"; printf '%s' "\$f" > "$t/mktflag-lin"
[ -d "\$f" ] && printf ok > "$t/mktflag-lin.exists" || printf no > "$t/mktflag-lin.exists"
S
chmod +x "$t/mkcmd-lin.sh"
rm -f "$t/mkbare-lin" "$t/mktflag-lin" "$t/mkbare-lin.exists" "$t/mktflag-lin.exists"
echo | FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$t/bin/bwrap" PATH="$t/gnubin:$t/psbin:$PATH" \
  "$SB" run --policy="$P" --root="$root" --ctl="$t/ctl" -- "$t/mkcmd-lin.sh"
assert_eq "0" "$?" "and on Linux, where GNU's mktemp already honours TMPDIR, the round succeeds with no stand-in"
mkbarelin="$(cat "$t/mkbare-lin" 2>/dev/null)"
mktflaglin="$(cat "$t/mktflag-lin" 2>/dev/null)"
assert_matches "$mkbarelin" "^$t/ctl/fm-sb\.[A-Za-z0-9]+/tmp/tmp\." \
  "a bare mktemp -d lands under the round's own TMPDIR there too"
assert_matches "$mktflaglin" "^$t/ctl/fm-sb\.[A-Za-z0-9]+/tmp/fm-x\." \
  "and so does mktemp -t"
# checked from inside the round too (T-123 round 9), for the same reason as
# the darwin pair above: the directory is only guaranteed to exist for the
# life of the round.
assert_eq "ok" "$(cat "$t/mkbare-lin.exists" 2>/dev/null)" "and its directory is real there too"
assert_eq "ok" "$(cat "$t/mktflag-lin.exists" 2>/dev/null)" "and so is the -t one's"

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
    # only the marker and the probes after it: the check's own source is an
    # argument too, and names 'bind:' itself (T-153)
    probes=''; seen=0
    for a in "\$@"; do
      if [ "\$seen" = 1 ]; then probes="\$probes \$a"
      elif [ "\$a" = fm-loopback-check ]; then seen=1
      fi
    done
    printf 'fm-loopback-check%s\n' "\$probes" >> "$t/lo.checks"
    wild=0; grep -qF '(allow network-outbound (remote ip "localhost:*"))' "\$prof" && wild=1
    case "\${LO_MODE:-open}:\$wild" in
      holds:*|tight:0|bindleak:0) echo checked; exit 0 ;;
      bindleak:1) echo checked; echo "bind:\$FM_PORT"; exit 0 ;;
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
# The board's port for these rounds is one of the suite's own that nothing
# holds, never the operator's 4173: behind a stand-in that plays no kernel
# the check really binds it (T-153).
fport="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
lo_round() {   # lo_round <mode> [board port] -> exit code; stderr in $t/lo.err
  rm -f "$t/lo.profile.sb" "$t/lo.checks"
  LO_MODE="$1" FM_PORT="${2:-$fport}" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec-lo" PATH="$t/lobin:$PATH" \
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
assert_contains "$(cat "$t/lo.checks" 2>/dev/null)" "bind:$fport" \
  "and, the board's port not listening, whether a round could bind it (T-153)"
assert_contains "$(grep 'loopback: ' "$t/lo.err")" "the port of the board, $fport, not listening, cannot be bound" \
  "which it says too"
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
# T-153: a profile that would let a round bind the board's port, while the
# board is down, is not relied on either: the round gets no loopback but its
# proxy, and says which bind got through
assert_eq "7" "$(lo_round bindleak)" "a bind of the board's port that gets through: the round still runs"
assert_contains "$(cat "$t/lo.err")" "a bind of the board's port $fport, which nothing held" "and says so"
assert_contains "$(cat "$t/lo.err")" "loopback: the round's profile allows it no port but its proxy's" \
  "behind a profile with no loopback but its proxy"
assert_lacks "$(cat "$t/lo.profile.sb" 2>/dev/null)" "$wild" "which binds nothing on loopback"
# a board that is listening holds its port: no round can bind it, and it is
# only tried by connecting, like every other listener
assert_eq "7" "$(lo_round holds "$lport")" "the board listening: the round runs"
assert_lacks "$(cat "$t/lo.checks" 2>/dev/null)" "bind:" "and no bind is tried on a port something already holds"
assert_contains "$(cat "$t/lo.checks" 2>/dev/null)" "fm-loopback-check $lport" "while connecting to it is"
# whether the board's port is held is asked of the port, not read from a
# listing: a netstat whose lines cannot be parsed still tries no bind on a
# board that is listening (T-153; the Linux runner's netstat)
mkdir -p "$t/lobin-garbled"; cp "$t/psbin/ps" "$t/lobin-garbled/ps"
printf '#!/bin/sh\nprintf "Active Internet connections\\nsomething else entirely\\n"\n' > "$t/lobin-garbled/netstat"
chmod +x "$t/lobin-garbled/netstat"
rm -f "$t/lo.profile.sb" "$t/lo.checks"
LO_MODE=holds FM_PORT="$lport" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec-lo" PATH="$t/lobin-garbled:$PATH" \
  "$SB" run --policy="$t/worker.json" --root="$root" --ctl="$t/ctl" -- "$t/seven.sh" </dev/null 2>"$t/lo.err"
assert_eq "7" "$?" "the board listening where netstat shows nothing: the round runs"
assert_lacks "$(cat "$t/lo.checks" 2>/dev/null)" "bind:" "and no bind is tried on the board's port it holds"
assert_contains "$(cat "$t/lo.checks" 2>/dev/null)" "fm-loopback-check $lport" "it is tried by connecting, as a listener"
assert_contains "$(cat "$t/lo.profile.sb" 2>/dev/null)" "(deny network-bind network-inbound (local ip \"localhost:$lport\"))" \
  "and its deny line is in the profile"
# Linux: the round's loopback is its network namespace's own, so a bind
# there is never the board's and nothing is tried before the round
rm -f "$t/lo.checks"
FM_PORT="$fport" FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$t/bin/bwrap" PATH="$t/lobin:$PATH" \
  "$SB" run --policy="$t/worker.json" --root="$root" --ctl="$t/ctl" -- "$t/seven.sh" </dev/null 2>"$t/lo.err"
assert_eq "7" "$?" "on Linux the round runs"
assert_lacks "$(cat "$t/lo.err")" "the board's port" "and no bind of the board's port was tried: the namespace is the round's"
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


safe_rm_rf "$t"
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
