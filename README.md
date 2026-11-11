# paredros: understand and decide on what a Claude Code session did

The Nimony port of [hitl](../hitl): the same program, written in Nimony on
its standard library alone, under its own name. It behaves as the Python
does and builds the same pages; its state (`~/.local/state/paredros`) has the
same layout as hitl's (`~/.local/state/hitl`), so copying one into the other
carries the ledger, briefs and drafts across. Where Nimony's standard library cannot match the Python
yet, the difference is listed under Gaps in [PORTING.md](PORTING.md); the
ones you may notice are under [Differences from the Python](#differences-from-the-python).

A desk beside any Claude Code session: one agent working alone, or a
coordinator that launches subagents, on any skill or kind of work (fixing
bugs, porting a library, building a feature). The agents never load it and do
no extra work. You still talk to the session as before; paredros gives you:

- **Review pages:** one page per work item, with a short brief and the code,
  in the same sections every time, where you choose and save your decisions.
- **A companion:** a read-only fork of the session that you can question, ask
  for a second opinion, or ask to challenge you, without interrupting it.
- **Saved decisions:** your answers, saved on the pages and re-checked against
  the current facts before you paste them into the session.

## Install

Needs a Nimony checkout built in `~/Projects/nimony` (or `$NIMONY_SRC`), git
and the `claude` CLI. paredros uses Nimony's standard library only. Build once,
then add an alias:

```sh
git clone <this repository> ~/Projects/hitl-nimony
cd ~/Projects/hitl-nimony
./build.sh --toolchain     # a private copy of the Nimony toolchain (see build.sh)
./build.sh                 # bin/paredros
alias paredros=~/Projects/hitl-nimony/bin/paredros
```

`bin/paredros` finds `companion.md` and `static/` in the repository it was built
in, so leave it there.

`paredros` alone prints its help. An option takes its value after `=` or `:`
(`--port=8000`), not as the next word. `--session=` picks the session: an id
prefix or a part of the project's name (`--session=nimony`). Without it,
paredros takes the newest session of the current directory's project, else the
newest session.

```sh
paredros brief            # sort the session into work items and write their briefs
paredros brief 3 5        # only the briefs of items 3 and 5 (rewritten when their inputs changed)
paredros serve            # pages, decisions and a chat: select text, "Ask about this"
```

| Option | Meaning |
|---|---|
| `--session=SESSION` | session id prefix or project-name substring |
| `--config=FILE` | config file (default: `.paredros.json` in the session's working directory) |
| `--model=MODEL` | `brief`: the model (default opus); `serve`: the companion's model |
| `--force` | `brief`: rewrite even if the inputs did not change |
| `--jobs=N` | `brief`: how many briefs may be written at once (default 4; see Gaps) |
| `--port=N` | `serve`: the port (default 8765; 0: one the system picks) |

`serve` builds the pages under `~/.local/state/paredros/review/<session>/`; they
also open as plain files, read only and without the chat. An error is one
line, `paredros: <message>`, and exit status 1.

## How it works with one agent or many

paredros reads the session's transcripts
(`~/.claude/projects/<project>/<session>.jsonl` and its `subagents/`) and git.
It never changes them. Three kinds of material come out of them:

- **Turns:** the main transcript, cut at each message you typed: what you said
  and everything the session said until your next message.
- **Agents:** each subagent's description, task and final report.
- **Commits:** the commits the session made. They come from git, not from the
  model. Every reflog of the repository (each worktree's HEAD and each
  branch, so a deleted worktree's commits are still found) is matched against
  the session's git commands that make commits: an entry counts when it was
  made while one of those commands ran, from its call to its recorded result
  (so your own commits and other sessions' commits in a shared checkout stay
  out). The command's transcript says which agent made the commit. Only
  commits that a ref still reaches count (so commits replaced by an amend or a
  rebase drop out).

`paredros brief` first asks the model to sort new material into **work items**
(one bug, one ported module, one feature). A single agent that fixed three
things in one session gets three items, each with its own commits; a
coordinator's fixer, reviewers and later redo of one bug share one item.
Housekeeping is left out by a rule in that prompt: status checks, filing or
updating bug reports, editing notes or prompts, combining reviewed branches
for upstream. The model names the agents and commits it leaves out that way;
any other agent or commit it fails to place is offered again on the next
run. paredros, not the model, numbers the items and keeps them in a ledger
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
`~/.local/state/paredros/briefs/<session>/`; a brief is rewritten only when its
inputs change. `--model=` picks the model (default opus).

## Config

Optional: `.paredros.json` in the session's working directory, or `--config=FILE`.
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
directory. [examples/nimony.paredros.json](examples/nimony.paredros.json) is the full
Nimony config. For a port, `spec` can name the source implementation ("the
Python sources in ../orig, which the port must match"), and a compare action
can run the original. A `.hitl.toml` from an older hitl must be converted to
`.paredros.json` by hand.

## Review pages

The look and behaviour of the pages are fixed in [DESIGN.md](DESIGN.md);
change that file first. The pages share `paredros.css` and `paredros.js`, which the
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

`paredros serve` runs a small web server (std/httpserver) that serves the pages
and passes your questions to the companion. Select any text and choose "Ask
about this", or press "Ask" in the corner. The server answers only requests
addressed to `127.0.0.1:<port>` or `localhost:<port>`; each run uses a random
token, and it refuses actions without it or from another site's page.

**Warning: the server listens on every network interface, not on 127.0.0.1
only** (the Python version binds 127.0.0.1). std/httpserver's `listenHttp`
cannot choose the address (bug-reports/113). So while `paredros serve` runs, it
is reachable from the network: a client there can send its own Host header,
read the token from `/config.js`, read the pages, and post decisions or
questions, which run `claude` as you. Do not run `paredros serve` on a network
you do not trust until bug 113 is fixed.

The chat's first question starts `claude -p --resume <session> --fork-session`
in the session's directory; later questions continue that fork. The fork
starts with the session's whole conversation; the session itself is not
changed. It runs in Claude Code's restricted mode, so your own and the
project's settings files do not widen what it may do, and its file tools
reach only the session's directory, its worktrees, the transcripts and the
briefs. Its permission profile lets it read files, run reading git
subcommands (`git log`, `show`, `diff`, ...) and `cat`, `head`, `ls`, `grep`
and the like, plus the config's compare commands; it can write only to its
scratch folder and has no MCP tools. Options that make a read write or run a
command (`--output`, `git grep -O`) are denied; everything else is
refused. Under each answer the chat lists what was refused. It drafts nothing: you save
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
page makes the check: it refuses when the
draft already reached the session or when those facts changed since (then
save it again on its page). Otherwise it copies the text, which ends with
`(d3, approved by me)`. You paste it into the session between turns.

## Differences from the Python

All are listed, with their cause, under Gaps in [PORTING.md](PORTING.md).
The ones you may notice:

- `paredros serve` listens on every interface (see the warning above), a port in
  use stops it with an assertion instead of a message, and a browser tab that
  closes before its answer is written stops the whole server (SIGPIPE).
- `--jobs` is accepted, but the briefs are written one after another.
- The command line follows std/smartcli: `--port=N`, not `--port N`; with no
  command, the help comes after `[Error] missing arguments` and paredros exits 1.
- The JSON files paredros writes (the ledger, the brief cache, drafts) are on one
  line instead of indented; both versions read them.
- A refused request or a missing file gets an empty answer instead of an HTML
  error page.
- Markdown in briefs and answers: `**a*b**` stays as written, and a
  non-ASCII space or digit is not taken for one (`std/rex` has no lazy
  repeats, lookaround or Unicode classes); the "From" line may drop a few
  more clock times or keep a stray separator.

## Tests

```sh
tests/run                  # build paredros and every test, run them in debug and release
tests/run tpages tserve    # only these
node --check static/paredros.js
```

The tests are the Python's `test_hitl.py`, one file per module, on throwaway
git repositories and transcripts in a temp directory, with a fake `claude`
(`tests/fakeclaude.nim`) first on PATH. Never run two builds at once: Nimony
builds in parallel fail.
