#!/usr/bin/env bash
# Fourteen cases: each gate has one that passes and one that does not.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
GATE="$ROOT/bin/fm-gate.sh"

# a fixture repo with a working ci.sh, a tasks.json, and main at a known state
fixture() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q -b main
  git -C "$d" config user.email a@b.c; git -C "$d" config user.name t
  mkdir -p "$d/bin" "$d/tests" "$d/design" "$d/src"
  printf '#!/usr/bin/env bash\nfor t in "${FM_ROOT:-.}"/tests/*.test.sh; do [ -e "$t" ] || continue; bash "$t" || exit 1; done\nexit 0\n' > "$d/bin/ci.sh"
  chmod +x "$d/bin/ci.sh"
  cat > "$d/design/tasks.json" <<JSON
{"tasks":[{"id":"T-X","scope":["src/**","tests/**"]}]}
JSON
  echo base > "$d/src/thing.sh"
  git -C "$d" add -A; git -C "$d" commit -qm base
  printf '%s' "$d"
}
# Hermetic against the caller's own environment: this suite runs as one of
# bin/ci.sh's own tests/*.test.sh, and firstmate's documented way to run the
# full local gate is FM_CI_MAX_SECONDS=600 bash bin/ci.sh (design.md section
# 10) - the very value gate3() itself now sets. Left to inherit, an ambient
# FM_CI_MAX_SECONDS would leak into gate3's subshell regardless of whether
# gate3's own code sets it, so the "slow" case below would pass even under
# gate3's old, unfixed bare-default behavior. env -u makes every case here
# test what gate3 itself does, not what surrounds it.
gate() { env -u FM_CI_MAX_SECONDS "$GATE" --task T-X --repo "$1" --branch "$2" --only "$3" "${@:4}" >/dev/null 2>&1; }

# --- gate 1 --------------------------------------------------------------
d="$(fixture)"
assert_fail "'$GATE' --task T-X --repo '$d' --branch nope --only 1" "1 blocks a branch that does not exist"
git -C "$d" checkout -q -b work; echo x >> "$d/src/thing.sh"; git -C "$d" commit -qam work
git -C "$d" checkout -q main
assert_ok "gate '$d' work 1" "1 passes a branch with commits"

# --- gate 2 --------------------------------------------------------------
assert_ok "gate '$d' work 2" "2 passes a branch that rebases cleanly"
git -C "$d" checkout -q main; echo conflicting > "$d/src/thing.sh"; git -C "$d" commit -qam diverge
assert_fail "gate '$d' work 2" "2 blocks a branch that conflicts"

# --- gate 3 --------------------------------------------------------------
d="$(fixture)"; git -C "$d" checkout -q -b green
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/a.test.sh"; chmod +x "$d/tests/a.test.sh"
echo impl > "$d/src/thing.sh"; git -C "$d" add -A; git -C "$d" commit -qm green; git -C "$d" checkout -q main
assert_ok "gate '$d' green 3" "3 passes when ci.sh exits 0"
git -C "$d" checkout -q -b red green
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/tests/a.test.sh"; git -C "$d" commit -qam red; git -C "$d" checkout -q main
assert_fail "gate '$d' red 3" "3 blocks when ci.sh exits non-zero"

# design.md section 10: GitHub sets FM_CI_MAX_SECONDS=600 and firstmate runs
# the same full local gate at that budget before publication. A suite whose
# real work fits in 600s but not the bare 180s default must pass gate3 only
# because gate3 sets that budget itself - not because it took 180s or less.
# The fixture fakes its own duration so this is deterministic, not a flaky
# real sleep. Branches off the same green fixture gate 4 below still needs,
# rather than calling fixture() again and shadowing $d out from under it.
git -C "$d" checkout -q -b slow green
printf '#!/usr/bin/env bash\nbudget="${FM_CI_MAX_SECONDS-180}"\ntook=300\n[ "$took" -le "$budget" ]\n' \
  > "$d/bin/ci.sh"
git -C "$d" commit -qam slow; git -C "$d" checkout -q main
assert_ok "gate '$d' slow 3" \
  "3 passes a 300s suite because gate3 itself sets the 600s budget design.md authorizes"

# --- gate 4 --------------------------------------------------------------
assert_ok "gate '$d' green 4" "4 passes a diff inside the declared scope"
git -C "$d" checkout -q -b wide green
mkdir -p "$d/elsewhere"; echo x > "$d/elsewhere/f"; git -C "$d" add -A; git -C "$d" commit -qm wide
git -C "$d" checkout -q main
assert_fail "gate '$d' wide 4" "4 blocks a diff that reaches outside it"

# --- gate 5: the one that matters ---------------------------------------
d="$(fixture)"
git -C "$d" checkout -q -b vacuous
printf 'real\n' > "$d/src/thing.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/v.test.sh"        # asserts nothing
chmod +x "$d/tests/v.test.sh"; git -C "$d" add -A; git -C "$d" commit -qm vacuous
git -C "$d" checkout -q main
assert_fail "gate '$d' vacuous 5" "5 blocks a test that passes without the implementation"

git -C "$d" checkout -q -b honest main
mkdir -p "$d/tests"          # git does not track an empty directory
printf 'real\n' > "$d/src/thing.sh"
printf '#!/usr/bin/env bash\ngrep -q real "${FM_ROOT:-.}/src/thing.sh"\n' > "$d/tests/h.test.sh"
chmod +x "$d/tests/h.test.sh"; git -C "$d" add -A; git -C "$d" commit -qm honest
git -C "$d" checkout -q main
assert_ok "gate '$d' honest 5" "5 passes a test that goes red without it"

git -C "$d" checkout -q -b untested main
printf 'more\n' >> "$d/src/thing.sh"; git -C "$d" commit -qam untested; git -C "$d" checkout -q main
assert_fail "gate '$d' untested 5" "5 blocks implementation that ships no test at all"

# --- gates 6 and 7: gh is injectable so the suite makes no network call ---
stub() {  # stub <dir> <checks-exit> <approver-login>
  mkdir -p "$1/stub"
  cat > "$1/stub/gh" <<EOF
#!/usr/bin/env bash
if [ "\$2" = "checks" ]; then exit $2; fi
if [ "\$2" = "view" ]; then printf '%s\n' "$3"; exit 0; fi
exit 0
EOF
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"
}
d2="$(fixture)"; git -C "$d2" checkout -q -b b; echo y >> "$d2/src/thing.sh"
git -C "$d2" commit -qam b; git -C "$d2" checkout -q main

assert_ok   "FM_GH='$(stub "$d2" 0 reviewer-1)' gate '$d2' b 6 --pr 9" "6 passes when the required check is green"
assert_fail "FM_GH='$(stub "$d2" 1 reviewer-1)' gate '$d2' b 6 --pr 9" "6 blocks when it is not"
assert_fail "'$GATE' --task T-X --repo '$d2' --branch b --only 6" "6 blocks with no pull request at all"

assert_ok   "FM_GH='$(stub "$d2" 0 reviewer-1)' FM_REVIEWER_LOGIN=reviewer-1 gate '$d2' b 7 --pr 9" \
  "7 passes on APPROVE from the reviewer"
assert_fail "FM_GH='$(stub "$d2" 0 someone-else)' FM_REVIEWER_LOGIN=reviewer-1 gate '$d2' b 7 --pr 9" \
  "7 ignores APPROVE from anyone else"

# --- the exit code names the gate ---------------------------------------
"$GATE" --task T-X --repo "$d" --branch untested --only 5 >/dev/null 2>&1
assert_eq "5" "$?" "the exit code is the number of the gate that failed"
finish
