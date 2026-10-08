#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/adapter.sh
. "$ROOT/tests/lib/adapter.sh"
# shellcheck source=tests/lib/adapter-policy.sh
. "$ROOT/tests/lib/adapter-policy.sh"
# --- a vendor with no login (T-117) -------------------------------------------
# Every vendor's login is read outside the round and handed in. A round
# with none to hand is refused before the sandbox starts, and reads as the
# vendor unavailable, so the chain moves on - never as a CLI that started
# and failed.
# The home is an empty one and the keychain's reader is not there, so
# whatever this runner is logged in to stays out of it. The policy is
# resolved once, before the loop: fm-config.sh's own loops use `v` too.
mkdir -p "$pv/nohome"
(
  export HOME="$pv/nohome"
  # shellcheck source=bin/fm-config.sh
  . "$ROOT/bin/fm-config.sh"
  printf 'vendor: mock\n' > "$pv/nl.yaml"; fm_policy worker "" "$pv/nl.yaml" > "$pv/nl.json"
)
# FM_SECRET_TOOL is pinned here too (T-126 round 4): claude is the one
# vendor with a libsecret tier, tried unconditionally, and naming none
# below would reach the host's own secret-tool, not this fixture's empty
# HOME (a comment naming it inside the "$( )" below breaks bash 3.2's
# parser on an apostrophe, so it is named here instead)
for nl_v in claude codex cursor-agent gemini; do
  rm -f "$pv/log"
  rc_nl="$(
    unset CLAUDE_CODE_OAUTH_TOKEN CURSOR_API_KEY ANTHROPIC_API_KEY CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
    export HOME="$pv/nohome" FM_KEYCHAIN_TOOL="$pv/no-such-security" FM_SECRET_TOOL="$pv/no-such-secret-tool"
    confined darwin "$pk/sandbox-exec" "$pv/nl.json" "$nl_v"
  )"
  assert_eq "2" "$rc_nl" "$nl_v with no login to hand in is unavailable"
  assert_fail "test -e '$pv/argv'" "and $nl_v's CLI never starts"
  assert_contains "$(cat "$pv/log" "$pv/err" 2>/dev/null)" "$nl_v is not logged in" "and it says so"
done

# --- a login kept in a file (T-117 round 2) ----------------------------------
# codex's auth.json and gemini's oauth_creds.json each hold a refresh
# token beside the access token. No round reads them in place: fm hands in
# a copy with the refresh token emptied, where the adapter points its CLI,
# so a round can neither refresh the operator's login nor spend a
# single-use refresh token. The fake CLI reports the login it finds where
# its vendor looks. cursor-agent's agent login file is here too, and its
# round never sees it.
lh="$pv/loginhome"
mkdir -p "$lh/.codex" "$lh/.gemini" "$lh/.config/cursor" "$lh/.config/firstmate"
future_ms=$(( ($(date +%s) + 3600) * 1000 ))
printf '{"OPENAI_API_KEY":null,"tokens":{"id_token":"id-codex","access_token":"at-codex","refresh_token":"rt-codex-secret","account_id":"acct"},"last_refresh":"2026-09-26T00:00:00Z"}' \
  > "$lh/.codex/auth.json"
printf '{"access_token":"at-gemini","refresh_token":"rt-gemini-secret","scope":"s","token_type":"Bearer","expiry_date":%s}' \
  "$future_ms" > "$lh/.gemini/oauth_creds.json"
printf '{"accessToken":"at-cursor","refreshToken":"rt-cursor-secret"}' > "$lh/.config/cursor/auth.json"
(
  export HOME="$lh"
  # shellcheck source=bin/fm-config.sh
  . "$ROOT/bin/fm-config.sh"
  printf 'vendor: mock\n' > "$pv/lh.yaml"; fm_policy worker "" "$pv/lh.yaml" > "$pv/lh.json"
)
assert_eq "[]" "$(jq -c '[.vendors[].auth[]]' "$pv/lh.json")" "no vendor's round reads a login file in place"
# where each vendor's CLI looks for its login, from the environment it is started with
cat > "$pv/copyfake" <<S
#!/usr/bin/env bash
cat > /dev/null
case "\$(basename "\$0")" in
  codex) f="\$CODEX_HOME/auth.json" ;;
  gemini) f="\$HOME/.gemini/oauth_creds.json" ;;
  *) f=/dev/null ;;
esac
{ printf 'file=%s\n' "\$f"; cat "\$f" 2>&1; echo; env; } > "$pv/copy"
printf 'ran\n'
S
for lf in "codex darwin at-codex rt-codex-secret .codex/auth.json" \
          "codex linux at-codex rt-codex-secret .codex/auth.json" \
          "gemini darwin at-gemini rt-gemini-secret .gemini/oauth_creds.json" \
          "gemini linux at-gemini rt-gemini-secret .gemini/oauth_creds.json"; do
  read -r lf_v lf_os lf_at lf_rt lf_file <<< "$lf"
  cp "$pv/copyfake" "$pv/fakebin/$lf_v"; chmod +x "$pv/fakebin/$lf_v"
  rm -f "$pv/copy" "$pk/profile.sb" "$pk/bwrap.args"
  lf_tool="$pk/sandbox-exec"; [ "$lf_os" = linux ] && lf_tool="$pk/bwrap"
  lf_rc="$(
    unset CLAUDE_CODE_OAUTH_TOKEN CURSOR_API_KEY ANTHROPIC_API_KEY CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
    export FM_KEYCHAIN_TOOL="$pv/no-such-security"
    FM_SANDBOX_OS="$lf_os" FM_SANDBOX_TOOL="$lf_tool" FM_POLICY="$pv/lh.json" PATH="$pv/fakebin:$closed_path" \
      "$ROOT/bin/adapters/$lf_v.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"
    echo $?
  )"
  lf_seen="$(cat "$pv/copy" 2>/dev/null)"
  assert_eq "0" "$lf_rc" "$lf_v's round starts on $lf_os with the login kept in its file"
  assert_contains "$lf_seen" "$lf_at" "$lf_v finds its access token where it looks ($lf_os)"
  assert_lacks "$lf_seen" "$lf_rt" "and never the refresh token ($lf_v, $lf_os)"
  assert_lacks "$(sed -n 's/^file=//p' <<< "$lf_seen")" "$lh" "the file it reads is a copy, not the operator's ($lf_v, $lf_os)"
  assert_lacks "$(grep -v '^(deny' "$pk/profile.sb" "$pk/bwrap.args" 2>/dev/null)" "$lh/$lf_file" \
    "and the round is given no way to the operator's login file ($lf_v, $lf_os)"
done
# cursor-agent (T-117 round 6) reads agent login's token through the
# keychain API, which no round reaches, so its round signs in with the
# crew's Cursor API key: fm's own keychain item on macOS, fm's own file
# elsewhere, handed in as CURSOR_API_KEY. The operator's keychain here
# holds that key and agent login's own items.
printf 'key-crew-file\n' > "$lh/.config/firstmate/cursor-api-key"
chmod 600 "$lh/.config/firstmate/cursor-api-key"
cat > "$pv/cursor-security" <<'S'
#!/usr/bin/env bash
s=''; while [ $# -gt 0 ]; do [ "$1" = -s ] && s="${2-}"; shift; done
case "$s" in
  firstmate-cursor-api-key) printf 'key-crew-kc\n' ;;
  cursor-access-token) printf 'at-cursor\n' ;;
  cursor-refresh-token) printf 'rt-cursor-secret\n' ;;
  *) echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44 ;;
esac
S
chmod +x "$pv/cursor-security"
cp "$pv/copyfake" "$pv/fakebin/cursor-agent"; chmod +x "$pv/fakebin/cursor-agent"
for cur in "darwin key-crew-kc" "linux key-crew-file"; do
  read -r cur_os cur_key <<< "$cur"
  rm -f "$pv/copy"
  cur_tool="$pk/sandbox-exec"; [ "$cur_os" = linux ] && cur_tool="$pk/bwrap"
  cur_rc="$(
    unset CLAUDE_CODE_OAUTH_TOKEN CURSOR_API_KEY ANTHROPIC_API_KEY CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
    export FM_KEYCHAIN_TOOL="$pv/cursor-security"
    FM_SANDBOX_OS="$cur_os" FM_SANDBOX_TOOL="$cur_tool" FM_POLICY="$pv/lh.json" PATH="$pv/fakebin:$closed_path" \
      "$ROOT/bin/adapters/cursor-agent.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"
    echo $?
  )"
  cur_seen="$(cat "$pv/copy" 2>/dev/null)"
  assert_eq "0" "$cur_rc" "cursor-agent's round starts on $cur_os with the crew's Cursor API key"
  assert_contains "$cur_seen" "CURSOR_API_KEY=$cur_key" "handed in as CURSOR_API_KEY ($cur_os)"
  assert_lacks "$cur_seen" "at-cursor" "never agent login's own token ($cur_os)"
  assert_lacks "$cur_seen" "rt-cursor-secret" "nor its refresh token ($cur_os)"
done
# claude (T-126): a crew token of fm's own - a keychain item of fm's own on
# macOS, else a file only the operator may read - is tried before the
# operator's own interactive login, through the real adapter
printf 'crew-claude-file\n' > "$lh/.config/firstmate/claude-token"
chmod 600 "$lh/.config/firstmate/claude-token"
cat > "$pv/claude-security" <<'S'
#!/usr/bin/env bash
s=''; while [ $# -gt 0 ]; do [ "$1" = -s ] && s="${2-}"; shift; done
case "$s" in
  firstmate-claude-token) printf 'crew-claude-kc\n' ;;
  'Claude Code-credentials') printf '{"claudeAiOauth":{"accessToken":"at-claude-interactive","refreshToken":"rt","expiresAt":9999999999999}}\n' ;;
  *) echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44 ;;
esac
S
chmod +x "$pv/claude-security"
# claude as copyfake, saying one line of its own on stderr first: the
# round's stderr must reach its log (T-126 round 7)
{ head -1 "$pv/copyfake"; echo 'echo claude-own-stderr-line >&2'; tail -n +2 "$pv/copyfake"; } > "$pv/fakebin/claude"
chmod +x "$pv/fakebin/claude"
# The default FM_SECRET_TOOL for every claude block below that does not name
# its own (T-126 round 4): never the host's real secret-tool(1). On Linux
# login_tier reads no keychain at all, so a claude case here that leaves
# FM_SECRET_TOOL unset would, on a runner that happens to have secret-tool
# on PATH and no D-Bus session to answer it, get whatever that produces
# instead of the fixture's own answer. This stub answers like the real tool
# - nothing on stdout, nothing on stderr, exit 1: "no such item", which a
# stderr line would turn into a failed read (T-126 round 7) - and records
# every call.
cat > "$pv/claude-secret-tool-guard" <<'S'
#!/usr/bin/env bash
[ -z "${FM_SECRET_TOOL_GUARD_LOG:-}" ] || echo "$*" >> "$FM_SECRET_TOOL_GUARD_LOG" 2>/dev/null
exit 1
S
chmod +x "$pv/claude-secret-tool-guard"
for cl in "darwin crew-claude-kc" "linux crew-claude-file"; do
  read -r cl_os cl_key <<< "$cl"
  rm -f "$pv/copy" "$pv/secret-guard-calls" "$pv/log"
  cl_tool="$pk/sandbox-exec"; [ "$cl_os" = linux ] && cl_tool="$pk/bwrap"
  cl_rc="$(
    unset CLAUDE_CODE_OAUTH_TOKEN CURSOR_API_KEY ANTHROPIC_API_KEY CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
    export FM_KEYCHAIN_TOOL="$pv/claude-security" FM_SECRET_TOOL="$pv/claude-secret-tool-guard" \
      FM_SECRET_TOOL_GUARD_LOG="$pv/secret-guard-calls"
    FM_SANDBOX_OS="$cl_os" FM_SANDBOX_TOOL="$cl_tool" FM_POLICY="$pv/lh.json" PATH="$pv/fakebin:$closed_path" \
      "$ROOT/bin/adapters/claude.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"
    echo $?
  )"
  cl_seen="$(cat "$pv/copy" 2>/dev/null)"
  assert_eq "0" "$cl_rc" "claude's round starts on $cl_os with the crew's own token (T-126)"
  assert_contains "$cl_seen" "CLAUDE_CODE_OAUTH_TOKEN=$cl_key" "handed in as CLAUDE_CODE_OAUTH_TOKEN ($cl_os)"
  assert_lacks "$cl_seen" "at-claude-interactive" "never the operator's interactive login while a crew token exists ($cl_os)"
  assert_contains "$(cat "$pv/log" 2>/dev/null)" "claude-own-stderr-line" \
    "and claude's own stderr reaches the round's log, never dropped ($cl_os)"
  assert_lacks "$(cat "$pv/err" 2>/dev/null)" "claude-own-stderr-line" \
    "while only fm-sandbox's own lines are repeated on the adapter's stderr ($cl_os)"
  if [ "$cl_os" = linux ]; then
    assert_contains "$(cat "$pv/secret-guard-calls" 2>/dev/null)" "firstmate-claude-token" \
      "and, with no keychain on Linux, fm's own secret-tool stand-in was asked, never the host's real one"
  fi
done
# and, off macOS, the crew's own libsecret item - secret-tool(1) - answers
# before that same file, through the real adapter too (T-126 round 2)
cat > "$pv/claude-secret-tool" <<'S'
#!/usr/bin/env bash
shift  # drop 'lookup'
svc=''; acct=''
while [ $# -gt 0 ]; do
  case "$1" in
    service) svc="${2-}"; shift 2 ;;
    account) acct="${2-}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$svc" in
  firstmate-claude-token) printf '%s' 'crew-claude-secret' ;;
  *) exit 1 ;;
esac
S
chmod +x "$pv/claude-secret-tool"
rm -f "$pv/copy"
cl_rc="$(
  unset CLAUDE_CODE_OAUTH_TOKEN CURSOR_API_KEY ANTHROPIC_API_KEY CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
  export FM_KEYCHAIN_TOOL="$pv/claude-security" FM_SECRET_TOOL="$pv/claude-secret-tool"
  FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$pk/bwrap" FM_POLICY="$pv/lh.json" PATH="$pv/fakebin:$closed_path" \
    "$ROOT/bin/adapters/claude.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"
  echo $?
)"
cl_seen="$(cat "$pv/copy" 2>/dev/null)"
assert_eq "0" "$cl_rc" "claude's round starts on Linux with the crew's libsecret item too (T-126 round 2)"
assert_contains "$cl_seen" "CLAUDE_CODE_OAUTH_TOKEN=crew-claude-secret" "handed in as CLAUDE_CODE_OAUTH_TOKEN"
assert_lacks "$cl_seen" "crew-claude-file" "and never the file while libsecret answers"
# with no crew token anywhere, claude's round falls back to the operator's
# own interactive login - as it always has - through the real adapter too.
# On Linux there is no keychain (login_tier reads one only on darwin), so
# the fallback's own file tier is what a real Claude Code CLI's interactive
# login lives in there: ~/.claude/.credentials.json, the same shape the
# keychain stand-in above answers with on macOS.
rm -f "$lh/.config/firstmate/claude-token" "$pv/copy" "$pv/err" "$pv/secret-guard-calls"
mkdir -p "$lh/.claude"
printf '{"claudeAiOauth":{"accessToken":"at-claude-interactive","refreshToken":"rt","expiresAt":9999999999999}}' \
  > "$lh/.claude/.credentials.json"
cl_rc="$(
  unset CLAUDE_CODE_OAUTH_TOKEN CURSOR_API_KEY ANTHROPIC_API_KEY CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
  export FM_KEYCHAIN_TOOL="$pv/claude-security" FM_SECRET_TOOL="$pv/claude-secret-tool-guard" \
    FM_SECRET_TOOL_GUARD_LOG="$pv/secret-guard-calls"
  FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$pk/bwrap" FM_POLICY="$pv/lh.json" PATH="$pv/fakebin:$closed_path" \
    "$ROOT/bin/adapters/claude.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"
  echo $?
)"
assert_eq "0" "$cl_rc" "with no crew token, claude's round still starts on the interactive login"
assert_contains "$(cat "$pv/copy" 2>/dev/null)" "CLAUDE_CODE_OAUTH_TOKEN=at-claude-interactive" \
  "handed in the same way as before T-126"
assert_contains "$(cat "$pv/err" 2>/dev/null)" "has no crew token" "and the fallback warns"
assert_contains "$(cat "$pv/err" 2>/dev/null)" "claude setup-token" "naming the fix, the crew tier's own hint"
assert_contains "$(cat "$pv/secret-guard-calls" 2>/dev/null)" "firstmate-claude-token" \
  "and fm's own secret-tool stand-in was asked while reaching that fallback, never the host's real one"
# a crew keychain item that exists but will not open (security exit 36) is
# not a missing one (T-126 round 7): the round is refused through the real
# adapter too, saying why, and never started on the interactive login the
# stand-in still answers for
sed "s/^  firstmate-claude-token).*/  firstmate-claude-token) echo 'security: SecKeychainItemCopyContent: User interaction is not allowed.' >\&2; exit 36 ;;/" \
  "$pv/claude-security" > "$pv/claude-security-locked"
chmod +x "$pv/claude-security-locked"
rm -f "$pv/copy" "$pv/err"
cl_rc="$(
  unset CLAUDE_CODE_OAUTH_TOKEN CURSOR_API_KEY ANTHROPIC_API_KEY CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
  export FM_KEYCHAIN_TOOL="$pv/claude-security-locked" FM_SECRET_TOOL="$pv/claude-secret-tool-guard"
  FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" FM_POLICY="$pv/lh.json" PATH="$pv/fakebin:$closed_path" \
    "$ROOT/bin/adapters/claude.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"
  echo $?
)"
assert_ne "0" "$cl_rc" "a crew keychain item that will not open refuses claude's round"
assert_contains "$(cat "$pv/err" 2>/dev/null)" "'firstmate-claude-token' could not be read (exit 36" \
  "saying which item and why, on the adapter's stderr"
assert_fail "test -e '$pv/copy'" "and claude never starts, on the interactive login or any other"
rm -f "$lh/.claude/.credentials.json"
# gemini is told its login is Google's, and runs with a HOME of the round's own
cp "$pv/copyfake" "$pv/fakebin/gemini"; chmod +x "$pv/fakebin/gemini"
( unset GEMINI_API_KEY GOOGLE_API_KEY CODEX_API_KEY
  FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" FM_POLICY="$pv/lh.json" PATH="$pv/fakebin:$closed_path" \
    "$ROOT/bin/adapters/gemini.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>&1 )
assert_contains "$(cat "$pv/copy" 2>/dev/null)" "GOOGLE_GENAI_USE_GCA=true" "gemini with no API key signs in with the copy"
assert_matches "$(sed -n 's/^HOME=//p' "$pv/copy" 2>/dev/null)" '/fm-round\.[A-Za-z0-9]+/gemini-home$' \
  "from a HOME of the round's own"
# a login file whose refresh token the policy does not name is refused, not handed in
printf '{"access_token":"at-gemini","refresh_token":"","refreshToken":"rt-moved-secret","expiry_date":%s}' \
  "$future_ms" > "$lh/.gemini/oauth_creds.json"
rm -f "$pv/copy" "$pv/log"
lf_rc="$(unset GEMINI_API_KEY GOOGLE_API_KEY
  FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" FM_POLICY="$pv/lh.json" PATH="$pv/fakebin:$closed_path" \
    "$ROOT/bin/adapters/gemini.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"; echo $?)"
assert_eq "2" "$lf_rc" "a login file still holding a refresh token under another name refuses the round"
assert_fail "test -e '$pv/copy'" "and the CLI never starts"
# fm-sandbox.sh says it where the adapter sends everything the launch says:
# the round's log
assert_contains "$(cat "$pv/log" "$pv/err" 2>/dev/null)" "refresh token" "and says why"

# --- the operator's escape hatch (T-117) --------------------------------------
# FM_ROUND_UNSANDBOXED is set by fm-worker.sh and fm-review.sh only from the
# operator's own FM_CREW_UNSANDBOXED. With it, a host whose OS sandbox is
# broken or missing still runs the round - the vendors' own sandboxes on,
# the scrub and the ulimits as ever - and the adapter says so loudly.
for v in claude codex cursor-agent gemini; do
  assert_eq "0" "$(FM_ROUND_UNSANDBOXED=1 confined darwin "$pv/no-such-sandbox" "$pk/none.json" "$v")" \
    "$v runs under the operator's hatch though the host has no OS sandbox"
  assert_ok "test -e '$pv/argv'" "($v's CLI did run)"
  if [ "$v" = cursor-agent ]; then
    # T-219 fail-first: plain mode also gets a fresh short data directory.
    plain_data="$(sed -n 's/^CURSOR_DATA_DIR=//p' "$pv/env")"
    assert_matches "$plain_data" '^(/private)?/tmp/fmc\.[A-Za-z0-9]+$' "Cursor plain mode receives private data"
    assert_lacks "$(cat "$pv/argv")" "--write=" "Cursor plain CLI receives no write argument"
    if [ -n "$plain_data" ]; then
      assert_fail "test -d '$plain_data'" "Cursor plain data is cleaned up"
    fi
  fi
  assert_fail "test -e '$pk/profile.sb'" "with no sandbox profile around it"
  assert_contains "$(cat "$pv/err")" "WITHOUT the OS sandbox" "and $v says so on stderr"
  assert_contains "$(cat "$pv/env" 2>/dev/null)" "FM_IN_ROUND=1" "the round is still marked as one"
  assert_lacks "$(cat "$pv/env" 2>/dev/null)" "FM_ROUND_UNSANDBOXED" "and never sees the hatch itself"
done
FM_ROUND_UNSANDBOXED=1 confined darwin "$pv/no-such-sandbox" "$pk/none.json" cursor-agent >/dev/null
assert_eq "enabled" "$(awk 'on{print;exit} $0=="--sandbox"{on=1}' "$pv/argv")" \
  "under the hatch cursor-agent's own sandbox is back on"
assert_eq "" "$(grep -xE -- '-f|--force' "$pv/argv")" "and it is not forced: no OS sandbox is there to confine what -f lets through"
FM_ROUND_UNSANDBOXED=1 confined darwin "$pv/no-such-sandbox" "$pk/none.json" codex >/dev/null
assert_eq "workspace-write" "$(awk 'on{print;exit} $0=="--sandbox"{on=1}' "$pv/argv")" "and codex's"
# and claude's, with T-066's settings: every shell command inside it, none
# let out, its network the policy's registries and nothing else - and the
# shell allowed because it is sandboxed, not by a rule of its own. Under the
# OS sandbox the same adapter turns it off (above).
for hat_pol in none net; do
  FM_ROUND_UNSANDBOXED=1 confined darwin "$pv/no-such-sandbox" "$pk/$hat_pol.json" claude >/dev/null
  hat_set="$(settings_of)"
  assert_eq "true" "$(jq -r '.sandbox.enabled' <<< "$hat_set" 2>/dev/null)" \
    "under the hatch claude's own sandbox is back on ($hat_pol)"
  assert_eq "true false" "$(jq -r '"\(.sandbox.autoAllowBashIfSandboxed) \(.sandbox.allowUnsandboxedCommands)"' <<< "$hat_set" 2>/dev/null)" \
    "every shell command runs inside it and none is let out ($hat_pol)"
  assert_eq "$(jq -c .network "$pk/$hat_pol.json")" "$(jq -c '.sandbox.network.allowedDomains' <<< "$hat_set" 2>/dev/null)" \
    "and its network is the policy's registries ($hat_pol)"
  assert_eq "" "$(awk '$0=="--allowedTools"{on=1;next} /^--/{on=0} on' "$pv/argv" | grep -x Bash || true)" \
    "no rule allows the shell outside it ($hat_pol)"
  assert_eq "false" "$(jq -r 'any(.permissions.allow[]; . == "Bash")' <<< "$hat_set" 2>/dev/null)" \
    "in the settings either ($hat_pol)"
  assert_ne "" "$(awk '$0=="--disallowedTools"{on=1;next} /^--/{on=0} on' "$pv/argv" | grep -xF 'Bash(git push:*)')" \
    "and its deny rules still refuse a push ($hat_pol)"
done
# gemini's own sandbox is a container or a seatbelt the adapter never turns
# on, so under the hatch its round has none (design 13.1 says so)
FM_ROUND_UNSANDBOXED=1 confined darwin "$pv/no-such-sandbox" "$pk/none.json" gemini >/dev/null
assert_eq "" "$(grep -xE -- '--sandbox|-s' "$pv/argv" || true)" "under the hatch gemini runs with no sandbox of its own"
# inside a round the hatch is not there to take
for v in claude codex cursor-agent gemini; do
  assert_eq "2" "$(FM_ROUND_UNSANDBOXED=1 FM_IN_ROUND=1 confined darwin "$pv/no-such-sandbox" "$pk/none.json" "$v")" \
    "$v inside a round cannot take the hatch"
  assert_fail "test -e '$pv/argv'" "and $v's CLI never starts unconfined"
  assert_contains "$(cat "$pv/err")" "ignoring it" "and says it ignored the hatch"
done

# An adapter reached without FM_POLICY - by hand, or by a caller that does
# not know about one - takes the engine's own policy for its role, never none
unset FM_POLICY
for v in claude codex cursor-agent gemini; do
  printf '#!/usr/bin/env bash\ncat > /dev/null\nprintf "%%s\\n" "$@" > "%s/argv"\nprintf "ran\\n"\nexit 0\n' \
    "$pv" > "$pv/fakebin/$v"; chmod +x "$pv/fakebin/$v"
  rm -f "$pv/argv" "$pk/profile.sb"
  # the engine's own policy resolves "~" when the adapter starts, so the
  # suite's login home is the home it starts in: codex's and gemini's round
  # login is the file there, never a key the round sheds (T-121)
  HOME="$pk/home" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" PATH="$pv/fakebin:$closed_path" \
    "$ROOT/bin/adapters/$v.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"
  assert_eq "0" "$?" "$v with no FM_POLICY still runs, under the engine's own policy"
  assert_contains "$(cat "$pk/profile.sb" 2>/dev/null)" "(subpath \"$phome/.ssh\")" \
    "and that policy's profile keeps ~/.ssh out of reach"
done
# and a policy file that is named but missing refuses the round
FM_POLICY="$pv/no-such-policy.json" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" \
  PATH="$pv/fakebin:$closed_path" "$ROOT/bin/adapters/claude.sh" run "$pv/prompt" "$pv/tree" "$pv/log" \
  >/dev/null 2>"$pv/err"
assert_eq "65" "$?" "a named policy that is not there refuses the round"
assert_contains "$(cat "$pv/err")" "no policy at" "and says so"

# --- credentials that would outrank the round's own login (T-121) ----------
# Ambient in the operator's own shell, each of these would silently switch a
# round to billing per key or per use instead of the login fm hands in
# (2026-09-26/27). Shed unless config.yaml names the vendor in billing:.
# FM_ADAPTER_CONFIG stands in for config.yaml the same way FM_POLICY stands
# in for a resolved policy, so this suite never has to edit the real one.
#
# fm_adapter_policy reads the policy's network list with a real python3, not
# a heredoc; on a host where /usr/bin/python3 is the unlicensed Xcode stub
# rather than a working interpreter, $pv/fakebin's own entry below stands in
# for it, ahead of /usr/bin in $PATH, for exactly this block.
printf '#!/usr/bin/env bash\nexec %s "$@"\n' \
  "$(printf '%q' "$closed_path/python3")" > "$pv/fakebin/python3" && chmod +x "$pv/fakebin/python3"
outrank_env() { sed -n "s/^$1=.*/$1/p" "$pv/env" 2>/dev/null; }
for pair in "claude ANTHROPIC_API_KEY leaked-personal-key" "claude ANTHROPIC_AUTH_TOKEN leaked-token" \
            "claude CLAUDE_CODE_USE_BEDROCK 1" "claude CLAUDE_CODE_USE_VERTEX 1" \
            "codex OPENAI_API_KEY leaked-openai-key" "codex CODEX_API_KEY leaked-codex-key" \
            "gemini GEMINI_API_KEY leaked-gemini-key" "gemini GOOGLE_API_KEY leaked-google-key"; do
  # shellcheck disable=SC2034  # val is read through the eval below, not here
  read -r v var val <<< "$pair"
  or_rc="$(eval "$var=\"\$val\" CLAUDE_CODE_OAUTH_TOKEN=fm-suite-token CURSOR_API_KEY=fm-suite-key \
    confined darwin \"\$pk/sandbox-exec\" \"\$pk/none.json\" \"\$v\"")"
  # the round has to have actually reached the CLI, or "no $var" is true of
  # a round that never ran at all, which is not what this asserts
  assert_eq "0" "$or_rc" "$v's round still starts with $var ambient"
  assert_eq "" "$(outrank_env "$var")" "$v's round never sees an ambient $var"
done
# a vendor config.yaml names in billing: keeps it, exactly as before T-121
cat > "$pv/billing.yaml" <<'CFG'
billing:
  claude: api-key
CFG
bi_rc="$(FM_ADAPTER_CONFIG="$pv/billing.yaml" ANTHROPIC_API_KEY=chosen-on-purpose CLAUDE_CODE_OAUTH_TOKEN=fm-suite-token \
  confined darwin "$pk/sandbox-exec" "$pk/none.json" claude)"
assert_eq "0" "$bi_rc" "claude still starts with billing: api-key chosen"
assert_contains "$(cat "$pv/env" 2>/dev/null)" "ANTHROPIC_API_KEY=chosen-on-purpose" \
  "billing: claude: api-key in config.yaml keeps ANTHROPIC_API_KEY, rather than shedding it"
unset FM_ADAPTER_CONFIG
# The real `given` path (T-121): an ambient ANTHROPIC_API_KEY that
# the round sheds, with no billing: entry and no token handed in by the
# caller, is no login of the round's. fm-sandbox.sh must not count it as
# `given` - it reads the crew token instead and hands it in - or the
# adapter's shedding would start the round with no credential at all.
printf '#!/usr/bin/env bash\ns=""; while [ $# -gt 0 ]; do [ "$1" = -s ] && s="${2-}"; shift; done\n[ "$s" = firstmate-claude-token ] || exit 44\necho crew-claude-token\n' \
  > "$pv/security"
chmod +x "$pv/security"
gv_rc="$(unset CLAUDE_CODE_OAUTH_TOKEN; FM_KEYCHAIN_TOOL="$pv/security" FM_SECRET_TOOL="$pv/no-secret-tool" \
  ANTHROPIC_API_KEY=leaked-personal-key confined darwin "$pk/sandbox-exec" "$pk/none.json" claude)"
assert_eq "0" "$gv_rc" "claude's round starts with only an ambient ANTHROPIC_API_KEY it sheds"
assert_contains "$(cat "$pv/env" 2>/dev/null)" "CLAUDE_CODE_OAUTH_TOKEN=crew-claude-token" \
  "and gets the crew token fm resolved, not no credential at all"
assert_eq "" "$(outrank_env ANTHROPIC_API_KEY)" "and never the shed key"
# gemini signs in with the Google-account flow once its API-key variables
# are shed, exactly as it does with none set at all
ge_rc="$(GEMINI_API_KEY=leaked-gemini-key confined darwin "$pk/sandbox-exec" "$pk/none.json" gemini)"
assert_eq "0" "$ge_rc" "gemini still starts once its API key is shed"
assert_contains "$(cat "$pv/env" 2>/dev/null)" "GOOGLE_GENAI_USE_GCA=true" \
  "gemini still signs in with the account flow once its API key is shed"
# cursor-agent has no such variable to shed: CURSOR_API_KEY is the only
# login this design ever hands it, never a credential that outranks another
cu_rc="$(CURSOR_API_KEY=fm-suite-key confined darwin "$pk/sandbox-exec" "$pk/none.json" cursor-agent)"
assert_eq "0" "$cu_rc" "cursor-agent still starts with its own login variable set"
assert_contains "$(cat "$pv/env" 2>/dev/null)" "CURSOR_API_KEY=fm-suite-key" \
  "cursor-agent's own login variable is never shed"

# --- the round holds exactly the credential its policy names (T-121) -------
# Not only "the shed ones are absent": with every login-bearing variable of
# every vendor ambient in the operator's shell, each vendor's round holds
# its own login and nothing else - claude only CLAUDE_CODE_OAUTH_TOKEN,
# cursor-agent only CURSOR_API_KEY, codex no variable at all but the copy
# of auth.json in its CODEX_HOME, less its refresh token, gemini its login
# file's copy and GOOGLE_GENAI_USE_GCA=true. The fake (copyfake, above)
# records the login file the CLI would read and its whole environment.
# the list itself, read with no sandbox in the way: every other vendor's
# credentials, and never the round's own login
shed_of() { bash -c '. "$1/bin/adapters/_lib.sh"; fm_adapter_shed "$2"' _ "$ROOT" "$1" | tr '\n' ' '; }
for fs in "claude CLAUDE_CODE_OAUTH_TOKEN CURSOR_API_KEY OPENAI_API_KEY GEMINI_API_KEY" \
          "cursor-agent CURSOR_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY CODEX_API_KEY" \
          "codex CODEX_HOME CLAUDE_CODE_OAUTH_TOKEN CURSOR_API_KEY GOOGLE_API_KEY" \
          "gemini GOOGLE_GENAI_USE_GCA ANTHROPIC_AUTH_TOKEN CURSOR_API_KEY OPENAI_API_KEY"; do
  read -r fs_v fs_own fs_others <<< "$fs"
  fs_list=" $(shed_of "$fs_v")"
  assert_lacks "$fs_list" " $fs_own " "$fs_v's round never sheds its own login ($fs_own)"
  for n in $fs_others; do
    assert_contains "$fs_list" " $n " "$fs_v's round sheds another vendor's $n"
  done
done
cred_names='CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
  CURSOR_API_KEY OPENAI_API_KEY CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENAI_USE_GCA GOOGLE_APPLICATION_CREDENTIALS'
for fs in "claude CLAUDE_CODE_OAUTH_TOKEN=fm-suite-token" "cursor-agent CURSOR_API_KEY=fm-suite-key" \
          "codex -" "gemini GOOGLE_GENAI_USE_GCA=true"; do
  read -r fs_v fs_want <<< "$fs"
  [ "$fs_want" != - ] || fs_want=''
  cp "$pv/copyfake" "$pv/fakebin/$fs_v"; chmod +x "$pv/fakebin/$fs_v"
  rm -f "$pv/copy"
  fs_rc="$(
    export CLAUDE_CODE_OAUTH_TOKEN=fm-suite-token CURSOR_API_KEY=fm-suite-key \
      ANTHROPIC_API_KEY=ambient ANTHROPIC_AUTH_TOKEN=ambient CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 \
      OPENAI_API_KEY=ambient CODEX_API_KEY=ambient GEMINI_API_KEY=ambient GOOGLE_API_KEY=ambient \
      GOOGLE_APPLICATION_CREDENTIALS=/nowhere
    FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" FM_POLICY="$pk/none.json" PATH="$pv/fakebin:$closed_path" \
      "$ROOT/bin/adapters/$fs_v.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"
    echo $?
  )"
  fs_seen="$(cat "$pv/copy" 2>/dev/null)"
  fs_have=''
  for n in $cred_names; do
    fs_val="$(sed -n "s/^$n=//p" <<< "$fs_seen" | head -1)"
    [ -z "$fs_val" ] || fs_have="$fs_have $n=$fs_val"
  done
  assert_eq "0" "$fs_rc" "$fs_v's round starts with every vendor's credentials ambient"
  assert_eq "$fs_want" "${fs_have# }" "a $fs_v round holds exactly the credential its policy names, and no other"
  case "$fs_v" in
    codex|gemini)
      fs_file="$(sed -n 's/^file=//p' <<< "$fs_seen")"
      assert_contains "$fs_seen" "at-suite" "$fs_v reads its login from the copy of its login file"
      assert_lacks "$fs_seen" "rt-suite" "a copy that holds no refresh token ($fs_v)"
      assert_lacks "$fs_file" "$phome" "and is never the operator's own file ($fs_v)" ;;
  esac
done


safe_rm_rf "$pv"
safe_rm_rf "$pk" "$closed_path"
finish
