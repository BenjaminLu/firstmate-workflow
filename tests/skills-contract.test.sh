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
# This suite reads the checkout, so gate 5's reverted skills are its inputs.
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

# Project-local evidence is the skills' name for the state/ brief store;
# do not demand a literal state/ path where the portable prompt supplies it.
assert_ok 'contract firstmate "approved brief.*project-local evidence.*worker" "(github|pr comment).*optional projection" "non-comment modes must not depend on a pr brief"' \
  "firstmate supplies the approved local brief with optional PR projection"
assert_ok 'contract worker "approved.*project-local record is authoritative" "pr comment.*optional projection" "no non-comment mode requires a published brief"' \
  "worker starts from the approved local brief with optional PR projection"

assert_ok 'contract reviewer "^## project and run provenance$"' \
  "reviewer has an explicit project and run provenance section"
assert_ok 'contract reviewer "external private records.*under fm_home" "not the engine or target tree"' \
  "reviewer keeps private external records under FM_HOME"
assert_ok 'contract reviewer "may run.*read-only commands.*git inspection" "checkout"' \
  "reviewer restricts in-checkout commands to read-only inspection"

# Keep head binding and carry-forward in the same paragraph: the older
# generic patch-id rule alone cannot establish authoritative remote readiness.
assert_ok 'contract reviewer "synchronize.*authoritative pr head.*local task ref.*isolated checkout" "bind.*checks?.*gates.*merge candidate" "approval carries only for unchanged authoritative patch-id with no later rejection"' \
  "merge evidence binds authoritative head and restricts approval carry-forward"

finish
