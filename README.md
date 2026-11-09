# hitl: understand and decide on what a Claude Code session did

A desk beside any Claude Code session: one agent working alone, or a
coordinator that launches subagents, on any skill or kind of work (fixing
bugs, porting a library, building a feature). The agents never load it and do
no extra work. You still talk to the session as before; hitl gives you:

- **Review pages:** one page per work item, with a short brief and the code,
  in the same sections every time, where you choose and save your decisions.
- **A companion:** a read-only fork of the session that you can question, ask
  for a second opinion, or ask to challenge you, without interrupting it.
- **Saved decisions:** your answers, saved on the pages and re-checked against
  the current facts before you paste them into the session.

hitl runs in the browser. It has two commands: `hitl brief` starts the model
runs (they cost money, so they run only when you ask), and `hitl serve` builds
the pages and serves them.

## Install

Needs a Nimony build (`nimony`), git and the `claude` CLI. kroki and hashi,
the two Nimony libraries hitl uses, are cloned into `deps/`. Build once, then
add an alias:

```sh
git clone <this repository> ~/Projects/hitl-nimony
cd ~/Projects/hitl-nimony
git clone <kroki> deps/kroki && git clone <hashi> deps/hashi
./build.sh --toolchain     # a private copy of the nimony toolchain (see build.sh)
./build.sh                 # bin/hitl
alias hitl=~/Projects/hitl-nimony/bin/hitl
```

`hitl` without a command prints its help. Options take their value after `=`.
`--session=` picks the session: an id prefix or a part of the project's name
(`--session=nimony`). Without it, hitl takes the newest session of the
current directory's project, else the newest session.

```sh
hitl brief            # sort the session into work items and write their briefs
hitl brief 3 5        # rewrite only the briefs of items 3 and 5 (when their inputs changed)
hitl serve            # pages, decisions and a chat: select text, "Ask about this"
```

The pages `hitl serve` builds stay in `~/.local/state/hitl/review/<session>/`;
opened as plain files they are read only.

## How it works with one agent or many

hitl reads the session's transcripts
(`~/.claude/projects/<project>/<session>.jsonl` and its `subagents/`) and git.
It never changes them. Three kinds of material come out of them:

- **Turns:** the main transcript, cut at each message you typed: what you said
  and everything the session said until your next message.
- **Agents:** each subagent's description, task and final report.
- **Commits:** the commits the session made. They come from git, not from the
  model: the HEAD reflog of every worktree where the session ran a git command
  that makes commits, keeping only entries made within 120 seconds after one
  of those commands (so your own commits and other sessions' commits in a
  shared checkout stay out) and only commits that a ref still reaches (so
  commits replaced by an amend or a rebase drop out).

`hitl brief` first asks the model to sort new material into **work items**
(one bug, one ported module, one feature). A single agent that fixed three
things in one session gets three items, each with its own commits; a
coordinator's fixer, reviewers and later redo of one bug share one item.
Housekeeping is left out by a rule in that prompt: status checks, filing or
updating bug reports, editing notes or prompts, combining reviewed branches
for upstream. The model names the agents and commits it leaves out that way;
any other agent or commit it fails to place is offered again on the next
run. hitl, not the model, numbers the items and keeps them in a ledger
(`items.json`): material once sorted stays in its item, and later runs sort
only what is new or, for a turn, what grew. So an item's page and the
decisions saved against it keep their number however often briefs are
rewritten.

An item's code is its newest commit plus every commit of the item that is an
ancestor of it, shown as one diff per unbroken run. Its other commits (an
abandoned attempt on another branch) are earlier attempts: the brief hears
about them, the page does not show them. When an older commit on another
branch is the one actually kept, the page still shows the newest; the brief
names the earlier attempts, and the companion can tell them apart.

Then one read-only `claude -p` per item writes the brief from the item's
turns, agents' reports and code. Both model runs get only the Read, Grep and
Glob tools (`--tools`), no MCP servers (`--strict-mcp-config`), and answer in
a fixed JSON schema (`--json-schema`). A brief lists every entry that meets
its bar; nothing is capped. Briefs and the ledger are cached under
`~/.local/state/hitl/briefs/<session>/`; a brief is rewritten only when its
inputs change. `--model=` picks the model (default opus).

## Config

Optional: `.hitl.json` in the session's working directory, or `--config=FILE`.
Without it everything works; the pages have no Spec lines and no compare
button. Every key may be left out; an unknown key is refused.

```json
{
  "spec": "doc/language.md",
  "reader": "a Nimony developer",
  "users": "people writing Nimony code",
  "compare": {
    "label": "Compare with Nim",
    "prompt": "Investigate how Nim 2 and Nimony handle the cases in this work item. ...",
    "allow": ["{home}/Projects/Nim/bin/nim r --nimcache:{scratch}/cache"]
  }
}
```

| Key | Meaning | Default |
|---|---|---|
| `spec` | what the code must agree with: a path in the repository or a short description | none: no Spec lines |
| `reader` | who reads the briefs | "a developer of this project" |
| `users` | whose behaviour a decision changes, as in "what <users> see or can do" | "the project's users" |
| `compare` | a button on each item page that asks the companion `prompt`; `label` is the button, `allow` the command prefixes the companion may run for it, with files in its scratch folder only | none: no button |

`{scratch}` is the companion's scratch folder and `{home}` your home
directory. [examples/nimony.hitl.json](examples/nimony.hitl.json) is the full
Nimony config. For a port, `spec` can name the source implementation ("the
Python sources in ../orig, which the port must match"), and a compare action
can run the original. A `.hitl.toml` from an older hitl must be converted to
`.hitl.json` by hand.

## Review pages

The look and behaviour of the pages are fixed in [DESIGN.md](DESIGN.md);
change that file first. The pages share `hitl.css` and `hitl.js`, which the
build copies beside them from `static/`.

The index is a board of three lanes, always in this order: Waiting for your
decision, Needs another review, Nothing open. An item goes into the first lane
that applies (open decisions; else spec conflicts, entries that need another
review, or no brief yet; else nothing open). Cards are coloured by lane,
ordered by number and all the same size; decision cards give the exact number
of open decisions. When served, "Your decisions" above the lanes lists your
saved answers, each with its own Copy.

Each item page is one column with these sections, always in this order; an
empty section stays in place and says "none":

1. Summary: one sentence on what the current code does and what is left
2. Decisions for you: open questions, the options, a suggestion
3. Contradicts the spec
4. Needs another review: changed after review, findings not addressed, claims
   nobody checked
5. Could cause more bugs: regressions, cases the change may break, side findings
6. Decisions made, each with its reason
7. The code: one fold per file

Every section shows every entry of the brief, the most important first, each
naming its evidence, with the exact count beside the heading; nothing is
folded or hidden. There is nothing about PRs, branches or pushing on the
pages. For anything deeper than a brief, ask the companion: it has every
agent's full report.

## Decisions on the page

When served, each decision is a radio group: the options, then a field for
your own answer. Choosing only selects; Save decision (or Enter in the field)
writes the approved draft, recording the item's code and the brief as the
page showed them. Then Copy puts its text on the clipboard, after checking its
facts again, and you paste it into the session. Undo withdraws the draft
(its number is never reused) and leaves your answer selected; an unsaved
choice is not stored once you leave the page. When the item's code or its
brief changed since you saved, the answer is marked "Out of date" and "Save
again" records it against today's facts. Opened as files, the pages are
read-only.

## The chat and the companion

`hitl serve` runs a small web server on 127.0.0.1 (hashi)
that serves the pages and passes your questions to the companion: a
read-only fork of the session (`claude -p --resume <session> --fork-session`,
in the session's directory), which later questions continue. Select any
text and choose "Ask about this", or press "Ask" in the corner. The server
answers only requests addressed to `127.0.0.1:<port>` or `localhost:<port>`;
each run uses a random token, and it refuses actions without it or from
another site's page.

The fork starts with the session's whole conversation; the session itself is
not changed. Its permission profile lets it read and run reading git
subcommands (`git --no-optional-locks log`, `show`, `diff`, ...), plus the
config's compare commands; it can write only to its scratch folder and has no
MCP tools. Git and `gh` writes (with or without `--no-optional-locks`, and any
`git -C`), `hitl brief` and `hitl serve`, messaging or stopping agents, and
`flock` are denied; anything else not listed is refused. It drafts nothing: you save
decisions on the pages and type everything else. Ask it to explain, to give a
second opinion (it starts a fresh reviewer that gets the code, not your
conclusion), or to grill you.

For a quick question without tools, `/btw` in the session's own terminal also
works and does not interrupt it.

## Directions

| You want to | Do |
|---|---|
| stop or pause the work | Esc in the session's terminal, now |
| answer a question it asked | type the answer there, now |
| answer a decision on a page | save it there, then Copy and paste it |
| change a design direction | type it into the session |
| understand something | ask the companion; nothing is sent |

Saving a decision on a page is your approval. The draft records the facts
you saw: the item's code and its brief as the page showed them. Copy on the
page checks them again: it refuses when the draft already reached the session
or when those facts changed since (then save it again on its page). Otherwise
it copies the text, which ends with `(d3, approved by me)`. You paste it into
the session between turns.

## Tests

```sh
tests/run                  # every test, debug and release
node --check static/hitl.js
```
