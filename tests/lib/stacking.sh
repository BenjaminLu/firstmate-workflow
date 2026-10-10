# shellcheck shell=bash
# fm:sourced
stacking_policy() {
  cat > "$1" <<POLICY
---
repository: "fixture/project"
base: "main"
land: card
review: fm
post: local
merge_method: squash
stacking: $2
delete_branch: false
force_with_lease: ${3:-false}
confirmed: true
policy_confirmed: true
required_checks: ["ci"]
captain: "fixture"
intent: "test stacking"
confirmed_at: "2026-10-03"
product: "fixture"
watch_seconds: 30
debounce_seconds: 1
reinspect_seconds: 60
---
POLICY
}
stacking_gh() {
  cat > "$1/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$1/ghcalls"
case "\$1 \$2" in
  'pr list')
    case " \$* " in
      *' --head '*) echo null ;;
      *) printf '[{"number":1,"headRefName":"$3","headRefOid":"$2","isCrossRepository":false,"baseRefName":"main"}]\\n' ;;
    esac ;;
  'pr create') echo https://github.com/fixture/project/pull/2 ;;
  *) echo "unexpected GitHub call: \$*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$1/gh"
}
# T-278: what the approved-scope reader needs where a dispatch can reach it.
# Committed config contract, design and task sources on main; the base
# ignores them, so assertions are unchanged.
stacking_scope_sources() { # dir
  grep -q '^project:' "$1/config.yaml" 2>/dev/null || printf 'project:\n  check: true\n' >> "$1/config.yaml"
  [ -f "$1/design/design.md" ] || printf '# design\n' > "$1/design/design.md"
  [ -d "$1/.git" ] || git -C "$1" init -q -b main
  git -C "$1" add config.yaml design
  git -C "$1" -c user.email=a@b.c -c user.name=t commit -qm 'approved sources' >/dev/null
}
# A captain greenlight naming each task file, the approval the reader accepts.
stacking_scope_approvals() { # dir
  local file id
  mkdir -p "$1/state"
  for file in "$1"/design/tasks/*.json; do
    id="$(jq -r '.id // empty' "$file" 2>/dev/null)" || continue
    [ -n "$id" ] || continue
    jq -cn --arg task "$id" '{ts:"2026-10-03T00:00:00Z",actor:"captain",type:"greenlit",task:$task}' \
      >> "$1/state/events.jsonl"
  done
}
