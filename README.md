# paredros

The paredros to your Claude Code session, so you get to be the proedros:
briefs of each work item, a companion to question, and decisions saved and
re-checked. Written in Nimony, standard library only
([Limitations](#limitations)).

## Install

Needs git and the `claude` CLI.

Linux and macOS:

```sh
curl -fsSL https://github.com/planetis-m/paredros/releases/latest/download/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://github.com/planetis-m/paredros/releases/latest/download/install.ps1 | iex
```

Targets: linux/amd64, linux/arm64, macos/arm64, windows/amd64. Installs into
`~/.local/bin` (Windows: `%LOCALAPPDATA%\Programs\paredros`).
`PAREDROS_VERSION` picks a tag, `PAREDROS_INSTALL_DIR` the folder.

### From source

Needs a Nimony checkout built in `~/Projects/nimony` (or `$NIMONY_SRC`):

```sh
git clone https://github.com/planetis-m/paredros ~/Projects/paredros
cd ~/Projects/paredros
./build.sh --toolchain     # a private copy of the Nimony toolchain (see build.sh)
./build.sh                 # bin/paredros (BACKEND=n: the native backend)
```

## Usage

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
| `--jobs=N` | `brief`: how many briefs may be written at once (default 4; see Limitations) |
| `--port=N` | `serve`: the port (default 8765; 0: one the system picks) |

`serve` builds the pages under `<data>/paredros/review/<session>/` and prints
the address to open; the pages also open as plain files, read only and
without the chat. `<data>` is the user's data directory: `~/.local/share`
(or `$XDG_DATA_HOME`) on Linux, `~/Library/Application Support` on macOS,
`%APPDATA%` on Windows. An error is one
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
(one bug, one module, one feature). A single agent that fixed three
things in one session gets three items, each with its own commits; a
coordinator's fixer, reviewers and later redo of one bug share one item.
Housekeeping is left out by a rule in that prompt: status checks, filing or
updating bug reports, editing notes, combining reviewed branches for
upstream. A change to what the agents are told (a prompt, a skill,
`CLAUDE.md`) is a work item. The model names the agents and commits it leaves out that way;
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
`<data>/paredros/briefs/<session>/`; a brief is rewritten only when its
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
Nimony config. `spec` can also name another implementation the code must
match, and a compare action can run it.

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
saved answers, with one Copy for all that are current.

Each item page is one column with these sections, always in this order; an
empty section stays in place and shows 0:

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
page showed them. One Copy below the decisions puts the text of every saved,
current one on the clipboard, after checking their facts again, and you paste
it into the session once. Discard withdraws a draft that was not sent yet
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
only.** std/httpserver's `listenHttp` cannot choose the address
(bug-reports/113). So while `paredros serve` runs, it is reachable from the
network: a client there can send its own Host header, read the token from
`/config.js`, read the pages, and post decisions or questions, which run
`claude` as you. Do not run `paredros serve` on a network
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
| answer a decision on a page | save it there, then Copy and paste |
| change a design direction | type it into the session |
| understand something | ask the companion; nothing is sent |

Saving a decision on a page is your approval. The draft records the facts
you saw: the item's code and its brief as the page showed them. Copy on the
page makes the check: it refuses when the
draft already reached the session or when those facts changed since (then
save it again on its page). Otherwise it copies the text, which ends with
`(c7f2e1, approved by me)`, a tag of six hex digits unique to that draft. You
paste it into the session between turns.

## Limitations

Each comes from a missing piece or a bug in Nimony's standard library. The
code marks each spot with a `# GAP:` comment; when the library is fixed, the
comment and its line here go.

Server:

- `paredros serve` listens on every interface, not on 127.0.0.1 only (see
  the warning above), because std/httpserver's `listenHttp` takes no address
  (bug-reports/113).
- A port in use stops paredros with a failed assertion, not a message,
  because std/ioring's `listenTcp` asserts that bind succeeds
  (bug-reports/109).
- A browser tab that goes away before its answer is written stops the whole
  server (SIGPIPE), because std/httpserver neither ignores nor suppresses
  the signal (bug-reports/114).
- A refused request or a missing file (421, 403, 404, 501) gets an empty
  answer, not an HTML error page; files have no Last-Modified and are never a
  304; a target that climbs above the pages (`/../x`) is a 400, not a 404.
  std/httpserver has no error pages and no file handler, and refuses such a
  target itself.

Model runs and child processes:

- `--jobs` is accepted, but the briefs are written one after another: runs
  started at once from std/parfor's `||` wait on each other for ever, because
  std/osproc's children inherit each other's pipes on Linux
  (bug-reports/105).
- A command that times out is killed, but not the processes it started,
  because std/osproc kills one process.
- A child that keeps stdout or stderr open is not stopped at its timeout,
  only once it closes them, and a child that fills its stderr pipe while
  stdout is read waits for ever, because std/osproc has no `communicate`
  (bug-reports/120).
- A program that cannot be found or started runs and exits 127 instead of
  failing to start, because std/osproc's fork and execve report a failed exec
  that way.

Files and JSON:

- The JSON files paredros writes (the ledger, the brief cache, drafts, the
  companion's settings) and the server's replies are on one line, not
  indented, with non-ASCII text as it is, not `\u`-escaped. Both are valid
  JSON. std/json has no pretty printer and no ASCII mode.
- A control character other than `\b \f \n \r \t` in a title, key, brief or
  reply is written raw, which is not JSON, because std/json's `$` does not
  escape them (bug-reports/104).
- Why a config file, a request body or the model's answer is not JSON is
  told in std/json's own message, the only one it gives.
- Times are read only as `YYYY-MM-DDTHH:MM:SS`, with a fraction, then `Z`,
  `±HH:MM` or no zone, and a time with no zone is taken as UTC, not local
  time, because std/times has no parse (bug-reports/119).

Text:

- Markdown in briefs and answers: the text of `**strong**` and `*emphasis*`
  holds no `*` (`**a*b**` and `*a*b*` stay as written), emphasis may touch
  another `*` (`**a*` gets one), and a non-ASCII character next to a `*`
  counts as a word character, because std/rex has no lazy repeats and no
  lookaround.
- `\s` is ASCII white space and the control characters: a URL, a fence's
  language or emphasis runs over U+00A0 and other Unicode spaces, and stops
  at `\x01`; `\d` is ASCII digits, so a list item numbered with non-ASCII
  digits is a paragraph. std/rex has no Unicode classes.
- A bare URL right after a non-ASCII digit (`٣`, `²`) is linked; a draft
  number, a page number, a `tips.json` key or a decision id is ASCII letters
  and digits only (`d٣.json` is no draft, `i٣.html` is never deleted).
  std/unicode has no digit test.
- `\x1c`..`\x1f` are not white space: they are not stripped and do not
  separate words, because std/unicode's white space list leaves them out.
- A C-quoted path in a diff with bytes that are not UTF-8 keeps them, not
  U+FFFD, because std/unicode has no decoding with replacement.
- The "From" line drops a clock time right after `:`, `.`, `/` or `-`
  (`x-10:01`) or right before `:` (`1:23:4` loses `1:23`), and of
  separators in a row takes out only the first (`(10:01, 10:05)` leaves
  `,)`), because std/rex has no lookaround.
- A project name whose first letter's capital is two letters (`ß`) gets one,
  because std/unicode maps one rune to one rune.

Command line:

- With no command, the help comes after `[Error] missing arguments` and
  paredros exits 1; a bad command line is told on stdout with the help and
  exit 1, not on stderr with the usage and exit 2; an option's value is given
  as `--port=N` or `--port:N`, not `--port N`. That is how std/smartcli
  parses.

## Tests

```sh
tests/run                  # build paredros and every test, run them in debug and release
tests/run tpages tserve    # only these
node --check static/paredros.js
```

The tests are one file per module, on throwaway git repositories and
transcripts in a temp directory, with a fake `claude` (`tests/fakeclaude.nim`)
first on PATH. Never run two builds at once: Nimony
builds in parallel fail.
