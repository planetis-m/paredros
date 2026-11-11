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
| `state.py` | `hitl/state.nim` | hitl's own files: `state()`, `writeAtomic`, companion fork ids, `HitlError` |
| `session.py` | `hitl/session.nim` | transcripts (the only module that knows their format), agents, sessions, `run()` for child processes, `git()`, `gitWrites` |
| `config.py` | `hitl/config.nim` | the config as a value: `load(cwd, path)`, `expand` |
| `render.py` | `hitl/render.nim` | all HTML: `tag()` escaping by default, `inline`, `markdown`, `diff` |
| `brief.py` | `hitl/brief.nim` | the split, the briefs, their cache and prompts, `decisionId` |
| `work.py` | `hitl/work.nim` | sources, commit discovery, current code, `collect`, `codeTips` |
| `pages.py` | `hitl/pages.nim` | the item and index pages, `build`, `builtTips` |
| `drafts.py` | `hitl/drafts.nim` | saved decisions: decide, withdraw, check, delivery |
| `companion.py` | `hitl/companion.nim` | the companion's setup: restricted mode, profile, prompt, dirs |
| `serve.py` | `hitl/serve.nim` | the server: pages, `/config.js`, the five POST actions, the chat |
| `hitl.py` | `hitl.nim` | the CLI: `brief`, `serve`; turns `HitlError` into an exit message |

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
- **Errors.** One exception type, `HitlError` (state.nim), raised by every
  layer; only `hitl.nim` turns it into `hitl: <message>` and exit 1.
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
| 1 | state, session, config | to do |
| 1 | render | to do |
| 2 | brief, work | to do |
| 3 | drafts, companion | to do |
| 4 | pages | to do |
| 4 | serve, CLI | to do |
| 5 | consistency pass, docs | to do |

## Gaps

What is inaccurate because the standard library lacks something or has a
bug, left for another day.

| Where | What is inaccurate | Because |
|---|---|---|
