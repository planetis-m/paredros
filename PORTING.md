# Porting hitl to Nimony (the redo)

The port is redone from the current Python, module for module. The earlier
port is on branch `main` (read it with `git show main:hitl/core.nim` and
`git show main:PORTING.md`): use it for Nimony idioms and the bugs it met, not
for its structure.

## Source of truth

- The Python in `~/Projects/hitl`, branch `general` (read only: never edit it).
  `ARCHITECTURE.md`, `DESIGN.md` and `README.md` there describe the behaviour.
- `test_hitl.py` there is the behaviour to keep: each module's tests are ported
  with it.
- `companion.md`, `static/hitl.css`, `static/hitl.js`, `examples/` and
  `DESIGN.md` here are copies of the Python repository's; keep them identical.

## Modules

One Nimony module per Python module, with the same layers: a module imports
only from the ones above it, never below, and never inside a proc.

| Python | Nimony | What |
|---|---|---|
| `state.py` | `hitl/state.nim` | hitl's own files: `state()`, `writeAtomic`, companion fork ids |
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

- **Names: Nim camelCase, plain words.** Keep the Python names in camelCase
  (`read_jsonl` -> `readJsonl`, `git_writes` -> `gitWrites`, `pick_session` ->
  `pickSession`). Short, plain names a shell script would use; no clever
  abbreviations, no `T`/`P` prefixes. Types Capitalized and plain (`Session`,
  `Agent`, `Commit`, `Draft`, `Brief`).
- **Simple, flat code.** Plain procs, objects, `seq`, `string`, `Table`. No
  macros, no templates or generics unless the code would be worse without
  them. Distinct types and enums only where they stop a real mix-up.
- **Regular comments.** Every exported proc has a `##` doc comment saying what
  it does and returns. Inside, a `#` comment says *why* at every step that is
  not obvious, the way the Python does. Section headers between groups of
  procs, like the Python's `# ---- name` lines.
- **Errors: what Nimony offers, no exception types of our own.** No `ref
  object of Exception`, no hierarchy. Follow the `nimony-error-handling` skill. A
  failure the user is told about (no session matches, a bad config file, an
  unreadable ledger, no working directory) is a value: the routine returns
  `Result[T, string]` with the message, and each layer passes it up; only
  `hitl.nim` prints `hitl: <message>` and exits 1. Absence is `Opt[T]`.
  Stdlib I/O raises the system `ErrorCode`: catch it at the first routine
  that has an answer, and mark a routine `{.raises.}` only where the failure
  really must cross layers.
- **Skills.** The Nimony skills in `~/.local/share/nyx/skills/` are the
  guide for writing the code: read `nimony-error-handling`,
  `nimony-nim2-differences`, `nim-style-guide`, `nim-doc-comments`,
  `nim-code-organization`, `nim-string-parsing`, `nim-testing` and
  `nim-porting` before writing, and any other one that fits the task.
- **Standard library only.** No kroki, no hashi, no other third-party code:
  std/json, std/httpserver, std/osproc, std/rex, std/paths, and so on.
- **No workarounds.** When the standard library lacks a function or has a bug,
  write the natural, clean code with what it provides and accept the
  inaccuracy. Do not hand-roll a replacement, do not add a scanner to dodge a
  regex bug, do not add fallbacks. Mark the spot with a comment:
  `# GAP: <what is inaccurate>, because <what std lacks or the bug report>`,
  and add one row to **Gaps** below. If the natural code does not compile,
  use the simplest form that does, with the same comment.
- **Same behaviour as the Python where the stdlib allows it.** The model
  prompts' text is identical to the Python's. Page HTML matches the Python's
  where the stdlib allows; differences go under Gaps.

## Build and tests

- `./build.sh FILE.nim OUT [-- flags]` builds with the toolchain copy in
  `nimcache/toolchain` (never writes into `~/Projects/nimony`). `./build.sh
  --toolchain` refreshes the copy.
- **Never run two builds at once** (bug-reports/08: concurrent builds fail).
- Tests: one `tests/t<module>.nim` per module, ported from the Python tests
  for that module; shared helpers in `tests/fixtures.nim` (throwaway git
  repositories and transcripts, the state and config directories in a temp
  directory) and a fake `claude` in `tests/fakeclaude.nim`. `tests/run`
  builds and runs them all, debug and release.
- Nimony bug reports are in `~/Projects/bug-reports/` (one folder each).
- Do not commit: the coordinator reviews and commits each layer.

## Progress

| Layer | Modules | State |
|---|---|---|
| 1 | state, session, config | done |
| 1 | render | done |
| 2 | brief, work | done |
| 3 | drafts, companion | done |
| 4 | pages | to do |
| 4 | serve, CLI | to do |
| 5 | consistency pass, docs | to do |

## Gaps

What is inaccurate because the standard library lacks something or has a
bug, left for another day.

| Where | What is inaccurate | Because |
|---|---|---|
| `session.run` | a child that keeps stdout or stderr open is not stopped at the timeout, only once it closes them (ProcessTests' timeout test passes, after 30 s); a child that fills its stderr pipe while stdout is read waits for ever | std/osproc has no `communicate` (bug-reports/120-osproc-has-no-communicate): stdout, then stderr are read to their end, then `waitForExit` gets the time left |
| `session.run` | a program that cannot be found or started runs and exits 127 instead of failing to start | std/osproc's fork + execve reports a failed exec as exit 127 |
| `config.load`, `brief.askModel` | why a file, or claude's output, is not JSON is said in std/json's words, not Python's | that is the message std/json gives |
| `render.inline` | the text of **strong** and *emphasis* holds no `*` (`**a*b**`, `*a*b*` stay as written), *emphasis* may touch another `*` (`**a*` and `*a**` get one), and a non-ASCII character next to a `*` counts as a word character | std/rex has no lazy repeats and no lookaround: render.py's STRONG and EM are written without them, `\B` for "no word character before or after" |
| `render` | `\s` is ASCII white space and the control characters: a URL, a fence's language or emphasis runs over U+00A0 and other Unicode spaces, and stops at `\x01` | std/rex has no Unicode classes |
| `render` | text is stripped of Unicode white space except `\x1c`..`\x1f` | std/unicode's white space list leaves out the separators Python's `str.isspace()` counts |
| `render.inline` | a bare URL right after a non-ASCII digit (`٣`, `²`) is linked | std/unicode has no digit test (Python's `str.isalnum()`) |
| `render.markdown` | a list item numbered with non-ASCII digits (`٣. x`) is a paragraph | std/rex's `\d` is ASCII |
| `render.diff` | a C-quoted path with bytes that are not UTF-8 keeps them, where Python writes U+FFFD | std/unicode has no decoding with replacement |
| `brief` (`short`, `decisionId`, a new item's title), `drafts.decide` (question, option) | `\x1c`..`\x1f` do not separate words when white space is collapsed | std/unicode's white space list leaves out the separators Python's `str.split()` counts |
| `brief`: the ledger and the brief cache; `drafts.decide`: a draft; `companion.setup`: the settings | a control character other than `\b \f \n \r \t` in a title, key or brief is written raw, which is not JSON | std/json's `$` does not escape them (bug-reports/104-json-dollar-control-chars-unescaped) |
| `brief`: the ledger and the brief cache; `drafts.decide`: a draft (Python keeps non-ASCII text too); `companion.setup`: the settings | written on one line, not indented, and non-ASCII text as it is, not `\u`-escaped (both still JSON) | std/json has no pretty printer |
| `brief.generateAll` | the briefs' model runs go one after another, whatever `--jobs` says | runs started at once from std/parfor's `||` wait on each other for ever: std/osproc's children inherit each other's pipes on Linux (bug-reports/105-osproc-pipes-inherited-by-later-children) |
| `work.epoch` | only `YYYY-MM-DDTHH:MM:SS`, with a fraction, then `Z`, `±HH:MM` or no zone, is read (else 0, as for bad input), and a time with no zone is taken as UTC, not local time | std/times has no parse (bug-reports/119-times-cannot-parse-a-date) |
| `drafts` (`allDrafts`, `decide`, `withdraw`) | a draft number is ASCII digits only: `d٣.json` is no draft (Python's `\d` and `int()` take any Unicode digit), nor is one too big for an int | std/unicode has no digit test |
| `drafts.decide` | a decision id with non-ASCII letters or digits is refused (Python's `\w` takes them) | std/unicode has no digit test, std/rex's `\w` is ASCII |
