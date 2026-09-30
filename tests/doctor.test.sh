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

DOCTOR="$ROOT/bin/fm-doctor.sh"
assert_ok "test -x '$DOCTOR'" "fm-doctor.sh is executable"
assert_eq "__pycache__/" "$(grep -v '^[[:space:]]*#' "$ROOT/.gitignore" | grep -x '__pycache__/')" \
  ".gitignore ignores __pycache__/, so a stray one no longer makes a worktree look dirty"

d="$(safe_tmpdir)"
repo="$d/repo"; mkdir -p "$repo"
fakebin="$d/fakebin"; mkdir -p "$fakebin"

# The suite's PATH is $fakebin then $sysbin, never /usr/bin or /bin
# themselves. $sysbin links every command the host has there except each
# name doctor asks about: the pins it requires, git, perl, herdr, both
# sandbox tools, mise and every vendor CLI (and the aliases they go by).
# The only copy of any of those the suite can see is the one it puts in
# $fakebin, so "missing" means missing on every host. GitHub's ubuntu image
# ships /usr/bin/gh, jq and shellcheck; macOS ships /usr/bin/git and a
# python3 stub. The list is read from doctor's own REQUIRED_PINS and
# fm_vendors, not kept by hand.
asked_about="$(sed -n 's/^REQUIRED_PINS=(\(.*\))$/\1/p' "$DOCTOR") git perl herdr sandbox-exec bwrap mise
  python bunx nodejs npm npx agent security secret-tool
  $(bash -c '. "$1"; fm_vendors' _ "$ROOT/bin/fm-config.sh" | tr '\n' ' ')"
sysbin="$d/sysbin"; mkdir -p "$sysbin"
# one ln per directory; a name both hold keeps /usr/bin's, and ln's
# complaint about it is expected
ln -s /usr/bin/* "$sysbin/" 2>/dev/null
ln -s /bin/* "$sysbin/" 2>/dev/null
for n in $asked_about; do rm -f "$sysbin/$n"; done
assert_contains "$asked_about" "gh" "the names kept off the suite's PATH include doctor's pins"
assert_contains "$asked_about" "cursor-agent" "and every vendor CLI"
assert_eq "" "$(for n in $asked_about; do PATH="$sysbin" command -v "$n"; done)" \
  "the suite's system PATH holds none of the tools doctor asks about, on any host"

# the real python3, resolved before $PATH is ever restricted: fm-auth-probe.sh
# parses claude's JSON with it, and the host's own may not run, e.g. an
# unlicensed Xcode stub
REAL_PYTHON3="$(command -v python3)"
# the real jq, for the --sandbox section below, which reads real JSON out of
# results.jsonl: fakebin's own jq (below) only ever answers --version, so
# using it there would read every field as empty rather than testing anything
REAL_JQ="$(command -v jq)"

# The fixture's own pins. Every stand-in below answers --version with a full
# dotted version satisfying its pin, so whether doctor's toolchain
# check is met depends on the fixture alone, never on the host's tools.
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
assert_eq "20.0.0" "$(version_for_pin 20)" "a major-only pin yields a full CLI version"
assert_eq "1.7.0" "$(version_for_pin 1.7)" "a two-part pin yields a full CLI version"
assert_eq "1.7.1" "$(version_for_pin 1.7.1)" "a full pin keeps its CLI version"
pin_of() {  # pin_of <mise.toml key> -> a full version satisfying the fixture's pin
  local pin
  pin="$(
  awk -F' = ' -v k="$1" '{ g = $1; gsub(/"/, "", g); if (g == k) { v = $2; gsub(/"/, "", v); print v } }' \
    "$repo/mise.toml"
  )"
  version_for_pin "$pin"
}
fake_tool() {  # fake_tool <name> <version-line> [<real binary every other call runs>]
  if [ -n "${3:-}" ]; then
    printf '#!/usr/bin/env bash\ncase "$1" in --version) printf %%s\\\\n %s;; *) exec %s "$@";; esac\n' \
      "$(printf '%q' "$2")" "$(printf '%q' "$3")" > "$fakebin/$1"
  else
    printf '#!/usr/bin/env bash\ncase "$1" in --version) printf %%s\\\\n %s;; esac\nexit 0\n' \
      "$(printf '%q' "$2")" > "$fakebin/$1"
  fi
  chmod +x "$fakebin/$1"
}
fake_tool bun "$(pin_of bun)"
fake_tool python3 "Python $(pin_of python)" "$REAL_PYTHON3"
fake_tool jq "jq-$(pin_of ubi:jqlang/jq)"
fake_tool gh "gh version $(pin_of ubi:cli/cli)"
fake_tool git "git version 2.43.0"
fake_tool herdr "herdr 1.0.0"
fake_tool node "v$(pin_of node)"
# the fake shellcheck names itself on its first line and its version on the second,
# exactly as the real one answers --version
printf '#!/usr/bin/env bash\nprintf "ShellCheck - shell script analysis tool\\nversion: %s\\nlicense: GNU General Public License, version 3\\n"\n' \
  "$(pin_of shellcheck)" > "$fakebin/shellcheck"; chmod +x "$fakebin/shellcheck"
assert_eq "1.7.1" "$(pin_of ubi:jqlang/jq)" "the stand-ins' versions are read from the fixture's own mise.toml"
# perl is only checked for presence, and anything that runs it gets the real one
ln -s "$(command -v perl)" "$fakebin/perl"
# the sandbox tool the suite names with FM_SANDBOX_TOOL: it only has to be
# there, since nothing in doctor starts a round with it
printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/fm-test-sandbox"; chmod +x "$fakebin/fm-test-sandbox"

printf 'vendor: claude\n' > "$repo/config.yaml"
mkdir -p "$repo/state/worktrees"

# $fakebin and $sysbin, never the rest of $PATH: this suite must not pick up
# whatever vendor CLIs happen to be installed on the machine running it.
# The platform and sandbox tool are the suite's too, the way fm-sandbox.sh
# reads them (T_OS, T_TOOL override them for one run). The operator's home and keychain are the suite's (T-121): the probe
# resolves a round's login from them, and must never read the real ones.
home="$d/home"; mkdir -p "$home/.config/firstmate" "$home/.codex"
printf 'crew-claude-token\n' > "$home/.config/firstmate/claude-token"; chmod 600 "$home/.config/firstmate/claude-token"
printf '{"tokens":{"access_token":"a","refresh_token":"r"}}' > "$home/.codex/auth.json"
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY CURSOR_API_KEY CODEX_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
run_doctor() { HOME="$home" FM_KEYCHAIN_TOOL="$d/no-security" FM_SECRET_TOOL="$d/no-secret-tool" \
  PATH="$fakebin:$sysbin" FM_SANDBOX_OS="${T_OS-darwin}" FM_SANDBOX_TOOL="${T_TOOL-$fakebin/fm-test-sandbox}" \
  "$DOCTOR" --repo "$repo" "$@"; }

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
assert_contains "$out" "0.10.0 (pinned 0.10.0)" "its version read from the line it says it on, not its first"
assert_contains "$out" "+ perl" "perl, the system's own, is checked rather than pinned"
assert_lacks "$out" "pins no" "a mise.toml pinning every tool ci.sh and the board call has no gap"

# --- the sandbox tool is the one fm-sandbox.sh would use, never uname's ------
# linux named, no tool named: bwrap, which the suite's PATH never holds
out="$(T_OS=linux T_TOOL='' run_doctor)"; rc=$?
assert_contains "$out" "x bwrap            missing; fix: apt install bubblewrap" \
  "FM_SANDBOX_OS=linux checks bwrap, whatever the host runs"
assert_eq "1" "$rc" "and a missing one makes doctor bad"
out="$(T_OS=darwin T_TOOL='' run_doctor)"
assert_contains "$out" "x sandbox-exec     missing; fix: sandbox-exec ships with macOS as /usr/bin/sandbox-exec" \
  "FM_SANDBOX_OS=darwin checks sandbox-exec, whatever the host runs, with macOS's own fix"
assert_lacks "$out" "bwrap" "and never bwrap"
out="$(T_TOOL="$d/no-such-sandbox" run_doctor)"; rc=$?
assert_contains "$out" "x no-such-sandbox" "a FM_SANDBOX_TOOL that is not there is reported x"
assert_contains "$out" "FM_SANDBOX_TOOL names $d/no-such-sandbox, which is not there" "saying which setting names it"
assert_eq "1" "$rc" "and doctor's exit is bad"

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
# the suite's PATH has no gh but fakebin's (see $sysbin above), so with it
# gone gh is missing on every host, ubuntu's /usr/bin/gh included
rm -f "$fakebin/gh"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x gh" "a missing pinned tool is reported x, not ok"
assert_contains "$out" "x gh               missing (pinned 2.63.0)" "and says missing, the word the acceptance names"
assert_contains "$out" "mise install" "with the one command that fixes it"
assert_eq "1" "$rc" "and doctor's own exit reflects it"
fake_tool gh "gh version $(pin_of ubi:cli/cli)"

# --- a tool older than its pin ------------------------------------------------
fake_tool jq "jq-1.5"
out="$(run_doctor)"
assert_contains "$out" "x jq" "an older-than-pinned tool is reported x too"
assert_contains "$out" "wrong version: 1.5, older than the pin 1.7.1" "and says wrong version, and why"
fake_tool jq "jq-$(pin_of ubi:jqlang/jq)"

# --- an Apple xcrun shim first on PATH (T-147) -------------------------------
# A stand-in for /usr/bin/git and /usr/bin/python3 on macOS: linked against
# libxcselect, which is how fm-config.sh's fm_xcrun_shim tells one, and
# answering the way an unlicensed one does. The suite's own, never the
# host's /usr/bin.
fake_shim() {  # fake_shim <file>
  printf '#!/usr/bin/env bash\n# /usr/lib/libxcselect.dylib\necho "You have not agreed to the Xcode license agreements." >&2\nexit 69\n' > "$1"
  chmod +x "$1"
}
# a shim later on PATH than a real git changes nothing: the real one is found
fake_shim "$sysbin/git"
out="$(run_doctor)"
assert_contains "$out" "+ git              ok, found on PATH" "a real git first on PATH is ok, with a shim behind it"
assert_lacks "$out" "xcrun shim" "and no shim is reported"
# with only the shim, git is reported as the wrong tool, with the fix
rm -f "$fakebin/git"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x git              wrong version: $sysbin/git is Apple's xcrun shim" \
  "a shim git first on PATH is reported x, as the wrong tool, naming the file"
assert_contains "$out" "fix: install git ahead of /usr/bin on PATH (brew install git), or accept the Xcode licence" \
  "with fm_xcrun_fix's line"
assert_lacks "$out" "+ git" "and never as ok"
assert_eq "1" "$rc" "and doctor's own exit reflects it"
rm -f "$sysbin/git"; fake_tool git "git version 2.43.0"
# python3, a pinned tool, the same way
fake_shim "$fakebin/python3"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x python3          wrong version: $fakebin/python3 is Apple's xcrun shim" \
  "a shim python3 first on PATH is reported x, as the wrong tool"
assert_contains "$out" "fix: install python3 ahead of /usr/bin on PATH (brew install python)" "with its fix"
assert_eq "1" "$rc" "and doctor's own exit reflects it"
fake_tool python3 "Python $(pin_of python)" "$REAL_PYTHON3"
out="$(run_doctor)"
assert_contains "$out" "+ python3" "a real python3 first on PATH is ok"
assert_lacks "$out" "xcrun shim" "and not called a shim"

# --- vendor logins: only 'authenticated' counts as usable --------------------
# each vendor CLI answers --version and its status check exactly as the
# real one did in its recorded transcript (tests/fixtures/auth-status)
FIX="$ROOT/tests/fixtures/auth-status"
recorded() {  # recorded <vendor> <fixture>
  printf '#!/usr/bin/env bash\nif [ "$1" = --version ]; then exec %q %q --version; fi\nexec %q %q\n' \
    "$FIX/replay.sh" "$FIX/$2.txt" "$FIX/replay.sh" "$FIX/$2.txt" > "$fakebin/$1"
  chmod +x "$fakebin/$1"
}
recorded claude claude-signed-in
out="$(run_doctor)"
assert_contains "$out" "+ claude" "an authenticated vendor is reported ok"
assert_contains "$out" "ok: claude's own status check confirms" "saying ok"
rm -f "$fakebin/claude"

recorded codex codex-signed-out
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x codex" "an unauthenticated vendor is reported x, not ok"
assert_contains "$out" "codex login" "with codex's own fix"
assert_eq "1" "$rc" "and it is what makes doctor's own exit code bad"
rm -f "$fakebin/codex"

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
fake_tool claude "2.1.0 (Claude Code)"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x claude           wrong version: 2.1.0, older than 2.1.284" "a vendor CLI too old for its status check is wrong version"
assert_contains "$out" "install: npm install -g @anthropic-ai/claude-code" "with its install line"
assert_eq "1" "$rc" "and doctor's exit is bad"
rm -f "$fakebin/claude"
fake_tool herdr "herdr 0.9.0"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x herdr            wrong version: 0.9.0, older than 0.9.1" "herdr older than 0.9.1 is wrong version"
assert_contains "$out" "install herdr 0.9.1 or later" "with the line that installs it"
assert_eq "1" "$rc" "and doctor's exit is bad"
fake_tool herdr "herdr 1.0.0"
out="$(run_doctor)"
assert_contains "$out" "+ herdr            ok 1.0.0 (at least 0.9.1)" "a new enough herdr is ok"

# gemini has no status command: with a round's login present its probe is
# indeterminate, which is never read as authenticated - so doctor says
# plainly, in both languages, that rounds on it are refused
fake_tool gemini "0.60.0"
mkdir -p "$home/.gemini"
printf '{"access_token":"g","refresh_token":"r","expiry_date":%s}' "$(( ($(date +%s) + 86400) * 1000 ))" \
  > "$home/.gemini/oauth_creds.json"
out="$(run_doctor)"; rc=$?
assert_contains "$out" "x gemini" "a vendor whose login cannot be verified is x, not ok"
assert_contains "$out" "gemini's login cannot be verified, so rounds on it are refused" "said in English"
assert_contains "$out" "拒絕在其上執行回合" "and in Traditional Chinese"
assert_lacks "$out" "unverified" "and never offered as usable but unverified"
assert_eq "1" "$rc" "and it makes doctor's exit code bad, like any vendor a round cannot use"
rm -rf "$fakebin/gemini" "$home/.gemini"

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
out="$(PATH="$fakebin:$sysbin" "$d2/bin/fm-doctor.sh" --repo "$noconfig" 2>&1)"; rc=$?
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
# the real git, since the question is what git itself shows: fakebin's git
# only answers --version
REAL_GIT="$(command -v git)"
gitbin="$d/gitbin"; mkdir -p "$gitbin"; ln -sf "$REAL_GIT" "$gitbin/git"
hygiene_doctor() { HOME="$home" FM_KEYCHAIN_TOOL="$d/no-security" FM_SECRET_TOOL="$d/no-secret-tool" \
  PATH="$gitbin:$fakebin:$sysbin" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$fakebin/fm-test-sandbox" \
  "$DOCTOR" --repo "$repo"; }
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

# a fake mise that records every install it is asked to run, never doing
# anything itself
: > "$d/mise-calls"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/mise-calls"\n' "$d" > "$fakebin/mise"
chmod +x "$fakebin/mise"
rm -f "$fakebin/gh"
: > "$d/mise-calls"
asked="$(printf 'n\n' | run_doctor --fix 2>&1)"
assert_contains "$asked" "install ubi:cli/cli" "it asks, naming the tool, before installing anything"
assert_eq "" "$(cat "$d/mise-calls")" "and a 'n' answer installs nothing"
: > "$d/mise-calls"
printf 'y\n' | run_doctor --fix >/dev/null 2>&1
assert_contains "$(cat "$d/mise-calls")" "install ubi:cli/cli@2.63.0" "a 'y' answer runs exactly the pinned install"
rm -f "$fakebin/mise"
fake_tool gh "gh version $(pin_of ubi:cli/cli)"

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
# The canary stand-in and doctor's record reader need a jq that reads JSON,
# but doctor's toolchain check reads that same jq's version: so it is a
# stand-in that answers --version with the fixture's pin and runs the real
# jq for everything else, never a bare link to the host's, whose version
# (ubuntu 24.04's apt jq is 1.7) would decide this section's exit.
fake_tool jq "jq-$(pin_of ubi:jqlang/jq)" "$REAL_JQ"
mkdir -p "$repo/state/canary"
sandbox_doctor() { HOME="$home" FM_KEYCHAIN_TOOL="$d/no-security" FM_SECRET_TOOL="$d/no-secret-tool" \
  PATH="$fakebin:$sysbin" FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$fakebin/fm-test-sandbox" \
  "$d3/fm-doctor.sh" --repo "$repo" --sandbox; }
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
