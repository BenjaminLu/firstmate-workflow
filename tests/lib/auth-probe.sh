# shellcheck shell=bash
# A test-only confinement stand-in. Logs contain argv/profile, never env.
auth_probe_sandbox_tool() {  # <tool path> <fixture directory>
  local tool="$1" fixture_dir="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$@" >> %q\n' "$fixture_dir/sandbox-argv"
    printf '[ "$1" = -p ] || exit 64\n'
    printf 'printf "%%s\\n" "$2" > %q\n' "$fixture_dir/profile"
    printf 'shift 2; exec "$@"\n'
  } > "$tool"
  chmod +x "$tool"
}
