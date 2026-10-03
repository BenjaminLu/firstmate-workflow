# shellcheck shell=bash
# fm:sourced
# Local git transport plus real GitHub JSON shapes, without network access.
head_binding_fixture() { # root branch [check conclusion] [PR base]
  local d="$1" branch="$2" conclusion="${3:-success}" base="${4:-main}"
  git -C "$d" remote remove origin 2>/dev/null || true
  git -C "$d" remote add origin https://github.com/fixture/project.git
  git -C "$d" config url."$d".insteadOf https://github.com/fixture/project.git
  git -C "$d" update-ref refs/pull/9/head "$branch"
  mkdir -p "$d/stub"
  cat > "$d/stub/head-gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  'pr comment') exit 0 ;;
  'repo view') echo fixture/project ;;
  'pr view') printf '{"state":"OPEN","headRefOid":"%s","baseRefName":"$base","baseRefOid":"%s","headRefName":"$branch"}\n' "\$(git -C "$d" rev-parse refs/pull/9/head)" "\$(git -C "$d" rev-parse "$base")" ;;
  'api repos/fixture/project/branches/$base/protection/required_status_checks') echo '{"contexts":["ci"],"checks":[]}' ;;
  *) case "\$2" in
    */check-runs*) printf '{"check_runs":[{"id":1,"name":"ci","head_sha":"%s","status":"completed","conclusion":"$conclusion"}]}\n' "\$(git -C "$d" rev-parse refs/pull/9/head)" ;;
    */status*) printf '{"sha":"%s","statuses":[]}\n' "\$(git -C "$d" rev-parse refs/pull/9/head)" ;;
    *) exit 1 ;;
  esac ;;
esac
STUB
  chmod +x "$d/stub/head-gh"
}
