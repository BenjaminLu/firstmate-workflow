# Authored drawings

`bin/fm-diagram.sh` renders a card for every decision the captain must rule
on: the id, the task, the pull request, where the task sits in the lanes, and
the answers on offer. That frame it can always build from the decision file
and `i18n/`.

What it cannot invent is the picture in the middle — the before and after of
a schema change, the two shapes a module could take. Q8 says **reuse existing
diagrams first**, and this directory is where they live.

## Lookup

The drawing is chosen **once for the decision**, not once per language.

For a decision `D-007` on task `T-004`, the files in this directory whose
stem is `D-007` are one tier and the files whose stem is `T-004` are the
next. The first tier with anything at all in it is the tier that is used:

| tier | files |
|---|---|
| the decision | `D-007.en.html`, `D-007.zh-TW.html`, `D-007.html` |
| the task     | `T-004.en.html`, `T-004.zh-TW.html`, `T-004.html` |

Within the tier, `<stem>.<lang>.html` serves that language and `<stem>.html`
serves any language it does not. A tier with nothing in it at all means the
built-in body: the seven gates for a `merge`, and for a `choice` the frame
alone.

## A tier answers every language, or it is refused

Once a tier is chosen it has to answer **both** `en` and `zh-TW` — with a
file of its own for each, or with one wordless `<stem>.html` that serves
them both. One that does not is **refused, exit 65**, and nothing is
written.

Refused rather than fallen back from, and refused rather than served:

- `D-007.en.html` on its own would have given the English reader a hand
  drawing and both Chinese readers the built-in frame, with exit 0 and no
  warning anywhere. That is one decision looking like two different
  decisions depending on who opens the board.
- `D-007.en.html` beside `T-004.zh-TW.html` is worse, because no file is
  missing: English gets the decision's picture and zh-TW gets the task's.
  A per-language existence check passes it. Deciding the tier first is what
  catches it.

A half-drawn decision does not quietly fall through to the task's drawing
either. If `D-007` has any file at all, `D-007` is the tier.

## What a file holds

A fragment, not a document — no `<html>`, no `<body>`. Inline SVG is the
usual thing. It is pasted into the card as it stands, so it carries its own
sizing.

## Languages

Write `en` and `zh-TW`. **Never write a `zh-CN` file**: `zh-CN` is the zh-TW
page with its text nodes put through `i18n/tw2cn.tsv`, the same rule the rest
of the board follows, and a third hand-written file is a third thing to keep
in step. A `zh-CN` file therefore answers no language at all, so a tier
holding only one is refused like any other tier that cannot answer `en` and
`zh-TW`.

A drawing with no words in it needs no language suffix and serves all three.

## When it is drawn

`bin/fm-decide.sh --request` runs the generator, so the file is on disk
before the card that embeds it reaches the board. Nothing else has to be
run by hand; `bin/fm-diagram.sh --decision D-007` redraws one if you are
editing a fragment.
