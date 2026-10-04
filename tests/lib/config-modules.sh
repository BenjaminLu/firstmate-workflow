# shellcheck shell=bash
# fm:sourced
# Minimal Python dependencies of copied fm-config.sh / ci.sh entrypoints.
config_modules_fixture() {
  local dest="$1"
  mkdir -p "$dest/lib"
  cp "$ROOT/bin/lib/fm_registry.py" "$ROOT/bin/lib/fm_config_values.py" \
     "$ROOT/bin/lib/fm_config_tasks.py" "$ROOT/bin/lib/fm_config_runtime.py" \
     "$ROOT/bin/lib/fm_ci_checks.py" "$dest/lib/"
}
