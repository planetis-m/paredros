# Porting hitl to Nimony

Status: **every command ported**, written as Nimony code rather than translated
Python. Toolchain: nimony `e3acab77`; all tests green in debug and release.

- Source: `~/Projects/hitl`, branch `general`, `cf055de` (Python 3.15).
  `ARCHITECTURE.md` and `DESIGN.md` govern this port; where the code needs a
  spec change, the user decides and the spec changes in the same commit.
- Byte-for-byte parity with Python is no longer a goal. The behaviour the specs
  define stays; every output difference the specs leave open is listed in
  section 8.

## 1. Build

```sh
./build.sh --toolchain                 # once: a copy of ~/Projects/nimony's bin, lib, src, doc
./build.sh                             # bin/hitl
./build.sh FILE.nim OUT [-- flags]     # any other program
tests/run [NAME...]                    # the tests, debug and release
```

`build.sh` compiles with the toolchain copy in `nimcache/toolchain/`, with
`--stdcache` in that copy. Plugins (smartcli, rex `re`) and compile-time
`const`s build their stdlib in `<toolchain>/stdcache` whatever `--stdcache`
says (bug 108), so with the user's checkout every build would write into
`~/Projects/nimony/stdcache`. `nimony.paths` puts `deps/kroki/src` and
`deps/hashi/src` on the search path.

## 2. Modules

The modules follow the data, not Python's files (`hitl.py`, `review.py`,
`brief.py`, `serve.py`).

```
hitl.nim            the CLI (smartcli): brief, serve
hitl/core.nim       the Desk (session, directory, config), state paths, the process
                    runner and git(), the transcript adapter, agents, sessions
hitl/items.nim      sources (turns, agents, commits), the ledger, the brief cache,
                    each item's current code: ItemId, SourceKey, Brief, WorkItem
hitl/briefs.nim     the split and the briefs: the two prompts and schemas, model runs
hitl/html.nim       escaping, the markdown subset, source lines without times,
                    lanes, diff files and hunks, the template glue
hitl/pages.nim      the pages, a stdtmpl source filter
hitl/review.nim     the page build
hitl/drafts.nim     decide, withdraw, the re-check, delivery: DraftId, DecisionKey, Stale
hitl/companion.nim  the companion's profile and prompt, the conversation the server keeps
hitl/serve.nim      the server (hashi): pages, /config.js, the five POST actions
static/hitl.css, static/hitl.js, companion.md   read at run time from the repository
                                                the binary was built in
tests/              fixtures, a fake claude, one file per area
```

Types carry the meaning strings carried in Python: `SessionId`, `ItemId`,
`DraftId` and `DecisionId` are distinct; a source key is an object of a
`SourceKind` and an id; the stale reasons, sections, lanes, record and block
kinds, brief results and POST actions are enums; absent values are `Opt`.
Strings remain only where JSON, CLI arguments, HTML and process I/O are read
or written.

## 3. Library choices

| Need | Choice | Why, and the limits found |
|---|---|---|
| CLI | std/smartcli `cliapp` | options take their value only after `=`; no default command (section 4) |
| JSON | kroki, decoding straight into the final types | custom `readJson`/`writeJson` overloads on the final types where a JSON name is not a Nim name (`open_decisions`, `session_id`, `ref`) or a key is typed (`SourceKey`); kroki's errors name a byte offset, not a key |
| HTTP server | hashi (`deps/hashi`) | std/httpserver crashes on a gone client (114); hashi binds 127.0.0.1 by argument and has a before-middleware for the Host, token and Origin checks |
| HTML pages | stdtmpl source filter | every data line ends in `\n`; the glue in `html.nim` drops it from literals only; type sections cannot live in a filter file |
| Patterns | std/rex, and scanners where a pattern needs lookaround or lazy repeats | `\b` after a repetition never matches (bug 106, D8) |
| Processes | std/osproc, used plainly | section 9 |
| Hashes, token | std/crypto/sha2, std/sha1, std/crypto/sysrand, std/base64 | |
| Paths, env, files, time | std/paths, dirs, files, os, envvars, tempfiles, times | std/times has no parser: transcript times are read field by field |

## 4. CLI

```
hitl
Review and decide on what a Claude Code session did: one agent, or a coordinator and its subagents.

Usage: hitl [options] brief|serve

Commands:
  brief ITEM...       sort the session into work items and write their briefs (model runs, cached)
  serve               build the review pages and serve them, with your decisions and a chat

Options:
  --session=S       session id prefix or project-name substring
  --config=FILE     config file (default: .hitl.json in the session's working directory)
  --model=M         brief: the model (default opus); serve: the companion's model
  --force           brief: rewrite even if the inputs did not change
  --jobs=N          brief: parallel brief runs (default 4)
  --port=N          serve: the port (default 8765)
  -h, --help        show this help and exit
```

`status`, `show`, `review`, `directions` and `companion` are gone (D10).
Integers for `--jobs`, `--port` and the items are checked after parsing (D7).
smartcli takes option values only after `=` or `:`, has no default command
(`hitl` alone prints the help), takes any option anywhere, and reports errors
on stdout with exit 1 (D1).

## 5. Server

- hashi's `serve(port, bindAddr = "127.0.0.1")`; port 0 picks a free one, and
  `serve` prints the port it bound (`serving http://127.0.0.1:<port>/`), then
  opens the browser (`$BROWSER`, else `xdg-open`; tests set `BROWSER=true`).
- State: the desk, output directory and token are a `Frozen` value set before
  serving; the bound port, the last build time and the busy flag are atomics;
  the companion's fork is a `Guarded` value.
- A before-middleware: 421 unless Host is `127.0.0.1:<port>` or
  `localhost:<port>` (HEAD too, D2); 403 for a POST to anything but the five
  actions, without the token, or with an Origin other than none or ours.
  hashi's per-request warnings are silenced (`setLogLevel(error)`).
- GET: `/config.js` (no-store); `/` and `/index.html` rebuild the pages at
  most every 20 s; other paths are built files with their content type, else
  404. hashi refuses `..` and other non-canonical targets with 400.
- POST `/drafts`, `/decide`, `/send`, `/withdraw`: JSON in and out, decoded
  into typed requests; a bad body or id is 400, a failed write 500, an
  unknown draft 404, a refused send 409 with the stale reasons.
- POST `/ask`: a passive handler. `claude` runs as a child; the handler is
  parked on the child's output pipe (`waitReadableUntil`), so hashi's worker
  thread goes on serving other connections. One question at a time: a second
  one while the first is answered gets 409.

## 6. Preserved behaviour (PORTBUG markers)

| ID | Source | Behaviour | Status |
|---|---|---|---|
| B1 | `review.py:58` `OWN_WINDOW = 120`, reflogs of every worktree where the session committed | commit discovery can take another session's commit inside the window | preserved (`items.nim`); fix pending the user's decision |
| B2 | `serve.py:69` `Handler` | `do_HEAD` is not overridden, so HEAD skips the Host check | changed, approved by the user: HEAD gets the Host check (D2) |
| B3 | `serve.py:156` `run` | prints the port it was given, not the bound one (`--port=0` prints `:0/`) | fixed: hashi reports the bound port and serve prints it |
| B4 | `hitl.py:241` `agents` | an agent's task joins the `text` of every block, not only text blocks | preserved (`core.agents`); pending decision |
| B5 | `hitl.py:341` `cmd_review` | `review --open` with a relative `--out` fails | gone with the `review` command (D10) |

## 7. Decisions

| ID | Decision | By |
|---|---|---|
| D1 | The CLI is smartcli as it is: options take their value after `=`; errors on stdout with exit 1; its generated help; `hitl` with no command prints the help | user |
| D2 | HEAD requests get the Host check too (B2) | user |
| D3 | The companion's rules that name hitl use the binary's absolute path, with and without `--session=<s>` | user |
| D4 | kroki for JSON, decoding straight into the final types (no raw, intermediate or wrapper types) | user |
| D5 | hashi for the server, after std/httpserver crashed on a gone client (114): `serve(port, bindAddr = "127.0.0.1")`, the checks as a before-middleware, `claude` off the request thread | user |
| D6 | No workarounds for Nimony bugs or stdlib gaps: natural code, a comment naming the bug report, the behaviour accepted until upstream fixes it (section 9) | user |
| D7 | Integer options that do not parse exit with `hitl: invalid value for <option>: <value>` | port |
| D8 | GIT_WRITE is written as `\bgit\b[^\n;&\|]*[^\w\n;&\|](?:commit\|...)\b`, the equivalent without a `\b` after the repetition (bug 106) | user |
| D9 | `build.sh` builds with a copy of the nimony toolchain in `nimcache/toolchain` (bug 108) | user |
| D10 | The CLI has two commands, `brief` and `serve`; `status`, `show`, `review`, `directions` and `companion` (with its terminal path) and their options, code and tests are removed. The companion runs only as the chat's `claude -p` fork; its profile allows no hitl command | user |
| D11 | Idiomatic Nimony over parity: Nimony's stdlib behaviour is kept where the specs leave an output open (section 8); the brief prompts stay byte-identical, so no cached brief is rewritten | user |

## 8. Accepted differences

Output details the specs leave open, where the port now differs from Python.

JSON files and replies:
- kroki writes compact JSON in field order; Python wrote `indent=1` with
  `ensure_ascii`.
- A cached brief writes every field of its types: `why: ""` on entries the
  model wrote without it, `recommended: null` when absent; the brief's keys
  in the order summary, `open_decisions`, then the four lists.
- `generated` is Nimony's ISO form of local time with its offset,
  `2026-11-09T17:57:00+01:00`; Python wrote `2026-11-09T17:57:00`.
- A ledger item's new sources are added in offer order (turns, agents,
  commits), not in the order the model listed their handles.
- `tips.json` is a list, `[{"item": 1, "tip": "..."}]`, not `{"1": "..."}`.
- `/drafts` lists each draft with its `code` and `brief` facts too (`null`
  when absent); a refusal from `/send` always carries `stale`, empty when the
  draft was delivered or is unknown.

Server:
- A malformed body, decision id or draft id is 400 with kroki's message
  (`JSON at byte 9: invalid value`); Python answered 500.
- A method other than GET, HEAD and POST is 405 (hashi); Python answered 501.
  Unknown POST paths stay 403.
- No `Last-Modified` and no 304: the pages are rebuilt and always sent whole.
- A second `/ask` while one is answered gets 409; Python queued it.

CLI and messages:
- Errors go to stdout through `quit`, Nimony's behaviour; Python wrote them to
  stderr. Messages name values plainly (`no session matches x`), without
  Python's `repr` quotes.
- A session whose transcript names no existing working directory is refused
  at start (`cannot find the working directory of session <s>`); Python fell
  back to the home directory for `brief`.

Reading:
- Invalid UTF-8 in transcripts and git output is kept as bytes; Python
  replaced it with U+FFFD.
- A transcript record whose known field has another JSON type than expected
  is skipped as unreadable (a tool's input fields stay tolerant). On two real
  sessions (4,684 and 5,156 records) the result is identical.
- Sessions with the same modification time are ordered by id alone.
- Reflog and transcript times are compared in whole seconds.
- An agent's working directory: an empty candidate (a path of only `/` and
  `.`) is skipped and the next one tried; Python stopped there with none.
- A draft's `code` and `brief` facts are checked against the item of its
  `decision` fact; the item number in each fact line is not read.

Pages:
- A diff is split into lines only at `\n`, `\r` and `\r\n`, not also at
  `\v`, `\f` and the Unicode line separators.
- Two backticks with nothing between stay literal text; Python made them an
  empty code span.
- In agent markdown, a line starting with `|` that is not a table is a
  paragraph; Python dropped it.
- Checked against the previous scanners on 1.1 million generated strings and
  the texts of the real briefs: no other difference in `inline`, `markdown`
  or the source lines.

## 9. Known issues

Nimony bugs and stdlib gaps the port meets. Per D6 the code is written the
natural way where it compiles, with a comment naming the report, and the
behaviour is accepted until upstream fixes it. Reports without a number are
new and wait for theirs.

| Report | Where it bites | Effect on hitl |
|---|---|---|
| `105-osproc-pipes-inherited-by-later-children` | `core.start`, `core.runAll`, the chat | each child gets its input and the end of it before the next starts; in the server a git child started while `claude` starts may hold its stdin a moment, which delays, never hangs (git reads no stdin) |
| `120-osproc-has-no-communicate` | `core.finish` | stdout is read to its end before stderr: a child that fills the stderr pipe (64 KB) first would wait for hitl |
| osproc's timeout (gap) | `core.finish` | `waitForExit(timeout)` runs after both pipes close, so a hanging child is not stopped |
| `106-rex-word-boundary-after-repetition` | `items.committing` | written with the non-word character `\b` stands for there (D8) |
| `108-const-eval-ignores-stdcache-option` | every build | `build.sh` uses a toolchain copy (D9) |
| `103-case-on-result-in-generic-proc` | `items.saveJson`, `briefs.answer` | `isOk`/`get` instead of `case` |
| `case-expression-opt-binding-must-be-discarded` | `core.pickSession`, `serve.listDrafts` | a `case` statement assigning a variable instead of a `case` expression |
| `enum-from-one-invalid-array-index-type` | `review.freshness` | month names indexed by `ord(month) - 1`, not by std/times' `Month` |
| `global-let-as-parameter-default-undeclared` | `tests/tserve.nim` `request` | `host = ""` meaning the server's own address |
| `paren-for-statement-finalir-assertion` | met in a scratch program only | |
| `74-sumtype-eq-discriminator-not-ordinalenum` | `drafts.drafts` | `==`/`!=` on two `Opt`s does not compile; compared through `isNone` and `get` |
| `122-strutils-has-no-count`, no `add` of a seq to a seq (gaps) | `pages`, `companion.askJob`, tests | counted from the parsed diff files; lists built with `add` in a loop |
| object `hash` is commented out in std/hashes (gap) | `items.SourceKey` | its own `hash` |
| the chat waits once for output | `serve.companionAnswer` | the handler is parked until `claude` first writes, then reads to the end; `claude -p --output-format json` writes its answer at the end, so the read does not block in practice |

## 10. Tests

`tests/run` builds hitl and the fake `claude`, then each `tests/t*.nim`, in
debug and release.

| File | What |
|---|---|
| `tconfig.nim` | the config file (Python's ConfigTests) |
| `titems.nim` | sources, the split, the briefs' inputs (WorkItemTests) |
| `treview.nim` | the pages (ReviewTests, the page parts of the others) |
| `tdrafts.nim` | drafts, the re-check, Undo, delivery, page identity, the companion's setup |
| `tsecurity.nim` | the model runs' tools and schema, the companion's profile (SecurityTests) |
| `tserve.nim` | the server: hosts, token and Origin, the pages, Copy's checks, the chat (ServerTests) |

- Fixtures (`tests/fixtures.nim`): throwaway git repositories and transcripts
  in a temp directory: a coordinator session and a single-agent session.
- Before anything runs: `XDG_STATE_HOME` and `CLAUDE_CONFIG_DIR` in the temp
  directory, `BROWSER=true`, `PATH` starting with the fake `claude`
  (`tests/fakeclaude.nim`), which records argv and stdin and answers from a
  plan file. Nothing touches `~/.local/state/hitl` or `~/.claude`; nothing
  uses the clipboard.
- `tserve.nim` runs `bin/hitl serve --port=0` and talks to it with curl.
