#!/usr/bin/env bash
# T-280: on Linux, bin/ci.sh, bin/fm-failfirst.sh and the two workflow steps
# that run suites directly put fm_git_quiet's git first on PATH, so no test
# repository leaves Git's automatic maintenance running in the background -
# where it can still hold objects/maintenance.lock when the test removes the
# repository. Maintenance itself stays on and runs in the foreground. Suites
# drop every GIT_* variable, so the probes below do too: only PATH reaches
# them.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/path.sh
. "$ROOT/tests/lib/path.sh"
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"
isolate_tmpdir

# This suite itself may run under a wrapper (the workflow step's, or the
# gate's on CI). Every folder holding one leaves PATH here, or the probes
# would see its settings on the base too and prove nothing.
unwrapped=''
IFS=: read -r -a path_dirs <<< "$PATH"
for dir in "${path_dirs[@]}"; do
  if [ -f "$dir/git" ] && grep -q 'maintenance\.auto' "$dir/git" 2>/dev/null; then continue; fi
  unwrapped="${unwrapped:+$unwrapped:}$dir"
done
PATH="$unwrapped"; export PATH
real_git="$(command -v git)"

osbin="$(safe_tmpdir)"
real_uname="$(command -v uname)"
printf '#!/usr/bin/env bash\nif [ "$1" = -s ]; then echo "$FM_TEST_OS"; else exec %q "$@"; fi\n' "$real_uname" > "$osbin/uname"
chmod +x "$osbin/uname"
nogit="$(safe_tmpdir)"
fixture_path "$nogit" 'git' || exit 1

# --- the probe: a suite in a gate's fixture tree -----------------------------
# Writes key=value lines to $PROBE_OUT; $PROBE_REAL_GIT is the git the
# wrapper should hand everything to unchanged.
q="$(safe_tmpdir)"; mkdir -p "$q/bin" "$q/tests"
cp "$ROOT/bin/ci.sh" "$ROOT/bin/fm-config.sh" "$q/bin/"; config_modules_fixture "$q/bin/"
cat > "$q/tests/probe.test.sh" <<'P'
#!/usr/bin/env bash
out="$PROBE_OUT"; real="$PROBE_REAL_GIT"
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep '^GIT_')
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
r="$(mktemp -d "${TMPDIR:-/tmp}/probe.XXXXXX")"
git init -q "$r"; git -C "$r" config user.email a@b.c; git -C "$r" config user.name t
echo a > "$r/a"; git -C "$r" add a
{
  printf 'detach=%s\n' "$(cd "$r" && git config --get maintenance.autoDetach)"
  printf 'auto=%s\n' "$(cd "$r" && git config --get maintenance.auto)"
  printf 'gc=%s\n' "$(cd "$r" && git config --get gc.auto)"
  git -C "$r" commit -qm 'two words'
  # Right after the commit returns: any `git maintenance` still running in
  # this repository, and the lock it holds.
  top="$(cd "$r" && pwd -P)"; live=0
  while read -r pid args; do
    case "$args" in "git maintenance"*) ;; *) continue ;; esac
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
    case "$cwd" in "$top"|"$top"/*) live=$((live + 1)) ;; esac
  done < <(ps -eo pid=,args=)
  printf 'live=%s lock=%s\n' "$live" "$([ -e "$r/.git/objects/maintenance.lock" ] && echo yes || echo no)"
  printf 'subject=%s\n' "$(git -C "$r" log -1 --format=%s)"
  printf 'short=%s\n' "$(cd "$r" && git -c core.abbrev=12 rev-parse --short HEAD)"
  printf 'realshort=%s\n' "$(cd "$r" && "$real" -c core.abbrev=12 rev-parse --short HEAD)"
  (cd "$r" && git rev-parse --verify no-such-ref >/dev/null 2>&1); printf 'rc=%s\n' "$?"
  (cd "$r" && "$real" rev-parse --verify no-such-ref >/dev/null 2>&1); printf 'realrc=%s\n' "$?"
  printf 'hash=%s\n' "$(printf x | git hash-object --stdin)"
  printf 'realhash=%s\n' "$(printf x | "$real" hash-object --stdin)"
} > "$out"
rm -rf "$r" "$r.trace"
exit 0
P
probe_out="$q.probe"
ci_out="$(FM_TEST_OS=Linux PATH="$osbin:$PATH" FM_ROOT="$q" PROBE_OUT="$probe_out" PROBE_REAL_GIT="$real_git" \
  bash "$q/bin/ci.sh" --stage bash 2>&1)"
[ -s "$probe_out" ] || printf '%s\n' "$ci_out" | tail -n 20
seen() { sed -n "s/^$1=//p" "$probe_out" 2>/dev/null; }

assert_eq "false" "$(seen detach)" "linux ci: maintenance.autoDetach is false"
assert_eq "auto= gc=" "auto=$(seen auto) gc=$(seen gc)" "linux ci: automatic maintenance is not turned off"
assert_eq "0 no" "$(sed -n 's/^live=\([0-9]*\) lock=/\1 /p' "$probe_out" 2>/dev/null)" "linux ci: no maintenance outlives a commit"
assert_eq "two words" "$(seen subject)" "wrapper: arguments pass through"
assert_eq "$(seen realshort)" "$(seen short)" "wrapper: arguments pass through (-c and --short)"
assert_ne "" "$(seen short)" "wrapper: rev-parse --short printed a name"
assert_eq "$(seen realrc)" "$(seen rc)" "wrapper: exit code passes through"
assert_ne "0" "$(seen rc)" "wrapper: a missing ref is still an error"
assert_eq "$(seen realhash)" "$(seen hash)" "wrapper: standard input passes through"
assert_ne "" "$(seen hash)" "wrapper: hash-object printed an object id"

# --- no git on Linux: the gate stops rather than run without the wrapper -----
rc=0; out="$(FM_TEST_OS=Linux PATH="$osbin:$nogit" FM_ROOT="$q" bash "$q/bin/ci.sh" --stage bash 2>&1)" || rc=$?
assert_eq "70" "$rc" "linux ci: missing git stops bin/ci.sh"
assert_contains "$out" "fm_git_quiet: git not found on PATH" "linux ci: missing git stops bin/ci.sh (message)"

gq="$(safe_tmpdir)"
rc=0; out="$(FM_TEST_OS=Linux PATH="$osbin:$nogit" bash -c '. "$1"; fm_git_quiet "$2"' _ "$ROOT/bin/fm-config.sh" "$gq/wrap" 2>&1)" || rc=$?
assert_eq "70" "$rc" "linux: missing git stops"
assert_contains "$out" "fm_git_quiet: git not found on PATH" "linux: missing git stops (message)"

# --- macOS: nothing changes ---------------------------------------------------
mkdir -p "$gq/mac"
out="$(FM_TEST_OS=Darwin PATH="$osbin:$PATH" bash -c '
  . "$1"; before="$PATH"; fm_git_quiet "$2"; rc=$?
  same=no; [ "$PATH" = "$before" ] && same=yes
  printf "rc=%s path=%s files=%s" "$rc" "$same" "$(ls -A "$2" | wc -l | tr -d " ")"' \
  _ "$ROOT/bin/fm-config.sh" "$gq/mac" 2>&1)"
assert_eq "rc=0 path=yes files=0" "$out" "macOS: nothing changes"

# --- the fail-first job runs the changed suites itself ----------------------
# A fixture like tests/failfirst.test.sh's: main says old, the change says
# new and adds a probe that records what git a new repository sees.
d="$(safe_tmpdir)"
git -C "$d" init -q -b main
git -C "$d" config user.email a@b.c; git -C "$d" config user.name t
mkdir -p "$d/bin" "$d/tests"
printf 'project:\n  tests:\n    - tests/**\n  test: case {file} in *.test.sh) bash {file} ;; esac\n' > "$d/config.yaml"
printf '#!/usr/bin/env bash\necho old\n' > "$d/bin/tool.sh"
git -C "$d" add -A; git -C "$d" -c maintenance.autoDetach=false commit -qm base
git -C "$d" checkout -q -b change
printf '#!/usr/bin/env bash\necho new\n' > "$d/bin/tool.sh"
cat > "$d/tests/probe.test.sh" <<'P'
#!/usr/bin/env bash
out="$FF_PROBE_OUT"
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep '^GIT_')
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
r="$(mktemp -d "${TMPDIR:-/tmp}/probe.XXXXXX")"
git init -q "$r"
printf '%s\n' "$(cd "$r" && git config --get maintenance.autoDetach)" >> "$out"
rm -rf "$r"
exit 0
P
git -C "$d" add -A; git -C "$d" -c maintenance.autoDetach=false commit -qm change
ff_out="$d.probe"; : > "$ff_out"
( cd "$d" && FM_TEST_OS=Linux PATH="$osbin:$PATH" FF_PROBE_OUT="$ff_out" bash "$ROOT/bin/fm-failfirst.sh" main ) \
  > "$d.report" 2>&1
assert_eq "$(printf 'false\nfalse')" "$(cat "$ff_out")" "fail-first job: suites run with the wrapper"

# --- the workflow's direct suites -------------------------------------------
# Each step that runs bash tests/pinned-context.test.sh itself, before the
# gate puts the wrapper on PATH, has to call fm_git_quiet first.
steps="$(awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*- (name|uses|run):/ { wrapped = 0 }
  /fm_git_quiet/ { wrapped = 1 }
  /bash tests\/pinned-context\.test\.sh/ { n++; if (wrapped) ok++ }
  END { printf "%d %d", n, ok }' "$ROOT/.github/workflows/ci.yml")"
assert_eq "${steps%% *} ${steps%% *}" "$steps" "workflow: direct suites use the wrapper"
assert_ok "[ '${steps%% *}' -ge 2 ]" "workflow: both direct steps are found"

safe_rm_rf "$q" "$osbin" "$nogit" "$gq" "$d"
rm -f "$probe_out" "$ff_out" "$d.report"
finish
