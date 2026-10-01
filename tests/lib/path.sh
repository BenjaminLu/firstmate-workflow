# shellcheck shell=bash
# Preserve the host toolchain except the commands a case must lack.
# Arguments: empty destination directory, space-separated omitted names.
# Stubs go in a separate prefix. Keep PATH order, but skip broken Python
# candidates (notably macOS's Xcode shim) in favour of a working interpreter.
fixture_path() {
  [ "$#" = 2 ] || { echo 'fixture_path: expected destination and exclusions' >&2; return 1; }
  local dest="$1" omitted="$2" name tool dir rest more
  mkdir -p "$dest" || return 1
  dest="$(cd "$1" && pwd)" || return 1
  rest="$PATH"
  while :; do
    more=0
    case "$rest" in *:*) dir="${rest%%:*}"; rest="${rest#*:}"; more=1 ;; *) dir="$rest" ;; esac
    dir="$(cd "${dir:-.}" 2>/dev/null && pwd)" || dir=''
    if [ -n "$dir" ] && [ "$dir" != "$dest" ]; then
      for tool in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [ -f "$tool" ] && [ -x "$tool" ] || continue
        name="${tool##*/}"
        case " $omitted " in *" $name "*) continue ;; esac
        [ ! -e "$dest/$name" ] && [ ! -L "$dest/$name" ] || continue
        if [ "$name" = python3 ]; then
          "$tool" -c 'import sys; sys.exit(sys.version_info.major != 3)' >/dev/null 2>&1 || continue
        fi
        ln -s "$tool" "$dest/$name" || return 1
      done
    fi
    [ "$more" = 1 ] || break
  done
  for name in $omitted; do
    if PATH="$dest" command -v "$name" >/dev/null 2>&1; then
      echo "fixture_path: omitted tool is reachable: $name" >&2; return 1
    fi
  done
  case " $omitted " in *' python3 '*) return 0 ;; esac
  if ! PATH="$dest" python3 -c 'import sys; sys.exit(sys.version_info.major != 3)' >/dev/null 2>&1; then
    echo 'fixture_path: no working python3 on the constructed PATH' >&2
    return 1
  fi
}
