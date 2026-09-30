#!/usr/bin/env bash
# The harness has to be right before anything it asserts means anything.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

d="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho original\n' > "$d/real.sh"; chmod +x "$d/real.sh"
printf '' > "$d/empty.sh"; chmod +x "$d/empty.sh"

# the ordinary case
stub_script "$d/real.sh" <<'S'
#!/usr/bin/env bash
echo stubbed
S
assert_eq "stubbed" "$("$d/real.sh")" "a stub replaces the script"
restore_scripts
assert_eq "original" "$("$d/real.sh")" "and the original comes back"
assert_fail "test -e '$d/real.sh.orig'" "with no saved copy left behind"

# stubbed twice: the first save is the one that matters
stub_script "$d/real.sh" <<'S'
#!/usr/bin/env bash
echo first
S
stub_script "$d/real.sh" <<'S'
#!/usr/bin/env bash
echo second
S
assert_eq "second" "$("$d/real.sh")" "the second stub wins while it is in place"
restore_scripts
assert_eq "original" "$("$d/real.sh")" "and the original still comes back, not the first stub"

# nothing was there before, so nothing may be there after
stub_script "$d/new.sh" <<'S'
#!/usr/bin/env bash
echo invented
S
assert_eq "invented" "$("$d/new.sh")" "a stub can stand in for a script that does not exist"
restore_scripts
assert_fail "test -e '$d/new.sh'" "and it is removed, not left for whatever runs next"
assert_fail "test -e '$d/new.sh.absent'" "with no marker left behind"

# an empty original is still an original
stub_script "$d/empty.sh" <<'S'
#!/usr/bin/env bash
echo stubbed
S
restore_scripts
assert_ok "test -e '$d/empty.sh'" "an empty original is restored rather than deleted"
assert_eq "" "$(cat "$d/empty.sh")" "and it is still empty"
rm -rf "$d"

# empty output matches nothing, not an empty line (T-103): a here-string
# hands grep "\n", so '^$' and '^[0-9]*$' passed on a command that printed
# nothing. Run in a subshell so its failure is counted there, not here.
counted() { ( _fails=0; "$@" >/dev/null; printf '%s' "$_fails" ); }
assert_eq "1" "$(counted assert_matches "" '^$' x)" "assert_matches fails an empty string against ^\$"
assert_eq "1" "$(counted assert_matches "" '^[0-9]*$' x)" "and against a pattern that allows nothing"
assert_eq "0" "$(counted assert_matches "42" '^[0-9]*$' x)" "and still passes what does match"
assert_eq "0" "$(counted assert_matches "$(printf 'a\n\nb')" '^$' x)" "and an empty line inside the text"
# The closed PATH is independent of ambient vendor installations.
# shellcheck source=tests/lib/path.sh
. "$ROOT/tests/lib/path.sh"
path_case="$(safe_tmpdir)"
fixture_path "$path_case/bin" 'cat' bash cat python3 || exit 1
assert_eq "" "$(PATH="$path_case/bin" command -v cat)" "an omitted host tool is unreachable"
assert_eq "$path_case/bin/bash" "$(PATH="$path_case/bin" command -v bash)" "a requested tool is on the closed PATH"
assert_eq "working" "$(PATH="$path_case/bin" python3 -c 'print("working")')" "the closed PATH uses the caller's working Python"
safe_rm_rf "$path_case"
finish
