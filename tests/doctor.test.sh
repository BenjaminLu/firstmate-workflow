#!/usr/bin/env bash
# fm doctor (T-121): says, for every dependency and every vendor login,
# whether it works here and how to fix it.
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# Hygiene fixtures read only their own Git ignore rules.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
DOCTOR="$ROOT/bin/fm-doctor.sh"
assert_ok "test -x '$DOCTOR'" "fm-doctor.sh is executable"
assert_eq "__pycache__/" "$(grep -v '^[[:space:]]*#' "$ROOT/.gitignore" | grep -x '__pycache__/')" \
  ".gitignore ignores __pycache__/, so a stray one no longer makes a worktree look dirty"

d="$(safe_tmpdir)"
repo="$d/repo"; mkdir -p "$repo"
facts="$d/facts"; : > "$facts"
# Facts are tab-separated data, never executable stubs or a fake PATH.
# tool: name, path, version, raw first version line, xcrun-shim path.
# probe: vendor, status, English explanation, Traditional Chinese explanation.
fact() {
  local kind="$1" name="$2"; shift 2
  awk -F '\t' -v k="$kind" -v n="$name" '!($1==k && $2==n)' "$facts" > "$facts.next"
  printf '%s\t%s' "$kind" "$name" >> "$facts.next"
  printf '\t%s' "$@" >> "$facts.next"; printf '\n' >> "$facts.next"
  mv "$facts.next" "$facts"
}
tool() { fact tool "$1" "/tools/$1" "${2-}" "${2-}" "${3-}"; }
missing() { fact tool "$1" ""; }
# The fixture supplies both pins and observations; the host's versions never decide a judgment.
toolchain='[tools]\nbun = "1.3.11"\npython = "3.14.6"\n"ubi:jqlang/jq" = "1.7.1"\n"ubi:cli/cli" = "2.63.0"\nnode = "20"\nshellcheck = "0.10.0"\n'
# shellcheck disable=SC2059  # the format is the file's own text, escapes included
printf "$toolchain" > "$repo/mise.toml"
version_for_pin() {  # a numeric mise prefix becomes a full CLI version
  local version="$1"
  case "$version" in
    *.*.*) ;;
    *.*) version="$version.0" ;;
    *) version="$version.0.0" ;;
  esac
  printf '%s\n' "$version"
}
pin_of() {  # pin_of <mise.toml key> -> a full version satisfying the fixture's pin
  local pin
  pin="$(
  awk -F' = ' -v k="$1" '{ g = $1; gsub(/"/, "", g); if (g == k) { v = $2; gsub(/"/, "", v); print v } }' \
    "$repo/mise.toml"
  )"
  version_for_pin "$pin"
}
version_fact() { tool "$1" "$(grep -oE '[0-9]+(\.[0-9]+){1,3}' <<<"$2" | head -1)"; }
for key in bun python ubi:jqlang/jq ubi:cli/cli node shellcheck; do
  case "$key" in python) name=python3 ;; ubi:jqlang/jq) name=jq ;; ubi:cli/cli) name=gh ;; *) name="$key" ;; esac
  tool "$name" "$(pin_of "$key")"
done
tool git 2.43.0; tool perl; tool herdr 1.0.0; tool fm-test-sandbox
fact host os darwin
fact host sandbox /tools/fm-test-sandbox
printf 'vendor: claude\n' > "$repo/config.yaml"
mkdir -p "$repo/state/worktrees"

unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY CURSOR_API_KEY CODEX_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
run_doctor() { "$DOCTOR" --facts "$facts" --repo "$repo" "$@"; }

# One collector smoke test. No assertion names tools the host must have.
"$DOCTOR" --collect --repo "$repo" > "$d/collected"
assert_eq "0" "$?" "the real collector emits facts without judging the host"
assert_contains "$(cat "$d/collected")" $'host\tos\t' "the collector records the host platform"

out="$(run_doctor)"; rc=$?
assert_contains "$out" "Toolchain" "doctor prints a toolchain section"
assert_contains "$out" "+ fm-test-sandbox" "the sandbox tool checked is the one FM_SANDBOX_TOOL names, as fm-sandbox.sh uses"
assert_lacks "$out" "bwrap" "never the host's own by uname"
assert_lacks "$out" "sandbox-exec" "nor the platform's default, when a tool is named"
assert_contains "$out" "bun" "and names bun"
assert_contains "$out" "+ bun" "which is ok at the pinned version"
assert_contains "$out" "ok 1.3.11 (pinned 1.3.11)" "saying ok, the word the acceptance names"
assert_eq "0" "$rc" "with every pin met and every vendor uninstalled but skipped, doctor is not bad"
# T-078, folded in: a missing vendor CLI says how to install it too, not
# only that it is missing
assert_contains "$out" "not installed" "an uninstalled vendor is named missing"
assert_contains "$out" "install: npm install -g @anthropic-ai/claude-code" "and claude's own install line is given"
assert_contains "$out" "install: curl https://cursor.com/install -fsS | bash" "cursor-agent's own install line is given"

assert_contains "$out" "+ node" "node is checked against its pin: bunx playwright runs on it"
assert_contains "$out" "+ shellcheck" "shellcheck is checked against its pin"
assert_contains "$out" "0.10.0 (pinned 0.10.0)" "the supplied shellcheck version is compared with its pin"
assert_contains "$out" "+ perl" "perl, the system's own, is checked rather than pinned"
assert_lacks "$out" "pins no" "a mise.toml pinning every tool ci.sh and the board call has no gap"

# --- the sandbox tool is the one fm-sandbox.sh would use, never uname's ------
# A Linux observation with no bwrap, then macOS with no sandbox-exec.
fact host os linux; fact host sandbox bwrap
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x bwrap            missing; fix: apt install bubblewrap" \
  "FM_SANDBOX_OS=linux checks bwrap, whatever the host runs"
assert_eq "1" "$rc" "and a missing one makes doctor bad"
fact host os darwin; fact host sandbox sandbox-exec
out="$(run_doctor)"
assert_contains "$out" "x sandbox-exec     missing; fix: sandbox-exec ships with macOS as /usr/bin/sandbox-exec" \
  "FM_SANDBOX_OS=darwin checks sandbox-exec, whatever the host runs, with macOS's own fix"
assert_lacks "$out" "bwrap" "and never bwrap"
fact host sandbox "$d/no-such-sandbox"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x no-such-sandbox" "a FM_SANDBOX_TOOL that is not there is reported x"
assert_contains "$out" "FM_SANDBOX_TOOL names $d/no-such-sandbox, which is not there" "saying which setting names it"
assert_eq "1" "$rc" "and doctor's exit is bad"

fact host sandbox /tools/fm-test-sandbox

# --- mise.toml itself must pin every tool bin/ci.sh and the board call -------
# the repository's own file, checked by the same doctor: a pin dropped from
# it (node, shellcheck, ...) turns this red
cp "$ROOT/mise.toml" "$repo/mise.toml"
out="$(run_doctor)"
assert_lacks "$out" "pins no" "the repository's own mise.toml pins every tool bin/ci.sh and the board call"
# and a mise.toml without one is reported, with the fix, and makes doctor bad
grep -v '^shellcheck' "$ROOT/mise.toml" > "$repo/mise.toml"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x shellcheck" "a mise.toml with no shellcheck pin is reported x"
assert_contains "$out" "missing from mise.toml: it pins no shellcheck, which bin/ci.sh or the board calls" "saying which tool and why"
assert_eq "1" "$rc" "and doctor's exit is bad"
grep -v '^node' "$ROOT/mise.toml" > "$repo/mise.toml"
out="$(run_doctor)"
assert_contains "$out" "missing from mise.toml: it pins no node" "and so is one with no node pin"
# shellcheck disable=SC2059  # the format is the file's own text, escapes included
printf "$toolchain" > "$repo/mise.toml"

# --- a missing tool ----------------------------------------------------------
# A missing observation stays missing even when the host has gh.
missing gh
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x gh" "a missing pinned tool is reported x, not ok"
assert_contains "$out" "x gh               missing (pinned 2.63.0)" "and says missing, the word the acceptance names"
assert_contains "$out" "mise install" "with the one command that fixes it"
assert_eq "1" "$rc" "and doctor's own exit reflects it"
version_fact gh "gh version $(pin_of ubi:cli/cli)"

# --- a tool older than its pin ------------------------------------------------
version_fact jq "jq-1.5"
out="$(run_doctor)"
assert_contains "$out" "x jq" "an older-than-pinned tool is reported x too"
assert_contains "$out" "wrong version: 1.5, older than the pin 1.7.1" "and says wrong version, and why"
version_fact jq "jq-$(pin_of ubi:jqlang/jq)"

# --- xcrun tool observations are judged without constructing a fake Mac ---
tool git "" /shims/git
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x git              wrong version: /shims/git is Apple's xcrun shim" "a collected git shim is refused"
assert_contains "$out" "fix: install git ahead of /usr/bin on PATH (brew install git), or accept the Xcode licence" "with the tool's repair"
assert_lacks "$out" "+ git" "a shim is never also reported ok"
assert_eq "1" "$rc" "a shim makes doctor bad"
tool git 2.43.0
tool python3 "" /shims/python3
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x python3          wrong version: /shims/python3 is Apple's xcrun shim" "a collected Python shim is refused"
assert_contains "$out" "fix: install python3 ahead of /usr/bin on PATH (brew install python)" "with the Python repair"
assert_eq "1" "$rc" "a pinned shim makes doctor bad"
tool python3 "$(pin_of python)"
out="$(run_doctor)"
assert_contains "$out" "+ python3" "a real Python observation is accepted"
assert_lacks "$out" "xcrun shim" "and is not called a shim"

# --- vendor logins: only 'authenticated' counts as usable --------------------
# Auth probe decoding lives in auth-probe.test.sh. Doctor judges its observations.
FIX="$ROOT/tests/fixtures/auth-status"
tool claude 2.1.284
fact probe claude authenticated "claude's own status check confirms the login" "登入已確認"
out="$(run_doctor)"
assert_contains "$out" "+ claude" "an authenticated vendor is reported ok"
assert_contains "$out" "ok: claude's own status check confirms" "saying ok"
missing claude

tool codex 0.155.1
fact probe codex unauthenticated "run codex login" "請執行 codex login"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x codex" "an unauthenticated vendor is reported x, not ok"
assert_contains "$out" "codex login" "with codex's own fix"
assert_eq "1" "$rc" "and it is what makes doctor's own exit code bad"
missing codex

# --- too old: a vendor CLI older than the oldest version known to have the
# status check the probe runs, and herdr older than 0.9.1 (T-078, folded in)
# the floors are the versions the transcripts were recorded from. The
# function goes to a file first: a <(...) handed to a sourcing child inside
# $(...) is lost under macOS's bash 3.2.
sed -n '/^vendor_min() {/,/^}/p' "$DOCTOR" > "$d/vendor_min.sh"
for v in claude codex cursor-agent; do
  rec="$(sed -n 's/^# cli: //p' "$FIX/$v-signed-out.txt" | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -1)"
  floor="$(bash -c '. "$1"; vendor_min "$2"' _ "$d/vendor_min.sh" "$v")"
  assert_eq "$rec" "$floor" "$v's floor is the version its status check was recorded from"
done
version_fact claude "2.1.0 (Claude Code)"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x claude           wrong version: 2.1.0, older than 2.1.284" "a vendor CLI too old for its status check is wrong version"
assert_contains "$out" "install: npm install -g @anthropic-ai/claude-code" "with its install line"
assert_eq "1" "$rc" "and doctor's exit is bad"
missing claude
version_fact herdr "herdr 0.9.0"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x herdr            wrong version: 0.9.0, older than 0.9.1" "herdr older than 0.9.1 is wrong version"
assert_contains "$out" "install herdr 0.9.1 or later" "with the line that installs it"
assert_eq "1" "$rc" "and doctor's exit is bad"
version_fact herdr "herdr 1.0.0"
out="$(run_doctor)"
assert_contains "$out" "+ herdr            ok 1.0.0 (at least 0.9.1)" "a new enough herdr is ok"

# gemini has no status command: with a round's login present its probe is
# indeterminate, which is never read as authenticated - so doctor says
# plainly, in both languages, that rounds on it are refused
version_fact gemini "0.60.0"
fact probe gemini indeterminate "gemini's login cannot be verified, so rounds on it are refused" "登入無法驗證，因此拒絕在其上執行回合"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x gemini" "a vendor whose login cannot be verified is x, not ok"
assert_contains "$out" "gemini's login cannot be verified, so rounds on it are refused" "said in English"
assert_contains "$out" "拒絕在其上執行回合" "and in Traditional Chinese"
# Login refusal and hook verification are separate judgments: unknown hook
# loading/delivery must remain visible even when a vendor login is refused.
assert_lacks "$out" "+ gemini" "and never offered as usable but unverified"
hook_status="$(sed -n '/^  ! claude: source=/p' <<<"$out")"
assert_contains "$hook_status" "loading=unverified" "hook loading remains explicitly unverified alongside refused login"
assert_contains "$hook_status" "delivery=unverified" "hook delivery remains explicitly unverified alongside refused login"
assert_eq "1" "$rc" "and it makes doctor's exit code bad, like any vendor a round cannot use"
missing gemini

# --- no config.yaml yet: doctor hands off to fm setup ------------------------
# A scratch copy of bin/, so the real fm-setup.sh is never touched: fm-doctor.sh
# execs "$(dirname itself)/fm-setup.sh", so a fake beside a copy of doctor,
# fm-config.sh and adapters/_lib.sh is a full stand-in for that path alone.
d2="$(safe_tmpdir)"; mkdir -p "$d2/bin/adapters"
cp "$DOCTOR" "$ROOT/bin/fm-config.sh" "$d2/bin/"
cp "$ROOT/bin/adapters/_lib.sh" "$d2/bin/adapters/"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "fm-setup ran: $*" > "%s/setup-ran"\n' "$d2"
  printf 'exit 3\n'
} > "$d2/bin/fm-setup.sh"
chmod +x "$d2/bin/fm-setup.sh"
noconfig="$d2/repo"; mkdir -p "$noconfig"
out="$("$d2/bin/fm-doctor.sh" --repo "$noconfig" 2>&1)"; rc=$?
assert_contains "$out" "fm setup" "with no config.yaml, doctor says it is handing off to fm setup"
assert_ok "test -f '$d2/setup-ran'" "and actually hands off to it"
assert_eq "3" "$rc" "carrying its exit code back"

# --- the environment section warns about a credential that would outrank ----
# the round's own login, and says so only when config.yaml did not choose it
out="$(ANTHROPIC_API_KEY=leftover-from-personal-use run_doctor)"
assert_contains "$out" "ANTHROPIC_API_KEY" "an ambient outranking credential is named"
assert_contains "$out" "would shed it" "and doctor says a round would shed it"
# every name on the one list the adapters shed (fm_adapter_outranking) is
# warned about, read from that list rather than a copy of it
outranking="$(bash -c '. "$1/bin/adapters/_lib.sh"; for v in claude codex gemini; do fm_adapter_outranking "$v"; done' _ "$ROOT")"
assert_ne "" "$outranking" "the adapters' outranking list is there to compare against"
out="$(while IFS= read -r n; do [ -n "$n" ] && export "$n=set-in-this-shell"; done <<<"$outranking"
       run_doctor)"
missed=''
while IFS= read -r n; do
  [ -n "$n" ] || continue
  grep -qE "^  ! $n +set in this shell" <<<"$out" || missed="$missed $n"
done <<<"$outranking"
assert_eq "" "$missed" "doctor warns about every variable the adapters shed, and misses none"

printf 'vendor: claude\nbilling:\n  claude: api-key\n' > "$repo/config.yaml"
out="$(ANTHROPIC_API_KEY=chosen-on-purpose run_doctor)"
assert_contains "$out" "api-key billing for claude" "chosen billing is reported as used as is, not a warning"
printf 'vendor: claude\n' > "$repo/config.yaml"

# --- repository hygiene: what git status would show in each worktree ------
# Real temporary repositories cover hygiene; tool judgments still consume facts.
REAL_GIT="$(command -v git)"
hygiene_doctor() { run_doctor; }
out="$(hygiene_doctor)"
assert_contains "$out" "no untracked build cache in any worktree" "a clean state/worktrees is reported clean"
wt="$repo/state/worktrees/T-1"
mkdir -p "$wt/bin/__pycache__" "$wt/lib/.pytest_cache/v"
"$REAL_GIT" init -q "$wt"
touch "$wt/bin/__pycache__/a.pyc" "$wt/bin/__pycache__/b.pyc" "$wt/lib/.pytest_cache/v/x" "$wt/work.txt"
out="$(hygiene_doctor)"
assert_contains "$out" "! T-1" "a worktree with an untracked build cache is flagged, by name"
assert_contains "$out" "bin/__pycache__" "naming the cache directory git shows"
assert_contains "$out" "lib/.pytest_cache" "every kind of build cache, not only __pycache__"
assert_lacks "$out" "work.txt" "and never ordinary untracked work, which is the round's"
assert_lacks "$out" "a.pyc" "one line per cache directory, not per file"
# ignored, git never shows it, and it cannot make the worktree look dirty
printf '__pycache__/\n.pytest_cache/\n' > "$wt/.gitignore"
out="$(hygiene_doctor)"
assert_lacks "$out" "! T-1" "a build cache the worktree's .gitignore ignores is not flagged"
assert_contains "$out" "no untracked build cache in any worktree" "and the worktrees are reported clean"
# a cache under a directory that is not a worktree at all is not git's to show
rm -rf "$wt"; mkdir -p "$wt/bin/__pycache__"; touch "$wt/bin/__pycache__/a.pyc"
out="$(hygiene_doctor)"
assert_lacks "$out" "! T-1" "a directory that is not a git worktree is not asked about"
rm -rf "$wt"

# --- --fix asks before installing, and does nothing when everything is met -
out="$(printf 'n\n' | run_doctor --fix)"
assert_contains "$out" "Fixing" "--fix runs a fixing pass"

# An explicit installer path in the supplied facts records the approved action.
: > "$d/mise-calls"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/mise-calls"\n' "$d" > "$d/mise"
chmod +x "$d/mise"
fact tool mise "$d/mise"
missing gh
asked="$(printf 'n\n' | run_doctor --fix 2>&1)"
assert_contains "$asked" "install ubi:cli/cli" "it asks before installing"
assert_eq "" "$(cat "$d/mise-calls")" "a no answer installs nothing"
printf 'y\n' | run_doctor --fix >/dev/null 2>&1
assert_contains "$(cat "$d/mise-calls")" "install ubi:cli/cli@2.63.0" "a yes answer runs the pinned install"
missing mise
tool gh "$(pin_of ubi:cli/cli)"

# --- --sandbox: every summary line is read from the record it describes ----
# A scratch bin/ whose fm-canary.sh stands in for a real run: it appends the
# records in $d3/fixture.jsonl, stamped with the run id doctor hands it
# (FM_CANARY_RUN), to FM_CANARY_STATE_DIR/results.jsonl, exactly where and
# how the real canary's record() writes them, and exits $d3/rc.
d3="$d/sandbox-bin"; mkdir -p "$d3/adapters"
cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-doctor.sh" "$d3/"
cp "$ROOT/bin/adapters/_lib.sh" "$d3/adapters/"
{
  printf '#!/usr/bin/env bash\n'
  printf 'jq -c --arg r "$FM_CANARY_RUN" %s %s >> "$FM_CANARY_STATE_DIR/results.jsonl"\n' \
    "'.run = \$r'" "$(printf '%q' "$d3/fixture.jsonl")"
  printf 'echo "canary ran"\n'
  printf 'exit "$(cat %s)"\n' "$(printf '%q' "$d3/rc")"
} > "$d3/fm-canary.sh"
chmod +x "$d3/fm-canary.sh" "$d3/fm-doctor.sh"
mkdir -p "$repo/state/canary"
sandbox_doctor() { "$d3/fm-doctor.sh" --facts "$facts" --repo "$repo" --sandbox; }
blocked_probes='{"write_outside":"blocked","read_ssh":"blocked","github":"blocked","loopback":"blocked","herdr_socket":"blocked","other_round_tmp":"blocked","gh_token":"blocked","git_credential":"blocked","keychain":"n/a","pasteboard":"n/a"}'
ran_record() {  # ran_record <vendor> <probes json> <own_loopback> -> a started, authenticated record
  printf '{"at":"2026-09-29T00:00:00Z","vendor":"%s","version":"1.0.0","sandbox":"darwin","outcome":"ran","why":"","started":true,"authenticated":true,"probes":%s,"own_loopback":"%s"}\n' \
    "$1" "$2" "$3"
}

# every probe blocked, the round's own loopback working: ok, and exit 0
: > "$repo/state/canary/results.jsonl"
ran_record claude "$blocked_probes" works > "$d3/fixture.jsonl"; echo 0 > "$d3/rc"
out="$(sandbox_doctor)"; rc=$?
assert_contains "$out" "started, authenticated, every probe blocked" \
  "a round with every probe blocked is ok"
assert_contains "$out" "a round's own loopback works on this host" \
  "and its own loopback is reported on a line of its own"
assert_contains "$out" "+ jq" "the toolchain line doctor reads here is the fixture's jq, not the host's"
assert_lacks "$out" "wrong version" "so no host version decides this section's exit"
assert_eq "0" "$rc" "and doctor's exit is good"

# a probe that reached is never summarised as blocked, whatever the canary's exit
: > "$repo/state/canary/results.jsonl"
ran_record claude "$(jq -c '.write_outside = "reached"' <<<"$blocked_probes")" untested > "$d3/fixture.jsonl"
out="$(sandbox_doctor)"; rc=$?
assert_contains "$out" "x claude" "a round in which a probe reached is reported x"
assert_contains "$out" "a probe reached what the sandbox must block: write_outside" "naming the probe that reached"
assert_lacks "$out" "every probe blocked" "and never as every probe blocked"
assert_contains "$out" "untested: the round never ran the own-loopback probe" "an own_loopback the round never tested is said to be untested"
assert_eq "1" "$rc" "and doctor's own exit is bad, though the canary stand-in exited 0"

# a probe that never ran is not a probe that was blocked
: > "$repo/state/canary/results.jsonl"
ran_record codex "$(jq -c '.github = "untested" | .read_ssh = "untested"' <<<"$blocked_probes")" broken \
  > "$d3/fixture.jsonl"
out="$(sandbox_doctor)"; rc=$?
assert_contains "$out" "these probes did not run, so they are not blocked: read_ssh github" \
  "untested probes are named, not read as blocked"
assert_contains "$out" "a round's own loopback is blocked on this host" \
  "and a broken own loopback is said to be blocked"
assert_eq "1" "$rc" "and doctor's exit is bad"

# an older run's records in the same file are never summarised as this run's
printf '{"at":"2026-09-01T00:00:00Z","run":"an-older-run","vendor":"oldvendor","outcome":"ran","started":true,"authenticated":true,"probes":{"write_outside":"reached"},"own_loopback":"works"}\n' \
  > "$repo/state/canary/results.jsonl"
ran_record claude "$blocked_probes" works > "$d3/fixture.jsonl"
out="$(sandbox_doctor)"
assert_lacks "$out" "oldvendor" "an older run's lines in results.jsonl are not summarised"
assert_contains "$out" "+ claude" "only this run's are"
# and a canary that wrote nothing for this run is not a clean bill
: > "$d3/fixture.jsonl"
out="$(sandbox_doctor)"; rc=$?
assert_contains "$out" "wrote no result for this run" "a run with no record of its own says so"
assert_lacks "$out" "oldvendor" "rather than falling back to an older run's lines"
assert_eq "1" "$rc" "and is bad"

# a quota-exhausted vendor's fix line names the reset time when the
# vendor's own log said one, and falls back to the dashboard when not
: > "$repo/state/canary/results.jsonl"; echo 1 > "$d3/rc"
printf '{"at":"2026-09-28T00:00:00Z","vendor":"codex","version":"0.1.0","sandbox":"darwin","outcome":"ran","why":"quota exceeded, try again in 45 minutes","started":true,"authenticated":false}\n' \
  > "$d3/fixture.jsonl"
out="$(sandbox_doctor)"
assert_contains "$out" "x codex" "a quota-exhausted vendor from a real canary round is reported x"
assert_contains "$out" "fix: quota exhausted; try again in 45 minutes" \
  "and the fix line names the vendor's own reset time, not just 'check the dashboard'"
assert_lacks "$out" "every probe blocked" "an outcome=ran, authenticated=false result is never read as a clean round"
: > "$repo/state/canary/results.jsonl"
printf '{"at":"2026-09-28T00:00:00Z","vendor":"codex","version":"0.1.0","sandbox":"darwin","outcome":"ran","why":"quota exceeded for this organisation","started":true,"authenticated":false}\n' \
  > "$d3/fixture.jsonl"
out="$(sandbox_doctor)"
assert_contains "$out" "check the vendor's own dashboard for when it resets" \
  "with no reset time in the vendor's own message, doctor falls back to the generic fix"
rm -f "$repo/state/canary/results.jsonl"


rm -rf "$d" "$d2"
finish
