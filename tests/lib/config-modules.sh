# shellcheck shell=bash
# fm:sourced
# Minimal Python dependencies of copied fm-config.sh / ci.sh entrypoints,
# declared in tests/lib/fixture-modules.json with what they import (T-279).
config_modules_fixture() {
  local dest="$1"
  mkdir -p "$dest/lib"
  python3 "$ROOT/tests/lib/fixture_modules.py" copy config "$dest"
}
