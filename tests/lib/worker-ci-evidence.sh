# shellcheck shell=bash
# Literal dependency for changed-suite selection: tests/lib/worker_ci_evidence.py
# Install a JSON responder while leaving exact log-command handling in each test.
install_ci_evidence() {
  local directory="$1" link="$2"
  cp "$ROOT/tests/lib/worker_ci_evidence.py" "$directory/stub/ci-evidence.py"
  printf '%s\n' "$link" > "$directory/stub/ci-link"
  python3 - "$directory/stub/gh" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
line = '''python3 "$(dirname "$0")/ci-evidence.py" "$(dirname "$0")/ci-link" "$@"
ci_rc=$?
[ "$ci_rc" -eq 64 ] || exit "$ci_rc"
'''
# Keep the call log before the responder.
lines = s.splitlines(keepends=True)
at = next(i for i, text in enumerate(lines) if text.startswith('case '))
lines.insert(at, line)
p.write_text(''.join(lines))
PY
}

check_strict_job_stub() (
  local stub="$1" id="$2" response rc
  cd "$ROOT" || return 1
  response="$("$stub" run view --job "$id" --log-failed --job 999 2>&1)"; rc=$?
  assert_eq 1 "$rc" "job $id stub rejects extra job selector"
  assert_eq 'could not find any workflow run' "$response" "job $id extra selector cannot return fixture output"
  response="$("$stub" run view "$id" --log-failed 2>&1)"; rc=$?
  assert_eq 1 "$rc" "job $id stub rejects workflow namespace"
  assert_eq 'could not find any workflow run' "$response" "job $id workflow namespace cannot return fixture output"
  response="$("$stub" run view --job "$id" 2>&1)"; rc=$?
  assert_eq 1 "$rc" "job $id stub requires log-failed flag"
  assert_eq 'could not find any workflow run' "$response" "job $id missing flag cannot return fixture output"
)
