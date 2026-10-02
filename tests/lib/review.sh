# shellcheck shell=bash
# Caller/consumer globals are checked when linting the feature suites.
# shellcheck disable=SC2034
# What the reviewer is shown is the whole point of this script.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
unset GH_REPO  # self fixtures keep their working-directory GitHub API paths
export HERDR_ENV=0 FM_TRANSPORT=direct
# A round given --pr waits for the head's required checks (T-153); the
# fixtures' checks never finish, so no case waits unless it says so
export FM_REVIEW_CI_WAIT=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/binding-fixture.sh
. "$ROOT/tests/lib/binding-fixture.sh"
# T-161: newer bash can run the old unbraced messages successfully. Check
# the actual executable sources too, independently of ci.sh's lint, so
# reverting either repair is detected on Linux as well as macOS bash 3.2.
# Keep one assertion per script so fail-first identifies each repair.
for boundary_script in fm-review.sh fm-auth-probe.sh; do
  python3 - "$ROOT/bin/$boundary_script" <<'PY_BOUNDARY_SOURCE'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
pattern = re.compile(rb'\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]')
violations = [number for number, line in enumerate(path.read_bytes().split(b'\n'), 1)
              if pattern.search(line)]
for number in violations:
    print(f'{path}:{number}: unbraced variable before non-ASCII text')
sys.exit(1 if violations else 0)
PY_BOUNDARY_SOURCE
  assert_eq '0' "$?" "$boundary_script production variables are braced before non-ASCII text"
done
# This suite runs fm-review.sh in run mode, which sweeps ${TMPDIR:-/tmp} for
# abandoned checkouts (T-123): give it a TMPDIR of its own before any of that,
# so running this suite from inside a live review round's bin/ci.sh can never
# sweep the round's own checkout.
real_tmp="${TMPDIR:-/tmp}"
isolate_tmpdir

eventually() {   # eventually <command...>: 0 once the command is, 1 after 60s
  local end=$(( $(date +%s) + 60 ))
  until "$@"; do [ "$(date +%s)" -le "$end" ] || return 1; sleep 0.05; done
}

fixture() {
  local d; d="$(safe_tmpdir)"
  git init -q -b main "$d/repo"; cd "$d/repo" || return 1
  git config user.email a@b.c; git config user.name t
  mkdir -p bin design/tasks "$d/repo/skills/reviewer" src state
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-review.sh" bin/; project_storage_fixture bin/
  cp "$ROOT/bin/fm-herdr.py" "$ROOT/bin/fm-auth-probe.sh" "$ROOT/bin/fm-sandbox.sh" bin/; project_storage_fixture bin/
  cp -r "$ROOT/bin/adapters" bin/
  cp -R "$ROOT/bin/lib" bin/   # the lifeline a round's runner holds (T-151)
  binding_service_fixture "$d/repo"  # unrelated orchestration cases; real head checks in role-prompts
  cp "$ROOT/skills/reviewer/SKILL.md" "$d/repo/skills/reviewer/"
  printf 'vendor: mock\n' > config.yaml
  printf '{"id":"T-Z","title":"a task","activity":{"en":"Review the authored task","zh-TW":"審查已撰寫的任務"},"scope":["src/**"],"acceptance":["it exists"]}\n' > design/tasks/T-Z.json
  echo base > src/a; git add -A; git commit -qm base
  git checkout -q -b work
  echo "SECRET_WORKER_REASONING" > src/a
  git commit -qam work; git checkout -q main
  printf '%s' "$d"
}
ghstub() { mkdir -p "$1/stub"
  printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/ghcalls"\nexit 0\n' "$1" > "$1/stub/gh"
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"; }

