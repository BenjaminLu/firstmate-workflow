#!/usr/bin/env bash
# T-166 owns this suite: guard role skill rules, which config.yaml classes
# as behaviour. These are instruction contracts, not proof of model compliance.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source the common assertions directly: tests/lib/review.sh also sources
# these, but runs unrelated runtime assertions and prepares review fixtures.
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# Require related concepts in the same operative paragraph, ignoring case,
# Markdown emphasis and line wrapping. Never eval text read from a skill.
# This suite reads the checkout, so gate 4's reverted skills are its inputs.
contract() {
  python3 - "$ROOT/skills/$1/SKILL.md" "${@:2}" <<'PY'
from pathlib import Path
import re
import sys

paragraphs = [re.sub(r"\s+", " ", p.replace("`", "").replace("*", ""))
              for p in re.split(r"\n\s*\n", Path(sys.argv[1]).read_text())]
sys.exit(0 if any(all(re.search(pattern, p, re.I) for pattern in sys.argv[2:])
                  for p in paragraphs) else 1)
PY
}

assert_ok 'contract firstmate "claude.*t-163.*managed codex.*support run mode" "trusted.*admission.*confinement"' \
  "run mode admits Claude and managed Codex with confinement"

# Return a canonical diagnostic rather than comparing a sentence literally.
obsolete_admission="$(python3 - "$ROOT/skills/firstmate/SKILL.md" <<'PY'
from pathlib import Path
import re
import sys

text = re.sub(r"\s+", " ", Path(sys.argv[1]).read_text().replace(chr(96), ""))
if re.search(r"only adapters[^.]{0,120}\btoday\s+claude\b", text, re.I):
    print("claude-only run admission")
PY
)"
assert_lacks "$obsolete_admission" "claude-only run admission" \
  "run mode no longer restricts admission to Claude alone"

assert_ok 'contract firstmate "managed codex.*current-attempt.*completed-turn.*final output" "authenticated.*review_final" "legacy.*(marker|substring).*not establish final-answer provenance"' \
  "verdict reading distinguishes authenticated Codex finals from legacy markers"

# Local round records and optional projection must be stated together;
# the captain's revision gives T-135 ownership without external prerequisites.
assert_ok 'contract firstmate "approved brief.*project-local evidence.*worker" "(github|pr comment).*optional projection" "non-comment modes must not depend on a pr brief" "t-135.*records.*append-only.*state/evidence" "comments/local"' \
  "firstmate supplies the approved local brief with optional PR projection"
assert_ok 'contract worker "approved.*project-local record is authoritative" "pr comment.*optional projection" "no non-comment mode requires a published brief" "t-135.*records append-only.*state/evidence" "comments/local"' \
  "worker starts from the approved local brief with optional PR projection"

assert_ok 'contract reviewer "^## project and run provenance$" && contract reviewer "t-135.*from round two.*local records" "every reject from round one" "comments/local" "missing local records.*never replaced"' \
  "reviewer has an explicit project and run provenance section"
assert_ok 'contract reviewer "external private records.*under fm_home" "not the engine or target tree"' \
  "reviewer keeps private external records under FM_HOME"
assert_ok 'contract reviewer "may run.*read-only commands.*git inspection" "checkout"' \
  "reviewer restricts in-checkout commands to read-only inspection"

# Keep head binding and carry-forward in the same paragraph: the older
# generic patch-id rule alone cannot establish authoritative remote readiness.
assert_ok 'contract reviewer "synchronize.*authoritative pr head.*local task ref.*isolated checkout" "bind.*checks?.*gates.*merge candidate" "approval carries only for unchanged authoritative patch-id with no later rejection"' \
  "merge evidence binds authoritative head and restricts approval carry-forward"

# T-274: flaky failures are rerun narrowly and recurring ones root-caused.
assert_ok 'contract firstmate "runs only two gh commands itself" "gh pr update-branch, only on a pull request github reports as both behind and mergeable" "gh run rerun <run> --failed, only for a ci failure shown to be flaky"' \
  "firstmate names its two gh commands and their conditions"
assert_fail 'contract firstmate "the only gh command firstmate runs itself"' \
  "update-branch is no longer called the only gh command"
assert_ok 'contract firstmate "update-branch exists to bring a branch up to date.*it and gh run rerun <run> --failed are the only two gh commands firstmate runs itself" "rerun <run> --failed reruns only the failed jobs of a ci run, and only when the failure is shown to be flaky" "same code passed that job before, or nothing the pull request changed can reach the failing test" "never rerun a whole run"' \
  "rerun only failed jobs and only when shown flaky"
assert_ok 'contract firstmate "second hit of one flaky signature.*counting the hits already in the ledger.*starts a root-cause investigation by a separate researcher" "stock read-only research round or a delegated agent" "reproduces the failure, proves the cause with a controlled experiment and writes a fix task spec for the captain" "rerun may still unblock the pull request meanwhile"' \
  "second hit starts an independent investigation with experiment and fix spec"
assert_ok 'contract firstmate "active investigation, open or fix task, is never started twice" "investigate refuses it"' \
  "an active investigation is never started twice"
assert_ok 'contract firstmate "projection allows pull request comments, a rerun gets a comment naming the job, the evidence and, from the second hit on, the open investigation"' \
  "a rerun comment names the open investigation"
assert_ok 'contract firstmate "external project \(fm_external=1\) follow that project.s projection and conventions" "never publish private project text, spec text or research findings" "evidence stays in the private ledger"' \
  "external projects keep flaky evidence private"
assert_ok 'contract firstmate "applies from t-274.s merge onward, for every firstmate session that has reloaded the merged skills" "hits seeded from earlier notes count toward the second hit"' \
  "the flaky rule applies from T-274's merge for reloaded sessions"
assert_ok 'contract firstmate "flaky ledger, state/flaky-ledger.json under the project.s state root" "bin/lib/fm_flaky.py: hit \(with --rerun once rerun\), investigate, link, fixed and show" "each with --project <name>"' \
  "the ledger path, its helper and its commands"

finish
