#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# T-221: fail-first runs Bash suites; the companion Playwright spec checks
# rendered geometry. These assertions pin the CSS that prevents tall pills.
python3 - "$ROOT/board/public/index.html" <<'PY'
import re
import sys
from pathlib import Path

html = Path(sys.argv[1]).read_text()
css = "\n".join(re.findall(r"<style\b[^>]*>(.*?)</style>", html, re.S))
css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)


def rule(selector):
    pattern = r"(?:^|[{}])\s*" + re.escape(selector) + r"\s*\{([^{}]*)\}"
    match = re.search(pattern, css)
    if match is None:
        return None
    return dict(
        (key.strip(), " ".join(value.split()))
        for declaration in match.group(1).split(";")
        if ":" in declaration
        for key, value in [declaration.split(":", 1)]
    )


header = rule(".card .hd") or {}
task_id = rule(".card .id") or {}
chip = rule(".card .hd .pchip")
checks = [
    ("card header centers children", header.get("align-items") == "center"),
    ("card header wraps children", header.get("flex-wrap") == "wrap"),
    ("card task id never wraps", task_id.get("white-space") == "nowrap"),
    ("card task id never shrinks", task_id.get("flex") == "0 0 auto"),
    ("card header has a scoped project chip rule", chip is not None),
    ("card project chip can truncate", (chip or {}).get("min-width") == "0"),
]
for name, passed in checks:
    print(f"    {name:<52} {'ok' if passed else 'FAIL'}")
sys.exit(0 if all(passed for _, passed in checks) else 1)
PY
