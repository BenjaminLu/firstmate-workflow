# shellcheck shell=bash
# Construct a closed PATH from the caller's toolchain, never /usr/bin's
# implicit contents. Arguments: destination, space-separated omitted names,
# then exactly the commands the fixture needs. Stubs go in a separate prefix.
fixture_path() {
  local dest="$1" omitted="$2" name tool
  shift 2
  mkdir -p "$dest" || return 1
  for name in "$@"; do
    case " $omitted " in *" $name "*) continue ;; esac
    tool="$(command -v "$name")" || {
      echo "fixture_path: required tool unavailable: $name" >&2; return 1;
    }
    case "$tool" in /*) ;; *) echo "fixture_path: $name is not an executable path" >&2; return 1 ;; esac
    ln -s "$tool" "$dest/$name" || return 1
  done
  for name in $omitted; do
    if PATH="$dest" command -v "$name" >/dev/null 2>&1; then
      echo "fixture_path: omitted tool is reachable: $name" >&2; return 1
    fi
  done
}
