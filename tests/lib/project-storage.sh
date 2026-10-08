# shellcheck shell=bash
# fm:sourced
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"

project_storage_fixture() {
  local dest="$1"
  config_modules_fixture "$dest"
  mkdir -p "$dest/lib"
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-herdr.py" "$dest/"
  cp "$ROOT/bin/lib/fm-task-grammar.sh" "$ROOT/bin/lib/fm_adopt.py" "$ROOT/bin/lib/fm_origin.py" "$ROOT/bin/lib/fm_concurrent.py" "$ROOT/bin/lib/fm_spec_pins.py" "$ROOT/bin/lib/fm_merge_outcome.py" "$ROOT/bin/lib/fm_project_paths.py" "$ROOT/bin/lib/fm-stack.sh" "$ROOT/bin/lib/fm-carry-base.sh" "$ROOT/bin/lib/fm_stack.py" "$ROOT/bin/lib/fm_conventions.py" "$dest/lib/"
  # Repeated storage setup must preserve an installed binding-service fixture.
  cp "$ROOT/bin/lib/fm_gates.json" "$dest/lib/"
  [ -f "$dest/lib/fm_binding.py" ] || cp "$ROOT/bin/lib/fm_binding.py" "$dest/lib/"
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
# Later notification controls deliberately enable their isolated Herdr stub.
export HERDR_ENV=0
  local root="$1" real_git
  real_git="$(command -v git)"
  mkdir -p "$root/fixture-tools"
  printf '#!/usr/bin/env bash\nREAL_GIT=%q\n' "$real_git" > "$root/fixture-tools/git"
  cat >> "$root/fixture-tools/git" <<'SH'
if [ "${1-}" = -C ] && [ "${3-}" = show ] && [[ "${4-}" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:design/tasks/*.json ]]; then
  task="${4##*/}"; task="${task%.json}"
  if [ -f "$2/.fixture-source.json" ]; then cat "$2/.fixture-source.json"
  else printf '{"id":"%s","scope":["src/**"],"acceptance":["The check passes."]}\n' "$task"; fi
  exit 0
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$root/fixture-tools/git"
  mv "$root/bin/fm-decide.sh" "$root/bin/fm-decide-real.sh"
  cat > "$root/bin/fm-decide.sh" <<'SH'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$root/fixture-tools:$PATH"
mode=''; kind=''; task=''; project="${FM_PROJECT:-}"; details=''
args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --request) mode=request; shift 2;;
    --task) task="$2"; shift 2;;
    --kind) kind="$2"; shift 2;;
    --project) project="$2"; shift 2;;
    --details) details="$2"; shift 2;;
    *) shift;;
  esac
done
if [ "$mode" = request ] && [ "$kind" = merge ] && [ -n "$details" ]; then
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
