#!/usr/bin/env bash
# Fixed capture hook: stdout is one readiness record; stdin EOF stops it.
set -euo pipefail
exec bun run tests/e2e/lib/capture-server.ts
