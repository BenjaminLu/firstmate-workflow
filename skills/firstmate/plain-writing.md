# Plain writing

These rules cover all text that firstmate or a crew member writes for a person
to read: specs, captain cards, pull-request titles and bodies, commit messages,
and every comment or status posted to GitHub. A person and an AI agent should
both be able to read the text without decoding it. This file is the only place
that defines the rules. The skills for firstmate, the reviewer and the worker
point here and do not copy it.

## Who reads it

Write for a backend engineer with three to five years of experience. This
reader knows git and CI. This reader has never seen this repository, its task
numbers, its decision ids or its private words. Write each sentence so that
this reader can act on it without opening another file.

The captain reads every card and approves every spec. If the captain has to
decode a sentence first, the approval is a guess.

## What comes first

Keep every fact, number, condition, scope and level of certainty. Improve the
wording only after that. A shorter sentence that drops a condition is wrong. A
clear sentence that turns "may" into "does" is wrong. When a clear rewrite
cannot keep the meaning, leave the sentence and report the problem.

Do not add a fact, name, number, date, path or claim that the source does not
contain. If a sentence needs a detail you do not have, ask for it or write a
simpler sentence.

## Our own rules

1. Explain a term of art in one plain sentence the first time it appears. The
   shared terms and their explanations are in `i18n/glossary.json`. A card
   lists the ids of the terms it uses in its `glossary` list, and the board
   shows each explanation under the card.
2. Never make an internal code the subject of a sentence. A task number, a
   decision id or a commit hash means nothing to the reader. Say what the thing
   is, then put the code in parentheses: "the change that added merge cards
   (T-242)", not "T-242 added merge cards".
3. Keep a number apart from the word next to it. Write "round 3", "10 MB" and
   "PR #12", never "round3" or "10MB". A commit hash glued to a word ("Main87df")
   hides both the word and the hash.
4. Give each acceptance line one requirement. Split a line that says "and"
   between two things a reviewer would check separately.
5. Name a code path by what it does, not by an internal label. "The check that
   skips cards that are not merge cards" says more than "nonmerge exclusion".
6. Do not chain words with slashes ("kind/purpose/chosen"). Write the relation
   out: "the kind, the purpose and the chosen option".
7. Keep machine tokens exactly as parsers need them, and put plain words next
   to each one. These tokens stay as they are: a task number at the start of a
   title or commit subject, `APPROVE:`, `REJECT:`, `ASK-` and `WORKER_` markers,
   `SPEC-OK:` and `SPEC-GAPS:` markers, the `<!-- fm-note ... -->` marker and
   `EVIDENCE:` lines. A reader who does not know the marker learns what it
   means from the sentence beside it.
8. Put code, paths, commands and identifiers in backquotes. Text in backquotes
   is never rewritten.

## Patterns that make text hard to read

These patterns come from the two humanizer guides credited below, adapted to
specs, cards, pull requests and comments. Each one hides a fact or makes the
reader work. Fix the pattern, not the word: a listed word that carries real
meaning stays.

### Staging instead of stating

- Not X but Y. "This is not a lint, it is a gate." Say what it is: "This check
  blocks the merge." Keep a contrast only when the reader really holds the
  wrong belief.
- One-line closers. "That is the real fix." after a paragraph that already said
  it. Cut it, or replace it with the consequence it implies.
- Sayings that sound deep. "At its core, the question is trust." State the
  specific claim.
- Run-ups. "Here is what you need to know:", "Let's look at". Start with the
  point.
- Arguing with no one. "To be clear, this does not change the gates." Keep it
  only if a reader would really think so; otherwise cut it.

### Rhythm by rule

- Forced lists of three. List exactly the items there are.
- Dashes as the universal connector. Use a period, a comma, a colon or
  parentheses, and say how the two parts relate.
- Stacked qualifiers. "could potentially possibly". Keep the one qualifier the
  evidence supports.
- Passive voice that hides who acts. "The pin is replaced." Say who replaces
  it: "firstmate replaces the pin".

### Inflation

- Words that sound important and say little: crucial, robust (outside its
  technical sense), seamless, comprehensive, key (as an adjective), leverage.
- Claims of significance. "This marks a major step for the workflow." Keep the
  fact, drop the significance.
- Vague links. "related to the merge path". Name the relation: "called by the
  merge path", "read by the merge path".
- Borrowed authority. "Reviewers agree that". Name the record or drop the
  claim.
- Avoiding is and has. "serves as", "features", "boasts". Use is and has.

### Formatting by rule

- Bold on every label. Use bold only where a reader skimming needs to stop.
- Title Case Headings and decorative emoji. Use sentence case and no emoji.

### Leftovers

- Chat wrappers: "Great question", "I hope this helps", "Let me know".
- Notes about the draft instead of the subject: "This section was rewritten
  to". Keep history only in change logs and migration notes.
- Re-explaining what the reader already has. A reply to a review comment leads
  with the decision and adds only what the reader lacks.

### Traditional Chinese text

The zh-TW guide adds checks for Chinese prose. Apply them to zh-TW card text:

- Long chains of 的. Split the modifier so the reader sees what modifies what.
- 進行 plus a verb. "進行測試" says the same as "測試".
- Stacked 被 sentences. Use the active voice when the actor is known; keep the
  passive when the actor is unknown.
- Four-character phrase runs that repeat one idea. Keep the ones that add a
  fact.
- "隨著……的發展" openings with no information. Start with the point.
- Closing slogans such as "讓我們拭目以待". End on the last fact.

The zh-CN text on the board comes from zh-TW through `i18n/tw2cn.tsv`. A word
left in Traditional characters after the table runs needs a zh-TW rewording or
a new row in that table.

## When not to act

Leave a phrase alone inside a quotation, a title, a proper name, or text that
discusses the phrase instead of using it. A pattern is a clue, not a ban: one
dash or one passive sentence is fine when it is the clearest choice.

## Mechanical checks

`bin/lib/fm_plain.py` runs three checks after it removes code spans in
backquotes, URLs, repository paths, hexadecimal hashes of seven or more
characters, task numbers, decision ids, version numbers such as 2.55 or v1.2,
and machine markers:

- glued number: a letter directly followed by a digit, or a digit directly
  followed by a letter, inside one word ("All13", "ts2672");
- slash chain: three or more words joined by slashes;
- unexplained term: a glossary term that appears in the text while its id is
  not in the card's `glossary` list.

The checks block a card request (`fm_ste.py check-plain`, all three checks), a
new pull-request draft when firstmate seals it (glued numbers and slash
chains), and the public fields of an external spec during spec preflight
(glued numbers and slash chains). A pull-request body gets its glossary section
generated from the terms it uses, so the unexplained-term check never blocks
pull-request text. Everywhere else, including commit messages and posted
comments, the checks only write findings to firstmate's log
(`state/runtime/plain-writing.jsonl`) and never stop a commit or a post.

These checks cannot judge meaning. Passing them does not make text clear.

## Credit

The patterns above are adapted from two guides, both under the MIT License:

- blader/humanizer (English), https://github.com/blader/humanizer, commit
  225a6f39ac85f76ee48dbad772ea4abe4ed6c9d8. It credits Wikipedia's "Signs of AI
  writing", maintained by WikiProject AI Cleanup.
- kevintsai1202/Humanizer-zh-TW (Traditional Chinese),
  https://github.com/kevintsai1202/Humanizer-zh-TW, commit
  e2cb6172c9264ea04f5bfa19433c06c653a4ac54. It is a Traditional Chinese branch
  of op7418/Humanizer-zh and also draws on blader/humanizer and
  hardikpandya/stop-slop.

### MIT License notice for blader/humanizer

```text
MIT License

Copyright (c) 2025 Siqi Chen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### MIT License notice for kevintsai1202/Humanizer-zh-TW

```text
MIT License

Copyright (c) 2026 歸藏

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
