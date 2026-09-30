#!/usr/bin/env bash
# fm-auth-probe.sh (T-121): a fixed-argv, stdin-closed, scrubbed, time-boxed
# check of the login a crew round would get - resolved by fm-sandbox.sh's own
# lookup, never the operator's own session - and never the vendor's output.
set -uo pipefail
# A live managed round exports FM_* into this shell; suites must not inherit it.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
# nothing of the machine running the suite may stand in for a round's login
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
  CURSOR_API_KEY CODEX_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

PROBE="$ROOT/bin/fm-auth-probe.sh"
assert_ok "test -x '$PROBE'" "fm-auth-probe.sh is executable"

d="$(safe_tmpdir)"
# The operator's home and keychain, stood in for: HOME is the suite's, the
# keychain is a stub that holds only what a test puts in $d/keychain, and
# secret-tool is never the machine's. FM_SANDBOX_OS=darwin so the keychain
# tier is read on every runner.
home="$d/home"; mkdir -p "$home"
export HOME="$home" FM_SANDBOX_OS=darwin FM_SECRET_TOOL="$d/no-secret-tool"
export FM_KEYCHAIN_TOOL="$d/security"
mkdir -p "$d/keychain"
{
  printf '#!/usr/bin/env bash\n'
  printf '# security find-generic-password -s <service> -a <account> -w\n'
  printf 'f="%s/keychain/$3"\n' "$d"
  printf '[ -f "$f" ] || exit 44\n'
  printf 'cat "$f"\n'
} > "$d/security"
chmod +x "$d/security"

bin="$d/bin"; mkdir -p "$bin"
# What a real CLI said is replayed from its recorded transcript
# (tests/fixtures/auth-status), never words made up here. fake() is for
# the probe's own classifier cases - expired, quota, noise, silence - which
# no recording here holds; its replies are the probe's signatures, not a
# vendor's words.
FIX="$ROOT/tests/fixtures/auth-status"
fake() {  # fake <vendor> <version line> <status-argv reply> <exit code>
  local v="$1" ver="$2" reply="$3" rc="$4"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "$1" = --version ]; then printf %%s\\\\n %s; exit 0; fi\n' "$(printf '%q' "$ver")"
    printf 'printf %%s\\\\n %s\n' "$(printf '%q' "$reply")"
    printf 'exit %s\n' "$rc"
  } > "$bin/$v"
  chmod +x "$bin/$v"
}
recorded() {  # recorded <vendor> <fixture>: answers exactly as the recorded CLI did
  local v="$1" f="$FIX/$2.txt"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "$1" = --version ]; then exec %q %q --version; fi\n' "$FIX/replay.sh" "$f"
    printf 'exec %q %q\n' "$FIX/replay.sh" "$f"
  } > "$bin/$v"
  chmod +x "$bin/$v"
}

# --- the recordings themselves: each says where it came from ----------------
for f in "$FIX"/*.txt; do
  n="$(basename "$f" .txt)"
  for key in recorded command cli date exit; do
    assert_ne "" "$(sed -n "s/^# $key: //p" "$f" | head -1)" "fixture $n names its $key"
  done
done
for n in claude-signed-in claude-signed-out codex-signed-in codex-signed-out cursor-agent-signed-in cursor-agent-signed-out; do
  assert_eq "yes" "$(sed -n 's/^# recorded: //p' "$FIX/$n.txt" | head -1)" "$n is a recording of the real CLI"
done
run() { PATH="$bin:$PATH" "$PROBE" "$@"; }
field() { sed -n "s/^$2: //p" <<<"$1" | head -1; }

# The logins a round could use, each where fm-sandbox.sh's lookup finds it
crew_claude() { mkdir -p "$home/.config/firstmate"; printf 'crew-claude-token\n' > "$home/.config/firstmate/claude-token"
                chmod 600 "$home/.config/firstmate/claude-token"; }
crew_cursor() { mkdir -p "$home/.config/firstmate"; printf 'crew-cursor-key\n' > "$home/.config/firstmate/cursor-api-key"
                chmod 600 "$home/.config/firstmate/cursor-api-key"; }
codex_auth()  { mkdir -p "$home/.codex"
                printf '{"tokens":{"access_token":"codex-access","refresh_token":"codex-refresh"}}\n' > "$home/.codex/auth.json"; }
no_logins()   { rm -rf "$home/.config/firstmate" "$home/.codex" "$home/.gemini" "$home/.claude" "$d/keychain"/*; }
crew_claude; crew_cursor; codex_auth

# --- not installed ----------------------------------------------------------
out="$(env PATH="$d/empty:/usr/bin:/bin" "$PROBE" claude 2>&1)"
assert_eq "unavailable" "$(field "$out" status)" "a vendor not on PATH is unavailable"
assert_ne "" "$(field "$out" en)" "and says so in English"
assert_ne "" "$(field "$out" tw)" "and in Traditional Chinese"

# --- usage -------------------------------------------------------------------
"$PROBE" >/dev/null 2>&1; assert_eq "64" "$?" "no vendor argument is a usage error"
"$PROBE" not-a-vendor >/dev/null 2>&1; assert_eq "64" "$?" "an unknown vendor is a usage error"

# --- authenticated, as the recorded CLIs said it ---------------------------
recorded claude claude-signed-in
out="$(run claude)"
assert_eq "authenticated" "$(field "$out" status)" "claude's recorded loggedIn:true is authenticated"
assert_eq "2.1.284 (Claude Code)" "$(field "$out" version)" "and the probed version is recorded"

recorded codex codex-signed-in
out="$(run codex)"
assert_eq "authenticated" "$(field "$out" status)" "codex's recorded 'Logged in using ChatGPT' is authenticated"

recorded cursor-agent cursor-agent-signed-in
out="$(run cursor-agent)"
assert_eq "authenticated" "$(field "$out" status)" "cursor-agent's recorded exit-0 '✓ Logged in as …' is authenticated"
assert_eq "2026.09.23-86fc751" "$(field "$out" version)" "and its probed version is recorded"

# --- unauthenticated, per vendor's own recorded wording --------------------
recorded claude claude-signed-out
assert_eq "unauthenticated" "$(field "$(run claude)" status)" "claude's recorded loggedIn:false is unauthenticated"

recorded codex codex-signed-out
assert_eq "unauthenticated" "$(field "$(run codex)" status)" "codex's recorded 'Not logged in' is unauthenticated"

recorded cursor-agent cursor-agent-signed-out
assert_eq "unauthenticated" "$(field "$(run cursor-agent)" status)" "cursor-agent's recorded exit-0 'Not logged in' is unauthenticated too"

# --- the login asked about is the round's, not the operator's session -----
# (T-121). Each fake answers "signed in" only when it is handed the
# credential a round gets, and marks $d/<vendor>-status when its status is
# asked at all. Both answers are the vendor's recorded ones.
fake_checks() {  # fake_checks <vendor> <bash condition> <yes fixture> <no fixture>
  local v="$1" cond="$2" yes="$FIX/$3.txt" no="$FIX/$4.txt"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "$1" = --version ]; then exec %q %q --version; fi\n' "$FIX/replay.sh" "$yes"
    printf 'touch %q\n' "$d/$v-status"
    printf 'env > %q\n' "$d/$v-env"
    printf 'if %s; then exec %q %q; fi\n' "$cond" "$FIX/replay.sh" "$yes"
    printf 'exec %q %q\n' "$FIX/replay.sh" "$no"
  } > "$bin/$v"
  chmod +x "$bin/$v"
  rm -f "$d/$v-status" "$d/$v-env"
}

# cursor-agent: the crew key kept only in the keychain item is the round's
# login, handed in as CURSOR_API_KEY
no_logins
printf 'crew-cursor-key' > "$d/keychain/firstmate-cursor-api-key"
fake_checks cursor-agent '[ "${CURSOR_API_KEY:-}" = crew-cursor-key ]' cursor-agent-signed-in cursor-agent-signed-out
out="$(run cursor-agent)"
assert_eq "authenticated" "$(field "$out" status)" "cursor-agent with the crew key in the keychain only is authenticated"
assert_contains "$(cat "$d/cursor-agent-env" 2>/dev/null)" "CURSOR_API_KEY=crew-cursor-key" \
  "and the probe hands it the keychain item as CURSOR_API_KEY, as the round gets it"

# cursor-agent: the operator's own `agent login` works, but there is no crew
# key - a round would have no login, so the probe refuses before asking
no_logins
fake_checks cursor-agent 'true' cursor-agent-signed-in cursor-agent-signed-out
out="$(run cursor-agent)"
assert_eq "unauthenticated" "$(field "$out" status)" "an interactive agent login with no crew key is refused"
assert_contains "$(field "$out" en)" "firstmate-cursor-api-key" "naming the keychain item a round's login comes from"
assert_ok "[ ! -e '$d/cursor-agent-status' ]" "and cursor-agent's own status is never asked about the operator's session"

# claude: the crew token is handed in as CLAUDE_CODE_OAUTH_TOKEN, and an
# ambient ANTHROPIC_API_KEY the round sheds is neither counted nor handed in
no_logins; crew_claude
fake_checks claude '[ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = crew-claude-token ] && [ -z "${ANTHROPIC_API_KEY:-}" ]' \
  claude-signed-in claude-signed-out
out="$(ANTHROPIC_API_KEY=personal-key run claude)"
assert_eq "authenticated" "$(field "$out" status)" "claude with a crew token and an ambient API key probes the crew token"
assert_lacks "$(cat "$d/claude-env" 2>/dev/null)" "ANTHROPIC_API_KEY" "the ambient key the round sheds never reaches the probe"
assert_contains "$(cat "$d/claude-env" 2>/dev/null)" "CLAUDE_CONFIG_DIR=" "claude reads a config directory of the probe's own"
assert_lacks "$(cat "$d/claude-env" 2>/dev/null)" "CLAUDE_CONFIG_DIR=$home" "never one under the operator's home"

# claude: no crew token and no interactive fallback, only an ambient key the
# round would shed - no login a round could use
no_logins
fake_checks claude '[ -n "${ANTHROPIC_API_KEY:-}" ]' claude-signed-in claude-signed-out
out="$(ANTHROPIC_API_KEY=personal-key run claude)"
assert_eq "unauthenticated" "$(field "$out" status)" "an ambient ANTHROPIC_API_KEY alone, not chosen for billing, is no round login"
assert_ok "[ ! -e '$d/claude-status' ]" "and claude is never asked about it"

# claude: the operator chose api-key billing, so that key is the round's login
printf 'billing:\n  claude: api-key\n' > "$d/billing.yaml"
out="$(FM_ADAPTER_CONFIG="$d/billing.yaml" ANTHROPIC_API_KEY=personal-key run claude)"
assert_eq "authenticated" "$(field "$out" status)" "with claude: api-key billing, the ambient key is the round's login"

# claude: the interactive fallback tier is what a round without a crew token
# uses (with a warning), so the probe uses it too
no_logins
printf '{"claudeAiOauth":{"accessToken":"operator-access","expiresAt":%s}}' "$(( ($(date +%s) + 86400) * 1000 ))" \
  > "$d/keychain/Claude Code-credentials"
fake_checks claude '[ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = operator-access ]' claude-signed-in claude-signed-out
assert_eq "authenticated" "$(field "$(run claude)" status)" "claude with only the interactive fallback probes that fallback, as the round would"

# codex: the round's CODEX_HOME holds a copy of auth.json less its refresh
# token; the probe reads that copy and nothing of ~/.codex
no_logins; codex_auth
fake_checks codex \
  'grep -q codex-access "$CODEX_HOME/auth.json" && ! grep -q codex-refresh "$CODEX_HOME/auth.json" && [ -z "${OPENAI_API_KEY:-}" ]' \
  codex-signed-in codex-signed-out
out="$(OPENAI_API_KEY=personal-key run codex)"
assert_eq "authenticated" "$(field "$out" status)" "codex probes the round's copy of auth.json, less its refresh token"
assert_lacks "$(cat "$d/codex-env" 2>/dev/null)" "OPENAI_API_KEY" "and never the ambient OPENAI_API_KEY the round sheds"

# codex: no auth.json, only an ambient key - refused before codex is asked
no_logins
fake_checks codex 'true' codex-signed-in codex-signed-out
out="$(OPENAI_API_KEY=personal-key CODEX_API_KEY=personal-key run codex)"
assert_eq "unauthenticated" "$(field "$out" status)" "codex with no auth.json and only ambient keys is refused"
assert_contains "$(field "$out" en)" "codex login" "with codex's own fix"
assert_ok "[ ! -e '$d/codex-status' ]" "and codex is never asked"
crew_claude; crew_cursor; codex_auth

# --- gemini: no documented status command, never a guess ------------------
# (T-121): with the round's login present it is indeterminate, which a
# round never runs on - and nothing but --version runs
no_logins
# no recording is needed: nothing but --version may ever run, and the fake
# marks $d/gemini-status if anything else does
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$1" = --version ]; then echo 0.60.0; exit 0; fi\n'
  printf 'touch %q\n' "$d/gemini-status"
  printf 'exit 0\n'
} > "$bin/gemini"
chmod +x "$bin/gemini"; rm -f "$d/gemini-status"
mkdir -p "$home/.gemini"
printf '{"access_token":"g","refresh_token":"r","expiry_date":%s}' "$(( ($(date +%s) + 86400) * 1000 ))" \
  > "$home/.gemini/oauth_creds.json"
out="$(run gemini)"
assert_eq "indeterminate" "$(field "$out" status)" "gemini with a login present is indeterminate, never authenticated"
assert_eq "0.60.0" "$(field "$out" version)" "gemini's version is still probed with --version"
assert_contains "$(field "$out" en)" "login cannot be verified, so rounds on it are refused" \
  "and says in English that its login cannot be verified, so rounds on it are refused"
assert_contains "$(field "$out" tw)" "拒絕在其上執行回合" "and in Traditional Chinese"
assert_ok "[ ! -e '$d/gemini-status' ]" "gemini is never asked anything but --version; no guessed argv runs"
printf '{"access_token":"g","refresh_token":"r","expiry_date":1000}' > "$home/.gemini/oauth_creds.json"
assert_eq "expired" "$(field "$(run gemini)" status)" "gemini's expired login is expired, a definite no"
rm -rf "$home/.gemini"
assert_eq "unauthenticated" "$(field "$(run gemini)" status)" "and no gemini login at all is unauthenticated"
crew_claude; crew_cursor; codex_auth

# --- expired -------------------------------------------------------------
fake claude "claude 2.1.3" "Your session has expired" 1
assert_eq "expired" "$(field "$(run claude)" status)" "an expired session is reported as expired, not unauthenticated"

# --- quota-exhausted -------------------------------------------------------
fake codex "codex-cli 0.1.0" "quota exceeded for this organisation" 1
out="$(run codex)"
assert_eq "quota-exhausted" "$(field "$out" status)" "a quota message is reported as quota-exhausted"

# --- indeterminate: exit 0 and nothing to show, or noise this probe cannot read
fake claude "claude 2.1.3" "" 0
assert_eq "indeterminate" "$(field "$(run claude)" status)" "a silent success is indeterminate, not authenticated"
fake claude "claude 2.1.3" "not valid json and no known phrase at all" 3
assert_eq "indeterminate" "$(field "$(run claude)" status)" "an answer with no recognised signature is indeterminate"
assert_ne "authenticated" "$(field "$(run claude)" status)" "indeterminate is never read as authenticated"

# --- timeout ---------------------------------------------------------------
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$1" = --version ]; then echo "claude 2.1.3"; exit 0; fi\n'
  printf 'sleep 5\n'
  printf 'echo late\n'
} > "$bin/claude"
chmod +x "$bin/claude"
out="$(FM_AUTH_PROBE_TIMEOUT=1 run claude)"
assert_eq "timeout" "$(field "$out" status)" "a status check that does not answer in time is a timeout"
assert_contains "$(field "$out" en)" "rounds on it are refused" "and says a round on it is refused"

# --- nothing the status check starts outlives the probe (T-151) -------------
# A hanging status check with a child of its own, both holding the write
# end of $d/held. The kernel gives the suite's reader EOF only once every
# holder has exited, so "no process of the check is left" is read from the
# kernel, not by polling a pid; a survivor shows as the bounded read timing
# out. $d/started says the check is running before anything is killed.
hang_check() {
  rm -f "$d/started" "$d/held" "$d/hang-pids"; mkfifo "$d/started" "$d/held"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "$1" = --version ]; then echo "claude 2.1.3"; exit 0; fi\n'
    printf 'exec 3<>%q\n' "$d/held"
    printf 'sleep 30 &\n'
    printf 'echo "$$ $!" > %q\n' "$d/hang-pids"
    printf 'echo started > %q\n' "$d/started"
    printf 'exec sleep 30\n'
  } > "$bin/claude"
  chmod +x "$bin/claude"
}
check_started=''
await_check() {  # opens $d/held for reading once the check says it runs
  check_started=''
  read -r -t 10 -u 4 _ || return 0
  exec 5<"$d/held"; check_started=1
}
gone=''
check_gone() {  # gone=1 when every holder of $d/held has exited within 8s
  local start="$SECONDS"
  if [ -z "$check_started" ]; then gone='the status check never started'; return; fi
  # read by the clock, not the exit status: macOS's bash 3.2 returns 1 for
  # a timed-out read as for EOF
  read -r -t 8 -u 5 _
  if [ "$((SECONDS - start))" -lt 6 ]; then gone=1; else gone='a process of the check was still running 8s later'; fi
  exec 5<&-
}
end_leftovers() {  # a red run's survivors are ended here, not left to ci.sh
  local p
  for p in $(cat "$d/hang-pids" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
}
mkdir -p "$d/probe-tmp"

hang_check
exec 4<>"$d/started"
( exec 4>&-; PATH="$bin:$PATH" TMPDIR="$d/probe-tmp" FM_AUTH_PROBE_TIMEOUT=1 exec "$PROBE" claude ) \
  > "$d/probe-out" 2>/dev/null &
probe_pid=$!
await_check
wait "$probe_pid"
assert_eq "timeout" "$(field "$(cat "$d/probe-out")" status)" "a hanging check with a child of its own is a timeout"
check_gone
assert_eq "1" "$gone" "and neither the check nor anything it started outlives the probe"
end_leftovers

hang_check
exec 4<>"$d/started"
( exec 4>&-; PATH="$bin:$PATH" TMPDIR="$d/probe-tmp" FM_AUTH_PROBE_TIMEOUT=60 exec "$PROBE" claude ) \
  >/dev/null 2>&1 &
probe_pid=$!
await_check
kill -KILL "$probe_pid"; wait "$probe_pid" 2>/dev/null
check_gone
assert_eq "1" "$gone" "a probe killed outright mid-check leaves no process of the check behind"
end_leftovers
exec 4>&-

# --- fixed argv: an operator argument never reaches the probe --------------
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$1" = --version ]; then echo "claude 2.1.3"; exit 0; fi\n'
  printf 'printf %%s\\\\n "$*" > "%s/argv-seen"\n' "$d"
  printf 'exec %q %q\n' "$FIX/replay.sh" "$FIX/claude-signed-in.txt"
} > "$bin/claude"
chmod +x "$bin/claude"
rm -f "$d/argv-seen"
FM_ADAPTER_ARGS="--dangerously-skip-permissions" run claude >/dev/null
assert_eq "auth status" "$(cat "$d/argv-seen" 2>/dev/null)" "the probe's argv is fixed, whatever FM_ADAPTER_ARGS says"

# --- stdin closed ------------------------------------------------------------
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$1" = --version ]; then echo "claude 2.1.3"; exit 0; fi\n'
  printf 'if read -t 1 -r line; then echo "read: $line"; else exec %q %q; fi\n' "$FIX/replay.sh" "$FIX/claude-signed-in.txt"
} > "$bin/claude"
chmod +x "$bin/claude"
out="$(printf 'a secret line\n' | run claude)"
assert_eq "authenticated" "$(field "$out" status)" "the probe's stdin is closed, not the caller's"

# --- scrubbed environment: only what the round's login needs ---------------
fake_checks claude 'true' claude-signed-in claude-signed-out
GH_TOKEN=secret-token SOME_OTHER_SECRET=x run claude >/dev/null
env_seen="$(cat "$d/claude-env" 2>/dev/null)"
assert_lacks "$env_seen" "GH_TOKEN" "the probe's environment carries none of the caller's unrelated secrets"
assert_lacks "$env_seen" "SOME_OTHER_SECRET" "nor anything else of the caller's shell"
assert_contains "$env_seen" "CLAUDE_CODE_OAUTH_TOKEN=crew-claude-token" "but does carry the login the round would get"
assert_lacks "$env_seen" "HOME=$home" "and a HOME of the probe's own, as a round's is, not the operator's"

# --- never echoes the vendor's own output, or a secret ----------------------
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$1" = --version ]; then echo "claude 2.1.3"; exit 0; fi\n'
  printf 'echo "sk-ant-totally-a-real-secret-token, not logged in"\n'
} > "$bin/claude"
chmod +x "$bin/claude"
out="$(run claude)"
assert_lacks "$out" "sk-ant-totally-a-real-secret-token" "the vendor's own line never reaches this script's own stdout"
assert_lacks "$out" "crew-claude-token" "and neither does the round's login"

# --- only authenticated is usable: the one rule fm-worker.sh, fm-review.sh
# and fm doctor apply to the probe's answer (fm_auth_refuses) --------------
( . "$ROOT/bin/adapters/_lib.sh"
  for st in unauthenticated expired quota-exhausted indeterminate timeout unavailable some-new-word ''; do
    fm_auth_refuses "$st" || echo "admitted:${st:-<empty>}"
  done
  fm_auth_refuses authenticated && echo "refused:authenticated"
) > "$d/refuses" 2>&1
assert_eq "" "$(cat "$d/refuses")" \
  "every answer but authenticated refuses a round - indeterminate and timeout included - and authenticated does not"

rm -rf "$d"
finish
