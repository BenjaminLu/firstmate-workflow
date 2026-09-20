# The browser suite

Every test here runs against the real `board/server.ts` over a fixture root
built from an event log. Nothing calls a model or the network: the crew you
see aboard is whatever `state/events.jsonl` says, and the one thing allowed to
merge is stubbed with a recorder so the merge path can be asserted without a
pull request existing.

Two rules, both from the design:

- **Poses are classes, never screenshots.** A ship that breathes, bobs and
  occasionally jumps cannot be diffed as an image; `s-<state>` and
  `a-<action>` can. A snapshot test here would fail on the animation and pass
  on the wrong crew.
- **Three languages for reading, one for clicking.** The page is read in `en`,
  `zh-TW` and `zh-CN`, because a missing key or an unconverted term is a
  per-language defect. Interaction runs in `zh-TW` only: a button that works
  in one locale works in all three, and running the flow three times buys
  nothing but wall clock.

Run it through the gate, not directly:

```sh
bun install && bunx playwright install chromium
bin/ci.sh
```
