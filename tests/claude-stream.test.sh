#!/usr/bin/env bash
# T-287: a claude round shows each step while it runs, through its streaming
# output, and keeps its final result exactly as before. The cases live in
# tests/lib/claude_stream.py; the claude CLI is tests/lib/claude_stream_stub.py.
# Shared fixtures: tests/lib/adapter.sh tests/lib/claude_stream.py
# tests/lib/claude_stream_stub.py
set -uo pipefail
cases="${FM_TEST_CASES:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/adapter.sh
. "$ROOT/tests/lib/adapter.sh"
# the adapter suites' OS sandbox stand-in and policy, on the Linux path
export FM_SANDBOX_OS=linux FM_SANDBOX_TOOL="$pk/bwrap" FM_TEST_CLOSED_PATH="$closed_path"
FM_TEST_CASES="$cases" python3 "$ROOT/tests/lib/claude_stream.py" "$ROOT"
