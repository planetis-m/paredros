# hitl: architecture

The Nimony port of hitl. The behaviour, the data model and the rules are the
Python version's (`~/Projects/hitl/ARCHITECTURE.md`, which also keeps the
review findings that led to them); this file says the same for the Nimony
code and marks where it differs. `DESIGN.md` governs the pages (look,
strings, behaviour); this file governs everything else; `PORTING.md` holds
the port's conventions and its Gaps: what the standard library cannot match
yet. To change what this file settles, get the user's approval first and
update it in the same commit.

## 1. Purpose and non-goals

hitl is a human-in-the-loop desk beside a running Claude Code session: one
agent or a coordinator with subagents, doing any kind of work. It reads what
the session already leaves behind (transcripts and git) and helps the human
understand the work and decide. It offers:

- review pages: one per work item, with a model-written brief (decisions for
  you, spec conflicts, needs another review, bug risks, decisions made) and
  the code;
- a read-only companion: a fork of the session the human can question;
- decision drafts: the human's saved answers, re-checked against current facts
  before the human copies them and pastes them into the session;

Non-goals:
- Controlling the session. hitl never sends, stops, resumes or launches
  anything in it. The only path into the session is the human pasting text.
- Burdening agents. No skills, hooks, protocol, files or extra reporting for
  them. They never know hitl exists.
- Writing to repositories, worktrees, transcripts, PRs or any upstream.
- Being a product: no accounts, no multi-user, no remote access (but see
  6.3: the Nimony server cannot yet refuse the network), no database, no
  plugins; the one build step is `./build.sh`.
- Tracking logistics (PRs, branches, CI) on the pages.

## 2. Settled decisions

These were decided with the user. Reopening one needs the user's approval.

| Topic | Decision |
|---|---|
| Dependencies | Nimony and its standard library, `git` and the `claude` CLI. No third-party Nimony code (the first port used kroki and hashi; the redo removed them), no database or npm. Where the standard library falls short, the code accepts the inaccuracy and records it (PORTING.md, Gaps). |
| Model calls | All through `claude -p` on the user's subscription. No other vendor or API: decision APIs (OpenAI's Decisions API, TypeSafe's Jev) were evaluated and rejected because the tasks are generative, need tool use and run rarely. |
| Structured output | Approved next step: `--json-schema` for the split and the brief, replacing regex JSON extraction. |
| Server | A minimal std/httpserver server with a Host check, a per-run token and an Origin check, used only for acting features (companion chat, saving, re-checking, copying). Static file mode stays for reading. It should bind 127.0.0.1 only; it cannot yet (6.3). |
| State | Plain files under `$XDG_STATE_HOME/hitl` (default `~/.local/state/hitl/`). |
| Config | Per project, JSON (`.hitl.json`), read with std/json. Replaces `.hitl.toml`/`tomllib`. |
| Agents | Never burdened (section 1). |
| Precompute | Everything that can be computed ahead is computed ahead (briefs, spec lines, recommendations). The companion does only live work. |
| UI | `DESIGN.md` is frozen and governs the pages. |

## 3. Components

One responsibility each, in layers: a module imports only from the layers
above it in this table, never from below, so there are no import cycles and
no imports inside procs. No module reaches into another's files directly;
they call each other's procs. Only `hitl.nim` exits the process. A failure
the user is told about is a `Result[T, string]` with the message, passed up
each layer: the CLI prints it as `hitl: <message>` and exits 1, the server
answers it as JSON. Absence is `Opt[T]`; standard-library I/O raises the
system `ErrorCode`, caught at the first routine that has an answer. There
are no exception types.

| Module | Responsibility |
|---|---|
| `hitl/state.nim` | hitl's own files: the state folder per session (`state()`), atomic writes, the list of companion forks, the repository the binary was built in (`appDir`, for `companion.md` and `static/`), and the text helpers every layer shares (`collapse`, `quote` for JSON text, `subGroup`). |
| `hitl/session.nim` | What hitl reads, read only: Claude Code's transcripts (the only module that knows their format: records, tool calls and their results, typed messages, agents, sessions), the one way to run a child process (`run()`: its own process group, killed whole on timeout), the git runner (`git()`, the only one), and the git commands a transcript ran that may make commits (`gitWrites`). |
| `hitl/config.nim` | The project's config (`load(cwd, path)`): a value, loaded once by the CLI and passed down; code given none loads the session's default. |
| `hitl/render.nim` | All HTML: `tag()` escapes text and attribute values unless a value is markup it built (`Html`, a distinct string) or a constant icon (`raw`); `inline` and `markdown` render a declared Markdown subset, and anything outside it stays as written; `diff` renders a unified diff by its hunk counts, names renames, mode changes and binary files, and past 600,000 characters shows whole files only and says how many it left out. No I/O. |
| `hitl/brief.nim` | Model work that can be precomputed: the split (sources into ledger items) and one brief per item, both cached; the prompts and schemas; the decision id. Owns the ledger and brief files, and declares the material's types (`Turn`, `Worker`, `Commit`, `Sources`, `WorkItem`, `Work`). |
| `hitl/work.nim` | The work as data: sources (turns, agents, commits) under stable keys, commits matched to the git calls that made them, each item's current code, and `collect`, which joins them with the ledger and the briefs. No model calls, no writes. |
| `hitl/pages.nim` | The item and index pages from `collect`, all HTML through `render`; `build` writes them to the output directory only. |
| `hitl/drafts.nim` | Saved decisions: write, read, withdraw, re-check, delivery detection. |
| `hitl/companion.nim` | The companion's setup: restricted mode, its permission profile, its system prompt, its directories. |
| `hitl/serve.nim` | The local server: serves the built pages, the token, and five POST actions that call `drafts`; holds the one companion conversation per run. Each connection runs on the thread pool; one question at a time goes to the companion. |
| `hitl.nim` | The CLI (std/smartcli: `brief`, `serve`): picks the session, loads the config, turns an error result into an exit message. |
| `companion.md` | The companion's system prompt (a template filled by `companion.setup`). |
| `DESIGN.md` | The page design spec (a copy of the Python's). |
| `static/hitl.css`, `static/hitl.js` | The pages' CSS and JS, copied beside the pages by `build` (copies of the Python's). |
| `tests/` | `t<module>.nim` per module (the Python's `test_hitl.py`), `fixtures.nim` (throwaway git repositories and transcripts in a temp directory), `fakeclaude.nim` (a fake `claude` put first on PATH), `run`. |
| `build.sh` | Builds with a private copy of the Nimony toolchain in `nimcache/toolchain`. |

Data flow:

```
 Claude Code (never written)                 git repos and worktrees (read only)
 ~/.claude/projects/<proj>/<sid>.jsonl        reflogs (log -g --all), rev-list, diff, log
   + <sid>/subagents/agent-*.jsonl|.meta.json           |
                 |                                      |
                 +---------------+----------------------+
                                 v
                session.nim  transcripts + git            config.nim
                   |
                   v
                work.collect   sources -> items (ledger) -> current code
                   |        ^
                   v        |  items.json, i<N>.json
                brief.nim split (claude -p) | brief per item (claude -p, Read/Grep/Glob)
                   |
                   v
                pages.build  -> review/<s>/index.html, i<N>.html    (file mode: read only)
                   |
                   v
                serve.nim :<port> (all interfaces) GET pages, /config.js (token)
                   |   POST /drafts /decide /send /withdraw -> drafts.nim -> directions/<s>/d<N>.json
                   |   POST /ask -> companion (claude -p --resume <sid> --fork-session, then --resume <fork>)
                   v
                human copies the re-checked text  -->  pastes it into the session
```

## 4. Data model

`<s>` is the first 8 characters of the session id. `$STATE` is
`$XDG_STATE_HOME/hitl`. All JSON files are written atomically (temp file,
then rename).

### 4.1 Sources and their keys

| Source | Key | Comes from |
|---|---|---|
| Turn | `turn:<uuid>` | the main transcript cut at each human-typed message: the human's text and everything the session said until the next one |
| Agent | `agent:<agent id>` | a subagent transcript: description (meta), task (first user message), final report (`SubagentHandback`, else last text) |
| Commit | `commit:<sha>` | reflog entries (every worktree's HEAD and every branch, read with one `git log -g --all` per repository) that made a commit while one of the session's committing git commands ran (its call to its recorded result, 2 s slack; 120 s when no result was recorded), still reachable from a ref; its agent is the transcript that ran the command |

Keys are stable for the life of the transcript and the repository. Commits
come from git, never from the model.

### 4.2 Work item and ledger

`$STATE/briefs/<s>/items.json`:

```json
{"items":[{"id":1,"title":"Parser accepts empty input","sources":["turn:u1","commit:ab12..."]}],"seen":{"turn:u1":412,"commit:ab12...":0}}
```

The port writes its JSON files on one line (std/json has no pretty printer)
where the Python indents them; each reads the other's.

- `id` is assigned by code (next free integer), never by the model, never
  reused, never renumbered.
- A source once in an item stays there. An agent or commit belongs to at most
  one item; a turn may belong to several or none.
- `seen` maps a key to its fingerprint (a turn's text length; 0 for agents and
  commits). Only keys whose fingerprint changed are offered to the next split.
- An item's current code: per repository (worktrees of one repository count
  as one), its newest commit plus every commit of the item that is an
  ancestor of it, shown as one diff per unbroken run. Its other commits are
  "earlier attempts": named to the brief, not shown on the page.
- The code tip: the sorted 12-character shas of the current code's head
  commits, comma-joined. It is derived, never stored except inside a draft fact.

### 4.3 Brief and its cache key

`$STATE/briefs/<s>/i<N>.json`:

```json
{"inputs": "<sha256(full prompt)[:16]>", "generated": "2026-11-09T17:57:00", "model": "opus",
 "brief": {"summary": "...",
           "open_decisions": [{"question": "", "reason": "", "spec": "", "source": "", "options": [], "recommended": -1}],
           "spec_conflicts": [{"text": "", "source": ""}], "needs_review": [...], "bug_risks": [...],
           "decisions_made": [{"text": "", "why": "", "source": ""}]}}
```

- The cache key `inputs` hashes the whole prompt: config text, the item's
  turns, agent reports, diff and earlier attempts. A brief is rewritten only
  when it changes, or with `--force`.
- Each list holds every entry that meets the bar, most important first. There
  is no cap and no count of left-out entries: nothing is hidden. Unknown keys
  are dropped on parse.
- A decision's id is `sha1(question with whitespace collapsed)[:10]`, so it
  is stable across rewrites that keep the question.

### 4.4 Drafts and their facts

`$STATE/directions/<s>/d<N>.json`:

```
{"item": 63, "did": "<decision id>", "question": "<question>", "option": "<the chosen answer>",
 "code": "<code tip the page showed>" or null, "brief": "<brief inputs hash the page showed>" or null}
```

The text pasted into the session is built from it, never stored:

```
#<item>: <question>
My decision: <answer>. (d<N>, approved by me)
```

- Drafts come only from saving on a page; saving is the approval. Older
  `d<N>.md` drafts (a header of fact lines) are not read: only three existed,
  in two old sessions (A.11).
- One draft per undelivered decision (`item:did`); saving again rewrites it.
  Undo renames it to `d<N>.withdrawn`, so a number is never reused.
- A draft is **delivered** when a human-typed message in the main transcript
  contains `(d<N>,`. Delivered drafts are never stale and never copied again.
- A draft is **stale** when what it recorded no longer holds: the item's code
  tip differs ("The code changed.") or the brief's `inputs` differs ("New
  evidence."). The page shows these reasons as the server gives them.
- The pasted text is a contract with `delivered_at` and with the human's
  session; it does not change without a migration.
- `/send` answers every Copy with the draft's state now, so the page repaints
  from it: out of date, already sent, or gone.

### 4.5 Companion state

| File | Content |
|---|---|
| `$STATE/companions` | session ids of companion forks, one per line, so a fork is never taken for the session |
| `$STATE/briefs/<s>/companion-settings.json` | the companion's permission profile, one per session, rewritten on each launch |
| `$STATE/scratch/<s>/` | files for the config's compare action, nothing else |
| in memory (`serve.Server`) | the fork's session id for this server run; one question at a time |

### 4.6 Pages

`$STATE/review/<s>/index.html` and `i<N>.html`,
beside `hitl.css`, `hitl.js` and `tips.json` (the code tips `/drafts` reads).
Disposable: rebuilt from items, briefs and git, each file written atomically;
a build deletes only pages of items that are gone. They carry, as data
attributes, exactly what an action needs: `data-item`, `data-did`,
`data-ref` (code tip), `data-brief` (brief inputs hash), `data-question`.

## 5. External boundaries

### 5.1 Claude Code transcripts (undocumented format; read only)

All knowledge of the format lives in `session.nim`. Assumed:
- Sessions: `$CLAUDE_CONFIG_DIR/projects/<project>/<sid>.jsonl`, the project
  name being the cwd with non-alphanumerics as `-`.
- Subagents: `<project>/<sid>/subagents/agent-<id>.jsonl` with an optional
  `agent-<id>.meta.json` (`description`, `finished`).
- One JSON record per line; unreadable lines are skipped.
- Records: `type` (`user`, `assistant`, others ignored), `timestamp` (ISO,
  `Z`), `uuid`, `cwd`, `message.content` (a string or a list of blocks with
  `type` `text` or `tool_use` {`name`, `input`}).
- A human-typed message: `type == "user"` and `origin.kind == "human"` or
  `promptSource == "typed"`.
- A final report: the `SubagentHandback` tool's `input.message`.
- Work directories are guessed from `cd`/`pushd`/`git -C` in Bash commands.

When the format changes, only this section changes, and the tests' fixtures
with it.

### 5.2 git (read only)

- Every call goes through `session.git()`: `git --no-optional-locks -C <dir>`,
  with a timeout, returning none on failure. Every child
  process, git and `claude`, goes through `session.run()`.
- Only reading subcommands: `rev-parse`, `rev-list`, `log` (also `-g --all`),
  `diff`, `merge-base --is-ancestor`, `worktree list`.

### 5.3 `claude` CLI

| Use | Call |
|---|---|
| Split, brief | `claude -p --model <m> --output-format json --tools Read,Grep,Glob --strict-mcp-config --json-schema <schema>`, prompt on stdin, no session persistence, cwd = the repository; the answer is `structured_output` |
| Companion | `claude -p --resume <sid> --fork-session --session-id <new> --settings <profile> --strict-mcp-config --append-system-prompt <companion.md> --add-dir ...` in the session's cwd; later questions `--resume <fork id>` |

Model output is data: parsed against a fixed shape, never trusted for
numbering, identity or paths.

### 5.4 Browser

- File mode (the pages `serve` built, opened as files): no server, read only;
  the scripts detect the missing `window.HITL` and leave every control inert.
- Served mode (`hitl serve`): the same pages plus `/config.js`, which sets
  `window.HITL.token`.
- Clipboard: `navigator.clipboard` in the page; when it fails, the text is
  shown for manual copying.

### 5.5 Config file

`.hitl.json` in the session's working directory, or `--config FILE`. All
keys optional; unknown keys are refused.

```json
{"spec": "doc/language.md", "reader": "a Nimony developer", "users": "people writing Nimony code",
 "compare": {"label": "Compare with Nim", "prompt": "...", "allow": ["{home}/Projects/Nim/bin/nim r --nimcache:{scratch}/cache"]}}
```

`{scratch}` and `{home}` are expanded in `compare`. Without a file, every
feature works; there are no Spec lines and no compare button.

## 6. Security and permissions

### 6.1 The read-only guarantee rests on

1. hitl's own code: it writes only under `$STATE`. It never opens a transcript or repository file
   for writing.
2. git: only reading subcommands, always `--no-optional-locks`, so no index
   lock is taken.
3. Model runs are constrained by permissions, not by prompts:
   - split and brief: Read, Grep and Glob are the only tools (`--tools`), no MCP;
   - the companion: the profile in 6.2.
4. Nothing hitl writes is read by the agents: drafts reach the session only
   when the human pastes them.

The user's own Claude Code settings merge with these profiles. Deny rules win
over the user's allows; allow rules do not. So every write-capable tool must
be denied or left out of the available tools, not merely left unallowed.

### 6.2 Companion permission profile

- `claude --restricted`: the user's, project's and local settings files are
  ignored (managed settings and `--settings` still apply), and the file tools
  reach only the working directories: the session's cwd, plus `--add-dir` for
  the transcripts, the briefs, its scratch folder and every worktree of the
  session's repository. Tools: Read, Grep, Glob, Bash, Edit, Write, Agent
  (`--tools`); no MCP servers (`--strict-mcp-config`).
- Allow: Read, Grep, Glob; `git --no-optional-locks` with `log`, `show`,
  `diff`, `status`, `rev-parse`, `blame`, `grep`, `ls-files`, `reflog show`,
  and the same without the flag except `status` (it may lock the index);
  `cat`, `head`, `tail`, `ls`, `wc`, `grep`, `diff` (not `rg`: `--pre` runs a
  command); Edit and Write only in its scratch folder (`Edit(//<abs path>/**)`:
  `//` marks an absolute path; a single `/` is relative to the settings file);
  the config's compare commands, with files in scratch only.
- Deny, as wildcard rules: options of allowed reads that write or run a
  command: `--output`, `git grep -O` / `--open-files-in-pager`, `--ext-diff`,
  `--textconv`.
- Everything else is refused: `-p` has nobody to ask. Claude Code itself also
  refuses output redirects and the writing part of a compound command. The
  chat lists what was refused under each answer (`permission_denials`).
- Checked against the real CLI on 2026-11-11 in a throwaway repository whose
  project settings allowed `touch`, `git commit`, Edit and Write: every
  allowed read ran, in the repository, a worktree and the transcripts; a file
  outside the working directories, `touch`, commits, `git -C`, `--output`,
  redirects and writes outside scratch were refused and left no file; a write
  and an edit in scratch ran; the Agent tool was there.
- It may start a fresh read-only reviewer for a second opinion; that reviewer
  inherits the same profile.

### 6.3 Server

- **Listens on every interface, not on 127.0.0.1 only**, on a fixed port
  (default 8765). The Python binds 127.0.0.1; std/httpserver's `listenHttp`
  takes no address (bug-reports/113), and the user keeps this as a recorded
  gap. So the server is reachable from the network: the Host check below
  stops browsers, not a client on the network, which can send its own Host,
  read the token from `/config.js`, read the pages and post decisions or
  questions, which run `claude` as the user. Do not run `hitl serve` on a
  network you do not trust until bug 113 is fixed; then bind 127.0.0.1 and
  drop this item.
- Answers only requests whose Host is `127.0.0.1:<port>` or
  `localhost:<port>` (DNS rebinding).
- A random token per run, served only in `/config.js`, required in the
  `X-HITL-Token` header of every POST. `/config.js` is refused when the
  browser marks the request as coming from another site (`Sec-Fetch-Site`
  other than `same-origin` or `none`): another site's `<script src>` passes
  the Host check and would otherwise run the file in its own page and read
  the token. Without the header (old browsers, curl) it is served; the
  Origin check below still refuses those POSTs.
- The companion's working directory and profile are set up once, at server
  start; a session without a working directory stops the server there.
- POSTs are refused unless Origin is empty or the server's own origin.
  No CORS, no OPTIONS handler, so cross-site pages cannot send the header.
- Five POST actions only: `/drafts`, `/decide`, `/send`, `/withdraw`, `/ask`.
  Every GET is a built file (pages, `hitl.css`, `hitl.js`, `tips.json`) or
  `/config.js`.
- Errors return JSON with a short message; a bad request never stops the
  server. A refusal or a missing file has no body (std/httpserver has no
  error pages). A client that goes away before its answer is written does
  stop it (SIGPIPE, bug-reports/114), and a port in use stops `hitl serve`
  with an assertion (bug-reports/109).

## 7. Invariants

These never break. A change that would break one needs the user's approval
and a migration.

1. **Read only.** hitl never writes to transcripts, repositories, worktrees,
   or anything upstream, and never sends anything to the session or its agents.
2. **Agents never know.** No files, hooks, skills or messages for them.
3. **Page identity is stable.** An item's number, once given, never changes,
   is never reused and never moves its agents or commits. A decision's id
   follows its question. Rewriting briefs or adding material changes neither.
4. **Numbers come from code.** The model proposes groupings and titles; code
   assigns numbers, validates handles and drops anything else.
5. **Approval is re-checked before use.** No draft text leaves hitl (page
   Copy) unless, at that moment, it is not delivered and every
   recorded fact still holds. `drafts.check` is the one check.
6. **Facts are the ones the human saw.** A draft records the code tip and the
   brief the human was looking at when they saved.
7. **Delivered is detected, not declared.** Only the session transcript says
   a draft was delivered; a delivered draft is never copied again.
8. **Briefs are a cache.** Deleting `$STATE/briefs/<s>/i*.json` loses only
   model spend; the ledger, though, is identity and is never regenerated.
9. **Pages are disposable.** Deleting `$STATE/review/` loses nothing.
12. **Nothing is hidden.** A brief keeps every entry that meets the bar, and
    the pages carry all of them. The index card shows the exact number of
    open decisions.
10. **Both modes work.** Every page reads correctly as a file; acting needs the
    server.
11. **Precompute first.** Anything a page shows comes from the build; the
    server's live work is limited to drafts, re-checks and the companion.

## 8. Rules for future changes

### 8.1 Needs the user's approval

- A new dependency, external program, vendor or network access.
- A new model call per item or per page view, or a change that rewrites
  every brief (a prompt or schema change), unless the user asked for it.
- A change to an identity scheme or file format in section 4, or to the
  draft text.
- Widening any permission profile, or a new server endpoint.
- Anything the agents could notice.
- A page change outside what `DESIGN.md` allows.
- A new config key.

### 8.2 Budgets

| What | Budget |
|---|---|
| Nimony, excluding tests and page CSS/JS | follows the Python's module for module (about 3,350 lines now); a module grows only with its Python module |
| Page CSS and JS | 700 lines together |
| Config keys | the current 4 (`spec`, `reader`, `users`, `compare`) |
| Model runs | one split per `hitl brief`, one brief per changed item; none on page view |
| Server actions | the five in 6.3 |

Growth past a budget needs an equal cut elsewhere or the user's approval.
Prefer deleting code to adding it.

### 8.3 Adding a config option without growing the core

A key is added only when the project, not hitl, holds the answer and no
generic default works. Then:
1. Add it to the Python first, then here: to `defaults()` with a default that
   leaves behaviour unchanged, and validate it in `config.load` (unknown keys
   stay refused).
2. Read it in exactly one place. It changes data (text in a prompt, a label,
   an allow list), never control flow across modules.
3. Document it in the README and in `examples/`.
4. No plugin hooks, no per-project code, no scripting in config.

### 8.4 Other rules

- Transcript-format knowledge stays in `session.nim`; git goes through
  `session.git()`.
- Behaviour changes are made in the Python first and ported; the two stay
  byte for byte the same on real sessions where the standard library allows.
- What the standard library cannot do yet is a GAP comment and a row in
  PORTING.md, never a workaround.
- State paths are computed in one helper, not rebuilt inline.
- New behaviour comes with a test on fixtures and the fake `claude`; tests never
  touch the real state directory or clipboard.
- Commit messages say what changed for the user.
