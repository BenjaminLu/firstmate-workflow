#!/usr/bin/env bash
# Fixed capture hook: stdout is one readiness record; stdin EOF stops it.
set -euo pipefail
XDG_CONFIG_HOME="$(mktemp -d)"; export XDG_CONFIG_HOME
exec bun run tests/e2e/lib/capture-server.ts "$XDG_CONFIG_HOME"
