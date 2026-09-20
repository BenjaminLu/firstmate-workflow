# Authored drawings

`bin/fm-diagram.sh` renders a card for every decision the captain must rule
on: the id, the task, the pull request, where the task sits in the lanes, and
the answers on offer. That frame it can always build from the decision file
and `i18n/`.

What it cannot invent is the picture in the middle — the before and after of
a schema change, the two shapes a module could take. Q8 says **reuse existing
diagrams first**, and this directory is where they live.

## Lookup

For a decision `D-007` on task `T-004`, rendering language `<lang>`, the
first of these that exists is used as the body of the card:

| | |
|---|---|
| `D-007.<lang>.html` | drawn for this decision, in this language |
| `D-007.html`        | drawn for this decision, no words in it |
| `T-004.<lang>.html` | drawn for the task, in this language |
| `T-004.html`        | drawn for the task, no words in it |

Nothing matching means the built-in body: the seven gates for a `merge`, and
for a `choice` the frame alone.

## What a file holds

A fragment, not a document — no `<html>`, no `<body>`. Inline SVG is the
usual thing. It is pasted into the card as it stands, so it carries its own
sizing.

## Languages

Write `en` and `zh-TW`. **Never write a `zh-CN` file**: `zh-CN` is the zh-TW
page with its text nodes put through `i18n/tw2cn.tsv`, the same rule the rest
of the board follows, and a third hand-written file is a third thing to keep
in step. A drawing with no words in it needs no language suffix at all and
serves all three.
