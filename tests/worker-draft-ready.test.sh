#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
for scenario in ready handmade already_ready question work_and_question first_question marker_failure ready_failure read_timeout; do
  d="$(fixture)"; r="$d/repo"; gh="$(ghstub "$d")"
  cat > "$gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in
  *' pr list '*) echo null ;;
  *' --json isDraft '*)
    [ "$FM_READY_CASE" != read_timeout ] || { sleep 30; exit 0; }
    if [ "$FM_READY_CASE" = already_ready ]; then echo false; else echo true; fi ;;
  *' pr ready '*)
    [ "$FM_READY_CASE" != ready_failure ] || exit 1
    printf '✓ Pull request #%s is marked as "ready for review"\n' "$3" ;;
  *' pr create '*) echo https://example.invalid/pull/42 ;;
  *' pr view '*) echo '{}' ;;
  *' api '*) echo '{}' ;;
esac
SH
  cat > "$r/bin/adapters/mock.sh" <<'SH'
#!/usr/bin/env bash
case "$FM_READY_CASE" in
  question|first_question|marker_failure) printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md" ;;
  work_and_question)
    mkdir -p "$3/src"; echo work > "$3/src/done"
    printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md" ;;
  *) mkdir -p "$3/src"; echo work > "$3/src/done" ;;
esac
SH
  chmod +x "$r/bin/adapters/mock.sh"
  mkdir -p "$r/state/drafts"
  [ "$scenario" = handmade ] || touch "$r/state/drafts/T-Z-9"
  pr=(--pr 9)
  case "$scenario" in first_question|marker_failure) pr=() ;; esac
  if [ "$scenario" = marker_failure ]; then
    # A regular file blocks the directory even when CI runs as root.
    rm -rf "$r/state/drafts"
    printf 'blocked\n' > "$r/state/drafts"
  fi
  out="$(cd "$r" && FM_READY_CASE="$scenario" FM_ROOT="$r" FM_GH="$gh" FM_GH_TIMEOUT=1 FM_GH_RETRY_DELAYS='0 0' bin/fm-worker.sh --task T-Z ${pr[@]+"${pr[@]}"} 2>&1)"; rc=$?
  assert_eq 0 "$rc" "$scenario round completes"
  calls="$(cat "$d/ghcalls")"
  case "$scenario" in
    ready)
      assert_eq 1 "$(grep -c '^gh pr ready 9$' "$d/ghcalls")" 'finished owned draft marked ready exactly once'
      assert_fail "test -e '$r/state/drafts/T-Z-9'" 'successful ready removes marker'
      assert_contains "$(cat "$r/state/events.jsonl")" 'marked ready for review' 'ready emits status' ;;
    first_question)
      assert_contains "$calls" --draft 'first question opens draft'
      assert_ok "test -f '$r/state/drafts/T-Z-42'" 'first question records draft ownership' ;;
    marker_failure)
      assert_contains "$calls" --draft 'marker failure still opens draft'
      assert_contains "$out" 'fm-worker: warning: could not record ownership of draft #42' 'marker failure warns'
      assert_contains "$(jq -r .type "$r/state/events.jsonl")" pr_opened 'marker failure still records opened pull request'
      assert_contains "$(cat "$r/state/events.jsonl")" 'Pull request #42 opened' 'marker failure still emits opened status' ;;
    ready_failure)
      assert_eq 1 "$(grep -c '^gh pr ready 9$' "$d/ghcalls")" 'ready write failure is never retried'
      assert_contains "$out" 'fm-worker: could not mark pull request #9 ready for review' 'ready failure warns without failing pushed round'
      assert_ok "test -f '$r/state/drafts/T-Z-9'" 'failed ready retains ownership marker' ;;
    read_timeout)
      assert_contains "$out" 'fm-worker: could not read draft status for pull request #9' 'draft read timeout warns without failing pushed round'
      assert_eq 3 "$(grep -c 'pr view 9 --json isDraft' "$d/ghcalls")" 'draft timeout retries only the read'
      assert_lacks "$calls" 'pr ready' 'failed draft read performs no write'
      assert_ok "test -f '$r/state/drafts/T-Z-9'" 'failed draft read retains marker' ;;
    *) assert_lacks "$calls" 'pr ready' "$scenario does not mark ready" ;;
  esac
  safe_rm_rf "$d"
done
# Adoption is external-only; execute the exact new transition with controlled boundaries.
python3 - "$ROOT" <<'PY'
import sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1])/'tests/lib'))
from crew_blocks import section, shell
root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as tmp:
    home = Path(tmp)
    (home/'state/drafts').mkdir(parents=True)
    (home/'state/drafts/T-Z-9').touch()
    block = section(root/'bin/fm-worker.sh', '  # Mark only a draft opened by firstmate', '  # End owned draft transition')
    result = shell(root, home, block, '''set -u
num=9; adopt_pr=9; asked=0; round_had_work=1
fm_github() { echo "$*" >> "$work/ghcalls"; echo true; }
''')
    assert result.returncode == 0, result.stderr
    assert not (home/'ghcalls').exists(), 'adopted draft must not be readied'
PY
assert_eq 0 "$?" 'adopted owned-marker draft is excluded'
finish
