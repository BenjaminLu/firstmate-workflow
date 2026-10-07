# shellcheck shell=bash
# fm:sourced
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"

project_storage_fixture() {
  local dest="$1"
  config_modules_fixture "$dest"
  mkdir -p "$dest/lib"
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-herdr.py" "$dest/"
  cp "$ROOT/bin/lib/fm_adopt.py" "$ROOT/bin/lib/fm_origin.py" "$ROOT/bin/lib/fm_concurrent.py" "$ROOT/bin/lib/fm_spec_pins.py" "$ROOT/bin/lib/fm_merge_outcome.py" "$ROOT/bin/lib/fm_project_paths.py" "$ROOT/bin/lib/fm-stack.sh" "$ROOT/bin/lib/fm_stack.py" "$ROOT/bin/lib/fm_conventions.py" "$dest/lib/"
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
