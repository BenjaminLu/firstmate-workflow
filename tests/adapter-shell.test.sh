#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/adapter.sh
. "$ROOT/tests/lib/adapter.sh"
# shellcheck source=tests/lib/adapter-policy.sh
. "$ROOT/tests/lib/adapter-policy.sh"
# --- a codex round's shell is the operator's working environment (T-147) ---
# The first codex worker round (T-146, 2026-09-29) stopped at once: codex
# runs every command as `$SHELL -lc <command>`, the operator's zsh as a
# login shell. zsh wrote its here-document under TMPPREFIX (/tmp/zsh), which
# the sandbox denies; and the system's login profile - macOS's path_helper -
# put /usr/bin, Apple's xcrun shims, ahead of the operator's git, whose
# shim then failed on its cache and the Xcode licence. No real sandbox or
# zsh runs here, so fakezsh plays that shell in exactly those two ways: as
# a login shell it puts the shims first and then reads ZDOTDIR's (else
# HOME's) .zprofile, and a here-document fails unless TMPPREFIX is inside
# the round's own TMPDIR, the one temp directory the sandbox lets it write.
# The codex stand-in answers as the real CLI does: it runs its command
# through $SHELL -lc in the worktree.
cx="$(safe_tmpdir)"; mkdir -p "$cx/fakebin" "$cx/opbin" "$cx/shimbin" "$cx/devbin"
realgit="$(command -v git)"
# python3 and jq for the adapter itself, whichever the runner has, in a
# directory of their own so no other tool of that directory comes with them
mkdir -p "$cx/toolbin"
ln -s "$closed_path/python3" "$cx/toolbin/python3"
ln -s "$(command -v jq)" "$cx/toolbin/jq"
git init -q "$cx/tree"
echo "do it" > "$cx/prompt"
cp "$pv/fakebin/netstat" "$cx/fakebin/netstat"
# Apple's shim, as fm_xcrun_shim knows one (it links libxcselect), failing
# the way it failed in the round
cat > "$cx/shimbin/git" <<'S'
#!/bin/sh
# /usr/lib/libxcselect.dylib
echo "git: error: couldn't create cache file '/var/folders/xx/T/xcrun_db-x' (errno=Operation not permitted)" >&2
echo "You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' from within a Terminal window to review and agree to the Xcode and Apple SDKs license." >&2
exit 69
S
# the operator's own git, first on the PATH they hand the round
ln -s "$realgit" "$cx/opbin/git"
# the tool Xcode's developer directory holds, which xcrun names
ln -s "$realgit" "$cx/devbin/git"
cat > "$cx/fakezsh" <<S
#!/usr/bin/env bash
[ "\$1" = -lc ] || exit 64
# the system's login profile: path_helper puts /usr/bin, the shims, first
PATH="$cx/shimbin:\$PATH"
zd="\${ZDOTDIR:-\$HOME}"
# shellcheck disable=SC1091
[ ! -r "\$zd/.zprofile" ] || . "\$zd/.zprofile"
case "\$2" in *"<<"*)
  case "\${TMPPREFIX:-/tmp/zsh}" in
    "\${TMPDIR:-/nonexistent}"/*) ;;
    *) echo "zsh:1: can't create temp file for here document: operation not permitted" >&2; exit 1 ;;
  esac ;;
esac
eval "\$2"
S
cat > "$cx/fakebin/codex" <<S
#!/usr/bin/env bash
cat > /dev/null
"\$SHELL" -lc 'cat <<EOF
heredoc ok
EOF
git status --short >/dev/null && echo "git status ok: \$(command -v git)"
git --version >/dev/null 2>"$cx/git.err"; echo "git exit \$?"' > "$cx/codex.out" 2>&1
exit 0
S
# xcode-select and xcrun, as fm_xcrun_resolve asks them outside the round
printf '#!/bin/sh\necho /Applications/Xcode.app/Contents/Developer\n' > "$cx/xcode-select"
printf '#!/bin/sh\n[ "$1" = --find ] && [ "$2" = git ] && { echo "%s/devbin/git"; exit 0; }\nexit 72\n' "$cx" > "$cx/xcrun-finds"
cat > "$cx/xcrun-licence" <<'S'
#!/bin/sh
echo "You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' from within a Terminal window to review and agree to the Xcode and Apple SDKs license." >&2
exit 69
S
chmod +x "$cx/shimbin/git" "$cx/fakezsh" "$cx/fakebin/codex" "$cx/xcode-select" "$cx/xcrun-finds" "$cx/xcrun-licence"
cx_path="$cx/closed"
fixture_path "$cx_path" 'git claude codex gemini cursor-agent agent gh security secret-tool' || exit 1
codex_round() {   # codex_round <PATH> <xcrun> -> its exit code; what its shell said in $cx/codex.out
  rm -f "$cx/codex.out" "$cx/git.err" "$cx/log"
  SHELL="$cx/fakezsh" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" FM_POLICY="$pk/none.json" \
    FM_XCODE_SELECT="$cx/xcode-select" FM_XCRUN="$2" PATH="$cx/toolbin:$1" \
    "$ROOT/bin/adapters/codex.sh" run "$cx/prompt" "$cx/tree" "$cx/log" >/dev/null 2>"$cx/err"
  echo $?
}
assert_eq "0" "$(codex_round "$cx/opbin:$cx/fakebin:$cx_path" "$cx/xcrun-finds")" "a codex round runs"
cxo="$(cat "$cx/codex.out" 2>/dev/null)"
assert_contains "$cxo" "heredoc ok" "a here-document works in a codex round's login shell"
assert_lacks "$cxo" "can't create temp file" "its temp file is not refused"
assert_contains "$cxo" "git status ok: $cx/opbin/git" \
  "and git status runs the operator's git, first on their PATH after the login profile ran, not Xcode's shim"
assert_contains "$cxo" "git exit 0" "which works"
# a machine whose only git is the shim: xcrun, asked outside the round,
# names the tool it would run, and the round runs that one directly
assert_eq "0" "$(codex_round "$cx/fakebin:$cx/shimbin:$cx_path" "$cx/xcrun-finds")" "a round on an xcrun-only machine runs"
cxo="$(cat "$cx/codex.out" 2>/dev/null)"
assert_contains "$cxo" "git exit 0" "where xcrun can name the real git, git works inside it"
assert_contains "$(cat "$cx/log")" "is Apple's xcrun shim ($cx/shimbin/git); the round runs the git it names, $cx/devbin/git" \
  "and the sandbox says which one it runs"
# and where xcrun has none to give - the Xcode licence not accepted - the
# round is told plainly, at once, rather than failing on a licence prompt
assert_eq "0" "$(codex_round "$cx/fakebin:$cx/shimbin:$cx_path" "$cx/xcrun-licence")" "a round on an unusable xcrun-only machine still runs"
cxo="$(cat "$cx/codex.out" 2>/dev/null)"
assert_contains "$cxo" "git exit 69" "its git exits 69 at once"
cxe="$(cat "$cx/git.err" 2>/dev/null)"
assert_contains "$cxe" "git here is only Apple's Xcode shim ($cx/shimbin/git), which cannot run inside a crew round" \
  "and says plainly why"
assert_contains "$cxe" "You have not agreed to the Xcode license agreements" "naming what xcrun said"
assert_contains "$cxe" "brew install git" "and how the operator fixes it"
assert_lacks "$cxe" "xcrun_db" "the shim itself never ran"
assert_contains "$(cat "$cx/log")" "git here is only Apple's Xcode shim" "the round's log says so too"
safe_rm_rf "$cx"

safe_rm_rf "$pv"
safe_rm_rf "$pk" "$closed_path"
finish
