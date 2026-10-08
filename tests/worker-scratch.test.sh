#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# A failed fixture on base is honest negative evidence, never permission to
# construct /repo, /stub or /tmp from an empty command-substitution result.
require_scratch_fixture() {
  local candidate="$1" base resolved leaf
  base="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || return 1
  [ -n "$candidate" ] && [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
  resolved="$(cd "$candidate" && pwd -P)" || return 1
  [ "$candidate" = "$resolved" ] || return 1
  case "$resolved" in "$base"/fm-test.*) ;; *) return 1 ;; esac
  leaf="${resolved#"$base"/}"
  case "$leaf" in */*) return 1 ;; esac
  [ -d "$candidate/repo" ] && [ ! -L "$candidate/repo" ] &&
    [ -d "$candidate/remote.git" ] && [ ! -L "$candidate/remote.git" ]
}
# and if it cannot be kept either, the run says so rather than pointing
# at a path inside the worktree as though it were safe - which is what
# the fallback this replaces did
d11="$(fixture)" && require_scratch_fixture "$d11" || {
  echo "worker-scratch: fixture d11 failed or returned an invalid owned directory" >&2
  exit 1
}
r11="$d11/repo"; GH11="$(ghstub "$d11")"
cat > "$r11/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
M
chmod +x "$r11/bin/adapters/mock.sh"
cat > "$d11/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in *" pr comment "*) exit 1 ;; esac
exit 0
G
chmod +x "$d11/stub/gh"
# a directory mode is advisory for root, so the test would silently
# invert under a root runner: it makes the destination a FILE instead,
# which no uid can cp into as if it were a directory
mkdir -p "$r11/state"; : > "$r11/state/unsent"
out12="$(cd "$r11" && FM_ROOT="$r11" FM_GH="$GH11" bin/fm-worker.sh --task T-Z --pr 9 2>&1)"; rc12=$?
rm -f "$r11/state/unsent"
assert_eq "73" "$rc12" "a question that can be neither posted nor kept still fails the run"
assert_contains "$out12" "could not be kept either" "and says the keeping failed too"
assert_lacks "$out12" "it is at state/unsent" "rather than naming a file it did not write"
# Every path that makes a scratch file, in a TMPDIR the test owns.
# Counting what is in the machine's $TMPDIR before and after scored
# every other process against the worker - and would have passed on a
# leak if anything else removed a file in the same window.
# By NAME. An owned TMPDIR settles whose machine, not whose file: git,
# the stub and the adapter all run under it too, and any of them would
# fail this as a worker leak. `scratch_new`'s template exists so a file
# left behind says who left it - so the check reads the name.
leak_check() {   # leak_check <label> <tmpdir> ; the run has already happened
  local left; left="$(find "$2" -name 'fm-worker-*' -type f 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "0" "$left" "$1"
}

# the exit-73 route, which makes say_err
d14="$(fixture)" && require_scratch_fixture "$d14" || {
  echo "worker-scratch: fixture d14 failed or returned an invalid owned directory" >&2
  exit 1
}
r14="$d14/repo"; GH14="$(ghstub "$d14")"
cat > "$r14/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
M
chmod +x "$r14/bin/adapters/mock.sh"
cat > "$d14/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in *" pr comment "*) echo "refused" >&2; exit 1 ;; esac
exit 0
G
chmod +x "$d14/stub/gh"
mkdir -p "$d14/tmp"
out16="$(cd "$r14" && TMPDIR="$d14/tmp" FM_ROOT="$r14" FM_GH="$GH14" \
    bin/fm-worker.sh --task T-Z --pr 9 2>&1)"; rc16=$?
# The control. "No file left" is also what a run that never made one
# looks like, and say_err has a path where it is not made at all -
# `scratch_new` failing leaves it empty and the run carries on. The
# replayed `gh:` line is printed only from a non-empty $say_err, so it
# is proof the file existed to be cleaned up.
assert_eq "73" "$rc16" "the run took the path that makes say_err"
assert_contains "$out16" "fm-worker: gh: refused" \
  "and it captured what gh said, which it can only do into a file it made"
leak_check "a run that exits 73 leaves no scratch file behind" "$d14/tmp"
rm -rf "$d14"

# the exit-74 route, which makes lookup_err - a different file on a
# different path, and the comment says every one of them
d15="$(fixture)" && require_scratch_fixture "$d15" || {
  echo "worker-scratch: fixture d15 failed or returned an invalid owned directory" >&2
  exit 1
}
r15="$d15/repo"; GH15="$(ghstub "$d15")"
cat > "$r15/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf '%s\n' "$RANDOM$$" > "$3/src/work"
M
chmod +x "$r15/bin/adapters/mock.sh"
( cd "$r15" && FM_ROOT="$r15" FM_GH="$GH15" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
printf '#!/usr/bin/env bash\nexit 1\n' > "$d15/stub/gh"; chmod +x "$d15/stub/gh"
mkdir -p "$d15/tmp"
( cd "$r15" && TMPDIR="$d15/tmp" FM_ROOT="$r15" FM_GH="$GH15" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
assert_eq "74" "$?" "the lookup failed, as this fixture intends"
leak_check "and a run that exits 74 leaves none either" "$d15/tmp"

# and the half the comment names by name: a signal. The scratch file is
# made at the lookup and is still there while the engine runs, so a run
# killed mid-engine is the case where "removed at the end" and "removed
# on the way out" differ.
cat > "$r15/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
: > "${FM_STARTED:?}"
exec 8<> "${FM_RELEASE:?}"
read -r -t 12 -u 8 || exit 124
M
chmod +x "$r15/bin/adapters/mock.sh"
cat > "$d15/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in *" pr list "*) echo 9; exit 0 ;; esac
exit 0
G
chmod +x "$d15/stub/gh"
safe_rm_rf "$d15/tmp"; mkdir -p "$d15/tmp"
started15="$d15/started"
mkfifo "$d15/release"
exec 8<> "$d15/release"
( cd "$r15" && TMPDIR="$d15/tmp" FM_ROOT="$r15" FM_GH="$GH15" FM_STARTED="$started15" FM_RELEASE="$d15/release" \
    exec bin/fm-worker.sh --task T-Z >/dev/null 2>&1 ) &
kp15=$!
for _ in $(seq 1 60); do [ -e "$started15" ] && break; sleep 0.2; done
assert_ok "test -e '$started15'" "the engine was running, so the scratch file is open"
kill -TERM "$kp15" 2>/dev/null
printf "release\n" >&8
wait "$kp15" 2>/dev/null
assert_eq 143 "$?" "scratch cleanup run exits on TERM after adapter release"
exec 8>&-
leak_check "and a run cut short by a signal leaves none" "$d15/tmp"
rm -rf "$d15"

rm -rf "$d11"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
