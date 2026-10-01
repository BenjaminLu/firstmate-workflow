# shellcheck shell=bash
# Caller/consumer globals are checked when linting the feature suites.
# shellcheck disable=SC2154
# --- one policy, every vendor (T-105) ----------------------------------------
# Each vendor's flags enforce what they can of the policy and the OS sandbox
# the rest; a dimension neither covers refuses the round with 2 - the
# fallback chain's "try the next one" - before the CLI starts, so no round
# runs less confined than its policy.
pv="$(safe_tmpdir)"; mkdir -p "$pv/fakebin" "$pv/tree"
echo "do it" > "$pv/prompt"
# The loopback listeners are netstat's, answered the way macOS's does, so the
# profile's loopback rules are the stand-in's and not the machine's
cat > "$pv/fakebin/netstat" <<'S'
#!/bin/sh
printf 'Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)\n'
printf 'tcp4       0      0  127.0.0.1.5555         *.*                    LISTEN\n'
S
chmod +x "$pv/fakebin/netstat"
confined() {   # confined <os> <tool> <policy> <vendor> -> its exit code; argv in $pv/argv, env in $pv/env
  printf '#!/usr/bin/env bash\ncat > /dev/null\nprintf "%%s\\n" "$@" > "%s/argv"\nenv > "%s/env"\nprintf "ran\\n"\nexit 0\n' \
    "$pv" "$pv" > "$pv/fakebin/$4"
  chmod +x "$pv/fakebin/$4"
  rm -f "$pv/argv" "$pv/env" "$pk/profile.sb" "$pk/bwrap.args"
  FM_SANDBOX_OS="$1" FM_SANDBOX_TOOL="$2" FM_POLICY="$3" PATH="$pv/fakebin:$closed_path" \
    "$ROOT/bin/adapters/$4.sh" run "$pv/prompt" "$pv/tree" "$pv/log" >/dev/null 2>"$pv/err"
  echo $?
}
settings_of() { awk 'on{print;exit} $0=="--settings"{on=1}' "$pv/argv"; }
