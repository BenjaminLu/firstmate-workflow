#!/usr/bin/env bash
# T-298: a designer with a fresh context reviews the rendered pages of every
# pull request that touches pages, and gate 6 holds a UI change until a
# design APPROVE on its head exists. Real launchers, a mock engine and a
# stand-in for the browser.
# Feature dependencies: bin/lib/fm_design.py bin/fm-review.sh bin/fm-gate.sh bin/fm-herdr.py
#   bin/lib/fm_evidence.py bin/lib/fm_round_budget.py bin/lib/fm_autopilot_loop.py
#   bin/lib/fm_context_pack.py bin/lib/fm_registry.py bin/fm-config.sh skills/designer/SKILL.md
# Shared fixtures: tests/lib/worker.sh tests/lib/binding-fixture.sh
#   tests/lib/design_review.py tests/lib/design_capture_stub.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/binding-fixture.sh
. "$ROOT/tests/lib/binding-fixture.sh"

unit() {  # unit <Class.test_name>: one case of tests/lib/design_review.py
  PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/lib/design_review.py" "$ROOT" "$1" > "$work/unit.out" 2>&1
}
work="$(safe_tmpdir)"

# --- design: project ui globs used (fail-first) ---------------------------
unit UiGlobs.test_project_ui_globs_replace_the_defaults
assert_eq 0 "$?" 'design: project ui globs used'
unit UiGlobs.test_defaults_without_a_project_list
assert_eq 0 "$?" 'design: the page-file defaults apply without a project list'
unit UiGlobs.test_this_repository_adds_the_board
assert_eq 0 "$?" "design: this repository's ui list is the defaults plus board/public/**"
unit UiGlobs.test_a_malformed_ui_list_is_refused
assert_eq 0 "$?" 'design: a ui value that is not a list is refused'
unit UiGlobs.test_viewports_include_each_breakpoint_edge
assert_eq 0 "$?" 'design: every web width plus both edges of each breakpoint; six app viewports'

# --- design: skill sources recorded (fail-first) --------------------------
unit SkillSources.test_skill_header_lists_every_source_and_notice_exists
assert_eq 0 "$?" 'design: skill sources recorded'

# --- design: missing round started (fail-first) ---------------------------
unit MissingRound.test_missing_design_round_started
assert_eq 0 "$?" 'design: missing round started'
unit MissingRound.test_both_missing_start_together
assert_eq 0 "$?" 'design: code and design review start together on the same head'
unit MissingRound.test_non_ui_starts_only_the_code_review
assert_eq 0 "$?" 'design: a gate with no design lane missing starts no designer'

# --- end to end: one fixture per pull request -----------------------------
# setup_repo <file the worker writes> [prototype]: a fixture repository driven by the real
# worker, reviewer and gate, with a mock engine that answers as a worker, a
# code reviewer or a designer from its prompt
setup_repo() {
  d="$(fixture)"; repo="$d/repo"
  binding_service_fixture "$repo"
  cp "$ROOT/bin/fm-review.sh" "$ROOT/bin/fm-gate.sh" "$ROOT/bin/fm-protocol.sh" "$repo/bin/"
  mkdir -p "$repo/skills/reviewer" "$repo/skills/designer"
  cp "$ROOT/skills/reviewer/SKILL.md" "$repo/skills/reviewer/"
  cp "$ROOT/skills/designer/SKILL.md" "$repo/skills/designer/"
  cat >> "$repo/config.yaml" <<'CONFIG'
default_project: firstmate-workflow
projects:
  firstmate-workflow:
    repo: .
    github: fixture/repository
    base: main
    required_check: ci
    design: design/design.md
    tasks: design/tasks
    projection: local
CONFIG
  cat > "$repo/bin/adapters/mock.sh" <<'ADAPTER'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
if [ "$FM_ROLE" = worker ]; then
  printf '%s\n' "${FM_PROTOTYPE_DIR:-}" > "$FM_TEST_DIR/worker-prototype"
  [ -z "${FM_CAPTURE:-}" ] || cp "$2" "$FM_CAPTURE"
  mkdir -p "$3/src"
  printf '<!doctype html><title>p</title><p>round %s</p>\n' "$RANDOM" > "$3/$FM_TEST_FILE"
elif grep -q '^# Designer$' "$2"; then
  cp "$2" "$FM_TEST_DIR/designer-prompt.md"
  printf '%s\n' "${FM_PROTOTYPE_DIR:-}" > "$FM_TEST_DIR/designer-prototype"
  printf 'called\n' >> "$FM_TEST_DIR/designer-called"
  if [ "$FM_TEST_DESIGN" = reject ]; then
    printf '1. [must-fix] page src/page.html, w390 light: DESIGN_FINDING the heading overlaps the menu\n```text fix-1\nfile: src/page.html:1\nchange: give the heading its own row\nfixes: the overlap at w390\nfail-first: the w390 screenshot shows the overlap\n```\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z\n' > "$3/verdict.txt"
  else
    printf 'APPROVE:T-Z\n' > "$3/verdict.txt"
  fi
else
  printf 'APPROVE:T-Z\n' > "$3/verdict.txt"
fi
ADAPTER
  chmod +x "$repo/bin/adapters/mock.sh"
  if [ -n "${2:-}" ]; then   # the approved prototype, named in the spec before dispatch pins it
    mkdir -p "$repo/state/prototypes/p1"
    printf '<!doctype html><title>proto</title><style>@media (min-width: 700px){p{margin:1em}}</style><p>p</p>\n' \
      > "$repo/state/prototypes/p1/index.html"
    jq '.design={mode:"prototype",kind:"web",prototype:"state/prototypes/p1"}' "$repo/design/tasks/T-Z.json" > "$d/spec.json" &&
      cp "$d/spec.json" "$repo/design/tasks/T-Z.json"
  fi
  git -C "$repo" add .
  git -C "$repo" commit -qm 'design fixture'
  git -C "$repo" push -q origin main
  seed_self_pr_authoring "$repo" T-Z firstmate-workflow
  mkdir -p "$d/stub"
  cat > "$d/stub/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  'pr comment') exit 1 ;;
  'pr list') echo null ;;
  'pr create') echo https://example.invalid/pull/42 ;;
  'pr checks') echo '[{"name":"ci","state":"SUCCESS","bucket":"pass"}]' ;;
  'pr view') printf '{"headRefOid":"%s","baseRefName":"main","mergeStateStatus":"CLEAN"}\n' "$(git rev-parse "${FM_TEST_BRANCH:-HEAD}")" ;;
  'api '*)
    case "$2" in
      *protection*) echo '{"contexts":["ci"]}' ;;
      *check-runs*) echo '{"check_runs":[]}' ;;
      */status*) printf '{"sha":"%s","statuses":[]}\n' "$(git rev-parse "${FM_TEST_BRANCH:-HEAD}")" ;;
      *) echo '{}' ;;
    esac ;;
esac
GH
  chmod +x "$d/stub/gh"
  export FM_GH="$d/stub/gh" FM_ROOT="$repo" FM_REVIEW_CI_WAIT=0 FM_TEST_DIR="$d" FM_TEST_FILE="$1"
  export FM_GATE_LOCK="$d/gate.lock" FM_TEST_DESIGN=approve
  export FM_DESIGN_CAPTURE="python3 $ROOT/tests/lib/design_capture_stub.py"
  export GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z
  unset FM_TEST_CAPTURE_FAIL FM_TEST_BRANCH
  (cd "$repo" && bin/fm-worker.sh --task T-Z) > "$d/worker.out" 2>&1 || return 1
  branch="$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
  head="$(git -C "$repo" rev-parse "$branch")"
  export FM_TEST_BRANCH="$branch"
}
gate6() { (cd "$repo" && bin/fm-gate.sh --task T-Z --repo "$repo" --branch "$branch" --only 6 --pr 42) > "$d/gate.out" 2>&1; }
review() { (cd "$repo" && bin/fm-review.sh "$@" --task T-Z --branch "$branch" --round 1 --pr 42) > "$d/review.out" 2>&1; }

# --- design: non-ui pr unaffected (regression) ----------------------------
setup_repo src/feature.txt
assert_eq 0 "$?" 'the worker completes a change that touches no page'
assert_eq '' "$(cat "$d/worker-prototype")" 'worker without a prototype receives none'
review
assert_eq 0 "$?" 'the code review signs it'
gate6
assert_eq 0 "$?" 'design: non-ui pr unaffected'
assert_contains "$(cat "$d/gate.out")" 'lane design: not-needed' 'gate 6 says no design review is needed'
assert_fail "test -e '$d/designer-called'" 'no designer round ran'
assert_fail "test -e '$repo/state/design'" 'no page was captured'
safe_rm_rf "$d"

# --- design: ui pr needs approve (fail-first) -----------------------------
setup_repo src/page.html prototype
assert_eq 0 "$?" 'the worker completes a change that touches a page'
assert_eq "$(cd "$repo/state/prototypes/p1" && pwd -P)" "$(cat "$d/worker-prototype")" 'worker launcher selects its pinned prototype'
review
assert_eq 0 "$?" 'the code review signs it'
gate6
assert_eq 6 "$?" 'design: ui pr needs approve'
assert_contains "$(cat "$d/gate.out")" 'lane code: ok' 'the code lane passes on its own'
assert_contains "$(cat "$d/gate.out")" 'lane design: missing' 'gate 6 names the missing design review'

# --- design: capture failure blocks (fail-first) --------------------------
FM_TEST_CAPTURE_FAIL=1 review --designer
rc=$?
assert_eq 65 "$rc" 'design: capture failure blocks'
assert_fail "test -e '$d/designer-called'" 'no designer engine started after a failed capture'
assert_contains "$(cat "$d/review.out")" 'no design round started' 'the launcher says the round did not start'

# a capture that works hands every page to the designer, for the head and the prototype
FM_TEST_CAPTURE_LOG="$d/captured" review --designer
assert_eq 0 "$?" 'the designer round runs once every page is captured'
assert_contains "$(cat "$d/captured")" 'head src/page.html w320 dark' 'the head page is captured narrow and dark'
assert_contains "$(cat "$d/captured")" 'prototype src/page.html w1920 light' 'the prototype is captured wide and light'
assert_contains "$(cat "$d/captured")" 'prototype src/page.html w699 light' 'the prototype breakpoint edge is captured'
assert_ok "test -s '$repo/state/design/T-Z/$head/manifest.json'" 'the screenshots are kept for the merge card'
assert_contains "$(cat "$d/designer-prompt.md")" 'Approved prototype' 'the designer is told a prototype exists'
assert_contains "$(cat "$d/designer-prompt.md")" 'w390 (390x900), dark: head ' 'the designer gets each head screenshot'
assert_lacks "$(cat "$d/designer-prompt.md")" 'Find the reason to reject' 'the designer does not get the code reviewer skill'
assert_eq "$(cd "$repo/state/prototypes/p1" && pwd -P)" "$(cat "$d/designer-prototype" 2>/dev/null)" \
  "the designer round is handed its task's prototype folder to read"
gate6
assert_eq 0 "$?" 'a design APPROVE on the head opens gate 6'
assert_contains "$(cat "$d/gate.out")" 'lane design: ok' 'gate 6 names the design approval'

# --- design: reject counts a round (fail-first) ---------------------------
FM_TEST_DESIGN=reject review --designer
assert_eq 0 "$?" 'the design REJECT is retained'
gate6
assert_eq 6 "$?" 'a later design REJECT closes gate 6 again'
budget="$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1] + "/bin/lib")
from fm_evidence import Store; from fm_round_budget import rounds
print(" ".join("%s:%s" % (r["round"], r["verdict"]) for r in rounds(Store(sys.argv[2], "firstmate-workflow", "T-Z"))))
' "$ROOT" "$repo/state")"
unit RoundBudget.test_design_reject_counts_a_round
assert_eq '0 1:REJECT' "$? $budget" 'design: reject counts a round'
unit RoundBudget.test_design_and_code_lists_stay_apart
assert_eq 0 "$?" 'design: lanes keep their own lists'
unit RoundBudget.test_a_design_item_open_two_rounds_stalls
assert_eq 0 "$?" 'design: a design item open two rounds stalls'
printf '1. fix the overlap at w390\n' > "$d/brief.md"
(cd "$repo" && bash bin/lib/fm-evidence.sh brief --task T-Z --round 2 --head "$head" --file "$d/brief.md")
export FM_CAPTURE="$d/worker-prompt.md"
(cd "$repo" && bin/fm-worker.sh --task T-Z --pr 42) > "$d/worker-two.out" 2>&1
assert_eq 0 "$?" 'the worker runs round two'
assert_contains "$(cat "$d/worker-prompt.md")" 'DESIGN_FINDING' 'the design REJECT reaches the worker'
unset FM_CAPTURE
safe_rm_rf "$d"
safe_rm_rf "$work"
finish
