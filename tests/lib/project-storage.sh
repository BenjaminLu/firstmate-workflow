# shellcheck shell=bash
# fm:sourced
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"

# The set, and every bin/lib module it imports, is declared in
# tests/lib/fixture-modules.json. Repeated storage setup must preserve an
# installed binding-service fixture: fm_binding.py is in its keep_existing list.
project_storage_fixture() {
  local dest="$1"
  mkdir -p "$dest/lib"
  python3 "$ROOT/tests/lib/fixture_modules.py" copy project-storage "$dest"
}

project_fixture_config() {
  local engine="$1" fixture_home
  if [ -f "$engine/.fixture-fm-home" ]; then fixture_home="$(cat "$engine/.fixture-fm-home")"
  else fixture_home="$(safe_tmpdir)"; printf '%s\n' "$fixture_home" > "$engine/.fixture-fm-home"; fi
  { printf 'home: %s\n' "$fixture_home"; cat "$engine/config.yaml"; } > "$engine/.fixture-config"
  mv "$engine/.fixture-config" "$engine/config.yaml"
}
project_fixture_state() {
  local engine="$1" name="$2" state
  state="$(bash -c '. "$1/bin/fm-config.sh"; fm_project_get "$3" state "$2/config.yaml"' _ "$ROOT" "$engine" "$name")" || return
  mkdir -p "$state/pending" "$state/decisions" "$state/merging" "$state/runtime/archived-pending"
  printf '%s' "$state"
}

# Opt-in for producer suites whose evidence service uses a synthetic SHA.
# Legacy/default module inventories are unchanged. Enriched committed-source
# tests use their own real repository instead of this synthetic git boundary.
merge_source_fixture() {
  # Disable inherited notifications only for explicit fixture preparation.
  # Notification controls use the unwrapped producer with their own stub.
  export HERDR_ENV=0
  local root="$1" real_git
  real_git="$(command -v git)"
  mkdir -p "$root/fixture-tools"
  printf '#!/usr/bin/env bash\nexport HERDR_ENV=0\nREAL_GIT=%q\nFIXTURE_ROOT=%q\n' "$real_git" "$root" > "$root/fixture-tools/git"
  cat >> "$root/fixture-tools/git" <<'SH'
printf '%s\0' "$@" >> "$FIXTURE_ROOT/.fixture-git-argv"
if [ "$#" = 4 ] && [ "${1-}" = -C ] && [ "${2-}" = "$FIXTURE_ROOT" ] && [ "${3-}" = show ] &&
   [[ "${4-}" =~ ^aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:design/tasks/((T|SK)-[0123456789]{3,})\.json$ ]]; then
  task="${BASH_REMATCH[1]}"
  if [ -f "$FIXTURE_ROOT/.fixture-source.json" ]; then cat "$FIXTURE_ROOT/.fixture-source.json"
  else printf '{"id":"%s","scope":["src/**"],"acceptance":["The check passes."]}\n' "$task"; fi
  exit 0
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$root/fixture-tools/git"
  mv "$root/bin/fm-decide.sh" "$root/bin/fm-decide-real.sh"
  cat > "$root/bin/fm-decide.sh" <<'SH'
#!/usr/bin/env bash
export HERDR_ENV=0
root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$root/fixture-tools:$PATH"
mode=''; kind=''; task=''; project="${FM_PROJECT:-}"; details=''
args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --request|--task|--kind|--project|--details) [ "$#" -ge 2 ] || break;;
  esac
  case "$1" in
    --request) mode=request; shift 2;;
    --task) task="$2"; shift 2;;
    --kind) kind="$2"; shift 2;;
    --project) project="$2"; shift 2;;
    --details) details="$2"; shift 2;;
    *) shift;;
  esac
done
if [ "$mode" = request ] && [ "$kind" = merge ] && [ -n "$project" ] &&
   [[ "$task" =~ ^(T|SK)-[0123456789]{3,}$ ]]; then
  . "$root/bin/fm-config.sh"
  fm_storage_init "$root" "$project" || exit 65
  if [ "$FM_EXTERNAL" = 1 ] && [ ! -f "$FM_TASKS_DIR/$task.json" ]; then
    mkdir -p "$FM_TASKS_DIR"
    if [ -f "$root/.fixture-source.json" ]; then cp "$root/.fixture-source.json" "$FM_TASKS_DIR/$task.json"
    else printf '{"id":"%s","scope":["src/**"],"acceptance":["The check passes."]}\n' "$task" > "$FM_TASKS_DIR/$task.json"; fi
  fi
fi
exec bash "$root/bin/fm-decide-real.sh" "${args[@]}"
SH
  chmod +x "$root/bin/fm-decide.sh"
}
