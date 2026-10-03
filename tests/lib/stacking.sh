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
      *) printf '[{"number":1,"headRefName":"$3","headRefOid":"$2","isCrossRepository":false}]\\n' ;;
    esac ;;
  'pr create') echo https://github.com/fixture/project/pull/2 ;;
  *) echo "unexpected GitHub call: \$*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$1/gh"
}
