# Security policy

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting:
open the repository's **Security** tab and choose **Report a vulnerability**
([direct link](https://github.com/BenjaminLu/firstmate-workflow/security/advisories/new)).
Please do not open a public issue, pull request or discussion for it.

Include what an attacker can do, the script or file involved, the commit you
tested against and the steps to reproduce. The report reaches the maintainer,
Benjamin Lu, who will reply in the advisory.

## Scope

In scope is the code this repository ships and runs:

- `bin/` — the firstmate scripts (`fm-*.sh`, `ci.sh` and their helpers)
- `bin/adapters/` — the vendor adapters and their shared library
- `board/` — the captain's board server and its pages
- `.githooks/` — the git hooks installed by `bin/fm-install-hooks.sh`

For example: a way to make a script write to `main`, run `git` or `gh` from an
adapter, read or open a file outside the repository through the board, or
reach the board from anything but `127.0.0.1`. `design/design.md` section 13
states what these components promise.

Out of scope are the third-party agent CLIs the adapters call, GitHub itself,
and the design documents and task list, which are plans rather than code.

## No bounty

This is a personal open-source project. There is no bug bounty and no paid
reward for reports.
