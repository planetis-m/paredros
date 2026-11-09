# Porting hitl to Nimony

Status: **plan (checkpoint 1)**. Nothing is ported yet.

- Source: `~/Projects/hitl`, branch `general`, `cf055de`. Python 3.15, stdlib
  only. `ARCHITECTURE.md` and `DESIGN.md` there are locked and govern this port.
- Compiler: `~/Projects/nimony/bin/nimony`, nimony `fd9742bf` (upstream master
  `e4f161c0` is one commit ahead, in `src/nimony/exprexec.nim` only).
- Baseline: `python3 -B -m unittest test_hitl.py` runs 24 tests, all pass
  (run with `PYTHONDONTWRITEBYTECODE=1`, so nothing is written to the source).

The port keeps the observable behaviour: the CLI's commands, arguments and
output, every file written (paths, JSON shapes), the HTML pages, and the
server's endpoints, checks and replies. Known weak spots are ported as they
are (section 9). Where the port seems to need a spec change, it stops and asks
(section 11).

## 1. Build

Every build keeps the stdlib cache in this repo. Without `--stdcache` nimony
writes it into `~/Projects/nimony/stdcache/`, the user's checkout:

```sh
nimony c --stdcache:$PWD/nimcache/stdcache --nimcache:nimcache/<name> -o:$PWD/nimcache/<name>/<name> <file>.nim
scratch/build.sh <name> <file>.nim [flags]     # the same, for the proofs
```

`nimony.paths` puts `deps/kroki/src` and `deps/hashi/src` on the search path.

`--stdcache` is not forwarded to sub-compiles (`src/nimony/cli.nim:159-165`):
a `const` evaluated at compile time (seen with `staticRead`) builds into
`~/Projects/nimony/stdcache/bin/<key>/` anyway. Plugin builds (smartcli, rex
`re`, parfor `||`) probably do the same on their first build; not confirmed.
The port avoids const evaluation where it can. The first proofs of this
checkpoint, built before `--stdcache` was used, and these sub-compiles wrote
about 2,500 files into `~/Projects/nimony/stdcache/bin/{7w79i41, 8biiry1,
bd49uj1, gld97k1, ip9feq, s8gfd7}`; they were left in place.

## 2. Module map

Python's modules import each other in a cycle (`review` and `brief` import
`hitl`; `hitl` imports both lazily). Nim modules cannot, so the shared base
(transcripts, git, config, state paths, the data types) moves into
`hitl/core.nim` and the rest stacks on it. Responsibilities stay where
ARCHITECTURE.md section 3 puts them.

```
hitl.nim            CLI (smartcli) and the cmd* procs            <- hitl.py commands
hitl/core.nim       state paths, config, transcript adapter,     <- hitl.py library part
                    git(), process runner, agents, data types
hitl/briefs.nim     split, briefs, ledger, cache, model calls    <- brief.py
hitl/review.nim     sources, commits, current code, collect,     <- review.py data + build
                    build, renderDiff
hitl/html.nim       esc, inline, markdown, template glue         <- review.py markdown part
hitl/pages.nim      the pages, as a stdtmpl source filter        <- review.py page builders, CHAT_HTML
hitl/drafts.nim     decide, withdraw, re-check, delivery         <- hitl.py directions part
hitl/companion.nim  profile, prompt, terminal and served runs    <- hitl.py companion part, serve.Companion
hitl/serve.nim      hashi server, routing, the security checks   <- serve.py
static/hitl.css, static/hitl.js, companion.md                    copied verbatim; read at run time from the
                                                                 directory above the binary, as Python reads them
                                                                 beside its source
examples/nimony.hitl.json                                        copied verbatim
tests/                                                           <- test_hitl.py (section 8)
```

Budget, in the spirit of ARCHITECTURE.md 8.2: the Python is 1,680 lines
(hitl 604, review 599, brief 316, serve 161). The port aims at the same
order: no module over 700 lines, about 1,900 lines without tests and
templates. Proc names are the Python names in camelCase.

### 2.1 Function map

| Python | Nimony |
|---|---|
| `hitl.CONFIG`, `PROJECTS`, `OUT`, `state()`, `COMPANIONS` | `core.claudeDir()`, `projectsDir()`, `stateRoot()`, `state(kind, sid)`, `companionsFile()`: procs that read the environment when called (globals are restricted, and the tests set the variables) |
| `read_jsonl`, `tool_uses`, `assistant_texts`, `is_human`, `text_of` | `core.readJsonl` (kroki `jsonLines` into `Rec`), iterators `toolUses`, `assistantTexts`, `isHuman`, `textOf` |
| `sessions`, `pick_session`, `companion_ids`, `new_companion_id` | `core.sessions`, `pickSession`; `companion.companionIds`, `newCompanionId` (uuid4 from `sysrand`) |
| `load_config`, `DEFAULTS`, `CONFIG_FILE`, `expand` | `core.loadConfig(cwd, configFile)` (the `--config` value is passed down, not a global), `Config` object, `expand` |
| `short`, `ago`, `describe_call`, `workdir_of`, `final_report` | `core.short`, `ago`, `describeCall`, `workdirOf`, `finalReport` |
| `git`, `git_summary` | `core.git(wd, args, timeoutMs): Opt[string]` on `core.run`; `gitSummary` |
| `agents`, `state_of`, `resolve` | `core.agents` (label by the shortest differing worktree part), `stateOf`, `resolve` |
| `session_cwd`, `decision_id` | `core.sessionCwd`, `decisionId` (sha1) |
| `cmd_status`, `cmd_show`, `cmd_review`, `cmd_brief`, `cmd_companion`, `cmd_serve`, `cmd_directions`, `main` | `hitl.nim`: one proc per command, dispatched on smartcli's `CliCommand` enum |
| `companion_setup`, `GIT_READS`, `GIT_WRITES`, `GH_WRITES` | `companion.companionSetup`, the same lists as `const` arrays |
| `read_draft`, `all_drafts`, `decide`, `withdraw`, `drafts_state`, `check`, `stale_facts`, `delivered_at` | `drafts.*`, same names; a draft is an object with `DraftId` (distinct) |
| `review.epoch`, `esc`, `turns`, `git_calls`, `session_commits`, `sources`, `current_code`, `collect`, `code_tips` | `review.*`, same names; `epoch` parses ISO 8601 by hand (std/times has no parser) |
| `review.INLINE`, `inline`, `markdown`, `render_diff` | `html.inline`, `html.markdown`, `review.renderDiff`, hand-written scanners where the regexes use lookaround or lazy repeats (proof in 4.4) |
| `svg`, icons, `CHAT_HTML`, `page`, `plural`, `untimed`, `source`, `qact`, `opt_button`, `decision_html`, `items_html`, `section_html`, `item_page`, `LANES`, `card`, `updated`, `index_page` | `pages.nim` (stdtmpl), with `Lane` and `Section` enums |
| `review.write`, `built_tips`, `build` | `review.writeAtomic`, `builtTips`, `build` |
| `brief.SECTIONS`, `SPLIT`, `PROMPT`, `entries`, `SPLIT_SCHEMA`, `BRIEF_SCHEMA`, `prompt_for` | `briefs.Section` enum with titles; prompts as `const` strings; the two schemas as the exact JSON text `json.dumps` produces (byte-equal argv) |
| `ask_model`, `write_json`, `ledger_path`, `load_ledger`, `fingerprint`, `split` | `briefs.askModel`, `writeJson`, `ledgerPath`, `loadLedger`, `fingerprint`, `split` |
| `gather`, `cache_path`, `load`, `parse`, `generate`, `generate_all` | `briefs.*`; `generateAll` runs at most `--jobs` `claude` children at once through `core.runAll` |
| `serve.ASK`, `Companion`, `server`, `run` | `serve.nim`: hashi routes and a before-middleware; the companion's fork id and lock in a `Guarded` value |

## 3. Library choices (provisional)

**All third-party and pattern choices below are provisional** until the
separate library review is done. Each one is backed by a program in
`scratch/` (gitignored) that compiles and runs on hitl-shaped input.

| Need | Choice | Program and evidence | Limits found |
|---|---|---|---|
| CLI | std/smartcli `cliapp` | `scratch/cli.nim`: the spec in section 5 parses every command | option values only with `=`/`:`; no default command (section 5) |
| JSON, transcripts | kroki `jsonLines` + custom `readJson` | `scratch/transcript.nim` vs `transcript.py` on the real 10 MB transcript of session 26c3c765: 4,658 records, 0 bad, 572 user, 71 human, 366 tool uses, 236,363 text code points, identical to Python; 37 ms vs 64 ms | none; a reader per record type (about 50 lines) reads mismatched field types as absent, as Python's `.get` does |
| JSON, state and model output | kroki | `scratch/state.nim`: ledger round trip keeps `seen` in insertion order (Nimony's `Table` is ordered); brief entries kept as `RawJson` so the cache keeps exactly the model's keys, read through a typed view with `Opt[int]` for an absent `recommended`; `structured_output` as `Opt[RawJson]`; POST `item` as number or numeric string; config with unknown keys refused | the unknown-key error names a byte, not the key: the config reader names it itself; kroki writes compact JSON, Python `indent=1` and `ensure_ascii` (section 7) |
| HTTP server | hashi | `scratch/server.nim` + `server_test.sh`: listens on `127.0.0.1` only, port 0 reported by `onBound`; Host check 421 (also without a port), token and Origin 403, built files 200/404, `/../` refused 400, JSON POST parsed and answered, bad JSON 500 with a message | logs 4xx/5xx to stderr by default (silenced with a no-op `setLogCallback`); `stopServe` is once per process (server tests get their own process) |
| HTML pages | stdtmpl source filter | `scratch/indexpage.nim` + `tmpl.nim`: the index of 10 items built from the real briefs is **byte-identical** to Python's (5,375 bytes) | every data line ends in `\n`; the glue in `scratch/html.nim` drops it from literals only (4.3); type sections cannot live in a filter file |
| Patterns | std/rex for deterministic ones, strutils scanners for the rest | `scratch/rex_corpus.nim` vs `rex_corpus.py` on 3,051 real Bash commands: `CD_RE` and `GITC_RE` findall identical; `GIT_WRITE` identical with a hand scan | `\b` after a repetition never matches (bug 106); lookaround, lazy repeats and `$1` replacement are not in rex |
| Processes | std/osproc + one `poll` loop | `scratch/procs.nim`: argv without a shell, cwd, 3 MB through stdin and stdout without deadlock, stderr apart, exit codes, a 500 ms timeout kills `sleep 10`, a missing program gives 127 | parent pipe ends leak into later children (bug 105): set close-on-exec after each start; no `poll` in std/posix (declared with `importc`) |
| Parallel briefs | osproc `runAll(jobs, parallel)` | 6 fake `claude` runs of 1 s, 4 at a time: 2.0 s, results in job order | std/parfor (`scratch/parbriefs.nim`) also works (1.0 s) but runs all 6 at once: it sizes by the pool, so `--jobs 4` is not honoured; each chunk would also block a pool worker in `waitpid` |
| Hashes, token | std/crypto/sha2, std/sha1, std/crypto/sysrand, std/base64 | `scratch/ids.nim`: brief `inputs` and decision ids equal Python's; token is 32 url-safe chars like `secrets.token_urlsafe(24)` | `sha1`'s `$` is upper case: lower it |
| Paths, env, files, time | std/paths, dirs, files, envvars, tempfiles, times | used in the proofs | std/times has no `format`/`parse` and `now()` is UTC: build `YYYY-MM-DD HH:MM` from `local(getTime())` by hand (Python's `strftime` is local time) |
| Static files | read at run time beside the binary | as Python does | `staticRead` was tried: a relative path fails with no message (bug 107), and its const-eval sub-compile writes into `~/Projects/nimony/stdcache` even with `--stdcache` (section 1), so it is not used |

## 4. Proofs in detail

### 4.1 Transcripts

`Rec` holds only what hitl reads: `type`, `timestamp`, `uuid`, `cwd`,
`promptSource`, `origin.kind`, and `message.content` as a string or a list of
blocks (`type`, `text`, `name`, `input.{command, description, file_path,
pattern, message}`). A field of another JSON type reads as absent, so a
record is never dropped for a field Python would ignore. A line that is not
JSON is skipped, as Python skips it.

### 4.2 State files

- Ledger `items.json`: `{items: seq[Item], seen: Table[string, int]}`.
- Brief cache `i<N>.json`: `{inputs, generated, model, brief}`; the brief's
  five lists are `seq[RawJson]`, so `brief.parse` keeps every entry as the
  model wrote it, and the pages read each through `Entry` with
  `recommended: Opt[int]`.
- `claude -p` output: `{result, session_id, structured_output: Opt[RawJson]}`;
  none means "the answer is not in the schema".
- POST bodies: one object type per endpoint; `item` accepts a number or a
  numeric string (`int(q["item"])`).

### 4.3 Templates

`pages.nim` starts with
`#? stdtmpl(conc = " &~ ", toString = "val", emit = "put result,") | standard`.
A literal piece loses the `\n` stdtmpl appends to each data line; a value from
`${...}` is passed through `val` into a distinct type and kept byte for byte.
This keeps the pages free of line breaks, as Python writes them, and keeps
the exact substrings the tests look for. The proof renders the index page
from the real briefs of session 26c3c765 (converted by `brief.parse`) and
compares it with Python's `review --out` of the same state: identical.

### 4.4 Inline markdown

`html.inline` replaces the four lookaround and lazy regexes of
`review.INLINE` with scanners, after the same `re.split` on code spans
(including Python's quirk that a part like ```` `` ```` becomes
`<code></code>`). On the 254 strings of the real briefs plus 15 edge cases
(nested and broken emphasis, links, autolinks after quotes and `=`, non-ASCII)
it matches Python on all 254 (`scratch/inline_corpus.*`).

## 5. CLI spec (smartcli)

```
hitl
Read-only views of a Claude Code session: one agent, or a coordinator and its subagents.

Usage: hitl [options] status|show|review|brief|companion|serve|directions

Commands:
  status              one line per agent (default)
  show AGENT          one agent: commits, last actions, final report
  review              build the HTML review pages and print the index path
  brief ITEM...       sort the session into work items and write their briefs (model runs, cached)
  companion ASK...    talk to a read-only fork of the session
  serve               serve the review pages with a chat to the companion
  directions ARG...   list your saved decisions (list), or re-check and copy one (send DRAFT)

Options:
  --session=S       session id prefix or project-name substring
  --config=FILE     config file (default: .hitl.json in the session's working directory)
  -n, --n=N         show: how many last actions (default 8)
  --open            review: open the index in the browser
  --out=DIR         review: output directory (default ~/.local/state/hitl/review/<session>)
  --model=M         brief: the model (default opus); companion, serve: the model
  --force           brief: rewrite even if the inputs did not change
  --jobs=N          brief: parallel brief runs (default 4)
  --port=N          serve: the port (default 8765)
  -h, --help        show this help and exit
```

What smartcli expresses exactly: every command, the positional `AGENT`, the
variadic `N...` (as `ITEM...`, since the field `n` is taken by `-n`) and
`ASK...`, every option. Checked in code after parsing, as argparse does in its
types: integers for `-n`, `--jobs`, `--port` and the items; `directions`
takes at most two words, the first `list` or `send`.

Where it differs from argparse (all confirmed with `scratch/cli.nim`):

1. **Option values need `=` or `:`.** `--session=x`, `--port=9000`, `-n=3`
   work; `--session x`, `--port 9000`, `-n 3` fail with "unexpected
   argument". argparse takes both.
2. **No default command.** `hitl` and `hitl --session=x` fail with "missing
   arguments"; argparse runs `status`. The generated parser calls
   `cliMissingArguments` for `cmdNone`.
3. **Options are global.** argparse takes `--session`/`--config` only before
   the command and `--model` etc. only after their command; smartcli takes any
   option anywhere. Only invocations argparse refuses become accepted.
4. **Help and errors.** The help text is the spec above, not argparse's;
   errors go to stdout as `[Error] ...` plus the help, exit 1 (argparse:
   usage to stderr, exit 2). No prefix abbreviations (`--sess`).
5. `directions ARG...` stands in for argparse's optional `action` with
   `choices` and optional `draft`.

Items 1 and 2 need the user's decision (section 11).

## 6. Server

- `serve(port, bindAddr = "127.0.0.1", onBound)`: 127.0.0.1 only (hashi's
  default `""` would also listen on `::1`).
- Before-middleware, in Python's order: a method other than GET, HEAD and POST
  gets 501 (`SimpleHTTPRequestHandler` has no handler for it); then the Host
  check, 421 unless `127.0.0.1:<port>` or `localhost:<port>` with the bound
  port.
- GET: `/config.js` (no-store), `/` and `/index.html` rebuild at most every 20 s
  (a lock around the build), every other path is a file in the output
  directory with Python's content types (`text/html`, `text/css`,
  `text/javascript`, `application/json`), `Last-Modified`, and 304 on
  `If-Modified-Since`. Missing files 404.
- POST `/drafts`, `/decide`, `/send`, `/withdraw`, `/ask`: 403 unless the token
  and Origin pass, then JSON replies with Python's codes (200, 404, 409, 500 with
  `{"error": ...}`); a bad request never takes the server down.
- 403/404/421/501 bodies: Python's `send_error` HTML page, same text.
- hashi's log goes to a no-op callback: Python's handler logs nothing.
- Handlers run on hashi's worker threads: the companion (one question at a
  time) and the rebuild time live behind locks (`hashi/guarded`).
- `serve` prints `serving http://127.0.0.1:<port>/  (Ctrl+C to stop)` and opens
  the browser like Python's `webbrowser`: `$BROWSER` if set, else `xdg-open`.
  Tests set `BROWSER=true`.

## 7. Details the port must match

- **Lengths and slices are in code points** where Python slices `str`:
  `short()`, `[:3000]`, `[-turn_limit:]`, `[:DIFF_LIMIT]`, `diff[:diff_limit]`,
  `[:400]` error texts, and `fingerprint` (a turn's text length is stored in
  `items.json`). Byte lengths would change prompts, cache keys and the ledger.
- **Invalid UTF-8** in transcripts and git output becomes U+FFFD
  (`errors="replace"`).
- **JSON files** are written atomically (temp file, rename). Python writes
  `indent=1` with `ensure_ascii`; kroki writes compact UTF-8. Same shapes and
  values; parity compares them parsed (section 10).
- **Times**: `generated` stamps and "updated 17:57" are local time;
  transcript times are ISO with `Z`, git's are epoch seconds.
- **Order**: `sessions()` newest first by (mtime, id, path, project);
  `agents()` by start, stable over the sorted file names; `Counter.most_common`
  breaks ties by first appearance; `dict` order everywhere is insertion order.
- **Python's `\s`, `\w`, `\d` and `str.split()`** are Unicode; the scanners
  treat every non-ASCII byte as a word character and split on ASCII
  whitespace. Differences only for non-ASCII spaces and digits; listed as
  found.
- **`companion.md`** is filled with Python's `str.format`; the port replaces
  the same named fields.

## 8. Tests

`test_hitl.py`'s 24 tests become Nimony tests in `tests/`, one block per test,
labelled with the Python name (nim-testing):

| Python class | Tests | Nimony file |
|---|---|---|
| ViewTests | 2 | `tests/tviews.nim` |
| WorkItemTests | 4 | `tests/titems.nim` |
| ConfigTests | 5 | `tests/tconfig.nim` |
| ReviewTests | 9 | `tests/treview.nim` |
| SecurityTests | 2 | `tests/tsecurity.nim` |
| ServerTests | 2 | `tests/tserve.nim` (its own process: `stopServe` is once per process) |

- Fixtures: the same throwaway git repos and transcripts as `setUpModule`,
  made by one shared helper (`tests/fixtures.nim`) under a temp directory.
- Environment, set before anything runs: `XDG_STATE_HOME` and
  `CLAUDE_CONFIG_DIR` in the temp directory, `HITL_NO_CLIPBOARD=1`,
  `BROWSER=true`, and `PATH` starting with a fake `claude`. Nothing touches
  `~/.local/state/hitl`, `~/.claude` or the clipboard.
- The fake model: Python patches `brief.ask_model` in process; the port has no
  such seam, so the fake is a small program on `PATH` (`tests/fakeclaude.nim`)
  that records its argv and stdin to files and answers from a plan file named
  in an environment variable, using the same handle rules as `fake_model`. The
  tests read the recorded prompts where Python reads `ask.calls`.
- `test_the_page_script_parses` runs `node --check` on `static/hitl.js` when
  node is installed, as in Python.
- Every test runs in debug and `-d:release`.

## 9. Preserved behaviour and suspicious spots

| ID | Source | Behaviour | Status |
|---|---|---|---|
| B1 | `review.py:58` `OWN_WINDOW = 120`, reflogs of every worktree where the session committed | commit discovery can take another session's commit inside the window | preserved; fix pending the user's decision |
| B2 | `serve.py:69` `Handler` | `do_HEAD` is not overridden, so HEAD skips the Host check and serves built files' headers (no body) to any Host; `/config.js` by HEAD is 404 | preserved (unconfirmed): asked in section 11 |
| B3 | `serve.py:156` `run` | prints the port it was given, not the bound one (`--port=0` prints `:0/`) | preserved (unconfirmed) |
| B4 | `hitl.py:241` `agents` | an agent's task joins the `text` of every block, not only text blocks, unlike `text_of` | preserved (unconfirmed) |

Each gets a `# PORTBUG(Bn): ...` marker at its translated site.

## 10. Parity method

A harness in `tests/parity/` runs the Python and the Nimony `hitl` on the
same inputs and diffs what they print and write.

- Each case gets a fresh temp directory with its own `XDG_STATE_HOME`,
  `CLAUDE_CONFIG_DIR`, `HITL_NO_CLIPBOARD=1`, `BROWSER=true` and the fake
  `claude` with a fixed plan. Python runs on a copy of the inputs, the port
  on another, so neither sees the other's writes.
- Inputs: the fixture sessions of the tests (coordinator `SID`, single agent
  `SOLO`), and the real session 26c3c765 with its 74 subagents copied into the
  temp `CLAUDE_CONFIG_DIR` (repos it names are read, never written).
- Cases: `status`, `show <agent>` (and `-n`), `review --out`, `brief` (new,
  unchanged, `--force`, items, a failing model), `directions` list and send
  (fresh, stale, delivered), `companion` (the fake records argv and the
  settings file), `serve` (a scripted request list against both servers:
  status codes and parsed JSON bodies, page bytes), and error paths (no
  session, bad config, unknown draft).
- Compared: stdout, stderr, exit code, and every file under the state and
  `--out` directories.
- Normalization, each rule documented in the harness: the temp-dir prefix;
  the "updated HH:MM" line and `generated` stamps; the server token and port;
  JSON compared parsed (whitespace and `\u` escapes); CLI usage and parse-error
  text (section 5).
- Self-check first: Python against Python must give zero differences.
- Every remaining difference is classified (porting defect, preserved bug,
  intentional change, nondeterminism, harness defect) and listed in this file.

## 11. Questions for the user

1. **Option values (section 5, item 1).** Accept `--session=x` / `-n=3` only,
   or should the CLI keep `--session x`? The README's examples
   (`--session nimony`) and the companion's allowed commands use the space form.
2. **Default command (section 5, item 2).** `hitl` alone cannot run `status`
   with smartcli. Either `status` must be typed, or `hitl.nim` passes
   `cliapp(spec, args)` an explicit `status` when no command word is present,
   which is a small pre-step around the generated parser.
3. **The companion's allowed hitl commands (ARCHITECTURE 6.2).** The profile
   and `companion.md` name `python3 <hitl.py> --session <s> status|show|directions
   list`. The port has to name its binary, and with smartcli the `=` form:
   `<hitl> --session=<s> status`. This changes text the spec quotes.
4. **B2.** Keep HEAD exempt from the Host check, as Python does by accident?
5. **CLI errors and help (section 5, item 4).** Accept smartcli's stdout,
   exit 1 and generated help in place of argparse's?

## 12. Nimony bugs

| Report | What | Workaround in the port |
|---|---|---|
| `bug-reports/103-case-on-result-in-generic-proc` | `case r of Ok(v)` on a `Result` fails inside a generic proc | `isOk`/`get`/`error` in generic code |
| `bug-reports/105-osproc-pipes-inherited-by-later-children` | filed by the parallel library review; found here too (6 runs took 4 s instead of 2) | close-on-exec on the parent's ends after `startProcess` |
| `bug-reports/106-rex-word-boundary-after-repetition` | `\b` right after a repetition never matches | hand scan for `GIT_WRITE` |
| `bug-reports/107-staticread-relative-path-fails-silently` | `staticRead("x")` in a `const` fails with no message | not needed: static files are read at run time |

Not bugs: `addr s[i]` is refused on strings (SSO; `readRawData` and
`beginStore` instead), and nested type sections cannot sit in a stdtmpl file
(the filter re-indents by keyword, as in Nim).

## 13. Milestones

Each ends with its tests green in debug and release, and a commit on `main`.

1. **Plan** (this file). Commit.
2. **Core**: `core.nim` (state paths, config, transcripts, git, runner, agents),
   `status`, `show`; ViewTests, ConfigTests. Parity: status and show.
3. **Items and briefs**: `review.nim` data part (sources, commits, current code,
   collect), `briefs.nim`, the fake `claude`; WorkItemTests, the model-run
   security test. Parity: brief, ledgers and caches.
4. **Pages**: `html.nim`, `pages.nim`, `build`, `review` command; ReviewTests.
   Parity: every page byte for byte.
5. **Decisions and companion**: `drafts.nim`, `directions`, `companion.nim`,
   `companion` command; the draft and companion tests. Parity: drafts and
   settings.
6. **Server**: `serve.nim`; ServerTests. Parity: the request script.
7. **Parity**: the full harness, including the real session; zero differences
   or each one justified in this file.
8. **The Nimony way**, after parity: drop every Python quirk and use Nimony's
   own stdlib behaviour (string handling, paths, error handling, formatting).
   Parity is a check during the port, not something to keep. Where Nimony's
   behaviour differs from Python's in an output detail that ARCHITECTURE.md and
   DESIGN.md do not specify, keep Nimony's and list the difference here. No
   stringly typed code: enums for fixed sets (commands, sections, lanes, draft
   states, endpoints, agent states), objects instead of string-keyed tables,
   distinct types for session ids, item numbers and draft ids, `Opt` instead
   of `""` or `0` for "no value"; strings only where JSON, CLI arguments and
   HTML are read or written. Much of this is done from milestone 2 on where
   it is easy.

Throughout: no `std/sequtils` (plain loops that fill a result), and the
nimony-error-handling channels (`Opt` for absence, `{.raises.}` with
`ErrorCode` across layers, first-error state in the readers).
