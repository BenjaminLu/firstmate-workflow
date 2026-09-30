#!/usr/bin/env bash
# fm doctor (T-121): says, for every dependency firstmate itself needs and
# every vendor login, whether it works here and the one command that fixes
# it - so the captain finds out up front, not the way 2026-09-26/27 did:
# codex out of quota, found only when a canary round failed; gemini's OAuth
# expired; cursor unable to `agent login` inside the sandbox; a stray
# bin/__pycache__ making a worktree look dirty.
#
# It asks nothing itself. With no config.yaml yet, it hands off to
# `fm setup`, which does the asking, then calls this back. It installs
# nothing unless told to (`--fix`, which asks before each install).
#
#   bin/fm-doctor.sh [--fix] [--sandbox] [--repo DIR] [--facts FILE | --collect]
set -uo pipefail
# The operator's answers to --fix are read from fd 9; every child this
# script starts gets /dev/null, never the operator's input.
exec 9<&0
exec < /dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE/fm-config.sh" ] || { echo "fm-doctor: missing $HERE/fm-config.sh" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$HERE/fm-config.sh"
# fm_adapter_outranking (the one list of credentials a round sheds),
# fm_auth_refuses (the one rule for a probe's answer) and, for --sandbox,
# fm_auth_quota_reset
[ -f "$HERE/adapters/_lib.sh" ] || { echo "fm-doctor: missing $HERE/adapters/_lib.sh" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$HERE/adapters/_lib.sh"

facts_file=''; collect_only=''; fix=''; sandbox=''; assume_yes=''; repo="${FM_ROOT:-$(pwd -P)}"
while [ $# -gt 0 ]; do
  case "$1" in
    --facts) fm_need "fm-doctor" "$@"; facts_file="${2-}"; shift 2 ;;
    --collect) collect_only=1; shift ;;
    --fix) fix=1; shift ;;
    --sandbox) sandbox=1; shift ;;
    --yes) assume_yes=1; shift ;;
    --repo) fm_need "fm-doctor" "$@"; repo="${2-}"; shift 2 ;;
    *) echo "usage: fm-doctor.sh [--fix] [--sandbox] [--yes] [--repo DIR] [--facts FILE | --collect]" >&2; exit 64 ;;
  esac
done
if [ -n "$facts_file" ]; then
  [ -f "$facts_file" ] || { echo "fm-doctor: no facts file: $facts_file" >&2; exit 64; }
  facts_file="$(cd "$(dirname "$facts_file")" && pwd)/${facts_file##*/}"
fi
repo="$(cd "$repo" 2>/dev/null && pwd -P)" || { echo "fm-doctor: no repo at $repo" >&2; exit 64; }
cd "$repo" || exit 70

# With no config.yaml, there is nothing to check against: send the operator
# to the wizard that asks what it cannot find out, then this same doctor
# runs again with the settings it wrote.
if [ ! -f config.yaml ]; then
  echo "fm doctor: no config.yaml here yet; running fm setup" >&2
  [ -x "$HERE/fm-setup.sh" ] || { echo "fm-doctor: missing $HERE/fm-setup.sh" >&2; exit 70; }
  # the one child handed the operator's input back: fm setup asks
  exec "$HERE/fm-setup.sh" --repo "$repo" <&9 9<&-
fi

bad=0
say_ok()   { printf '  + %-16s %s\n' "$1" "$2"; }
say_bad()  { printf '  x %-16s %s\n' "$1" "$2"; bad=1; }
say_warn() { printf '  ! %-16s %s\n' "$1" "$2"; }

# --- version comparison: dotted, numeric, missing parts count as 0 ---------
ver_ge() {  # ver_ge <have> <want> -> 0 when <have> is at least <want>
  local have="$1" want="$2" hp wp i n
  IFS=. read -r -a hp <<<"$have"
  IFS=. read -r -a wp <<<"$want"
  n=${#hp[@]}; [ "${#wp[@]}" -gt "$n" ] && n=${#wp[@]}
  for ((i = 0; i < n; i++)); do
    local h="${hp[i]:-0}" w="${wp[i]:-0}"
    h="${h//[!0-9]/}"; h="${h:-0}"
    w="${w//[!0-9]/}"; w="${w:-0}"
    if ((10#$h > 10#$w)); then return 0; fi
    if ((10#$h < 10#$w)); then return 1; fi
  done
  return 0
}

extract_version() {  # extract_version <text> -> the first dotted number in it
  grep -oE '[0-9]+(\.[0-9]+){1,3}' <<<"$1" | head -1
}

# The judging layer reads observations, never command -v or --version.
# TSV is deliberately readable with awk, even when Python or jq is missing.
# tool<TAB>name<TAB>path<TAB>version<TAB>raw<TAB>shim
# host<TAB>os|sandbox<TAB>value; probe<TAB>vendor<TAB>status<TAB>en<TAB>tw
fact_value() {
  awk -F '\t' -v k="$1" -v n="$2" -v c="$3" '$1==k && ($2==n || (k=="tool" && $3==n)) {print $c; exit}' <<<"$tool_facts"
}
tool_path() { fact_value tool "$1" 3; }
tool_present() { [ -n "$(tool_path "$1")" ]; }
extract_tool_version() { fact_value tool "$1" 4; }

# Every tool bin/ci.sh or the board calls that mise pins, by the binary on
# PATH: bun (the board, bun test), node (bunx playwright test: playwright's
# CLI is `#!/usr/bin/env node`), python3 (fm-sandbox.sh, the adapters,
# fm-herdr.py), jq, gh, and shellcheck, whose stage bin/ci.sh skips when it
# is missing - so a host without it would pass a gate it never ran. A
# mise.toml that pins none of one of these is itself reported, not only a
# tool that is missing from PATH. git and perl are the system's, checked
# below rather than pinned.
REQUIRED_PINS=(bun node python3 jq gh shellcheck)

# --- mise.toml: name -> the binary on PATH, and the argv that prints its version
mise_key_bin() {
  case "$1" in
    bun) echo bun ;;
    python) echo python3 ;;
    "ubi:jqlang/jq") echo jq ;;
    "ubi:cli/cli") echo gh ;;
    *) echo "${1#*:}" ;;
  esac
}

mise_tools() {  # one "key<TAB>pin" per [tools] entry of <file>
  local f="$1"
  [ -f "$f" ] || return 0
  awk -F'=' '
    /^\[tools\]/ { intools = 1; next }
    /^\[/ { intools = 0 }
    intools {
      line = $0; sub(/#.*/, "", line)
      if (line !~ /=/) next
      split(line, kv, "=")
      k = kv[1]; v = kv[2]
      gsub(/^[ \t"]+|[ \t"]+$/, "", k)
      gsub(/^[ \t"]+|[ \t"]+$/, "", v)
      if (k != "" && v != "") print k "\t" v
    }
  ' "$f"
}

# An Apple xcrun shim first on PATH (T-147): /usr/bin/git, /usr/bin/python3
# and the rest of FM_XCRUN_TOOLS on macOS are launchers that ask xcrun for
# the real tool, which fails inside a round (its cache is denied, and an
# unaccepted Xcode licence stops it). Reported as the wrong tool, with the
# fix, instead of ok; the detector is fm-config.sh's, the one fm-sandbox.sh
# uses.
xcrun_shim_bad() {  # xcrun_shim_bad <bin> -> 0, having said so, when it is a shim
  local found
  found="$(fact_value tool "$1" 6)"
  [ -n "$found" ] || return 1
  say_bad "$1" "wrong version: $found is Apple's xcrun shim, not $1 itself, and a crew round cannot run it; fix: $(fm_xcrun_fix "$1")"
}

# The collecting layer only observes the host. It prints data and makes no
# pass/fail decision; --collect is also useful for a reproducible diagnosis.
collect_tools() {
  local os sandbox_tool key pin bin path raw version shim
  os="${FM_SANDBOX_OS:-}"
  [ -n "$os" ] || os="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  case "$os" in darwin) sandbox_tool="sandbox-exec" ;; linux) sandbox_tool=bwrap ;; *) sandbox_tool='' ;; esac
  [ -z "$sandbox_tool" ] || sandbox_tool="${FM_SANDBOX_TOOL:-$sandbox_tool}"
  printf 'host\tos\t%s\nhost\tsandbox\t%s\n' "$os" "$sandbox_tool"
  {
    while IFS=$'\t' read -r key pin; do [ -z "$key" ] || mise_key_bin "$key"; done < <(mise_tools "$repo/mise.toml")
    printf '%s\n' git perl herdr mise "$sandbox_tool"
    fm_vendors
  } | sort -u | while IFS= read -r bin; do
    [ -n "$bin" ] || continue
    path="$(command -v "$bin" 2>/dev/null)" || path=''
    raw=''; version=''; shim=''
    if [ -n "$path" ]; then
      case " $FM_XCRUN_TOOLS " in
        *" $bin "*) fm_xcrun_shim "$path" && shim="$path" ;;
      esac
      # Presence-only dependencies need no invocation.
      case "$bin" in
        git|perl|mise|"$sandbox_tool") ;;
        *) if [ -z "$shim" ]; then
             raw="$("$path" --version </dev/null 2>&1 | head -3)"
             version="$(extract_version "$raw")"
           fi ;;
      esac
    fi
    raw="$(head -1 <<<"$raw" | tr '\t\r\n' '   ')"
    printf 'tool\t%s\t%s\t%s\t%s\t%s\n' "$bin" "$path" "$version" "$raw" "$shim"
  done
}
if [ -n "$facts_file" ]; then tool_facts="$(cat "$facts_file")"
else tool_facts="$(collect_tools)"
fi
if [ -n "$collect_only" ]; then printf '%s\n' "$tool_facts"; exit 0; fi

echo "== Toolchain =="
pinned=' '
while IFS=$'\t' read -r key pin; do
  [ -n "$key" ] || continue
  bin="$(mise_key_bin "$key")"
  pinned="$pinned$bin "
  if ! tool_present "$bin"; then
    say_bad "$bin" "missing (pinned $pin); fix: mise install $key@$pin"
    continue
  fi
  xcrun_shim_bad "$bin" && continue
  have="$(extract_tool_version "$bin")"
  if [ -z "$have" ]; then
    say_warn "$bin" "version unreadable: installed, but no version in: $(fact_value tool "$bin" 5)"
  elif ver_ge "$have" "$pin"; then
    say_ok "$bin" "ok $have (pinned $pin)"
  else
    say_bad "$bin" "wrong version: $have, older than the pin $pin; fix: mise install $key@$pin"
  fi
done < <(mise_tools "$repo/mise.toml")
for bin in "${REQUIRED_PINS[@]}"; do
  case "$pinned" in
    *" $bin "*) ;;
    *) say_bad "$bin" "missing from mise.toml: it pins no $bin, which bin/ci.sh or the board calls; fix: add it to mise.toml's [tools], then mise install" ;;
  esac
done

# Dependencies mise does not pin, folded in from T-078: presence and the one
# command that installs each on this OS. git and perl are the system's own
# (bin/ci.sh times its suites with perl; the board and every script call
# git), so they are checked here rather than pinned.
# The platform and the sandbox binary are read exactly as bin/fm-sandbox.sh's
# host_os and host_tool read them - FM_SANDBOX_OS, else uname; then
# FM_SANDBOX_TOOL, else the platform's own tool - so doctor never checks a
# tool the sandbox would not use.
os="$(fact_value host os 3)"
dep_fix() {  # dep_fix <name> -> the install line for this OS
  case "$1:$os" in
    git:darwin) echo "xcode-select --install, or: brew install git" ;;
    git:*) echo "apt install git  (or your distribution's package manager)" ;;
    perl:darwin) echo "perl ships with macOS; reinstall the command line tools: xcode-select --install" ;;
    perl:*) echo "apt install perl  (or your distribution's package manager)" ;;
    herdr:*) echo "install herdr 0.9.1 or later for your platform, then re-run fm doctor" ;;
    sandbox-exec:darwin) echo "sandbox-exec ships with macOS as /usr/bin/sandbox-exec; put /usr/bin back on PATH" ;;
    sandbox-exec:*) echo "sandbox-exec ships with macOS; this host is not macOS" ;;
    bwrap:*) echo "apt install bubblewrap  (or your distribution's package manager)" ;;
  esac
}
# The oldest version each is known to work at, or nothing where no version
# matters (design 13.3 says which, and why): herdr's is the one firstmate's
# host code was written against.
dep_min() {
  case "$1" in
    herdr) echo 0.9.1 ;;
  esac
}
for dep in git perl herdr; do
  if ! tool_present "$dep"; then
    say_bad "$dep" "missing; fix: $(dep_fix "$dep")"
    continue
  fi
  xcrun_shim_bad "$dep" && continue
  min="$(dep_min "$dep")"
  if [ -z "$min" ]; then
    say_ok "$dep" "ok, found on PATH"
    continue
  fi
  have="$(extract_tool_version "$dep")"
  if [ -z "$have" ]; then
    say_warn "$dep" "version unreadable: installed, but no version in its --version; it needs $min or later"
  elif ver_ge "$have" "$min"; then
    say_ok "$dep" "ok $have (at least $min)"
  else
    say_bad "$dep" "wrong version: $have, older than $min; fix: $(dep_fix "$dep")"
  fi
done
sandbox_tool="$(fact_value host sandbox 3)"
if [ -n "$sandbox_tool" ]; then
  sandbox_name="${sandbox_tool##*/}"
  sandbox_fix="$(dep_fix "$sandbox_name")"
  [ -n "$sandbox_fix" ] || sandbox_fix="FM_SANDBOX_TOOL names $sandbox_tool, which is not there; unset it or point it at the $os sandbox tool"
  if tool_present "$sandbox_tool"; then
    say_ok "$sandbox_name" "ok, the OS sandbox tool for $os is there: $sandbox_tool"
  else
    say_bad "$sandbox_name" "missing; fix: $sandbox_fix"
  fi
else
  say_warn "sandbox" "$os has no OS sandbox tool this doctor knows; every crew round on it is refused"
fi

# The vendor's own documented installer, folded in from T-078: one line per
# CLI, so a missing vendor says how to get it rather than only that it is
# missing. Each is the vendor's own published install method at the time
# this was written, not verified live the way the toolchain versions above
# are - a vendor that changes its installer needs this line updated.
vendor_install() {  # vendor_install <vendor> -> its own install line
  case "$1" in
    claude)       echo "npm install -g @anthropic-ai/claude-code" ;;
    codex)        echo "npm install -g @openai/codex" ;;
    cursor-agent) echo "curl https://cursor.com/install -fsS | bash" ;;
    gemini)       echo "npm install -g @google/gemini-cli" ;;
  esac
}

# The oldest version of each vendor CLI known to have the status check
# fm-auth-probe.sh runs: the version its recorded transcript came from
# (tests/fixtures/auth-status, 2026-09-29; tests/doctor.test.sh keeps the
# two equal). The vendors' changelogs could not be read where these were
# recorded, so the first version that had each command is not known, and
# the floor may be later than it has to be; a recording from an older
# version lowers it. gemini has none: it has no status check to need.
vendor_min() {
  case "$1" in
    claude)       echo 2.1.284 ;;
    codex)        echo 0.155.1 ;;
    cursor-agent) echo 2026.09.23 ;;
  esac
}

echo "== Vendor logins =="
while IFS= read -r v; do
  if ! tool_present "$v"; then
    say_warn "$v" "missing: not installed; fallback never tries it; install: $(vendor_install "$v")"
    continue
  fi
  min="$(vendor_min "$v")"
  if [ -n "$min" ]; then
    have="$(extract_tool_version "$v")"
    if [ -z "$have" ]; then
      say_bad "$v" "version unreadable: no version in its --version, and it needs $min or later for its status check; install: $(vendor_install "$v")"
      continue
    elif ! ver_ge "$have" "$min"; then
      say_bad "$v" "wrong version: $have, older than $min, the oldest known to have its status check; install: $(vendor_install "$v")"
      continue
    fi
  fi
  if [ -n "$facts_file" ]; then
    pstatus="$(fact_value probe "$v" 3)"
    pen="$(fact_value probe "$v" 4)"
    ptw="$(fact_value probe "$v" 5)"
  else
    [ -x "$HERE/fm-auth-probe.sh" ] || { echo "fm-doctor: missing $HERE/fm-auth-probe.sh" >&2; exit 70; }
    probe="$("$HERE/fm-auth-probe.sh" "$v" </dev/null 2>/dev/null)"
    pstatus="$(sed -n 's/^status: //p' <<<"$probe" | head -1)"
    pen="$(sed -n 's/^en: //p' <<<"$probe" | head -1)"
    ptw="$(sed -n 's/^tw: //p' <<<"$probe" | head -1)"
  fi
  # The same rule fm-worker.sh and fm-review.sh apply (fm_auth_refuses in
  # adapters/_lib.sh): anything but `authenticated` refuses a round, said in
  # both languages.
  if fm_auth_refuses "$pstatus"; then
    say_bad "$v" "${pstatus:-no answer}: ${pen:-the login probe did not answer, so rounds on it are refused}"
    say_bad "" "${pstatus:-無回應}：${ptw:-登入探測沒有回應，因此拒絕在其上執行回合}"
  else
    say_ok "$v" "ok: $pen"
  fi
done < <(fm_vendors)

echo "== Environment =="
# Credentials that would outrank the round's own login if the operator's
# shell has them set for personal use (T-121): the same list the adapters
# shed unless config.yaml's billing: block names the vendor explicitly.
warn_outranking() {  # warn_outranking <vendor> <var>...
  local v="$1"; shift
  local billed; billed="$(fm_cfg_in billing "$v" "$repo/config.yaml" 2>/dev/null)"
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || continue
    if [ "$billed" = api-key ]; then
      say_ok "$name" "set, and config.yaml chose api-key billing for $v: used as is"
    else
      say_warn "$name" "set in this shell; a $v round would shed it (would also change your own interactive billing)"
    fi
  done
}
while IFS= read -r v; do
  outranking=()
  while IFS= read -r name; do [ -n "$name" ] && outranking+=("$name"); done < <(fm_adapter_outranking "$v")
  [ "${#outranking[@]}" -eq 0 ] || warn_outranking "$v" "${outranking[@]}"
done < <(fm_vendors)

echo "== Repository hygiene =="
# What makes a worktree look dirty is what `git status` shows in it, so git
# is asked, per worktree: an untracked build cache it lists is flagged, and
# one git ignores is not, because git never shows it. Only the cache
# directories themselves are named, not every file under them.
cache_dirs() {  # untracked paths on stdin -> each build cache directory among them, once
  awk -F/ '{
    p = ""
    for (i = 1; i <= NF; i++) {
      p = (p == "" ? $i : p "/" $i)
      if ($i ~ /^(__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.tox|\.nox|\.eslintcache|\.parcel-cache|\.turbo)$/ \
          || (i > 1 && $(i - 1) == "node_modules" && $i == ".cache")) { print p; next }
    }
  }' | sort -u
}
flagged=0
for wt in "$repo"/state/worktrees/*/; do
  [ -e "$wt.git" ] || continue
  wt="${wt%/}"; name="${wt##*/}"
  if ! st="$(git -C "$wt" status --porcelain --untracked-files=all </dev/null 2>/dev/null)"; then
    say_warn "$name" "git status did not answer here, so its build caches could not be checked"
    continue
  fi
  found="$(sed -n 's/^?? //p' <<<"$st" | sed 's/^"//; s/"$//' | cache_dirs)"
  [ -n "$found" ] || continue
  flagged=1
  say_warn "$name" "untracked build cache git status shows, which makes the worktree look dirty to firstmate's sync: $(paste -sd ' ' - <<<"$found"); delete it, or ignore it in that project's .gitignore"
done
[ "$flagged" = 1 ] || say_ok "worktrees" "ok, no untracked build cache in any worktree under state/worktrees"

if [ -n "$fix" ]; then
  echo "== Fixing =="
  # The tool list is read from fd 3, not stdin: stdin has to stay free for
  # the y/N prompt below, or it would race the same process substitution
  # the while loop is already reading from and every prompt would see EOF.
  while IFS=$'\t' read -r key pin <&3; do
    [ -n "$key" ] || continue
    bin="$(mise_key_bin "$key")"
    have=''
    tool_present "$bin" && have="$(extract_tool_version "$bin")"
    if [ -n "$have" ] && ver_ge "$have" "$pin"; then continue; fi
    if ! tool_present mise; then
      say_warn "$bin" "mise is not installed; run: mise install $key@$pin yourself once mise is set up"
      continue
    fi
    ans=y
    if [ -z "$assume_yes" ]; then
      printf 'install %s@%s with mise? [y/N] ' "$key" "$pin" >&2
      IFS= read -r ans <&9 || ans=n
    fi
    case "$ans" in
      y|Y|yes|YES) "$(tool_path mise)" install "$key@$pin" </dev/null && say_ok "$bin" "installed $pin" || say_bad "$bin" "mise install failed" ;;
      *) say_warn "$bin" "left as is" ;;
    esac
  done 3< <(mise_tools "$repo/mise.toml")
fi

if [ -n "$sandbox" ]; then
  echo "== Sandbox reality check =="
  [ -x "$HERE/fm-canary.sh" ] || { echo "fm-doctor: missing $HERE/fm-canary.sh" >&2; exit 70; }
  # This run's records only: the canary tags every record with the id it is
  # handed, and results.jsonl keeps every earlier run's lines too, so "the
  # last N lines" could summarise another run or another set of vendors.
  canary_dir="${FM_CANARY_STATE_DIR:-$repo/state/canary}"
  canary_run="doctor-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  canary_out="$(FM_CANARY_STATE_DIR="$canary_dir" FM_CANARY_RUN="$canary_run" "$HERE/fm-canary.sh" </dev/null 2>&1)"
  canary_rc=$?
  printf '%s\n' "$canary_out" | sed 's/^/  /'
  results="$canary_dir/results.jsonl"
  seen=0
  # One line per record, its fields split on the unit separator (a tab is
  # whitespace to `read`, which would merge an empty field into the next),
  # every field the summary names read
  # from the record itself: the probes that reached, the ones that did not
  # say blocked (untested, or anything else), and own_loopback.
  while IFS=$'\x1f' read -r name outcome started authed own reached untested why; do
    [ -n "$name" ] || continue
    seen=1
    # Matched field by field, not as one concatenated string: a glob like
    # "*:false:*" never matches a trailing "false", and a quota-exhausted
    # vendor - outcome=ran, started=true, authenticated=false - fell through.
    if [ "$outcome" = skipped ]; then
      say_warn "$name" "skipped: ${why:-not installed or not logged in}"
      continue
    elif [ "$outcome" = refused ] || [ "$started" != true ] || [ "$authed" != true ]; then
      fixmsg=''
      case "$name:$why" in
        cursor-agent:*) fixmsg=" fix: security add-generic-password -s firstmate-cursor-api-key -a \"\$USER\" -w" ;;
        gemini:*expired*) fixmsg=" fix: start gemini once outside a round" ;;
        *:*[Qq]uota*|*:*[Rr]ate*imit*|*:*429*)
          reset="$(fm_auth_quota_reset "$why")"
          if [ -n "$reset" ]; then fixmsg=" fix: quota exhausted; $reset"
          else fixmsg=" fix: quota exhausted; check the vendor's own dashboard for when it resets"
          fi ;;
      esac
      say_bad "$name" "${why:-did not start}.$fixmsg"
    elif [ -n "$reached" ]; then
      say_bad "$name" "started and authenticated, but a probe reached what the sandbox must block: $reached"
    elif [ -n "$untested" ]; then
      say_bad "$name" "started and authenticated, but these probes did not run, so they are not blocked: $untested"
    else
      say_ok "$name" "started, authenticated, every probe blocked"
    fi
    # whether a round's own loopback works on this host: its own line, as
    # the canary recorded it, for every vendor whose round ran
    case "$own" in
      works) say_ok "$name loopback" "a round's own loopback works on this host" ;;
      broken) say_warn "$name loopback" "a round's own loopback is blocked on this host; suites that start their own server fail in a round" ;;
      *) say_warn "$name loopback" "untested: the round never ran the own-loopback probe" ;;
    esac
  done < <(jq -r --arg run "$canary_run" 'select(.run == $run)
      | [.vendor, .outcome, (.started | tostring), (.authenticated | tostring), (.own_loopback // ""),
         ((.probes // {}) | to_entries | map(select(.value == "reached") | .key) | join(" ")),
         (if .probes == null then "every probe"
          else (.probes | to_entries | map(select(.value != "blocked" and .value != "reached" and .value != "n/a") | .key) | join(" ")) end),
         ((.why // "") | gsub("[\u001f\n]"; " "))] | join("\u001f")' "$results" 2>/dev/null)
  [ "$seen" = 1 ] || say_bad "canary" "wrote no result for this run to $results"
  [ "$canary_rc" -eq 0 ] || bad=1
fi

exit "$bad"
