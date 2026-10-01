#!/usr/bin/env python3
"""Static split preservation audit; runs no suite, browser or production script.

The manifest binds the eight original suites to a Git revision and lists each
replacement plus its shared helpers exactly once. Counts are source call sites,
not runtime loop iterations. Besides counting assertions/test declarations, the
audit requires every original non-comment source line to survive (multiplicity
included). Thus assertion arguments and names cannot disappear behind equal
counts. Only explicit, reviewed scaffolding removals are exempted.
"""
import collections
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "tests/lib/split-manifest.json"


def code_lines(text):
    lines = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(("#", "//")):
            continue
        # Moving exported TS helpers and making old allocations safe does not
        # change assertion names or arguments. No general string rewriting.
        line = re.sub(r"^export (?=(?:const|function) )", "", line)
        line = line.replace("$(mktemp -d)", "$(safe_tmpdir)")
        lines.append(line)
    return collections.Counter(lines)


def inventory(text):
    code = "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith(("#", "//")))
    return {
        "assert_*": len(re.findall(r"(?:^|[;&|])\s*assert_\w+\s", code, re.M)),
        "Playwright": len(re.findall(r"^\s*test\(", code, re.M)),
        "Python assertions": len(re.findall(r"\bself\.assert\w+\(", code)),
        "Python tests": len(re.findall(r"^\s*def test_\w+\(", code, re.M)),
    }


def audit():
    manifest = json.loads(MANIFEST.read_text())
    print(f"Baseline: `{manifest['base']}`. Static inspection only; no suites executed.\n")
    print("| Original suite | assert_* before/after | Playwright before/after | Python assertions before/after | Python tests before/after | Original test source and names |")
    print("|---|---:|---:|---:|---:|---|")
    failed = False
    for old, entry in manifest["suites"].items():
        before = subprocess.check_output(
            ["git", "show", f"{manifest['base']}:{old}"], cwd=ROOT, text=True)
        assert len(entry["files"]) == len(set(entry["files"])), old
        after = "\n".join((ROOT / f).read_text() for f in entry["files"])
        left, right = inventory(before), inventory(after)
        retained = code_lines(after)
        for removal in entry.get("scaffolding", []):
            # Exemptions cannot contain tests, assertions, or their messages.
            assert removal["reason"] and not re.search(
                r"assert_|self\.assert|test\(|def test_", removal["line"])
            retained[removal["line"]] += removal["count"]
        missing = code_lines(before) - retained
        good = left == right and not missing
        failed |= not good
        counts = " | ".join(f"{left[k]}/{right[k]}" for k in left)
        print(f"| {old} | {counts} | {'preserved' if good else 'FAIL'} |")
        if missing:
            for line, count in missing.items():
                print(f"Missing {count} × {line!r}", file=sys.stderr)
    oversized = []
    files = [p for p in (ROOT / "tests").rglob("*") if p.is_file()]
    for path in files:
        count = len(path.read_bytes().splitlines())
        if count > 1200:
            oversized.append(f"{path.relative_to(ROOT)}: {count}")
    print(f"\n1200-line cap: {len(files)} files inspected; {len(oversized)} oversized.")
    if oversized:
        print("\n".join(oversized), file=sys.stderr)
    print("\nCounts are static call sites, including embedded fixture source; parameterized tests remain parameterized. All original non-comment source lines, including full assertion arguments and test names, must be retained with multiplicity. Manifest exemptions name only replaced setup, cleanup, class declarations and runner scaffolding. New regression tests are counted separately from the moved suites. This does not establish runtime equivalence or model compliance.")
    return int(failed or bool(oversized))


if __name__ == "__main__":
    raise SystemExit(audit())
