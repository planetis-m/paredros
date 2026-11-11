# Review desk: design spec

Status: frozen. Every change to the pages (`static/hitl.css`, `static/hitl.js`, and `pages.py`'s `CHAT_HTML` and page builders) follows this file. To change something this file does not allow, get the user's approval first and update this file in the same commit.

Baseline: commit bd249f5. That design stays. This file records it, answers the open questions and lists the few changes to make. Where this file says nothing, bd249f5's behaviour stands.

Note: the pages in `~/.local/state/hitl/review/26c3c765/` were built by the rejected implementation (`main.index`, `p.fresh`, `.save-btn`). Don't use them as a reference.

---

## 1. Answers

1. **"3 or more decisions".** (Revised, decided by the user.) The card shows the exact number of decisions, for example "5 decisions". Briefs have no cap: each list holds every entry that meets the bar, most important first (see 6.2), and the item page shows all of them. There is no "more" count, no "N more not shown" note and no "Show more". *Reason: say the number you know, and hide nothing.*
2. **Unsaved choice, blur, Save, Undo/Redo.** A selection stays until you change it. Blur, scrolling or clicking elsewhere never clears it (as today). An unsaved selection lasts while the page is open; it is not stored, and leaving the page asks nothing. There is no single Save for all items, because each decision is a separate approval with its own facts and its own stale check. Saving several at once would approve things you have not looked at, and the button would sit far from the choices. There are no Undo/Redo buttons on the card either. Undo already follows Save in the same line, choosing again is one click, and the text field keeps its own Ctrl+Z. One fix to Undo: it removes the saved draft and leaves your answer selected but unsaved, so it returns you to the moment before Save instead of clearing your choice. *Reason: one approval per decision, saved where you chose it; nothing is lost silently.*
3. **Home button.** No house icon. "‹ All items" at the leading edge of the top bar is the home link, drawn as a back button: a chevron plus the destination, as in macOS and iOS. A house icon would say "start of a website" and would add a second symbol for the same place. *Reason: this page is one level down, and a back button says exactly that.*
4. **"Ask the companion".** The floating button becomes **[speech-bubble icon] Ask**. The chat sheet's title becomes "Chat". "Companion" appears nowhere on the pages. The selection popover keeps **[bubble] Ask about this**. The earlier plain "Ask" failed because it had no icon. With the bubble, the button reads as a chat control at a glance. *Reason: one short verb plus a familiar symbol.*
5. **Previous/Next.** (Revised, approved by the user.) The top of an item page holds only the way out, "‹ All items". There is no visible Previous or Next control at the top, and no Previous anywhere: you move on from the end of a page, where the Next item row names the next item (answer 6). Alt+Left and Alt+Right still go to the previous and next item. *Reason: one way out at the top, one way on at the bottom; nothing to read past before the title.*
6. **The bottom "Next: #N" link.** It is for moving on once you have finished reading, which is the right job, but "#50" says nothing. Replace it with a full-width row: "Next item" above the next item's number and title, with a chevron. On the last item the row reads "All items". There is no back-to-top button: the Home key and the top bar already cover that, and a floating button would sit over content. *Reason: at the end of a page you want the next thing, and its title tells you what it is.*
7. **"nimony, read 2026-11-09 17:57".** It stays at the bottom of the index and becomes "Nimony, updated 17:57" (the project's directory name; date added only when not today). It is status, not content. Mail puts "Updated just now" at the foot of a list too, and when served the board is rebuilt on each visit anyway. *Reason: keep the title clean; the line is there when you look for it.*
8. **The repeated label on "Your decisions".** Rows start with the answer itself, with no "You chose:" or "My decision:" prefix: the strip's heading already says whose they are. Line two is the item number and the question, in grey, and links to that decision. The draft id and "(approved by me)" are not shown; they stay in the copied text, which the session needs. *Reason: say it once.*
9. **One more improvement.** **Chat bubbles show the button you pressed** ("Explain the options", "Grill me", the compare button), not the long prompt behind it. (Copy all on the strip and the cards' countdown were tried and dropped to keep the pages simple: each decision is copied with one click, and a card always shows its exact number of decisions.)

10. **Work items instead of bug reports.** (Added when hitl became generic.) A page is one work item of any Claude Code session: a bug fixed, a module ported, a feature. So the words follow: the index is "Work items", the eyebrow "Item #63", the way out "‹ All items", the end row "Next item". The stale reason says "The code changed" (not "the fix"). The compare button and the Spec lines appear only when the project's config asks for them. Everything else stays as it is. *Reason: the pages describe the work, whatever kind it is.*

Two things are replaced: the "Next: #N" link (its job moves to the Next item row) and "Ask the companion" (now "Ask"). Dropped later, by decision: Copy all, the card countdown, the remembered unsaved choice and the "more" note.

---

## 2. Principles

1. **The decision is the point.** Each decision has one filled button (Save decision), and the next step after it (Copy) is the most visible control on that line. Everything else supports these two.
2. **Same place, every time.** Fixed lanes, fixed sections, fixed order. An empty one stays where it is and says "none". A control's line keeps its height when its state changes.
3. **Say it once.** A fact is shown once, in one form: a lane colour, a word or a control, never several at once.
4. **Depth from tone, not lines.** Page, surface and raised are three tone steps. Hairlines are neutral and appear only between rows of one group. Colour comes only from the lanes, the one blue tint, and the diff.
5. **Calm.** Nothing moves unless you did something. No badges, no popping, no gimmicks. There is room around everything.

---

## 3. Tokens

### 3.1 Colour

`color-scheme: light dark`, following the system. Dark mode is designed rather than inverted: every surface sits above the page, raised things are lighter again, and nothing is darker than `--page`.

| Token | Use | Light | Dark |
|---|---|---|---|
| `--page` | page | `#f2f2f7` | `#161618` |
| `--surface` | grouped lists, clear cards, file rows | `#ffffff` | `#262629` |
| `--raised` | popover, sheet without blur | `#ffffff` | `#2f2f33` |
| `--fill` | inline code, pressed rows, dimmed button | `#ececf1` | `#353539` |
| `--hover` | hover on a row | `#f5f5f8` | `#2d2d31` |
| `--sep` | hairline between rows | `#dcdce1` | `#3c3c41` |
| `--edge` | radio circle, field outline | `#8a8a8f` | `#8a8a91` |
| `--ink` | text | `#1d1d1f` | `#f5f5f7` |
| `--ink2` | secondary text, "none", stale messages | `#5f5f66` | `#aeaeb5` |
| `--tint` | links, text controls, icons | `#0066cc` | `#5eaaff` |
| `--tint-fill` / `--tint-press` | filled button / its hover | `#0066cc` / `#0058b0` | `#1170dc` / `#0b5cb8` |
| `--on-tint` | text on a filled button | `#ffffff` | `#ffffff` |
| `--tint-soft` / `--tint-soft2` | soft button / its hover, your chat bubble | `#e3eefb` / `#dde9fa` | `#1f3250` / `#273d5f` |
| `--ring` | focus ring | `#2f7de1` | `#5eaaff` |
| `--sel` | text selection | `#c4dcfa` | `#264a78` |
| `--material` | floating Ask, chat sheet (blurred) | `rgba(255,255,255,.86)` | `rgba(38,38,41,.88)` |

Lane tints (card fill, card hover, number capsule, capsule and status text):

| Lane | Light | Dark |
|---|---|---|
| Waiting for your decision | `#e8f0fb` · `#dfe9f8` · `#d2e2f7` · `#0057ad` | `#1f2a3a` · `#243143` · `#2b3e5a` · `#93c5ff` |
| Needs another review | `#f8f0e3` · `#f3e8d6` · `#efdfc3` · `#864a00` | `#2f281e` · `#362e22` · `#4a3b25` · `#f2c47f` |
| Nothing open | `--surface` · `--hover` · `#ececf1` · `--ink2` | `--surface` · `--hover` · `#38383d` · `--ink2` |

Diff: added `#e4f4e8`/`#1c6a33` (dark `#1b3123`/`#8fdba3`), removed `#fbe8e6`/`#a5271d` (dark `#3c2323`/`#ff9f96`), hunk `#eff0f5` (dark `#2d2e34`).

States use no colour of their own:
- Saved and Sent: a tinted check icon, with the text in `--ink2`.
- Stale: the short mark "Out of date", styled exactly like "Suggested" (13px `--ink2`, no fill, no icon). Never gold or amber, never a sentence.
- Error: text in `--ink`, beginning "Not saved."

### 3.2 Type

Stack: `-apple-system, "Adwaita Sans", "Inter", system-ui, sans-serif` (Adwaita Sans is Inter-based, which is the closest to SF on Fedora). Mono: `"Adwaita Mono", "Noto Sans Mono", monospace`. Use tabular figures everywhere.

| Role | Size/line | Weight | Use |
|---|---|---|---|
| Large title | 34/1.18 (phone 28), tracking −0.022em | 650 | h1 |
| Title | 22/1.27 | 600 | lane and section headings; their counts in 400 `--ink2` |
| Lead | 20/1.5 (phone 18) | 400 | item summary |
| Question | 18/1.45 (phone 17) | 500 | decision question |
| Body | 17/1.55 | 400 | items, strip answers (500) |
| Callout | 16/1.5 | 400 | options, why lines, chat |
| Subheadline | 15/1.45 | 500–600 | buttons, nav, card status, state line |
| Footnote | 13/1.4 | 400–600 | sources, number capsule, freshness, notes |
| Code | 14 (file rows), 13 (diff), 12 (line numbers) | 400 | mono |

Use sentence case everywhere. Never use capitals with letter-spacing.

### 3.3 Spacing, radii, elevation

Spacing (px): 4, 8, 12, 16, 20, 24, 32, 40, 52, 56, 72, 96.
- Page gutter: 24 (phone 16). Item column: 44rem. Index: 72rem. The code breaks out to 76rem.
- Between sections and lanes: 56 / 52 (phone 48). From a heading to its group: 12–14. An empty section takes 28.
- Inside rows: 18×20 (phone 16). Inside a decision: 24 (phone 20×16).

Radii (px):
- 5: inline code
- 8–10: text controls
- 12: buttons, option group, fields
- 14: grouped surfaces and cards
- 22: floating Ask
- 50%: close buttons

Elevation:
- 0: page
- 1: surface, separated by tone only, no shadow
- 2: floating Ask and popover: `--material` with a 24px blur, plus the shadow `0 1px 3px rgba(0,0,0,.06), 0 6px 20px rgba(0,0,0,.07)` (dark: `.3`/`.28`)
- 3: chat sheet: `--material` with a 32px blur, the same shadow and a 1px `--sep` leading edge

Without backdrop blur, levels 2 and 3 use `--raised`.

### 3.4 Focus ring and targets

The focus ring is 3px solid `--ring`, offset 2px, following the control's radius. On rows inside a group the offset is −3px, so the ring stays inside the surface. It appears on keyboard focus only (`:focus-visible`). The own-answer row shows a 2px inset ring while its field has focus.

Every control is at least 44px tall. No text is smaller than 12px, and only line numbers use 12.

### 3.5 Motion

Motion only answers something you did.

| What | Motion |
|---|---|
| Hover/press on a row, card or button | background colour, 150ms ease-out |
| File row opens or closes | chevron turns 90°, 200ms ease-out; content appears instantly |
| Chat sheet opens or closes | opacity plus 12px slide from the trailing edge, 220ms ease-out in, 160ms out |
| Everything else | no motion |

`prefers-reduced-motion: reduce` turns all of it off. Never use smooth scrolling, spinners, pulses or skeletons. The wait text "Thinking…" is enough.

---

## 4. Layouts

### 4.1 Index

```
Desktop, max 72rem, gutter 24                                   --page
+--------------------------------------------------------------------+
| Work items                                           large title    |
|                                                            (32)     |
| Your decisions                                                      |  served, only when drafts exist
| +----------------------------------------------------------------+ |  --surface, r14
| | Ignore order, document it on the alias                 [⧉ Copy]| |  answer: body 500
| | #63  Once Table gets ==, should OrderedTable compare order…     | |  ink2, 2 lines max, links to the decision
| |   ------------------------------------------------------------  | |  hairline starts at the text
| | Keep it                                                [⧉ Copy]| |
| | #63  Should system's field-wise == keep comparing private…      | |
| +----------------------------------------------------------------+ |
|   1 already sent.                                         footnote  |
|                                                            (52)     |
| Waiting for your decision  4                                        |
| +-------------------+ +-------------------+ +-------------------+   |  decide tint, r14
| | (#45)             | | (#49)             | | (#63)             |   |  number capsule
| | Title, up to      | | Title, up to      | | Title, up to      |   |  3 lines, fixed height
| | three lines       | | three lines       | | three lines       |   |
| | 1 decision        | | 1 decision        | | 2 decisions       |   |  lane ink, 15/500
| +-------------------+ +-------------------+ +-------------------+   |
|                                                            (52)     |
| Needs another review  1                                             |
| +-------------------+                                               |  review tint
| | (#50) Title …     |                                               |
| |                   |  (empty status line keeps the height)         |
| +-------------------+                                               |
|                                                            (52)     |
| Nothing open  none                                     ink2, 500    |  an empty lane, as an empty section
|                                                            (96)     |
| Nimony, updated 17:57                                     footnote  |
+--------------------------------------------------------------------+

Phone (<640): gutter 16, one card per row (grid minmax 15rem), gap 12.
A strip row stacks: answer / #63 question / [⧉ Copy] on its own line.
                                   [bubble Ask]   floating, served only, 16 from the corner
```

### 4.2 Item page

```
Desktop: one column of 44rem, centred; phone: full width, gutter 16
+------------------------------------------------+
| ‹ All items                                    |  nav, 44 high, not sticky; the way out only
|                                          (40)  |
| Item #63                            15/500 ink2|
| Title, balanced, wraps                         |  large title
| One sentence: what the code does, what is left.|  lead
| [bubble Compare with Nim]                      |  soft button, served only, when configured
|                                          (56)  |
| Decisions for you  3                           |
| +--------------------------------------------+ |  --surface r14, 24 padding
| | Question in 18/500?                        | |
| | +----------------------------------------+ | |  option group: --page, r12
| | | (•) Implement First Trial counts…      | | |
| | |     Suggested                          | | |  "Suggested" trails on wide screens
| | |     Reordering alone lets declaration… | | |  why line, 15 ink2
| | |    --------------------------------    | | |
| | | ( ) Keep fewer-typevars-first ranking  | | |
| | |    --------------------------------    | | |
| | | ( ) Type your answer                   | | |  last radio, a text field
| | +----------------------------------------+ | |
| | [Save decision]                            | |  state line, 44 high, always present
| | Spec  Second Trial says G[A[T]] is more…   | |
| | From the agent's report and the spec review| |  footnote ink2
| | Explain the options   Grill me             | |  text controls
| |  ----------------------------------------  | |
| | (next decision)                            | |
| +--------------------------------------------+ |
|   No Spec line means the spec says nothing on  |  footnote, only if one lacks a Spec line
|   it.                                          |
|                                          (56)  |
| Contradicts the spec  none                     |  empty: ink2, 28 below
| Needs another review  2                        |
| +--------------------------------------------+ |
| | Item text.                                 | |
| | From the spec review                       | |
| +--------------------------------------------+ |
| Could cause more bugs  1                       |
| Decisions made  3                              |
| +--------------------------------------------+ |
| | Item text.                                 | |
| | Why, in ink2.                              | |
| | From …                                     | |
| +--------------------------------------------+ |
|                                          (72)  |
| The code  3 files               (76rem wide)   |
| +--------------------------------------------+ |
| | › src/sem.nim                    +12  −3   | |  every file starts closed
| |  ----------------------------------------  | |
| | › tests/t63.nim                  +30  −0   | |
| +--------------------------------------------+ |
|                                          (40)  |
| +--------------------------------------------+ |
| | Next item                                › | |  footnote ink2
| | #69  staticContracts: an index a[int(…     | |  body 500, one line
| +--------------------------------------------+ |
|                                 [bubble Ask]   |  floating, served only
+------------------------------------------------+

Phone (<640): "Suggested" moves under the option text.
The code stops breaking out. The decision padding becomes 20×16.
```

An item without a brief shows the header without a summary, then "No brief yet. Run `hitl brief 63`.", the compare button when configured, The code, and the Next item row.

Before `hitl brief` has sorted the session into work items, the index shows "No work items yet. Run `hitl brief`." under the title, then the three empty lanes.

### 4.3 Chat sheet (served only)

```
Desktop: fixed on the trailing edge, width min(28rem, 100%), level 3.
At 1480px and wider the page shifts left to make room; narrower, the sheet covers it.
+------------------------------+
| Chat                     (x) |  17/600; close 44 round
|------------------------------|
|        +-------------------+ |
|        | > quoted text     | |  your bubble: --tint-soft, r18
|        | What does this    | |
|        | mean?             | |
|        +-------------------+ |
| Answer in 16/1.6, markdown   |
|------------------------------|
| +--------------------------+ |  quote box: --tint-soft, remove (x)
| | quoted selection     (x) | |
| +--------------------------+ |
| +--------------------------+ |
| | Ask a question           | |  field, r12, --edge outline
| +--------------------------+ |
| Ctrl+Enter to send   [Send]  |
+------------------------------+
Phone: full width, gutters 16.
```

---

## 5. Components

Icons are inline SVG in the SF Symbols style, drawn as below: `viewBox="0 0 20 20"`, `fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"`, stroke 1.6 (chevrons 2), shown at 16–18px, `aria-hidden="true"`. Each icon sits next to a word and never replaces it, except the close buttons, which carry an `aria-label`.

| Name | Symbol | Paths |
|---|---|---|
| bubble | bubble.left | `<path d="M10 3.5c4.1 0 7 2.5 7 5.6s-2.9 5.6-7 5.6c-.8 0-1.6-.1-2.3-.3L4 16.2l.9-3.1C3.7 12.1 3 10.7 3 9.1 3 6 5.9 3.5 10 3.5z"/>` |
| copy | doc.on.doc | `<rect x="7" y="7" width="9.5" height="10.5" rx="2"/><path d="M13 7V5.5a2 2 0 0 0-2-2H5.5a2 2 0 0 0-2 2V12a2 2 0 0 0 2 2H7"/>` |
| check | checkmark | `<path d="M4.5 10.5l3.5 3.5 7.5-8"/>` |
| back / prev | chevron.left | `<path d="M12.5 4.5L7 10l5.5 5.5"/>` |
| next / disclosure | chevron.right | `<path d="M7.5 4.5L13 10l-5.5 5.5"/>` |
| close | xmark | `<path d="M5.5 5.5l9 9M14.5 5.5l-9 9"/>` |

Button styles. There are only three.

| Style | Look | Used for |
|---|---|---|
| Filled | `--tint-fill`, `--on-tint`, 600 15px, r12 (decision) or r10, 44 high, padding 0 18 | Save decision, Send, the Ask about this popover |
| Soft | `--tint-soft`, `--tint` text, 600 15px, r12, icon gap 8 | Copy, the compare button |
| Text | `--tint` text, 500 15px, no fill; hover `--hover` fill or underline | Undo, Cancel, Save again, Explain the options, Grill me, nav links |

The floating Ask uses its own capsule: `--material`, `--tint` text, a `--sep` hairline, r22.

### 5.1 Top bar (item)

Anatomy: a `nav` holding only "‹ All items" (chevron.left plus the words) at the leading edge, a text control 44 high. No Previous or Next, and no disabled placeholders. Hover underlines the label.

The previous and next items are `<link rel="prev">` and `<link rel="next">` in the page head, which Alt+Left and Alt+Right follow; nothing on the page shows them.

### 5.2 Card (index)

Anatomy: a link, r14, filled with the lane tint, padding 16×20×18. It holds a number capsule (`#63`, 13/600, capsule tint, lane ink), the title (17/500, clamped to 3 lines with a fixed height), and a status line (15/500, lane ink) that keeps its height even when empty.

Status line:
- Decision lane: the exact number of open decisions, "1 decision" / "5 decisions". It does not change as you save.
- No brief: "No brief yet".
- Other cases: empty.

Hover uses the lane hover tint. No other marks.

Card grid, kept exactly as in bd249f5:
- Cards are ordered by item number, ascending, within each lane. Nothing reorders them: not saving, not hover.
- One grid (`repeat(auto-fill, minmax(15rem, 1fr))`, gap 16) gives every card the same width. The title's fixed 3-line height and the always-present status line give every card the same height. Columns align from lane to lane.
- No card is ever wider, taller or emphasised over another. No masonry, no auto-height, no featured card.

### 5.3 Lane (index)

Anatomy: a heading (22/600) with its count in 400 `--ink2`, then the card grid (minmax 15rem, gap 16, phone 12).

An empty lane shows its heading in `--ink2` at 500 with "none" beside it and takes 28 below. The order is fixed: Waiting for your decision, Needs another review, Nothing open.

An item goes into the first lane that applies:
1. Waiting for your decision: its brief has open decisions.
2. Needs another review: its brief has spec conflicts or needs-another-review entries, or it has no brief yet.
3. Nothing open: everything else (bug risks and decisions made alone do not hold an item in a lane).

### 5.4 Your decisions strip (index, served only)

Hidden when there are no drafts. Anatomy:
- The heading "Your decisions".
- One `--surface` group, r14. Each row is one target that opens its decision (`i63.html#q63-<did>`); hover fills it with `--hover`. Each row holds:
  - the answer (17/500 `--ink`, wraps in full);
  - "#63  " followed by the question (15 `--ink2`, 2-line clamp);
  - a trailing soft "Copy" button with the copy icon. On a phone it moves to its own line.
- Build: the question line is the row's only link, and its `::after` is stretched over the row (`position:absolute; inset:0`), so the link's name is "#63 <question>" and its focus ring (inset 3px) outlines the row. Copy, the message line and a copy-failed field sit above it (`position:relative; z-index:1`), so they are siblings of the link, never inside it: no button nested in a link. Hovering Copy does not fill the row.
- Below the group: "N already sent." (13 `--ink2`), when there are any.

| Row state | Shows |
|---|---|
| Ready | answer, question link, Copy |
| Copied | the button stays; the line under it reads "Copied." |
| Stale (known from `/drafts`) | the mark "Out of date" after the answer (like "Suggested"), and no Copy button: the answer can't be sent as it stands, and the row already opens the decision to save again. The reason is in the mark's tooltip and screen-reader text. |
| Copy failed | the exact text appears in a read-only, preselected field under the row, with "Copy failed. Press Ctrl+C." |

Copy runs `/send`, which makes the same re-check as `hitl directions send`: it refuses a draft that already reached the session or whose facts changed.

### 5.5 Item header

Anatomy, in order, below the top bar ("‹ All items" only, 5.1):
- the eyebrow "Item #63" (15/500 `--ink2`);
- the h1;
- the summary (lead), shown only when a brief exists;
- the compare button: a soft button with the bubble icon and the label from the project's config ("Compare with Nim" for Nimony), 24 above it, served only, and only when the config defines one.

### 5.6 Section

Anatomy: a heading (22/600) with its count (400 `--ink2`), then one grouped list. The code section's count reads "3 files". An empty section shows its heading and "none", both in `--ink2` at 500.

The order is fixed: Decisions for you, Contradicts the spec, Needs another review, Could cause more bugs, Decisions made, The code. A section shows every entry of its list in the brief, most important first: nothing is capped, folded or behind a "Show more". Its count is the exact total.

### 5.7 Item (other sections)

Anatomy:
- the text (17, max 40rem);
- an optional why line (16 `--ink2`, with a hidden "Why: " prefix for screen readers);
- the source line "From …" (13 `--ink2`).

Rows are split by hairlines that start at the text.

### 5.8 Decision

Anatomy, top to bottom:
1. **Question**: 18/500, the radiogroup's label.
2. **Option group**: a `--page` inset, r12, `role="radiogroup"`. Each option is a row with a radio circle (16px, 1.5px `--edge` ring; when checked it fills with `--tint-fill` around a 3px `--on-tint` dot). The text is 16 and turns 500 when checked. The suggested option carries "Suggested" (13 `--ink2`) at its trailing edge and its reason as a second line (15 `--ink2`). The last row is **your own answer**: the same circle, with an auto-growing field whose placeholder is "Type your answer". Clicking, focusing or typing in it selects it. Hairlines start at the text (48 from the edge).
3. **State line**: always present when served, 44 high, so switching states never moves the page.
4. **Suggested line**: "Suggested" (label 500) followed by the brief's reason. It appears only when the brief recommends none of the options. Otherwise the brief names the recommended option by its index, and that option carries the mark and the reason.
5. **Spec line**: "Spec" (label 600 `--ink`) followed by the sentence, 15 `--ink2`.
6. **Source**: "From …".
7. **Helpers**: the text buttons "Explain the options" and "Grill me". They are hidden once the decision is sent.

State line, by state:

| State | State line | Options |
|---|---|---|
| Opened as a file | hidden; helpers hidden | inert; own-answer row hidden |
| Nothing chosen | [Save decision] dimmed (`--fill`, `--ink2`) | enabled |
| Chosen, not saved | [Save decision] enabled | selected one checked |
| Saving failed | "Not saved. <error>" then [Save decision] | unchanged |
| Saved | ✓ "Saved." · [⧉ Copy] · Undo | saved one checked |
| Copied | ✓ "Copied." · [⧉ Copy] · Undo | unchanged |
| Copy failed | "Copy failed. Press Ctrl+C." with the exact text in a preselected read-only field below | unchanged |
| Saved, then another answer chosen | [Save decision] · Cancel (Cancel goes back to the saved answer) | new one checked |
| Stale | Save again · Undo (no sentence) | saved one checked, with the mark "Out of date" at its trailing edge where "Suggested" sits (both can show: "Suggested · Out of date"). The reason ("The code changed" / "New evidence") is its tooltip and screen-reader text. |
| Sent | ✓ "Sent at 17:57." | locked; the others in `--ink2`; empty own row hidden |

Rules:
- Only a click, an arrow key or typing changes the selection. Blur never does.
- Enter in the own-answer field saves (Shift+Enter adds a new line). A trailing full stop is trimmed.
- Undo removes the draft and keeps the answer selected, unsaved. Save decision is then enabled again.
- Save again re-saves the same answer, which records today's facts.
- An unsaved selection is not stored: it lasts while the page is open.
- Save records the code tip and the brief the page showed (`data-ref`, `data-brief`), so a decision is checked against what you saw.

### 5.9 Code

Anatomy: one grouped list, r14, wider than the column. Each file row (52 high, mono 14) holds a chevron.right that turns 90° when open, the path, and "+12 −3" in the diff inks. The open body scrolls sideways: two line-number columns (12 `--ink2`), the sign, then the line. Every file starts closed.

If there are no changes, the section shows "No code changes."

### 5.10 Next item row

Anatomy: one `--surface` row, r14, at least 64 high, 40 below The code. "Next item" (13 `--ink2`) sits above "#69  <title>" (17/500, 1-line clamp), with a chevron.right at the trailing edge in `--ink2`. The whole row is the link; its tooltip is "#69 <title> (Alt+Right)". Hover uses `--hover`. It is the page's only visible way to the next item.

It is a link, not a button: it goes to another page, so it keeps what links give (open in a new tab, the address on hover). It stays a full-width row, not a button shape, because the next item's title is its content and a button would cut it to a label. Its text is not selectable (`user-select: none`), like the top bar's links and the index cards, so dragging over it selects nothing and never opens the Ask popover.

On the last item the row reads only "All items ›" and links to the index.

### 5.11 Freshness line (index)

"Nimony, updated 17:57" (the project's directory name, capitalised) in 13 `--ink2`, 96 below the last lane. When the data is not from today it reads "updated Nov 8 17:57".

### 5.12 Ask (served only)

- **Floating Ask**: fixed 24 from the bottom-trailing corner (16 on a phone). The capsule holds the bubble icon and "Ask". It is hidden while the sheet is open, and its tooltip reads "Ctrl+Shift+A asks about selected text".
- **Popover**: a filled button with the bubble icon and "Ask about this", placed 10 below the selection and kept inside the viewport. It does not appear for selections inside controls, navigation or the strip. Esc dismisses it.
- **Sheet**: the title "Chat" and a close button (`aria-label` "Close chat").
  - The empty log reads "Select text to ask about it, or type a question."
  - Your bubble shows the quote, then your words. For a helper button, your bubble shows that button's label.
  - While waiting: "Thinking…" (`aria-busy`).
  - On error: "No answer. <error>".
  - Composer: a quote box with a remove button ("Remove quote"), the field "Ask a question", the hint "Ctrl+Enter to send" and a filled "Send" button (dimmed while waiting).

---

## 6. Strings

### 6.1 Every visible string

| Where | String |
|---|---|
| Index title | Work items |
| No items yet | No work items yet. Run `hitl brief`. |
| Strip heading | Your decisions |
| Strip button | Copy |
| Strip row | `<answer>` / `#63  <question>` |
| Strip copied | Copied. · Already sent. (sent meanwhile) |
| Stale mark (decision and strip) | Out of date |
| Stale mark tooltip / screen reader | The code changed. · New evidence. · The code changed. New evidence. (as the server gives them) |
| Copy failed | Copy failed. Press Ctrl+C. |
| Strip sent | 1 already sent. / 3 already sent. |
| Lane headings | Waiting for your decision · Needs another review · Nothing open |
| Empty lane or section | none |
| Card status | 1 decision · 5 decisions · No brief yet |
| Freshness | Nimony, updated 17:57 |
| Top bar | All items |
| Next row tooltip | #69 `<title>` (Alt+Right) |
| Eyebrow | Item #63 |
| No brief | No brief yet. Run `hitl brief 63`. |
| Header button | the config's compare label, e.g. Compare with Nim |
| Section headings | Decisions for you · Contradicts the spec · Needs another review · Could cause more bugs · Decisions made · The code |
| Code count | 1 file · 3 files |
| Option mark | Suggested |
| Own answer | Type your answer (placeholder) · Your own answer (label) |
| State line | Save decision · Cancel · Saved. · Copy · Undo · Save again |
| Copied | Copied. |
| Sent | Sent at 17:57. |
| Error | Not saved. `<error>` |
| Decision lines | Suggested `<reason>` · Spec `<sentence>` · From `<source>` |
| Spec note | No Spec line means the spec says nothing on it. (only when the config names a spec) |
| Helpers | Explain the options · Grill me |
| Item, screen reader | Why: |
| No diff | No code changes. |
| Next row | Next item · #69 `<title>` · All items (last) |
| Floating button | Ask |
| Popover | Ask about this |
| Sheet | Chat · Close chat |
| Empty log | Select text to ask about it, or type a question. |
| Composer | Ask a question · Your question (label) · Ctrl+Enter to send · Send · Remove quote |
| Default question | What does this mean? |
| Waiting | Thinking… |
| Chat error | No answer. `<error>` |
| Chat refusals | Not allowed: `<n>` (a closed disclosure under the answer, listing what the companion tried and its permissions refused) |

Strings shortened at the user's request ("the wording is needlessly complex"): every message says what happened in the fewest plain words; where to paste is left out, since you know it. Strings removed: the long stale sentences ("The code changed after you chose.", "There is new evidence since you chose.", "… Look again and choose.", "… Open the report and choose again.", "Look again"), "3 or more decisions", "Ask the companion", "Companion", "Close the companion", "The companion failed:", "Next: #N", "No changes against the base.", "Copying failed. Copy it from the reports page.", "Copy it from above and paste it into the coordinator.", and the built-line form "nimony, read 2026-11-09 17:57". Removed later with their features: "Copy all", "Copied 3.", "Nothing to copy.", "Skipped 1 out of date.", "2 decisions left", "All decided", "2 more not shown." and "Ask about them".

The copied draft text is not a page string. It stays as `drafts.decide` builds it ("#63: question / My decision: answer. (d3, approved by me)") because the session and `delivered_at` rely on it.

### 6.2 Brief shape (for answers 1 and 5.8)

- Each list holds every entry that meets the bar, most important first. There is no cap and no `more` field; a section's count and the card's count are the list's length.
- An open decision carries `options`, `recommended` (the index of the recommended option, or -1 for none) and `reason` (the one reason, without restating the option). The brief is written with `--json-schema`, so the page never guesses which option is meant.
- `brief.parse` keeps the summary and the five lists and drops anything else.

---

## 7. Keyboard and accessibility

| Key | Where | Does |
|---|---|---|
| Tab / Shift+Tab | everywhere | page order: top bar, header, each decision (radiogroup as one stop, then its state line, then helpers), items' links, file rows, Next item row, Ask |
| Arrow keys | radiogroup | move to an option and select it, wrapping. In the own-answer field the arrows edit text; Up or Left at its very start leaves it |
| Enter | own-answer field | Save decision |
| Space / Enter | an option | select it |
| Alt+Left / Alt+Right | item page, outside fields | Previous / Next item (no visible control for Previous) |
| Ctrl+Shift+A | served | Ask about the selection, or open the chat |
| Ctrl+Enter | chat field | Send |
| Esc | served | close the popover, else the chat (focus returns to where it came from) |
| Ctrl+C | a copy-failed field | copy the preselected text |

Accessibility:
- **Landmarks**: `main`; `nav` "Items" for the top bar; `nav` "Next item" for the end row; `aside` for the chat, labelled by its title.
- **Headings**: h1 for the page title, h2 for lanes and sections, h3 and below inside agent text.
- **Radiogroup**: the options are `role="radio"` with `aria-checked`. The own-answer row is a radio labelled "Your own answer". The group uses a roving tabindex (Tab enters at the checked radio, else the first).
- **Announcements**: the state line, strip messages and the chat log are `aria-live="polite"`. The waiting answer is `aria-busy`.
- **Disabled things**: Save decision uses `disabled` when there is nothing to save.
- **Contrast**: body text 7:1 or better, secondary text 4.5:1 or better on every surface and tint in both modes, including lane ink on lane tint. Check any new pair with a contrast tool before shipping.
- **Colour is never the only signal**: lanes have headings, states have words, the diff has + and − signs.
- **Text**: honours a 200% zoom with no horizontal page scroll. Only code scrolls sideways.
- **Reduced motion** is respected (3.5).

---

## 8. Rules for future changes

1. Keep the baseline's character: the soft blue and sand lane tints, number capsules, counts beside headings, filled Save decision, soft Copy, the radio circles, icons next to words, and the blurred floating Ask and chat sheet. "Plainer" is a regression, not a simplification.
2. Never add thin coloured bars, stripes, accent borders, pips, coloured dots, badges beyond the number capsule, lineage graphs, hook controls, a second column on item pages, a sticky bar, skeuomorphic or editorial/print styling, or a GNOME header-bar look.
3. Lanes and sections are fixed in name, number and order. Empty ones stay and say "none". A section shows every entry, with its exact count: no cap, no fold, no "Show more", nothing behind a drop-down.
4. Each decision has one filled button. A new action is a soft or text button, an existing style. Don't invent a fourth button style.
5. Every state change keeps the control line's height and position. Blur never changes a selection. No confirm dialogs, no auto-save, no save-all.
6. No logistics on pages (PRs, branches, hashes, draft ids, agent names, times other than "updated" and "Sent … at"). Plain sentence-case words; every new string goes into section 6 in the same change.
7. Every colour, size, spacing value, radius and duration comes from section 3. A new one goes into section 3 first, with a light and a dark value.
8. Motion only answers an action, and is off under reduced motion.
9. Staleness is only the mark "Out of date" (styled as "Suggested"), never a sentence, never gold, amber or red.
10. Before merging, check both modes at 360px and desktop width, a keyboard-only pass over one decision (choose, type, Save, Copy, Undo, Cancel, Save again), an empty section, an empty lane, an item without a brief, the last item's end row, and file mode (no server).
11. Index cards stay in item-number order within each lane, in one aligned grid, all the same size.
