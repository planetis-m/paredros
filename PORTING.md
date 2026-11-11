# Porting hitl to Nimony

hitl is ported from the Python in `~/Projects/hitl` (branch `general`),
module for module, on Nimony's standard library alone. The port is done:
every module and its tests are ported, the pages built from a real session
are byte for byte the Python's, and the two share `~/.local/state/hitl` (each
reads the ledger, the brief cache and the drafts the other writes). What is
still less accurate than the Python is listed under **Gaps**, each with the
standard library's missing piece or bug report; when upstream fixes one, the
`# GAP:` comment and its row go. The first port, on kroki and hashi, is on
branch `main`.

## Source of truth

- The Python in `~/Projects/hitl`, branch `general` (read only: never edit it).
  `ARCHITECTURE.md`, `DESIGN.md` and `README.md` there describe the behaviour.
- `test_hitl.py` there is the behaviour to keep: each module's tests are
  ported with it.
- `companion.md`, `static/hitl.css`, `static/hitl.js`, `examples/` and
  `DESIGN.md` here are copies of the Python repository's; keep them identical.

## Modules

One Nimony module per Python module, with the same layers: a module imports
only from the ones above it, never below, and never inside a proc.

| Python | Nimony | What |
|---|---|---|
| `state.py` | `hitl/state.nim` | hitl's own files: `state()`, `writeAtomic`, companion fork ids, `appDir`, and the shared text helpers `collapse`, `quote` (JSON text) and `subGroup` (re.sub with a group) |
| `session.py` | `hitl/session.nim` | transcripts (the only module that knows their format), agents, sessions, `run()` for child processes, `git()`, `gitWrites` |
| `config.py` | `hitl/config.nim` | the config as a value: `load(cwd, path)`, `expand` |
| `render.py` | `hitl/render.nim` | all HTML: `tag()` escaping by default, `inline`, `markdown`, `diff` |
| `brief.py` | `hitl/brief.nim` | the split, the briefs, their cache and prompts, `decisionId` |
| `work.py` | `hitl/work.nim` | sources, commit discovery, current code, `collect`, `codeTips` |
| `pages.py` | `hitl/pages.nim` | the item and index pages, `build`, `builtTips` |
| `drafts.py` | `hitl/drafts.nim` | saved decisions: decide, withdraw, check, delivery |
| `companion.py` | `hitl/companion.nim` | the companion's setup: restricted mode, profile, prompt, dirs |
| `serve.py` | `hitl/serve.nim` | the server: pages, `/config.js`, the five POST actions, the chat |
| `hitl.py` | `hitl.nim` | the CLI: `brief`, `serve`; prints an error result as an exit message |

## How the code is written

- **Names: Nim camelCase, plain words.** The Python names in camelCase
  (`read_jsonl` -> `readJsonl`, `git_writes` -> `gitWrites`, `pick_session` ->
  `pickSession`). Short, plain names a shell script would use; no clever
  abbreviations, no `T`/`P` prefixes. Types Capitalized and plain (`Session`,
  `Agent`, `Commit`, `Draft`, `Brief`). The one exception: the fields of the
  record types `toJson` writes are the files' keys (`open_decisions`).
- **Simple, flat code.** Plain procs, objects, `seq`, `string`, `Table`. No
  macros, no templates or generics unless the code would be worse without
  them (`state.quote` is generic, as `toJson` is). Distinct types and enums
  only where they stop a real mix-up. Only what another module or a test
  uses is exported.
- **Regular comments.** Every exported proc, and every private one but a
  one-line helper, has a `##` doc comment saying what it does and returns. Inside, a `#` comment says *why* at every step that is
  not obvious, the way the Python does. Section headers between groups of
  procs, like the Python's `# ---- name` lines.
- **Errors: what Nimony offers, no exception types of our own.** No `ref
  object of Exception`, no hierarchy (the `nimony-error-handling` skill). A
  failure the user is told about (no session matches, a bad config file, an
  unreadable ledger, no working directory) is a value: the routine returns
  `Result[T, string]` with the message, and each layer passes it up; only
  `hitl.nim` prints `hitl: <message>` and exits 1. Absence is `Opt[T]`.
  Stdlib I/O raises the system `ErrorCode`: it is caught at the first routine
  that has an answer, and a routine is `{.raises.}` only where the failure
  really must cross layers (`writeAtomic`, `writeJson`, `newCompanionId`).
- **JSON.** Files and values are written with std/json's `toJson` and `$`
  (`state.quote`), from record types where the shape is an object. Joined by
  hand only where `toJson` cannot express the shape, with a comment saying
  why: a `Table` as an object (the ledger's `seen`, `tips.json`;
  bug-reports/112) and `null` (a draft's `code` and `brief`, the server's
  replies). Read with `parseJson`, member by member.
- **Skills.** The Nimony skills in `~/.local/share/nyx/skills/` are the guide:
  `nimony-error-handling`, `nimony-nim2-differences`, `nim-style-guide`,
  `nim-doc-comments`, `nim-code-organization`, `nim-string-parsing`,
  `nim-testing` and `nim-porting`.
- **Standard library only.** No kroki, no hashi, no other third-party code:
  std/json, std/httpserver, std/osproc, std/rex, std/smartcli, std/paths, and
  so on.
- **No workarounds.** When the standard library lacks a function or has a
  bug, the code is the natural, clean code with what it provides, and the
  inaccuracy is accepted: no hand-rolled replacement, no scanner to dodge a
  regex bug, no fallbacks. The spot is marked
  `# GAP: <what is inaccurate>, because <what std lacks or the bug report>`,
  with one row in **Gaps** below; every comment has a row and every row a
  comment. If the natural code does not compile, the simplest form that does,
  with the same comment.
- **Same behaviour as the Python where the stdlib allows it.** The model
  prompts' text is identical to the Python's. Page HTML matches the Python's
  byte for byte where the stdlib allows; differences go under Gaps.

## Build and tests

- `./build.sh` builds `bin/hitl`; `./build.sh FILE.nim OUT [-- flags]` any
  other program. It uses the toolchain copy in `nimcache/toolchain` (never
  writes into `~/Projects/nimony`, bug-reports/108); `./build.sh --toolchain`
  makes or refreshes the copy.
- **Never run two builds at once** (bug-reports/08: concurrent builds fail).
- Tests: one `tests/t<module>.nim` per module, ported from the Python tests
  for that module; shared helpers in `tests/fixtures.nim` (throwaway git
  repositories and transcripts, the state and config directories in a temp
  directory) and a fake `claude` in `tests/fakeclaude.nim`. `tests/run`
  builds and runs them all, debug and release; `tests/run tpages` only some.
- Real data: build the pages of a real session with the port and with the
  Python into two `scratch/` directories, both reading a copy of
  `~/.local/state/hitl` (never the real one), and compare them byte for byte.
- Nimony bug reports are in `~/Projects/bug-reports/` (one folder each).

## Progress

| Layer | Modules | State |
|---|---|---|
| 1 | state, session, config | done |
| 1 | render | done |
| 2 | brief, work | done |
| 3 | drafts, companion | done |
| 4 | pages | done |
| 4 | serve, CLI | done |
| 5 | consistency pass, docs | done |

## Gaps

What is inaccurate because the standard library lacks something or has a
bug, left for another day.

| Where | What is inaccurate | Because |
|---|---|---|
| `session.run` | a child that keeps stdout or stderr open is not stopped at the timeout, only once it closes them (ProcessTests' timeout test passes, after 30 s); a child that fills its stderr pipe while stdout is read waits for ever | std/osproc has no `communicate` (bug-reports/120-osproc-has-no-communicate): stdout, then stderr are read to their end, then `waitForExit` gets the time left |
| `session.run` | a program that cannot be found or started runs and exits 127 instead of failing to start | std/osproc's fork + execve reports a failed exec as exit 127 |
| `config.load`, `brief.askModel`, `serve` (a POST body, the companion's answer) | why a file, a body or claude's output is not JSON is said in std/json's words, not Python's | that is the message std/json gives |
| `render.inline` | the text of **strong** and *emphasis* holds no `*` (`**a*b**`, `*a*b*` stay as written), *emphasis* may touch another `*` (`**a*` and `*a**` get one), and a non-ASCII character next to a `*` counts as a word character | std/rex has no lazy repeats and no lookaround: render.py's STRONG and EM are written without them, `\B` for "no word character before or after" |
| `render` | `\s` is ASCII white space and the control characters: a URL, a fence's language or emphasis runs over U+00A0 and other Unicode spaces, and stops at `\x01` | std/rex has no Unicode classes |
| `render` | text is stripped of Unicode white space except `\x1c`..`\x1f` | std/unicode's white space list leaves out the separators Python's `str.isspace()` counts |
| `render.inline` | a bare URL right after a non-ASCII digit (`٣`, `²`) is linked | std/unicode has no digit test (Python's `str.isalnum()`) |
| `render.markdown` | a list item numbered with non-ASCII digits (`٣. x`) is a paragraph | std/rex's `\d` is ASCII |
| `render.diff` | a C-quoted path with bytes that are not UTF-8 keeps them, where Python writes U+FFFD | std/unicode has no decoding with replacement |
| `state.collapse`: `brief` (`short`, `decisionId`, a new item's title), `drafts.decide` (question, option) | `\x1c`..`\x1f` do not separate words when white space is collapsed | std/unicode's white space list leaves out the separators Python's `str.split()` counts |
| `state.quote`: the ledger, the brief cache, a draft, the companion's settings | a control character other than `\b \f \n \r \t` in a title, key or brief is written raw, which is not JSON | std/json's `$` does not escape them (bug-reports/104-json-dollar-control-chars-unescaped) |
| `brief`: the ledger and the brief cache; `drafts.decide`: a draft (Python keeps non-ASCII text too); `companion.setup`: the settings | written on one line, not indented, and non-ASCII text as it is, not `\u`-escaped (both still JSON) | std/json has no pretty printer and no ASCII mode |
| `brief.generateAll` | the briefs' model runs go one after another, whatever `--jobs` says | runs started at once from std/parfor's `||` wait on each other for ever: std/osproc's children inherit each other's pipes on Linux (bug-reports/105-osproc-pipes-inherited-by-later-children) |
| `work.epoch` | only `YYYY-MM-DDTHH:MM:SS`, with a fraction, then `Z`, `±HH:MM` or no zone, is read (else 0, as for bad input), and a time with no zone is taken as UTC, not local time | std/times has no parse (bug-reports/119-times-cannot-parse-a-date) |
| `drafts` (`allDrafts`, `decide`, `withdraw`) | a draft number is ASCII digits only: `d٣.json` is no draft (Python's `\d` and `int()` take any Unicode digit), nor is one too big for an int | std/unicode has no digit test |
| `drafts.decide` | a decision id with non-ASCII letters or digits is refused (Python's `\w` takes them) | std/unicode has no digit test, std/rex's `\w` is ASCII |
| `pages.untimed` (the "From" line) | a clock time right after `:`, `.`, `/` or `-` (`x-10:01`) or right before `:` (`1:23:4` loses `1:23`) is taken out; `\s` and `\d` are ASCII | std/rex has no lookaround and no Unicode classes: `(?<![\w:./-])` and `(?![\w:])` are `\b` |
| `pages.untimed` | of separators in a row only the first is taken out: `(10:01, 10:05)` leaves `,)` where Python leaves `)` (seen on the test fixtures, not on the real session) | std/rex has no lookahead: `([(,;])\s*(?=[,;)])` is written `[(,;]\s*([,;)])`, keeping the separator it matched |
| `pages.updated` | a project name whose first letter's capital is two letters (`ß`) gets one | std/unicode maps one rune to one rune |
| `pages.build`, `pages.builtTips` | a page or tips.json item number is ASCII digits only: `i٣.html` is no page and is never deleted | std/unicode has no digit test |
| `serve.run` | the server listens on every interface, not on 127.0.0.1 only (the Host check and the token still hold) | std/httpserver's `listenHttp` takes no address (bug-reports/113-listenhttp-cannot-choose-listen-address) |
| `serve.run` | a port in use stops hitl with a failed assertion, not a message | std/ioring's `listenTcp` asserts that bind succeeds (bug-reports/109-listentcp-asserts-on-busy-port) |
| `serve` | a client that goes away before its answer is written stops the whole server (SIGPIPE) | std/httpserver neither ignores nor suppresses the signal (bug-reports/114-httpserver-sigpipe-kills-process-on-gone-peer) |
| `serve` | a refusal or a missing file (421, 403, 404, 501) has no body, where Python sends an HTML error page; files have no Last-Modified and are never a 304; a target that climbs above the pages (`/../x`) is a 400, not a 404 | std/httpserver has no error pages and no file handler, and refuses such a target itself |
| `serve` (every JSON reply) | non-ASCII text is written as it is, not `\u`-escaped as Python's `json.dumps` does, and control characters other than `\b \f \n \r \t` raw | std/json has no ASCII mode, and its `$` does not escape them (bug-reports/104-json-dollar-control-chars-unescaped) |
| `serve.run` (the browser) | `$BROWSER` is one command given the URL, else `xdg-open`; Python's webbrowser also reads a list of commands in `$BROWSER`, fills in `%s` and knows the desktop's browsers | Nimony's standard library has no browser module |
| `hitl.nim` | with no command the help follows `[Error] missing arguments` and hitl exits 1 (Python: the help alone, exit 0); a bad command line is told on stdout with the help and exit 1 (Python: stderr, the usage, exit 2); an option's value is given as `--port=N` or `--port:N`, not `--port N` | that is how std/smartcli parses |
