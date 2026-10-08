#!/usr/bin/env bash
# Feature dependencies: bin/fm-worker.sh tests/lib/worker.sh tests/lib/worker-rebuild.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/worker-rebuild.sh
. "$ROOT/tests/lib/worker-rebuild.sh"

sync_fixture() {
  d="$(fixture)" || exit 1; repo="$d/repo"; GH="$(ghstub "$d")"
  printf 'project:\n  check: true\n' >> "$repo/config.yaml"
  printf 'state/\n' > "$repo/.gitignore"
  git -C "$repo" add config.yaml .gitignore
  git -C "$repo" commit -qm contract; git -C "$repo" push -q origin main
  printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-03T00:00:00Z"}' > "$repo/state/events.jsonl"
  seed_spec_preflight "$repo" T-Z "" firstmate-workflow
  seed_self_pr_authoring "$repo" T-Z firstmate-workflow
  cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
cp "$2" "$FM_SEEN/prompt.md"
cp "$3/design/tasks/T-Z.json" "$FM_SEEN/seen-spec.json"
cd "$3" || exit 1
# shellcheck disable=SC1090
. "$FM_SEEN/step.sh"
M
  chmod +x "$repo/bin/adapters/mock.sh"
  printf 'mkdir -p src; printf "one\n" > src/feature\n' > "$d/step.sh"
}
sync_round() {
  local pr="${1:-}"
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" FM_MIRROR_INTERVAL=60 \
    bin/fm-worker.sh --task T-Z --project firstmate-workflow ${pr:+--pr "$pr"}) > "$d/out" 2>&1
  sync_rc=$?
  branch="$(rb_branch "$d")"
}
sync_seed() {
  sync_fixture
  sync_round
  assert_eq 0 "$sync_rc" 'setup: first pinned round publishes'
  assert_ok "test -s '$repo/state/pins/T-Z/1.json'" 'setup: pin v1 exists'
}
sync_repin() {
  mkdir -p "$repo/state/decisions"
  printf '%s\n' '{"id":"D-sync","project":"firstmate-workflow","task":"T-Z","chosen":"A","kind":"choice","ts":"2026-10-04T00:00:00Z"}' > "$repo/state/decisions/D-sync.json"
  printf '%s\n' '{"type":"decision_made","actor":"captain","task":"T-Z","ts":"2026-10-04T00:00:00Z","data":{"decision":"D-sync","chosen":"A"}}' >> "$repo/state/events.jsonl"
  jq '.scope += ["design/tasks/T-Z.json", "lib/**"]' "$repo/design/tasks/T-Z.json" > "$d/v2.json"
  # Deliberate extra trailing whitespace: canonical JSON comparisons and
  # command substitutions cannot prove this byte-preserving contract.
  printf '\n\n' >> "$d/v2.json"
  cp "$d/v2.json" "$repo/design/tasks/T-Z.json"
  seed_spec_preflight "$repo" T-Z "" firstmate-workflow
  seed_self_pr_authoring "$repo" T-Z firstmate-workflow
  "$ROOT/bin/fm-project.sh" repin --repo "$repo" --project firstmate-workflow --task T-Z --decision D-sync > "$d/repin.out" 2>&1
  assert_eq 0 "$?" 'setup: captain decision authorizes v2'
}
sync_bytes() {
  local version="$1" label="$2"
  jq -j .snapshots.spec.text < "$repo/state/pins/T-Z/$version.json" > "$d/expected"
  git --git-dir="$d/remote.git" show "$branch:design/tasks/T-Z.json" > "$d/published"
  assert_eq 0 "$?" "$label: published head contains task file"
  assert_ok "cmp -s '$d/expected' '$d/published'" "$label: published task equals exact pinned bytes"
}

# a: repin alone is published by the normal round, without a worker edit.
sync_seed
sync_repin
printf ':\n' > "$d/step.sh"
sync_round 42
assert_eq 0 "$sync_rc" 'a: repin alone completes'
sync_bytes 2 a
assert_ok "cmp -s '$d/expected' '$d/seen-spec.json'" 'a: adapter sees v2 before it runs'
assert_eq 'T-Z: a mock task' "$(git --git-dir="$d/remote.git" log -1 --format=%s "$branch")" 'a: normal round commit, not a checkpoint'
assert_contains "$(cat "$d/out")" 'follows pin v2' 'a: start reports sync'
assert_contains "$(cat "$d/prompt.md")" 'approved spec changed (pin v2)' 'a: prompt explains approved change'
head="$(rb_head "$d" "$branch")"
(cd "$repo" && . bin/fm-config.sh && fm_storage_init "$repo" firstmate-workflow && \
  fm_pin scope --task T-Z --head "$head" --base main) > "$d/scope.out" 2>&1
assert_eq 0 "$?" 'a: unchanged gate 3 accepts synced branch'
# d: already equal, an empty adapter leaves no commit or sync message.
sync_round 42
assert_eq 1 "$sync_rc" 'd: unchanged round remains no-work'
assert_eq "$head" "$(rb_head "$d" "$branch")" 'd: equal pin publishes nothing'
assert_lacks "$(cat "$d/out")" 'follows pin' 'd: equal pin is silent'
rm -rf "$d"

# a2: launcher writes must not stop vendor fallback.
sync_seed
cat > "$repo/bin/adapters/mock2.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
: > "$FM_SEEN/mock2-called"
exit 0
M
chmod +x "$repo/bin/adapters/mock2.sh"
printf 'vendor: mock\nfallback:\n  - mock\n  - mock2\nproject:\n  check: true\n' > "$repo/config.yaml"
git -C "$repo" add config.yaml bin/adapters/mock2.sh
git -C "$repo" commit -qm fallback; git -C "$repo" push -q origin main
sync_repin
printf 'exit 2\n' > "$d/step.sh"
sync_round 42
assert_eq 0 "$sync_rc" 'a2: fallback completes'
assert_ok "test -e '$d/mock2-called'" 'a2: second vendor is invoked'
sync_bytes 2 a2
rm -rf "$d"

# b: a non-rebuilt worker cannot rewrite its approved task entry.
sync_fixture
cat > "$d/step.sh" <<'S'
printf '{"id":"T-Z","scope":["**"]}\n' > design/tasks/T-Z.json
mkdir -p src; printf 'implemented\n' > src/feature
S
sync_round
assert_eq 0 "$sync_rc" 'b: task edit repaired without refusing worker code'
sync_bytes 1 b
assert_eq implemented "$(git --git-dir="$d/remote.git" show "$branch:src/feature")" 'b: implementation published'
assert_contains "$(cat "$d/out")" 'restored to pin v1' 'b: repair is explained'
rm -rf "$d"

# b2: force the first mirror generation (which precedes the sync) back.
# The adapter is synchronous; the foreground restore overlays surviving work.
sync_seed
sync_repin
cat > "$d/step.sh" <<'S'
tree="$PWD"
cd "$FM_SEEN" || exit 1
rm -rf "$tree"
mkdir -p "$tree/src"
printf 'after wreck\n' > "$tree/src/feature"
S
sync_round 42
assert_eq 0 "$sync_rc" 'b2: recovered round completes'
assert_contains "$(cat "$d/out")" 'destroyed its own tree' 'b2: mirror actually restored'
sync_bytes 2 b2
assert_contains "$(cat "$d/out")" 'restored to pin v2' 'b2: post-adapter repair replaces the old mirror bytes'
# rsync -au may keep either copy when their timestamps fall in the same second.
git --git-dir="$d/remote.git" cat-file -e "$branch:src/feature"
assert_eq 0 "$?" 'b2: surviving feature is published'
rm -rf "$d"

# e: a copied new task remains excluded, including its spec-only next round.
sync_fixture
git -C "$repo" rm -q --cached design/tasks/T-Z.json
git -C "$repo" commit -qm 'task not yet on main'; git -C "$repo" push -q origin main
seed_spec_preflight "$repo" T-Z "" firstmate-workflow
seed_self_pr_authoring "$repo" T-Z firstmate-workflow
printf ':\n' > "$d/step.sh"
sync_round
assert_eq 1 "$sync_rc" 'e: new task without worker changes is still no-work'
sync_bytes 1 e
assert_eq 1 "$(git --git-dir="$d/remote.git" rev-list --count "main..$branch")" 'e: exactly one checkpoint'
assert_eq 'T-Z: checkpoint (exit-1)' "$(git --git-dir="$d/remote.git" log -1 --format=%s "$branch")" 'e: existing checkpoint behavior'
head="$(rb_head "$d" "$branch")"
sync_round
assert_eq 1 "$sync_rc" 'e: spec-only next round remains no-work'
assert_eq "$head" "$(rb_head "$d" "$branch")" 'e: no second checkpoint'
assert_lacks "$(cat "$d/out")" 'follows pin' 'e: same bytes do not sync'
rm -rf "$d"

# f: early adapter exits cannot publish a launcher-only sync through EXIT.
sync_seed
sync_repin
head="$(rb_head "$d" "$branch")"
git --git-dir="$d/remote.git" show "$head:design/tasks/T-Z.json" > "$d/old-spec"
for early in unavailable transport model; do
  case "$early" in
    unavailable) printf 'exit 2\n' > "$d/step.sh"; expected_rc=2 ;;
    transport) printf 'exit 64\n' > "$d/step.sh"; expected_rc=70 ;;
    model)
      cat > "$d/step.sh" <<'S'
printf 'mock\tmissing-model\tmodel refused\n' > "$FM_MODEL_REFUSED"
exit 0
S
      expected_rc=65 ;;
  esac
  sync_round 42
  assert_eq "$expected_rc" "$sync_rc" "f/$early: expected early exit"
  if [ "$early" = unavailable ]; then
    assert_contains "$(cat "$d/out")" 'every vendor was unavailable' 'f: unavailable reason retained'
  fi
  assert_eq "$head" "$(rb_head "$d" "$branch")" "f/$early: no sync checkpoint pushed"
  assert_ok "cmp -s '$d/old-spec' '$repo/state/worktrees/T-Z/design/tasks/T-Z.json'" "f/$early: early exit puts HEAD bytes back"
done
rm -rf "$d"

# c/c2/c3: independently relocated pinned seeds leave default fixtures alone.
saved_seed="$rb_seed"
rb_seed="$(RB_PINNED=1 rb_build_fixture)" || exit 1
pinned_seed="$rb_seed"
for mode in clean edited failed_read; do
  d="$(rb_fixture)"; repo="$d/repo"; branch="$(rb_branch "$d")"
  rb_replay_conflict "$d"
  sync_repin
  head="$(rb_head "$d" "$branch")"; pushed="$(rb_pushed "$d")"
  printf ':\n' > "$d/step.sh"
  case "$mode" in
    edited) cat > "$d/step.sh" <<'S'
# A formatting-only edit must be held too, not compared as canonical JSON.
printf '\n' >> design/tasks/T-Z.json
S
      ;;
    failed_read)
      printf 'printf "ASK-PASS-CRITERIA:T-Z\\n" > .fm-say.md\n' > "$d/step.sh"
      mkdir -p "$d/jqwrap"
      real_jq="$(command -v jq)"
      cat > "$d/jqwrap/jq" <<W
#!/usr/bin/env bash
if [ "\$#" = 2 ] && [ "\$1" = -j ] && [ "\$2" = .snapshots.spec.text ]; then
  exit 1
fi
exec "$real_jq" "\$@"
W
      chmod +x "$d/jqwrap/jq"
      ;;
  esac
  if [ "$mode" = failed_read ]; then
    PATH="$d/jqwrap:$PATH" RB_PINNED=1 rb_round_two "$d" "$d/step.sh"
  else
    RB_PINNED=1 rb_round_two "$d" "$d/step.sh"
  fi
  rb_rebuilt "$d" "c/$mode"
  prompt="$(cat "$d/prompt.md")"
  assert_contains "$prompt" 'must come through exactly as pin v2 has it' "c/$mode: prompt freezes to pin"
  assert_lacks "$prompt" "is at $head; a rebuilt round" "c/$mode: no previous-head freeze"
  case "$mode" in
    clean)
      assert_eq 0 "$rb_rc" 'c: clean rebuilt repin publishes'
      sync_bytes 2 c
      assert_lacks "$rb_out" 'own entry is not as' 'c: pin does not trigger refusal'
      assert_eq "$(rb_head "$d" main)" "$(rb_head "$d" "$branch^")" 'c: published commit is on moved main'
      ;;
    edited)
      assert_eq 75 "$rb_rc" 'c2: pinned rebuilt edit holds round'
      assert_contains "$rb_out" 'not as pin v2 has it in: design/tasks/T-Z.json' 'c2: refusal names pin'
      assert_eq "$head" "$(rb_head "$d" "$branch")" 'c2: no publication'
      assert_eq "$pushed" "$(rb_pushed "$d")" 'c2: no push event'
      ;;
    failed_read)
      assert_eq 0 "$rb_rc" 'c3: asking round completes without publishing rebuild'
      assert_contains "$prompt" "The rebuild could not keep your task's own entry" 'c3: failed pin read is unresolved'
      assert_contains "$prompt" 'Put it back exactly as pin v2 has it (the approved spec at ' 'c3: repair prompt names pinned spec'
      assert_contains "$prompt" '/pinned/spec.json)' 'c3: repair prompt gives pinned path'
      assert_eq "$head" "$(rb_head "$d" "$branch")" 'c3: no publication'
      assert_eq "$pushed" "$(rb_pushed "$d")" 'c3: no push event'
      ;;
  esac
  rm -rf "$d"
done
rb_seed="$saved_seed"
rm -rf "$pinned_seed" "$rb_seed" "$rb_hook_seed"
cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
