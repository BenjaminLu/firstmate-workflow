# shellcheck shell=bash
# Caller/consumer globals are checked when linting the feature suites.
# shellcheck disable=SC2034,SC2154
pol worker 'vendor: mock
policy:
  network: registry.npmjs.org
'
P="$t/worker.json"
mkdir -p "$t/bin"
# the stand-ins: each records what it was handed and runs the command
# Builtins only, no fork: it runs under the round's process limit, which a
# test below sets below what the user already runs
cat > "$t/bin/sandbox-exec" <<S
#!/usr/bin/env bash
[ "\$1" = -f ] || exit 99
# It applies no profile, so it answers fm-sandbox's loopback check before the
# round the way a profile that holds does: run behind it, the check would
# bind and connect on the machine running the suite, the board's port
# included (T-153). What the check does is the loopback cases' own stand-in.
case " \$* " in *" fm-loopback-check "*) echo checked; exit 0 ;; esac
printf '%s\n' "\$2" > "$t/profile.path"
while IFS= read -r l; do printf '%s\n' "\$l"; done < "\$2" > "$t/profile.sb"
shift 2
exec "\$@"
S
cat > "$t/bin/bwrap" <<S
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$t/bwrap.args"
while [ \$# -gt 0 ] && [ "\$1" != -- ]; do shift; done
shift
exec "\$@"
S
chmod +x "$t/bin/sandbox-exec" "$t/bin/bwrap"
mac() { FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$t/bin/sandbox-exec" "$SB" "$@"; }
lin() { FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$t/bin/bwrap" "$SB" "$@"; }
root="$t/tree"; mkdir -p "$root/.claude" "$t/round-a" "$t/round-b"
cat > "$t/probe.py" <<'PY'
import os, socket, sys
out = open(sys.argv[1], 'w')
out.write('stdin=%s\n' % sys.stdin.read().strip())
for name in ('GH_TOKEN', 'GITHUB_TOKEN', 'SSH_AUTH_SOCK', 'AWS_SECRET_ACCESS_KEY', 'HERDR_SOCKET', 'KEEP_ME',
             'FM_CREW_UNSANDBOXED', 'FM_ROUND_UNSANDBOXED', 'FM_IN_ROUND'):
    out.write('%s=%s\n' % (name, os.environ.get(name, '')))
proxy = os.environ.get('HTTPS_PROXY', '')
out.write('proxy=%s\n' % ('set' if proxy else ''))
host, port = proxy.rsplit('/', 1)[-1].split(':')
for target in ('undeclared.example.org:443', 'github.com:443', 'undeclared.example.org:443'):
    s = socket.create_connection((host, int(port)))
    s.sendall(('CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n' % (target, target)).encode())
    out.write('%s %s\n' % (target, s.recv(64).split(b'\r\n')[0].decode()))
    s.close()
PY
cat > "$t/cmd.sh" <<S
#!/usr/bin/env bash
printf 'TMPDIR=%s\nNO_PROXY=%s\nHOME=%s\nXDG_CACHE_HOME=%s\nXDG_CONFIG_HOME=%s\nXDG_DATA_HOME=%s\n' \
  "\$TMPDIR" "\${NO_PROXY:-}" "\$HOME" "\${XDG_CACHE_HOME:-}" "\${XDG_CONFIG_HOME:-}" "\${XDG_DATA_HOME:-}" > "$t/tmpdir"
# T-147: a shell's own temp files, and the PATH a login shell ends with
# once the system's profile has put its own directories first
printf 'TMPPREFIX=%s\nZDOTDIR=%s\nPATH=%s\n' "\${TMPPREFIX:-}" "\${ZDOTDIR:-}" "\$PATH" >> "$t/tmpdir"
for rc in .zprofile .bash_profile .profile; do
  printf 'LOGIN %s=%s\n' "\$rc" "\$(PATH="$suite_tools"; [ -r "\${ZDOTDIR:-\$HOME}/\$rc" ] && . "\${ZDOTDIR:-\$HOME}/\$rc"; printf '%s' "\$PATH")" >> "$t/tmpdir"
done
python3 "$t/probe.py" "$t/ran"
exit 7
S
chmod +x "$t/cmd.sh"
# The process count is ps's, and the suite does not ask the machine running
# it for one: a reviewer's own sandbox may refuse ps. A stand-in answers.
mkdir -p "$t/psbin"
printf '#!/bin/sh\nprintf "1\\n2\\n3\\n"\n' > "$t/psbin/ps"
# and the listeners are netstat's, answered the way macOS's netstat does
cat > "$t/psbin/netstat" <<'S'
#!/bin/sh
printf 'Active Internet connections (including servers)\n'
printf 'Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)\n'
printf 'tcp4       0      0  127.0.0.1.5555         *.*                    LISTEN\n'
printf 'tcp4       0      0  10.0.0.2.52000         1.2.3.4.443            ESTABLISHED\n'
S
chmod +x "$t/psbin/ps" "$t/psbin/netstat"
# room to fork: the stand-in's count is 3, far below what the user runs
: > "$t/blocked"; rm -f "$t/ran" "$t/profile.sb" "$t/profile.path" "$t/started"
mkdir -p "$t/ctl"
