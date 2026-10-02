#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/sandbox.sh
. "$ROOT/tests/lib/sandbox.sh"
# shellcheck source=tests/lib/sandbox-os.sh
. "$ROOT/tests/lib/sandbox-os.sh"
# --- the vendor's login (T-117) -----------------------------------------------
# On macOS claude's login is in the keychain, with gh's token and git's,
# and the round reaches none of it. fm reads the vendor's own item outside
# the round - that item and no other - and hands it in as a variable:
# claude's access token as CLAUDE_CODE_OAUTH_TOKEN, and the crew's Cursor
# API key as CURSOR_API_KEY. The operator's keychain here is a stand-in: it
# holds claude's login, the crew's Cursor key, cursor-agent's own `agent
# login` items and gh's token, and records every item asked for.
# kctmp is declared here, at top level, not inside kc(): every kc()
# call runs through $(...) command substitution to capture its echoed
# exit code, which forks a subshell - a plain assignment made inside
# that subshell's copy of kc() never reaches back into this script's
# own variables (T-123 round 13; every assertion below that reads
# $kctmp after a kc() call was reading one that command substitution
# had already thrown away, unbound under set -u on a real run).
kctmp="$t/kc-tmp"
mkdir -p "$t/kc"
future=$(( ($(date +%s) + 3600) * 1000 ))
printf '{"claudeAiOauth":{"accessToken":"at-claude","refreshToken":"rt-claude-secret","expiresAt":%s}}' \
  "$future" > "$t/kc/claude"
cat > "$t/kc/security" <<S
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$t/kc/calls"
s=''; while [ \$# -gt 0 ]; do [ "\$1" = -s ] && s="\${2-}"; shift; done
case "\$s" in
  firstmate-claude-token) printf 'crew-claude-token\n' ;;
  'Claude Code-credentials') cat "$t/kc/claude" ;;
  firstmate-cursor-api-key) printf 'key-cursor-crew\n' ;;
  cursor-access-token) printf 'at-cursor\n' ;;
  cursor-refresh-token) printf 'rt-cursor-secret\n' ;;
  gh:github.com) printf 'gho_ghsecret\n' ;;
  *) echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44 ;;
esac
S
chmod +x "$t/kc/security"
# A second stand-in exactly like the operator's, but as if the crew had
# never made its own claude token (T-126): every other item answers the
# same way, so a test using this one exercises claude's fallback tier.
sed "/firstmate-claude-token)/d" "$t/kc/security" > "$t/kc/security-nocrew"
chmod +x "$t/kc/security-nocrew"
# A stand-in for secret-tool(1), libsecret's CLI - the keychain's rough
# equivalent off macOS (T-126 round 2). Real secret-tool prints the secret
# with no trailing newline on success and exits 0; nothing on stdout and a
# non-zero exit when no item matches.
cat > "$t/kc/secret-tool" <<S
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$t/kc/secret-calls"
shift  # drop 'lookup'
svc=''; acct=''
while [ \$# -gt 0 ]; do
  case "\$1" in
    service) svc="\${2-}"; shift 2 ;;
    account) acct="\${2-}"; shift 2 ;;
    *) shift ;;
  esac
done
case "\$svc:\$acct" in
  firstmate-claude-token:*) printf '%s' 'crew-claude-secret' ;;
  *) exit 1 ;;
esac
S
chmod +x "$t/kc/secret-tool"
# The default FM_SECRET_TOOL for every claude test below that does not name
# its own (T-126 round 4): a stub of fm's own, never the host's real
# secret-tool(1). CI's runner has one on PATH, and secret_read() looks it
# up on PATH when FM_SECRET_TOOL is unset (T-126 round 8) - naming no
# FM_SECRET_TOOL at all here would reach it for real, outside any sandbox,
# with no D-Bus session to answer it: an unreachable store, passed over for
# the crew file or refusing the round (T-126 round 10), on one machine and
# "no item" on another. This stub answers like secret-tool always does -
# nothing on stdout, exit 1 - and records every call, so a test can assert
# fm's own stub, not the host's, was asked.
cat > "$t/kc/secret-tool-guard" <<S
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$t/kc/secret-tool-guard-calls"
exit 1
S
chmod +x "$t/kc/secret-tool-guard"
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
lpath="$t/psbin:$suite_tools"
# The board warning (T-126 round 2): a fallback tier is worth a line on the
# board, not only in the round's log. fm-sandbox.sh posts it through
# fm_herdr_emit_status (bin/fm-config.sh) and bin/fm-herdr.py under FM_ROOT
# - the same path fm-worker.sh's and fm-review.sh's own mid-run activity
# takes, and the reason a direct `fm-emit.sh --actor` call is never made
# here (tests/traps.test.sh) - when the caller carries FM_ROOT/FM_TASK/
# FM_ACTOR - fm_identity's own exports, present for a real worker or
# reviewer round; fm-canary.sh's own probe rounds set none of those and so
# get no board write at all (asserted below too).
board="$t/board"
mkdir -p "$board/bin"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-herdr.py" "$board/bin/"; project_storage_fixture "$board/bin/"
kc() {   # kc <mode> <os> <vendor> [env...] -> exit code; the round's view in $t/login.out
  local mode="$1" os_="$2" v="$3" tool="$t/bin/sandbox-exec"
  shift 3
  [ "$os_" = linux ] && tool="$t/bin/bwrap"
  rm -f "$t/login.out" "$t/profile.sb" "$t/kc/calls"; echo stale > "$t/started"
  # its own --tmp (T-123 round 9), same as any real caller passes: with
  # none, the round's own temp directory falls back to under --ctl, and the
  # mktemp stand-in the round installs there then reads as fm's own control
  # directory on the round's PATH, not the round's own business. $kctmp
  # is the caller's own (T-123 round 13); kc() only clears and recreates it.
  rm -rf "$kctmp"; mkdir -p "$kctmp"
  # FM_SECRET_TOOL defaults to fm's own stub, never the host's real
  # secret-tool(1) (T-126 round 4); a caller naming its own in "$@" comes
  # after and wins, the way every later env(1) assignment of the same name
  # does.
  env FM_SANDBOX_OS="$os_" FM_SANDBOX_TOOL="$tool" FM_KEYCHAIN_TOOL="$t/kc/security" \
    FM_SECRET_TOOL="$t/kc/secret-tool-guard" PATH="$lpath" "$@" \
    "$SB" "$mode" --policy="$t/worker.json" --root="$root" --vendor="$v" --ctl="$t/ctl" --tmp="$kctmp" --started="$t/started" \
    -- "$t/login.sh" "$t/login.out" </dev/null >/dev/null 2>"$t/login.err"
  echo $?
}
pol worker 'vendor: mock
'
# claude (T-126): the crew's own long-lived token is tried first, never
# the operator's interactive login while one exists
rm -rf "$board/state"
assert_eq "0" "$(kc run darwin claude FM_ROOT="$board" FM_TASK=T-board FM_ACTOR=worker-board FM_ROLE=worker)" \
  "claude's round starts on macOS with the crew's own token"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "token=crew-claude-token" "handed in as CLAUDE_CODE_OAUTH_TOKEN"
assert_lacks "$lo" "at-claude" "never the operator's interactive login while a crew token exists"
assert_lacks "$lo" "rt-claude-secret" "the refresh token never enters the round"
assert_eq "1" "$(grep -c '^CLAUDE_CODE_OAUTH_TOKEN=' <<< "$lo")" \
  "exactly one CLAUDE_CODE_OAUTH_TOKEN in the round's environment"
assert_contains "$lo" "CLAUDE_CODE_OAUTH_TOKEN=crew-claude-token" "holding exactly the crew token"
assert_eq "find-generic-password -s firstmate-claude-token -a $me -w" "$(cat "$t/kc/calls" 2>/dev/null)" \
  "and fm read one item of the keychain: the crew's own"
assert_eq "" "$(ls -A "$t/ctl" 2>/dev/null)" "nothing of the login is left behind"
assert_lacks "$(cat "$t/login.err" 2>/dev/null)" "has no crew token" \
  "and no fallback warning when the crew token answers"
assert_eq "" "$(cat "$board/state/events.jsonl" 2>/dev/null)" \
  "and no board event either, even with FM_ROOT/FM_TASK/FM_ACTOR set, when the crew token answers"

# claude with no crew token anywhere (T-126): falls back to the operator's
# own interactive login, on macOS the way it always has, but warns - in the
# round's log AND on the board (en and zh-TW), when the caller carries
# FM_ROOT/FM_TASK/FM_ACTOR (fm_identity's own exports)
mkdir -p "$t/chome/.config/firstmate"
( export HOME="$t/chome"; pol worker 'vendor: mock
' )
rm -rf "$board/state"
rm -f "$t/kc/secret-tool-guard-calls"
assert_eq "0" "$(kc run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew" \
    FM_ROOT="$board" FM_TASK=T-board FM_ACTOR=worker-board FM_ROLE=worker)" \
  "with no crew token, claude's round still starts on the interactive login"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "token=at-claude" "handed in the same way as before T-126"
assert_contains "$(cat "$t/login.err")" "has no crew token" "and the fallback warns, in the round's log"
assert_contains "$(cat "$t/login.err")" "can be revoked when that login refreshes" "naming the risk"
assert_contains "$(cat "$t/login.err")" "claude setup-token" "and how to make one, so the fallback warning is actionable"
assert_contains "$(cat "$t/kc/secret-tool-guard-calls" 2>/dev/null)" "firstmate-claude-token" \
  "asked fm's own secret-tool stand-in, this test's default, never the host's real one"
warn_ev="$(jq -c 'select(.type=="crew_status" and .task=="T-board" and .actor=="worker-board")' \
  "$board/state/events.jsonl" 2>/dev/null | tail -1)"
assert_eq "true" "$(jq -r '. != null' <<< "${warn_ev:-null}")" "and it also posts a crew_status event to the board"
assert_eq "true" "$(jq -r '.data.activity.en // "" | test("no crew token")' <<< "${warn_ev:-null}")" \
  "carrying the en warning"
assert_eq "true" "$(jq -r '(.data.activity."zh-TW" // "") | test("\\S")' <<< "${warn_ev:-null}")" \
  "and a non-empty zh-TW translation of it"
assert_eq "true" "$(jq -r '(.summary.en // "") | test("no crew token")' <<< "${warn_ev:-null}")" \
  "in the event's own summary too (en)"
assert_eq "true" "$(jq -r '(.summary."zh-TW" // "") | test("\\S")' <<< "${warn_ev:-null}")" \
  "and (zh-TW)"
assert_eq "worker" "$(jq -r '.data.role // ""' <<< "${warn_ev:-null}")" \
  "under the run's own role, worker"

# the same fallback on a reviewer round (T-126 round 9): the board event
# carries the run's own FM_ROLE, never fm_herdr_emit_status's worker default
rm -rf "$board/state"
assert_eq "0" "$(kc run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew" \
    FM_ROOT="$board" FM_TASK=T-board FM_ACTOR=reviewer-board FM_ROLE=reviewer)" \
  "a reviewer round with no crew token still starts on the interactive login"
assert_contains "$(cat "$t/login.err")" "has no crew token" "and warns in its log"
rv_ev="$(jq -c 'select(.type=="crew_status" and .task=="T-board" and .actor=="reviewer-board")' \
  "$board/state/events.jsonl" 2>/dev/null | tail -1)"
assert_eq "reviewer" "$(jq -r '.data.role // ""' <<< "${rv_ev:-null}")" \
  "and its board warning names the run's own role, reviewer, never worker"

# with no FM_ROLE the role is never guessed: no board event, and the log
# warning still stands (passed empty, so an FM_ROLE in the environment
# running this suite cannot stand in for it)
rm -rf "$board/state"
assert_eq "0" "$(kc run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew" \
    FM_ROOT="$board" FM_TASK=T-board FM_ACTOR=worker-board FM_ROLE=)" \
  "a round with no FM_ROLE and no crew token still starts"
assert_contains "$(cat "$t/login.err")" "has no crew token" "still warning in the log without FM_ROLE"
assert_fail "test -e '$board/state/events.jsonl'" "but posting no board event with no role to name"

# fm-canary.sh's own probe rounds set no FM_ROOT/FM_TASK/FM_ACTOR (T-126
# round 2): the warning still reaches the round's log, but posting to a
# board that names no run is a no-op, not a failure
rm -rf "$board/state"
assert_eq "0" "$(kc run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew")" \
  "and the round still starts with none of those set"
assert_contains "$(cat "$t/login.err")" "has no crew token" "still warning in the log"
assert_fail "test -e '$board/state/events.jsonl'" "but posting nothing to any board"

# the crew token kept as a file, chosen when the keychain has none of it (T-126)
printf 'crew-file-token\n' > "$t/chome/.config/firstmate/claude-token"
chmod 600 "$t/chome/.config/firstmate/claude-token"
assert_eq "0" "$(kc run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew")" \
  "the 0600 crew token file is chosen when the keychain has none"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "token=crew-file-token" "handed in as CLAUDE_CODE_OAUTH_TOKEN"
assert_lacks "$lo" "at-claude" "never the interactive login while the crew file answers"
assert_lacks "$(cat "$t/login.err" 2>/dev/null)" "has no crew token" \
  "and no fallback warning when the crew file answers"

# a crew token file others can read is refused outright - never silently
# downgraded to the weaker interactive login (T-126)
chmod 644 "$t/chome/.config/firstmate/claude-token"
assert_eq "77" "$(kc run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew")" \
  "a 0644 crew token file refuses the round"
assert_contains "$(cat "$t/login.err")" "chmod 600" "and says what to do"
assert_fail "test -e '$t/login.out'" "and the command never starts"

# claude on Linux (T-126 round 2): there is no keychain there, so the
# crew's own libsecret item - secret-tool(1) - is tried next, before the
# file; even a file the operator left readable by others (still 0644 from
# just above) is never reached while libsecret answers
assert_eq "0" "$(kc run linux claude FM_SECRET_TOOL="$t/kc/secret-tool")" \
  "claude's round starts on Linux with the crew's libsecret item"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "token=crew-claude-secret" "handed in as CLAUDE_CODE_OAUTH_TOKEN"
assert_eq "lookup service firstmate-claude-token account $me" "$(cat "$t/kc/secret-calls" 2>/dev/null)" \
  "and fm read one item of libsecret: the crew's own"
assert_lacks "$(cat "$t/login.err" 2>/dev/null)" "has no crew token" \
  "and no fallback warning when secret-tool answers"
rm -f "$t/kc/secret-calls"

# secret-tool's own absence is skipped, not refused: the file tier is
# reached next, and refused on its own terms (still 0644)
assert_eq "77" "$(kc run linux claude FM_SECRET_TOOL="$t/no-such-secret-tool")" \
  "an FM_SECRET_TOOL that does not exist is skipped, and the 0644 crew file is reached next and refuses the round"
assert_contains "$(cat "$t/login.err")" "chmod 600" "and says what to do"
assert_fail "test -e '$t/login.out'" "and the command never starts"

# With FM_SECRET_TOOL unset (empty here, over kc()'s guard default),
# secret-tool is looked up on the operator's PATH (T-126 round 8), wherever
# it lives - Nix, Homebrew on Linux, /usr/local/bin - never only
# /usr/bin/secret-tool.
mkdir -p "$t/secret-path"
cp "$t/kc/secret-tool" "$t/secret-path/secret-tool"
rm -f "$t/kc/secret-calls"
assert_eq "0" "$(kc run linux claude FM_SECRET_TOOL= PATH="$t/secret-path:$lpath")" \
  "a secret-tool first on the operator's PATH is found with FM_SECRET_TOOL unset"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "token=crew-claude-secret" "and its crew item is handed in as CLAUDE_CODE_OAUTH_TOKEN"
assert_eq "lookup service firstmate-claude-token account $me" "$(cat "$t/kc/secret-calls" 2>/dev/null)" \
  "and that secret-tool on PATH was the one asked"
assert_lacks "$(cat "$t/login.err" 2>/dev/null)" "has no crew token" \
  "and no fallback warning when the secret-tool on PATH answers"
src="$(FM_SANDBOX_OS=linux FM_SECRET_TOOL='' PATH="$t/secret-path:$lpath" \
  "$SB" login-source --policy="$t/worker.json" --vendor=claude 2>/dev/null)"
assert_eq "tier=primary source=secret:firstmate-claude-token" "$src" \
  "login-source names that item as the crew's own tier (crew-token)"
rm -f "$t/kc/secret-calls"
# and with no secret-tool anywhere on PATH, the tier is skipped and the
# 0644 crew file is reached next. The PATH is lpath's own tools, linked
# into one directory with any secret-tool left out, so a runner that has
# one installed (CI's does) cannot answer here.
PATH="$lpath" fixture_path "$t/nosecret-path" 'secret-tool' || exit 1
assert_fail "PATH='$t/nosecret-path' command -v secret-tool" "(no secret-tool on that PATH)"
assert_eq "77" "$(kc run linux claude FM_SECRET_TOOL= PATH="$t/nosecret-path")" \
  "with FM_SECRET_TOOL unset and no secret-tool on PATH, the 0644 crew file is reached next and refuses the round"
assert_contains "$(cat "$t/login.err")" "chmod 600" "and says what to do (no secret-tool on PATH)"
assert_fail "test -e '$t/login.out'" "and the command never starts (no secret-tool on PATH)"

# a working file behind a working secret-tool: libsecret still wins
chmod 600 "$t/chome/.config/firstmate/claude-token"
assert_eq "0" "$(kc run linux claude FM_SECRET_TOOL="$t/kc/secret-tool")" \
  "libsecret is chosen over a working crew file too"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "token=crew-claude-secret" "so the secret-tool item answers"
assert_lacks "$lo" "crew-file-token" "and never the file while libsecret answers"
rm -f "$t/kc/secret-calls"

# A crew token that exists but cannot be read is not a missing one (T-126
# round 7): it refuses the round, naming the source and its error, and the
# operator's interactive login is never asked for. Only security(1)'s exit
# 44, secret-tool's silent exit 1 and a file that is not there are missing.
# The operator's interactive login is there on both OSes throughout (the
# keychain stand-ins below answer for it; on Linux, its credentials file),
# so a read failure taken for absence would start the round on it.
rm -f "$t/chome/.config/firstmate/claude-token"
mkdir -p "$t/chome/.claude"
cp "$t/kc/claude" "$t/chome/.claude/.credentials.json"
# security(1) as it answers for an item it will not open: exit 36, "User
# interaction is not allowed" - and one that never answers at all
sed "s/^  firstmate-claude-token).*/  firstmate-claude-token) echo 'security: SecKeychainItemCopyContent: User interaction is not allowed.' >\&2; exit 36 ;;/" \
  "$t/kc/security" > "$t/kc/security-locked"
sed "s/^  firstmate-claude-token).*/  firstmate-claude-token) exec sleep 5 ;;/" "$t/kc/security" > "$t/kc/security-hang"
chmod +x "$t/kc/security-locked" "$t/kc/security-hang"
# secret-tool(1) as it answers when it cannot reach libsecret at all: exit
# 1 like "no such item", but saying why on stderr
cat > "$t/kc/secret-tool-broken" <<S
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$t/kc/secret-calls"
echo "secret-tool: Cannot autolaunch D-Bus without X11 \\\$DISPLAY" >&2
exit 1
S
chmod +x "$t/kc/secret-tool-broken"
crew_fail() {   # crew_fail <label> <reason text> <kc args...>: refused, and the fallback never asked
  local label="$1" reason="$2"
  shift 2
  assert_eq "77" "$(kc "$@")" "$label refuses the round"
  assert_contains "$(cat "$t/login.err" 2>/dev/null)" "$reason" "naming the source and its error ($label)"
  assert_fail "test -e '$t/login.out'" "and the command never starts ($label)"
  assert_lacks "$(cat "$t/kc/calls" 2>/dev/null)" "Claude Code-credentials" \
    "and the operator's interactive login is never asked for ($label)"
  assert_lacks "$(cat "$t/login.err" 2>/dev/null)" "has no crew token" "nor said to be missing ($label)"
}
crew_fail "a crew keychain item that will not open (security exit 36)" \
  "keychain item 'firstmate-claude-token' could not be read (exit 36" \
  run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-locked"
assert_contains "$(cat "$t/login.err" 2>/dev/null)" "User interaction is not allowed" "with security's own words"
crew_fail "a crew keychain read that never answers" "reading the keychain item 'firstmate-claude-token' timed out" \
  run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-hang" FM_LOGIN_READ_TIMEOUT=1
# a store that cannot be reached, with no crew file behind it, still
# refuses: it is never read as "no crew token" (T-126 round 10)
crew_fail "a secret-tool that cannot reach libsecret" "Cannot autolaunch D-Bus" \
  run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew" FM_SECRET_TOOL="$t/kc/secret-tool-broken"
crew_fail "the same secret-tool error on Linux" "secret-tool item 'firstmate-claude-token' could not be reached" \
  run linux claude FM_SECRET_TOOL="$t/kc/secret-tool-broken"
assert_contains "$(cat "$t/login.err" 2>/dev/null)" "Cannot autolaunch D-Bus" "with secret-tool's own words (Linux)"
# An unreachable store says nothing about whether the crew token is in it,
# so the next crew source - the 0600 file - is read (T-126 round 10): a
# headless or SSH Linux host, or CI, with secret-tool installed and no D-Bus
# session. Only the step to the interactive login is a downgrade.
printf 'crew-file-token\n' > "$t/chome/.config/firstmate/claude-token"
chmod 600 "$t/chome/.config/firstmate/claude-token"
rm -f "$t/kc/secret-calls"
assert_eq "0" "$(kc run linux claude FM_SECRET_TOOL="$t/kc/secret-tool-broken")" \
  "a secret-tool with no D-Bus session passes over to the 0600 crew file, and the round starts"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "token=crew-file-token" "on the crew file's token (no D-Bus)"
assert_lacks "$lo" "at-claude" "never the interactive login's (no D-Bus)"
assert_contains "$(cat "$t/kc/secret-calls" 2>/dev/null)" "firstmate-claude-token" "after secret-tool was asked (no D-Bus)"
le="$(cat "$t/login.err" 2>/dev/null)"
assert_contains "$le" "could not be reached" "and the round's log says the secret-tool store was unreachable"
assert_contains "$le" "claude-token instead" "and that the crew file was used"
assert_lacks "$le" "has no crew token" "and no fallback warning (no D-Bus)"
src="$(FM_SANDBOX_OS=linux FM_SECRET_TOOL="$t/kc/secret-tool-broken" \
  "$SB" login-source --policy="$t/worker.json" --vendor=claude 2>/dev/null)"
assert_eq "0" "$?" "login-source answers when the secret-tool store is unreachable and the crew file is there"
assert_eq "tier=primary source=file:$t/chome/.config/firstmate/claude-token" "$src" \
  "and names the crew file, the crew's own tier"
# a hung bus is the same: the read times out and the file is used
cat > "$t/kc/secret-tool-hang" <<S
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$t/kc/secret-calls"
exec sleep 5
S
chmod +x "$t/kc/secret-tool-hang"
assert_eq "0" "$(kc run linux claude FM_SECRET_TOOL="$t/kc/secret-tool-hang" FM_LOGIN_READ_TIMEOUT=1)" \
  "a secret-tool that never answers passes over to the 0600 crew file"
assert_contains "$(cat "$t/login.out" 2>/dev/null)" "token=crew-file-token" "on the crew file's token (hung bus)"
assert_contains "$(cat "$t/login.err" 2>/dev/null)" "timed out" "and the round's log says the read timed out"
# but a store that is there and fails - a locked collection - still refuses,
# with the working crew file right behind it
cat > "$t/kc/secret-tool-locked" <<S
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$t/kc/secret-calls"
echo "secret-tool: Cannot get secret of a locked object" >&2
exit 1
S
chmod +x "$t/kc/secret-tool-locked"
crew_fail "a secret-tool item in a locked collection" "secret-tool item 'firstmate-claude-token' could not be read" \
  run linux claude FM_SECRET_TOOL="$t/kc/secret-tool-locked"
assert_contains "$(cat "$t/login.err" 2>/dev/null)" "locked object" "with secret-tool's own words (locked)"
rm -f "$t/kc/secret-calls"
printf 'crew-file-token\n' > "$t/chome/.config/firstmate/claude-token"
chmod 000 "$t/chome/.config/firstmate/claude-token"
if [ -r "$t/chome/.config/firstmate/claude-token" ]; then
  # root reads a mode-000 file anyway, so there is no unreadable file to test
  echo "  (skipped: a mode-000 crew file is readable to this user, $(id -un))"
else
  crew_fail "a mode-000 crew token file" "claude-token could not be read" \
    run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew"
fi
rm -f "$t/chome/.config/firstmate/claude-token"
mkdir -m 700 "$t/chome/.config/firstmate/claude-token"
crew_fail "a directory where the crew token file should be" "claude-token could not be read" \
  run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew"
rmdir "$t/chome/.config/firstmate/claude-token"
: > "$t/chome/.config/firstmate/claude-token"
chmod 600 "$t/chome/.config/firstmate/claude-token"
crew_fail "an empty crew token file" "claude-token is empty" \
  run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew"
rm -f "$t/chome/.config/firstmate/claude-token"
# the same refusal through login-source, which fm-canary.sh reads
FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" FM_KEYCHAIN_TOOL="$t/kc/security-locked" \
  "$SB" login-source --policy="$t/worker.json" --vendor=claude >"$t/ls.out" 2>"$t/ls.err"
assert_eq "77" "$?" "login-source says 77 for a crew item that will not open"
assert_eq "" "$(cat "$t/ls.out")" "and names no source on stdout"
# and true absence, with every one of these stubs saying missing, still
# falls back and warns - on both OSes
assert_eq "0" "$(kc run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew")" \
  "with the crew token truly missing, the round still falls back"
assert_contains "$(cat "$t/login.out" 2>/dev/null)" "token=at-claude" "to the interactive login"
assert_contains "$(cat "$t/login.err" 2>/dev/null)" "has no crew token" "and warns"
assert_eq "0" "$(kc run linux claude)" "and on Linux too"
assert_contains "$(cat "$t/login.out" 2>/dev/null)" "token=at-claude" "to the interactive login's file (Linux)"
assert_contains "$(cat "$t/login.err" 2>/dev/null)" "has no crew token" "and warns (Linux)"
rm -f "$t/kc/secret-calls"

rm -rf "$t/chome"
pol worker 'vendor: mock
'
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
# kc() always passes its own --tmp ($kctmp, T-123 round 9), so the round's
# own temp directory is exactly that path, never nested under --ctl; and
# with an explicit --tmp nothing under --ctl is the round's temp directory
# any more, so nothing under it may be named readable in the profile at all
assert_eq "" "$(grep -o "\"$t/ctl/fm-sb\.[^\"]*\"" "$t/profile.sb" 2>/dev/null)" \
  "nor made readable in its profile"
assert_contains "$(cat "$t/profile.sb" 2>/dev/null)" "(subpath \"$kctmp\")" \
  "(the round's own temp directory, wherever --tmp points it, is what the profile names)"
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
# ...but not a variable the round sheds (T-121): with --shed, which
# the adapter passes unless config.yaml's billing: chose api-key, an ambient
# ANTHROPIC_API_KEY is no `given` login. The crew token is read and handed
# in, and the key never reaches the round - never a round with neither.
shed_run() {   # shed_run [--shed=NAME]... -> exit code; the round's view in $t/login.out
  rm -f "$t/login.out" "$t/kc/calls"; rm -rf "$kctmp"; mkdir -p "$kctmp"
  env FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" FM_KEYCHAIN_TOOL="$t/kc/security" \
    FM_SECRET_TOOL="$t/kc/secret-tool-guard" PATH="$lpath" ANTHROPIC_API_KEY=personal-key \
    "$SB" run --policy="$t/worker.json" --root="$root" --vendor=claude --ctl="$t/ctl" --tmp="$kctmp" "$@" \
    -- "$t/login.sh" "$t/login.out" </dev/null >/dev/null 2>"$t/login.err"
  echo $?
}
assert_eq "0" "$(shed_run --shed=ANTHROPIC_API_KEY --shed=ANTHROPIC_AUTH_TOKEN)" \
  "claude's round starts with an ambient ANTHROPIC_API_KEY it sheds"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "token=crew-claude-token" "and is handed the crew token as CLAUDE_CODE_OAUTH_TOKEN"
assert_lacks "$lo" "ANTHROPIC_API_KEY" "and never the shed key"
assert_contains "$(cat "$t/kc/calls" 2>/dev/null)" "firstmate-claude-token" "which fm read, since the key was not the login"
# without --shed (billing: api-key chose it) the key is the given login, as before
assert_eq "0" "$(shed_run)" "with the key chosen for billing, claude's round starts"
lo="$(cat "$t/login.out" 2>/dev/null)"
assert_contains "$lo" "ANTHROPIC_API_KEY=personal-key" "on that key"
assert_eq "" "$(cat "$t/kc/calls" 2>/dev/null)" "and the keychain is not read"
# login-source reads the same way, so fm-canary.sh and the probe agree
src="$(env FM_SANDBOX_OS=darwin FM_KEYCHAIN_TOOL="$t/kc/security" FM_SECRET_TOOL="$t/kc/secret-tool-guard" \
  ANTHROPIC_API_KEY=personal-key "$SB" login-source --policy="$t/worker.json" --vendor=claude \
  --shed=ANTHROPIC_API_KEY 2>/dev/null)"
assert_eq "tier=primary source=keychain:firstmate-claude-token" "$src" "login-source with --shed names the crew token too"
# login-env (the probe's): every credential the round would get, in one file
rm -rf "$t/le"; mkdir -p "$t/le/ctl" "$t/le/tmp"
env FM_SANDBOX_OS=darwin FM_KEYCHAIN_TOOL="$t/kc/security" FM_SECRET_TOOL="$t/kc/secret-tool-guard" \
  ANTHROPIC_API_KEY=personal-key "$SB" login-env --policy="$t/worker.json" --vendor=claude \
  --tmp="$t/le/tmp" --ctl="$t/le/ctl" --shed=ANTHROPIC_API_KEY >/dev/null 2>&1
assert_eq "CLAUDE_CODE_OAUTH_TOKEN=crew-claude-token" "$(cat "$t/le/ctl/env" 2>/dev/null)" \
  "login-env writes exactly the credential the round would get"
env FM_SANDBOX_OS=darwin FM_KEYCHAIN_TOOL="$t/kc/security" FM_SECRET_TOOL="$t/kc/secret-tool-guard" \
  CURSOR_API_KEY=key-from-env "$SB" login-env --policy="$t/worker.json" --vendor=cursor-agent \
  --tmp="$t/le/tmp" --ctl="$t/le/ctl" >/dev/null 2>&1
assert_contains "$(cat "$t/le/ctl/env" 2>/dev/null)" "CURSOR_API_KEY=key-from-env" \
  "and a given variable the round would inherit, too"
rm -rf "$t/le"
# expired, or no login at all: refused before the sandbox starts, which the
# adapter counts as the vendor unavailable
past=$(( ($(date +%s) - 60) * 1000 ))
cp "$t/kc/claude" "$t/kc/claude.good"
printf '{"claudeAiOauth":{"accessToken":"at-old","refreshToken":"rt","expiresAt":%s}}' "$past" > "$t/kc/claude"
assert_eq "77" "$(kc run darwin claude FM_KEYCHAIN_TOOL="$t/kc/security-nocrew")" \
  "an expired claude login refuses the round, with no crew token to fall back to first"
assert_contains "$(cat "$t/login.err")" "has expired" "and says so"
assert_contains "$(cat "$t/login.err")" "claude setup-token" \
  "and, since the crew's own tier has a hint, how to avoid this next time"
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
# with no crew token file either (T-126), this is the fallback tier, so it warns
assert_contains "$(cat "$t/login.err")" "has no crew token" "and the fallback warns, in the round's log (Linux)"
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
# cursor-agent's keychain item that exists but will not open refuses the
# round, the same as claude's crew item (T-126 round 7); it never falls
# through to the key file behind it. With the item truly missing (security
# exit 44), that same 0600 file is reached, so the refusal is the exit 36's.
sed "s/^  firstmate-cursor-api-key).*/  firstmate-cursor-api-key) echo 'security: SecKeychainItemCopyContent: User interaction is not allowed.' >\&2; exit 36 ;;/" \
  "$t/kc/security" > "$t/kc/security-cursor-locked"
sed "/firstmate-cursor-api-key)/d" "$t/kc/security" > "$t/kc/security-cursor-missing"
chmod +x "$t/kc/security-cursor-locked" "$t/kc/security-cursor-missing"
assert_eq "0" "$(kc run darwin cursor-agent FM_KEYCHAIN_TOOL="$t/kc/security-cursor-missing")" \
  "a missing crew Cursor keychain item on macOS falls through to the 0600 key file"
assert_contains "$(cat "$t/login.out" 2>/dev/null)" "cursorkey=key-cursor-file" "which is handed in"
assert_eq "77" "$(kc run darwin cursor-agent FM_KEYCHAIN_TOOL="$t/kc/security-cursor-locked")" \
  "a crew Cursor keychain item that will not open (security exit 36) refuses cursor-agent's round"
assert_contains "$(cat "$t/login.err" 2>/dev/null)" "keychain item 'firstmate-cursor-api-key' could not be read (exit 36" \
  "naming the item and its error"
assert_fail "test -e '$t/login.out'" "and the command never starts, on the key file behind it or otherwise"
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
  assert_eq "$kctmp/$lf_copy" "$(grep -m1 "/$lf_copy\$" <<< "$lo")" \
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
assert_eq "tier=primary source=keychain:firstmate-claude-token" "$src" "login-source names where claude's login is, and that it is the crew's own (T-126)"
assert_lacks "$src" "crew-claude-token" "and never prints it"
# off macOS, with no keychain, login-source names the libsecret item instead
# (T-126 round 2)
src="$(FM_SANDBOX_OS=linux FM_SECRET_TOOL="$t/kc/secret-tool" \
  "$SB" login-source --policy="$t/worker.json" --vendor=claude 2>&1)"
assert_eq "tier=primary source=secret:firstmate-claude-token" "$src" "and, on Linux, that it is the crew's libsecret item"
assert_lacks "$src" "crew-claude-secret" "and never prints it either"
# with no crew token, login-source says the fallback tier answered instead.
# FM_SECRET_TOOL is fm's own stub, never left to the host's real
# secret-tool(1) (T-126 round 4): the crew keychain item is absent here, so
# login_tier tries the secret tier next.
rm -f "$t/kc/secret-tool-guard-calls"
src="$(FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" FM_KEYCHAIN_TOOL="$t/kc/security-nocrew" \
  FM_SECRET_TOOL="$t/kc/secret-tool-guard" \
  "$SB" login-source --policy="$t/worker.json" --vendor=claude 2>&1)"
assert_eq "tier=fallback source=keychain:Claude Code-credentials" "$src" "and that a fallback tier answered when there is no crew token"
assert_lacks "$src" "at-claude" "and never prints it either"
assert_contains "$(cat "$t/kc/secret-tool-guard-calls" 2>/dev/null)" "firstmate-claude-token" \
  "and fm's own secret-tool stand-in answered here too, never the host's"
FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" FM_KEYCHAIN_TOOL="$t/no-such-security" \
  "$SB" login-source --policy="$t/nohome.json" --vendor=cursor-agent >/dev/null 2>&1
assert_eq "77" "$?" "and says 77 when the operator is not logged in"

# fm-canary.sh reports which login a claude round used (T-126 round 7):
# crew-token or interactive-fallback, read from login-source's stdout line
# alone, in its status line and its results record - never the token. The
# real bin/fm-canary.sh, the way tests/canary.test.sh runs it, with claude
# stood in: no OS sandbox tool, so the adapter refuses the round before
# anything starts and no model call is spent; the login is judged first.
cvh="$t/canary-home"; cvs="$t/canary-state"; cvt="$t/canary-tmp"
mkdir -p "$cvh/.config/firstmate" "$cvh/.claude" "$t/canary-bin" "$cvt"
printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { echo "9.9.9 (Claude Code)"; exit 0; }\ncat >/dev/null; exit 0\n' \
  > "$t/canary-bin/claude"
chmod +x "$t/canary-bin/claude"
canary_claude() {   # canary_claude -> the canary's stdout in $t/canary.out, stderr in $t/canary.err
  rm -rf "$cvs"
  ( cd "$ROOT" && env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY HOME="$cvh" TMPDIR="$cvt" \
      FM_CANARY_STATE_DIR="$cvs" FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$t/no-such-bwrap" \
      FM_SECRET_TOOL="$t/kc/secret-tool-guard" PATH="$t/canary-bin:$PATH" \
      bin/fm-canary.sh --sections=vendors --vendor=claude </dev/null >"$t/canary.out" 2>"$t/canary.err" )
}
printf 'crew-canary-token-SECRET\n' > "$cvh/.config/firstmate/claude-token"
chmod 600 "$cvh/.config/firstmate/claude-token"
printf '{"claudeAiOauth":{"accessToken":"at-canary-interactive-SECRET","refreshToken":"rt","expiresAt":%s}}' \
  "$future" > "$cvh/.claude/.credentials.json"
canary_claude
assert_eq "crew-token" "$(jq -r 'select(.vendor=="claude") | .login_source' "$cvs/results.jsonl" 2>/dev/null)" \
  "the canary records a claude round on the crew's own token as crew-token"
assert_contains "$(cat "$t/canary.out")" "login=crew-token" "and says so beside the vendor"
assert_eq "" "$(grep -rlF crew-canary-token-SECRET "$t/canary.out" "$t/canary.err" "$cvs" "$cvt" 2>/dev/null)" \
  "and the token itself appears in none of its output, records or scratch"
rm -f "$cvh/.config/firstmate/claude-token"
canary_claude
assert_eq "interactive-fallback" \
  "$(jq -r 'select(.vendor=="claude") | .login_source' "$cvs/results.jsonl" 2>/dev/null)" \
  "with no crew token, it records interactive-fallback"
assert_contains "$(cat "$t/canary.out")" "login=interactive-fallback" "and says so beside the vendor"
assert_eq "" "$(grep -rlF at-canary-interactive-SECRET "$t/canary.out" "$t/canary.err" "$cvs" "$cvt" 2>/dev/null)" \
  "and the interactive login appears in none of its output, records or scratch either"
rm -rf "$cvh" "$cvs" "$cvt" "$t/canary-bin"
# plain, the operator's hatch: every vendor still gets its login
assert_eq "0" "$(kc plain darwin claude)" "under the hatch claude's round starts, with the crew's own token"
assert_contains "$(cat "$t/login.out" 2>/dev/null)" "token=crew-claude-token" "with its login handed in"
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


safe_rm_rf "$t"
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
