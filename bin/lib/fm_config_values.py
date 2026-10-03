"""Config values helpers extracted from fm-config.sh."""

import sys


def set_value():
    import re, sys
    path, value, f = sys.argv[1].split("."), sys.argv[2], sys.argv[3]
    try:
        with open(f) as fh:
            lines = fh.readlines()
    except FileNotFoundError:
        lines = []
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"

    def indent(s):
        return len(s) - len(s.lstrip(" "))

    def blank(s):
        return s.strip() == "" or s.lstrip().startswith("#")

    start, end, ind = 0, len(lines), 0
    for depth, name in enumerate(path):
        last = depth == len(path) - 1
        found = None
        for j in range(start, end):
            if blank(lines[j]) or indent(lines[j]) != ind:
                continue
            m = re.match(r"^ *([A-Za-z0-9_.-]+):", lines[j])
            if m and m.group(1) == name:
                found = j
                break
        if found is None:
            at = start
            for j in range(start, end):
                if not blank(lines[j]):
                    at = j + 1
            if start == 0 and depth == 0:
                at = len(lines)
            lines.insert(at, " " * ind + name + (": " + value if last else ":") + "\n")
            found, end = at, end + 1
        elif last:
            # only the value changes: the key's own spacing and trailing
            # comment stay, and a value that is already this one is not touched
            m = re.match(r"^( *[A-Za-z0-9_.-]+:[ \t]*)(.*?)([ \t]+#.*)?$", lines[found].rstrip("\n"))
            if m.group(2) != value:
                lines[found] = m.group(1) + value + (m.group(3) or "") + "\n"
        if last:
            break
        start, end, ind = found + 1, found + 1, ind + 2
        while end < len(lines) and (blank(lines[end]) or indent(lines[end]) >= ind):
            end += 1
    with open(f, "w") as fh:
        fh.writelines(lines)


def main():
    command = sys.argv.pop(1)
    commands = {
        'set-value': set_value,
    }
    commands[command]()


if __name__ == "__main__":
    main()
