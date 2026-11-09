# hitl: architecture

Status: locked. Every change to the code follows this file. To do something
it does not allow, get the user's approval first and update this file in the
same commit. `DESIGN.md` governs the pages (look, strings, behaviour); this
file governs everything else. Where the two meet (endpoints, data attributes,
draft text), both apply.

---

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
  before the human copies them and pastes them into the session.

hitl is a browser GUI: `hitl serve` builds the pages and serves them with the
drafts and the chat; `hitl brief` starts the model runs, which cost money, only
when the human asks.

Non-goals:
- Controlling the session. hitl never sends, stops, resumes or launches
  anything in it. The only path into the session is the human pasting text.
- Burdening agents. No skills, hooks, protocol, files or extra reporting for
  them. They never know hitl exists.
- Writing to repositories, worktrees, transcripts, PRs or any upstream.
- Being a product: no accounts, no multi-user, no remote access, no database,
  no build step, no plugins.
- Tracking logistics (PRs, branches, CI) on the pages.

## 2. Settled decisions

These were decided with the user. Reopening one needs the user's approval.

| Topic | Decision |
|---|---|
| Dependencies | The Nimony standard library, two Nimony libraries (kroki for JSON, hashi for HTTP), `git` and the `claude` CLI. No frameworks, database or npm; one build step (`./build.sh`). No downloaded third-party binaries; Fedora packages are fine. |
| Model calls | All through `claude -p` on the user's subscription. No other vendor or API: decision APIs (OpenAI's Decisions API, TypeSafe's Jev) were evaluated and rejected because the tasks are generative, need tool use and run rarely. |
| Structured output | Approved next step: `--json-schema` for the split and the brief, replacing regex JSON extraction. |
| Server | A minimal hashi server on 127.0.0.1, with a per-run token and an Origin check, used only for acting features (companion chat, saving, re-checking, copying). Static file mode stays for reading. |
| State | Plain files under `$XDG_STATE_HOME/hitl` (default `~/.local/state/hitl/`). |
| Config | Per project, JSON (`.hitl.json`), read with kroki. Replaces `.hitl.toml`/`tomllib`. |
| Agents | Never burdened (section 1). |
| Precompute | Everything that can be computed ahead is computed ahead (briefs, spec lines, recommendations). The companion does only live work. |
| UI | `DESIGN.md` is frozen and governs the pages. |

## 3. Components

One responsibility each. No module reaches into another's files directly;
they call each other's functions.

| Module | Responsibility |
|---|---|
| `hitl.nim` | Entry point and CLI (`brief`, `serve`). |
| `hitl/core.nim` | The only adapter to Claude Code's transcript format and to git (`git()` is the one git runner). Config loading. State paths. The process runner. |
| `hitl/items.nim` | Turns transcripts + git into sources (turns, agents, commits) and work items with their current code (`workItems`). Owns the ledger and brief files and their types. Does no model calls. |
| `hitl/briefs.nim` | Model work that can be precomputed: the split (sources into ledger items) and one brief per item, both cached; the two prompts and schemas. |
| `hitl/companion.nim` | The companion's arguments and permission profile; the companion conversation the server runs. |
| `hitl/drafts.nim` | Drafts: write, read, withdraw, re-check, delivery detection. |
| `hitl/review.nim` | Renders the pages from items and briefs (`build`). Writes only the output directory. |
| `hitl/serve.nim` | The local server: serves the built pages, the token, and five POST actions that call `hitl` functions; runs the one companion conversation per run. No logic of its own beyond routing and the security checks. |
| `hitl/html.nim`, `hitl/pages.nim` | Escaping, the markdown subset, lanes and diff parsing; the page templates (a stdtmpl source filter). |
| `companion.md` | The companion's system prompt (a template filled by `companion.companionSetup`). |
| `DESIGN.md` | The page design spec. |
| `static/hitl.css`, `static/hitl.js` | The pages' CSS and JS, one file each, copied beside the pages by `build`. |
| `tests/` | Tests on throwaway git repos and fixture transcripts, with a fake model. |

Data flow:

```
 Claude Code (never written)                 git repos and worktrees (read only)
 ~/.claude/projects/<proj>/<sid>.jsonl        HEAD reflogs, rev-list, diff, log
   + <sid>/subagents/agent-*.jsonl|.meta.json           |
                 |                                      |
                 +---------------+----------------------+
                                 v
                hitl/core   transcript + git adapters, config
                   |
                   v
                items.workItems  sources -> items (ledger) -> current code
                   |        ^
                   v        |  items.json, i<N>.json
                briefs    split (claude -p) | brief per item (claude -p, Read/Grep/Glob)
                   |
                   v
                review.build  -> review/<s>/index.html, i<N>.html    (file mode: read only)
                   |
                   v
                serve    127.0.0.1:<port>   GET pages, /config.js (token)
                   |   POST /drafts /decide /send /withdraw -> hitl drafts -> directions/<s>/d<N>.md
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
| Commit | `commit:<sha>` | HEAD reflog entries that made a commit, in each worktree where the session ran a committing git command, within 120 s after such a call, still reachable from a ref |

Keys are stable for the life of the transcript and the repository. Commits
come from git, never from the model.

### 4.2 Work item and ledger

`$STATE/briefs/<s>/items.json`:

```json
{"items": [{"id": 1, "title": "Parser accepts empty input", "sources": ["turn:u1", "commit:ab12..."]}],
 "seen": {"turn:u1": 412, "commit:ab12...": 0}}
```

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
           "open_decisions": [{"question": "", "options": [], "recommendation": "", "spec": "", "source": ""}],
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

`$STATE/directions/<s>/d<N>.md`:

```
facts:
- decision <item>:<did>
- option <the chosen answer>
- code <item> <code tip the page showed>
- brief <item> <brief inputs hash the page showed>
---
#<item>: <question>
My decision: <answer>. (d<N>, approved by me)
```

- Drafts come only from saving on a page; saving is the approval. Files
  without a `decision` fact (old companion drafts) are ignored.
- One draft per undelivered decision (`item:did`); saving again rewrites it.
  Undo renames it to `d<N>.withdrawn`, so a number is never reused.
- A draft is **delivered** when a human-typed message in the main transcript
  contains `(d<N>,`. Delivered drafts are never stale and never copied again.
- A draft is **stale** when any fact no longer holds: the item's code tip
  differs or the brief's `inputs` differs.
- The text format is a contract with `delivered_at` and with the human's
  session; it does not change without a migration.

### 4.5 Companion state

| File | Content |
|---|---|
| `$STATE/companions` | session ids of companion forks, one per line, so a fork is never taken for the session |
| `$STATE/briefs/<s>/companion-settings.json` | the companion's permission profile, one per session, rewritten on each question |
| `$STATE/scratch/<s>/` | files for the config's compare action, nothing else |
| in memory (`companion.Companion`) | the fork's session id for this server run; one question at a time |

### 4.6 Pages

`$STATE/review/<s>/index.html` and `i<N>.html`, built by `hitl serve`,
beside `hitl.css`, `hitl.js` and `tips.json` (the code tips `/drafts` reads).
Disposable: rebuilt from items, briefs and git, each file written atomically;
a build deletes only pages of items that are gone. They carry, as data
attributes, exactly what an action needs: `data-item`, `data-did`,
`data-ref` (code tip), `data-brief` (brief inputs hash), `data-question`.

## 5. External boundaries

### 5.1 Claude Code transcripts (undocumented format; read only)

All knowledge of the format lives in `hitl/core.nim`'s transcript section. Assumed:
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

- Every call goes through `core.git()`: `git --no-optional-locks -C <dir>`,
  with a timeout, returning `None` on failure.
- Only reading subcommands: `rev-parse`, `rev-list`, `reflog show`, `log`,
  `diff`, `merge-base --is-ancestor`, `status --porcelain`, `branch
  --show-current`.

### 5.3 `claude` CLI

| Use | Call |
|---|---|
| Split, brief | `claude -p --model <m> --output-format json --tools Read,Grep,Glob --strict-mcp-config --json-schema <schema>`, prompt on stdin, no session persistence, cwd = the repository; the answer is `structured_output` |
| Companion | `claude -p --resume <sid> --fork-session --session-id <new> --settings <profile> --strict-mcp-config --append-system-prompt <companion.md> --add-dir ... --output-format json`, prompt on stdin, cwd = the session's; later questions `--resume <fork id>` |

Model output is data: parsed against a fixed shape, never trusted for
numbering, identity or paths.

### 5.4 Browser

- File mode (the built pages opened as files): pages work without a server
  and are read only; the scripts detect the missing `window.HITL` and leave
  every control inert.
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

- Allow: Read, Grep, Glob; `git --no-optional-locks` with `log`, `show`,
  `diff`, `status`, `rev-parse`, `blame`, `grep`, `ls-files`, `reflog show`;
  Edit only in its scratch folder; the config's compare commands, with files
  in scratch only. No MCP servers (`--strict-mcp-config`).
- Deny: git writes with and without `--no-optional-locks`, `git -C` in both
  spellings, `gh` writes, `hitl brief` and `hitl serve` (`hitl` is the binary's
  absolute path) with and without `--session`,
  `flock`, `tmux`, `rm`, `mv`, `kill`, `pkill`, SendMessage, TaskStop,
  NotebookEdit, Edit in the parent of the session's cwd.
- Anything else is refused (`-p` asks no one).
- It may start a fresh read-only reviewer for a second opinion; that reviewer
  inherits the same profile.

### 6.3 Server

- Binds 127.0.0.1 only, on a fixed port (default 8765), and answers only
  requests whose Host is `127.0.0.1:<port>` or `localhost:<port>` (DNS
  rebinding).
- A random token per run, served only in `/config.js`, required in the
  `X-HITL-Token` header of every POST.
- POSTs are refused unless Origin is empty or the server's own origin.
  No CORS, no OPTIONS handler, so cross-site pages cannot send the header.
- Five POST actions only: `/drafts`, `/decide`, `/send`, `/withdraw`, `/ask`.
  Every GET is a built file (pages, `hitl.css`, `hitl.js`, `tips.json`) or
  `/config.js`.
- Errors return JSON with a short message; the server never crashes on a bad
  request.

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
5. **Approval is re-checked before use.** No draft text leaves hitl (the page's
   Copy) unless, at that moment, it is not delivered and every recorded fact
   still holds.
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
| Nimony, excluding tests and page CSS/JS | 1,800 lines; each module at most 700 |
| Page CSS and JS | 700 lines together |
| Config keys | the current 4 (`spec`, `reader`, `users`, `compare`) |
| Model runs | one split per `hitl brief`, one brief per changed item; none on page view |
| Server actions | the five in 6.3 |

Growth past a budget needs an equal cut elsewhere or the user's approval.
Prefer deleting code to adding it.

### 8.3 Adding a config option without growing the core

A key is added only when the project, not hitl, holds the answer and no
generic default works. Then:
1. Add it to `DEFAULTS` with a default that leaves behaviour unchanged, and
   validate it in `load_config` (unknown keys stay refused).
2. Read it in exactly one place. It changes data (text in a prompt, a label,
   an allow list), never control flow across modules.
3. Document it in the README and in `examples/`.
4. No plugin hooks, no per-project code, no scripting in config.

### 8.4 Other rules

- Transcript-format knowledge stays in `hitl/core.nim`'s transcript section; git
  goes through `core.git()`.
- State paths are computed in one helper, not rebuilt inline.
- New behaviour comes with a test on fixtures and the fake model; tests never
  touch the real state directory or `~/.claude`.
- Commit messages say what changed for the user.

---
---

# Review findings (not part of the locked spec)

These refer to the Python sources of hitl, which this repository ports.

## A. Issues

Ranked by severity. File and line are on branch `general` at `e62755d`.

| # | Sev. | Where | Issue | Verdict |
|---|---|---|---|---|
| 1 | High | `hitl.py:392`, `386-390` | The companion is allowed `Bash(git --no-optional-locks:*)`, which matches `git --no-optional-locks commit/push/reset/checkout`. The deny list only matches `git push ...` without the flag. The read-only guarantee is broken for the companion. | Fix: allow only reading subcommands (`git --no-optional-locks log:*`, `show`, `diff`, `status`, `rev-parse`, `blame`, `grep`, `ls-files`, `reflog`). |
| 2 | High | `hitl.py:393`, `review.py:1305-1306` | The companion may run any `python3 hitl.py ...`: `review --out <any dir>` deletes every `*.html` in that dir; `brief --force` spends model runs and makes drafts stale; `companion` execs a nested session. | Fix: allow `status`, `show`, `directions` only; `build` deletes only `index.html` and `i<N>.html`. |
| 3 | Med-high | `brief.py:143-145` | Split and brief runs use `--allowedTools`/`--disallowedTools`; NotebookEdit, WebFetch, Agent and the user's MCP tools stay available if the user's settings allow them. | Fix: `--tools Read,Grep,Glob --strict-mcp-config` (both in the installed CLI). |
| 4 | Medium | `hitl.py:472-475` | `decide` records the brief hash at save time, not the brief the page showed. Item pages are rebuilt only when the index is fetched (`serve.py:390-391`), so a brief rewritten in between is silently approved. Breaks invariant 6. | Fix: put the brief hash on the page (`data-brief`) and record that, as `data-ref` already does. |
| 5 | Medium | `serve.py:431-441` vs `hitl.py:560` | The page's `/send` skips the `status: approved` check that the CLI makes, so an unapproved companion draft is copyable from the strip. Two re-checks that differ. | Fix: one re-check function for both (or simplification 3). |
| 6 | Medium | `review.py:963-965`, `companion.md:519-527` | Companion drafts have no `decision`/`option` facts: the strip shows an empty answer and links to `i.html`. | Fix with simplification 3. |
| 7 | Medium | `serve.py:389-405` | No Host check: a DNS-rebinding page can read every built page (code, briefs) and `/config.js`. POSTs are still stopped by the Origin check. | Fix: refuse any request whose Host is not `127.0.0.1:<port>` or `localhost:<port>` (2 lines). |
| 8 | Medium | `review.py:85-107` | **Commits leak from a reused worktree** (heard): any reflog commit in a worktree the session committed in, within the session's whole time span, is taken, including the human's or another session's. Long sessions span days. | Not acceptable for a shared main checkout. Fix: keep a reflog entry only within ~120 s after one of this session's own committing Bash calls in that repository (~8 lines). |
| 9 | Medium | `brief.py:235-236` | **Material the split leaves out is never offered again** (heard): every offered key is marked seen, placed or not. | Acceptable for turns. Not for agents and commits: mark those seen only when placed. |
| 10 | Medium | `hitl.py:398-399` | One `companion-settings.json` for all sessions: two `serve` runs overwrite each other's profile (drafts path) between write and launch. | Fix: one file per session under `$STATE/briefs/<s>/` or scratch. |
| 11 | Low-med | `$STATE/directions/26c3c765/`, `bef67b4d/` | **Old drafts point at old report numbers** (heard): `decision 87:...` from the bug-report era; the strip links to missing or wrong items and shows them out of date forever. | Acceptable as a one-time cleanup: the user moves those two folders aside by hand. Rule kept: identity changes need a migration. |
| 12 | Low | `hitl.py:513-515`, `review.py:179-181` | **The 1.4 s `/drafts` call** (heard): every page load runs a full `collect` (all reflogs, `rev-list --all`) to get code tips. | Acceptable for `/send`, which must be live; not for page load. Fix: write the tips at build, `/drafts` reads them, `/send` recomputes. |
| 13 | Low | `review.py:140` | **The newest attempt wins over an older kept one** (heard): an item's current code is its newest commit's line, even if an older commit on another branch is the one kept. | Acceptable: the brief names earlier attempts; the human can ask the companion. Document only. |
| 14 | Low | `brief.py:47-48` | **The 5 housekeeping items in the Nimony test run** (heard): the split made items of status checks despite the rule. Cost: 5 brief runs and 5 cards in "Nothing open". | Acceptable; addressed by simplification 5. |
| 15 | Low | `hitl.py:465-466`, `485-488` | Draft numbers are reused after Undo of the highest one; a copied-then-undone text pasted later marks the new draft delivered. | Fix: number from a counter that never goes down, or keep withdrawn drafts as `.withdrawn`. |
| 16 | Low | `hitl.py:467`, `485-488`, `serve.py:429` | `did` and `id` from the request are not validated: a newline in `did` injects fact lines; `id` with `../` deletes any `.md`. Token-gated, so local only. | Fix: `did` must match `\w+`, `id` must match `d\d+`. |
| 17 | Low | `hitl.py:532` vs `review.py:43` | Two definitions of a human message; `delivered_at` ignores `promptSource == "typed"`. A pasted draft could go undetected and be copied twice. | Fix: one `is_human` in `hitl.py`. |
| 18 | Low | `review.py:1175`, `1233-1237` | The lane "Needs another review" holds only spec conflicts and missing briefs; items with `needs_review` or `bug_risks` go to "Nothing open". The other two counts are computed and unused. | Design question for `DESIGN.md` (flagged, not changed). |
| 19 | Low | `review.py:1305-1314` | `build` deletes all pages, then writes them; a request during a rebuild gets 404. | Fix: write each page to a temp file and rename. |
| 20 | Low | `brief.py:152-156` | JSON is pulled out of prose with a greedy regex. | Fixed by `--json-schema` (simplification 2). |

## B. Simplifications

Each keeps the behaviour the user relies on, the re-check before copying and
the read-only model. Line counts are estimates, including tests.

| # | Cut | Lines saved | Risk |
|---|---|---|---|
| 1 | Drop Copy all, the browser-remembered unsaved choice (`keep/forget/recall/tidy/known`, `data-dids`) and the card countdown (`count`, `data-total`). Needs `DESIGN.md` edits (answers 2, 9). | ~85 (+20 in DESIGN.md) | Low. Each decision is still copied in one click. |
| 1a | No cap of 3 and no `more` count (decided by the user): the brief lists every entry that meets the bar; drop `more` from the schema, the prompt rule, `parse`, `LIMIT`, `PER_SECTION`, the cache format, `more_of`, `MORE_Q` and the "N more not shown / Ask about them" note. The card shows the exact decision count. `DESIGN.md` answer 1, 5.6 and 6.2 follow. | ~30 (+15 in DESIGN.md) | Low. Long sections get longer; how the page presents them is open in `DESIGN.md` (below). |
| 2 | `--json-schema` for the split and the brief, and the brief returns the recommended option's index plus its reason: delete `json_object`, the defensive filtering in `parse`, `suggested`, `_words`, `_STOP`. | ~45 | Low. Every brief is rewritten once (prompt change). |
| 3 | One draft path: drafts come only from saving on a page; saving is the approval. Drop `status:`, the `ref`/`since` facts, the companion's drafting section and its file format; keep `hitl directions` for listing and sending. Fixes issues 5 and 6. | ~70 | Medium: free-form directions drafted by the companion go; the human types those, or uses "Type your answer" on a decision. **User decides.** |
| 4 | Move `CSS`+`CHAT_CSS` to `static/hitl.css` and `CHAT_JS`+`DECIDE_JS` to `static/hitl.js`, copied beside the pages at build. Drops the `__ICONS__` splice; `review.py` goes from 1,315 to ~640 lines; each page ~45 KB smaller; `node --check` runs on a file. | ~15 net | Low. File mode needs the two files beside the pages (build copies them). |
| 5 | Leave housekeeping out of the split: drop the "leave out housekeeping" rule; the split must place every agent and commit; turns may stay unplaced. Fixes issue 9. | ~5 | Low: a few more "Nothing open" cards per session. |
| 6 | Small dedupes: one `is_human`/`text_of` in `hitl.py`; one state-path helper (drafts, briefs and scratch paths are built in 4 places); `webbrowser.open` instead of `gio` twice; `collect` reads the transcript twice; unused `KINDS` counts; dead `note` parameter (the page always sends `''`); `serve.review_brief_path`. | ~35 | Low. |
| 7 | Cut `lock_holders` (`lslocks`) from `status`: it serves one workflow's heavy-job lock. | ~22 | Low-medium: Nimony sweeps lose that line. **User decides.** |
| 8 | Config as JSON (settled): replace `tomllib`, `.hitl.toml` and `examples/nimony.hitl.toml` with `json`, `.hitl.json` and `examples/nimony.hitl.json`; the key comments move to the README. | ~0 | Low. Existing `.hitl.toml` files must be converted by hand. |
| 9 | Precompute code tips at build for `/drafts`; `/send` stays live (issue 12). | adds ~6 | Low. |

Considered and not recommended: replacing the chat's markdown renderer
(`review.py:186-286`, ~95 lines) with plain text. `DESIGN.md` 4.3 asks for
markdown, and companion answers carry tables and code.

Top five: 1 with 1a, 2, 3, 6, 4, saving about 280 lines (about 11% of the code).

## C. Decided by the user (2026-11-09)

1. Simplification 3: drop companion-drafted directions; drafts are made only
   on the page, and saving is the approval.
2. Simplification 7: drop the lock line in `status`.
3. Issue 8: filter commits by the session's own git calls.
4. Issue 18: "Needs another review" also takes items with `needs_review`
   entries (DESIGN.md changes accordingly).
5. Issue 3 and 6.2: the companion runs with `--strict-mcp-config` (no MCP tools).
6. The budgets in 8.2 stand: 1,800 Python lines, 700 CSS/JS lines, 4 config keys.

Settled for `DESIGN.md`: an item page shows every entry of every section, most
important first, with no fold and no "Show more"; a section's count is its
exact total.
