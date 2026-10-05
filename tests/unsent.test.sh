#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
d="$(fixture)"; r="$d/repo"
mkdir -p "$r/state/unsent" "$d/elsewhere"
git -C "$d/elsewhere" init -q
export FM_HOME="$d/private-home"
export FM_IN_ROUND=1 FM_ROOT="$r" FM_GH="$d/gh" FM_PROJECT=unrelated GH_REPO=elsewhere/wrong
cat > "$d/gh" <<'G'
#!/usr/bin/env bash
[ -z "${GH_REPO:-}" ] || exit 64
printf '%s\n' "$PWD" >> "$FM_ROOT/../cwd"
printf '%s\n' "$*" >> "$FM_ROOT/../calls"
case "$1 $2" in
  'api repos/{owner}/{repo}/issues/9/comments')
    [ "$*" = 'api repos/{owner}/{repo}/issues/9/comments --paginate --jq .[].body' ] || exit 64
    case "${UNSENT_MODE:-new}" in
      landed) cat "$FM_ROOT/../marker" ;;
      lookup-fails) exit 1 ;;
    esac ;;
  'api '*) echo '{}'; exit 0 ;;
  'pr comment')
    [ "$1 $2 $3 $4" = 'pr comment 9 --body-file' ] || exit 64
    cat "$5" > "$FM_ROOT/../body"
    [ "${UNSENT_MODE:-new}" != fails ] || exit 1 ;;
esac
G
chmod +x "$d/gh"
run_unsent() { (cd "$d/elsewhere" && bash "$ROOT/bin/fm.sh" unsent "$@"); }
printf 'old evidence\n' > "$r/state/unsent/worker-x-t1-r2.md"
printf 'old question\n' > "$r/state/unsent/SK-007-old.md"
printf 'unpublished\n' > "$r/state/unsent/T-199-pending.md"
printf '{"pr":9,"head":null,"round":2,"saved_at":"now"}\n' > "$r/state/unsent/T-199-pending.md.json"
cp "$r/state/unsent/T-199-pending.md.json" "$d/pending.json"
cp "$r/state/unsent/T-199-pending.md" "$d/pending.md"
cp "$r/state/unsent/SK-007-old.md" "$d/legacy.md"
cp "$r/state/unsent/worker-x-t1-r2.md" "$d/actor.md"
out="$(run_unsent)"
assert_eq worker-x-t1-r2 "$(printf '%s\n' "$out" | awk -F '\t' '$1=="worker-x-t1-r2.md" {print $2}')" 'actor evidence uses actor as task column'
assert_eq SK-007 "$(printf '%s\n' "$out" | awk -F '\t' '$1=="SK-007-old.md" {print $2}')" 'skill task prefix is recognized'
assert_contains "$out" 'not published' 'pending push is explicit'
assert_contains "$out" 'no pull request recorded' 'legacy notes lack a PR'
: > "$d/calls"
run_unsent --post >/dev/null
assert_eq 0 "$?" 'skipping unrecoverable notes is successful'
assert_eq '' "$(cat "$d/calls")" 'legacy and unpublished notes never reach gh'
assert_eq 'old question' "$(cat "$r/state/unsent/SK-007-old.md")" 'legacy bytes retained'
assert_eq 'old evidence' "$(cat "$r/state/unsent/worker-x-t1-r2.md")" 'actor bytes retained'
assert_eq 'unpublished' "$(cat "$r/state/unsent/T-199-pending.md")" 'pending bytes retained'
assert_ok "cmp '$d/pending.md' '$r/state/unsent/T-199-pending.md'" 'pending note byte-identical'
assert_ok "cmp '$d/legacy.md' '$r/state/unsent/SK-007-old.md'" 'legacy note byte-identical'
assert_ok "cmp '$d/actor.md' '$r/state/unsent/worker-x-t1-r2.md'" 'actor note byte-identical'
assert_ok "cmp '$d/pending.json' '$r/state/unsent/T-199-pending.md.json'" 'pending metadata unchanged'
for mode in landed new fails lookup-fails; do
  f="$r/state/unsent/T-199-$mode.md"
  printf 'the original note\n' > "$f"
  hex="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$f")"
  printf '<!-- fm-note sha256=%s -->\n' "$hex" > "$d/marker"
  jq -n --arg marker "$hex" '{pr:9,head:"abc",round:2,marker:$marker,saved_at:"yesterday"}' > "$f.json"
  # Exercise hash fallback when the original note was never offered.
  [ "$mode" != new ] || jq 'del(.marker)' "$f.json" > "$d/meta"
  [ "$mode" != new ] || cp "$d/meta" "$f.json"
  : > "$d/calls"; : > "$d/cwd"
  UNSENT_MODE="$mode" run_unsent --post >/dev/null 2>&1; post_rc=$?
  assert_eq "$r" "$(sort -u "$d/cwd")" "$mode: every gh call runs in self root"
  case "$mode" in
    landed|new)
      assert_eq 0 "$post_rc" "$mode: recovery succeeds"
      assert_ok "test -f '$r/state/unsent/posted/$(basename "$f")'" "$mode: note archived"
      assert_ok "test -f '$r/state/unsent/posted/$(basename "$f").json'" "$mode: sidecar archived"
      assert_fail "test -f '$f'" "$mode: no remaining pending copy"
      count=0; [ "$mode" != new ] || count=1
      assert_eq "$count" "$(grep -c '^pr comment' "$d/calls" || true)" "$mode: lookup controls post"
      if [ "$mode" = new ]; then
        assert_eq "$(cat "$d/marker")" "$(tail -1 "$d/body")" 'recovery post ends with marker'
        assert_eq 'the original note' "$(cat "$r/state/unsent/posted/$(basename "$f")")" 'marker never changes kept bytes'
      fi ;;
    *)
      assert_eq 1 "$post_rc" "$mode: failure is reported"
      count=0; [ "$mode" != fails ] || count=1
      assert_eq "$count" "$(grep -c '^pr comment' "$d/calls" || true)" "$mode: failed lookup never posts"
      assert_ok "test -f '$f' && test -f '$f.json'" "$mode: failure retains both files"
      assert_eq 'the original note' "$(cat "$f")" "$mode: original unchanged"
      # Remove this fixture entry so the next case tests only its own note.
      mv "$f" "$f.json" "$d/"
      ;;
  esac
done
cat > "$r/config.yaml" <<'C'
default_project: self
projects:
  self:
    repo: .
    github: owner/self
    base: main
    required_check: ci
    projection: local
C
out="$(run_unsent --post 2>&1)"; rc=$?
assert_eq 64 "$rc" 'self local projection refuses recovery publication'
assert_ok "test -f '$r/state/unsent/SK-007-old.md'" 'local projection moves nothing'
# Selecting an external default must not accidentally recover engine notes.
sed '/    repo: ./d' "$r/config.yaml" > "$d/config"
cp "$d/config" "$r/config.yaml"
assert_eq '' "$(run_unsent)" 'external default lists no self notes'
run_unsent --post >/dev/null 2>&1; rc=$?
assert_eq 64 "$rc" 'external default refuses --post'
assert_ok "test -f '$r/state/unsent/SK-007-old.md'" 'external default moves nothing'
cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$d"; safe_rm_rf "$suite_tools"
finish
