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
finish
