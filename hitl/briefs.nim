## Model work done ahead of time: sorting the session's new material into work
## items (the split) and writing one brief per item. Both are read-only
## `claude -p` runs that answer in a JSON schema.
##
## An item's number is given by this code, never by the model, and is kept in
## the ledger: a source once sorted stays in its item, and later runs sort only
## what is new or, for a turn, what grew. So a page, and the decisions saved
## against it, keep their number when briefs are rewritten. A brief is cached
## under a hash of its whole prompt and rewritten only when that changes.

import std/[strutils, tables, opt, result, algorithm, times, crypto/sha2]
from std/unicode import runeLen
import kroki
import core, items

const
  SplitPrompt = """
You sort the material of a Claude Code session into work items, for a human who
reviews the work. A work item is one piece of work they may want to review or
decide on: a bug fixed, a module or file ported, a feature, a design change.

Below are the existing items, then material not yet sorted (or grown since).
Each line starts with a handle. Answer with "items" (each: an existing item's
id, or 0 for a new item with a title; and the handles of its sources) and
"housekeeping" (the handles you leave out as housekeeping).

Rules:
- Put material in an existing item (its id) when it continues that work: a
  review of it, a redo, a follow-up commit. Otherwise start a new item (id 0)
  with a title: at most 10 plain words naming the thing, sentence case, no
  numbers or handles.
- An agent (A) or a commit (C) goes to at most one item. A commit marked "by A2"
  goes where A2 goes. A turn (T) may go to several items, or to none.
- Leave out housekeeping: it is no piece of work. Housekeeping is status
  checks, tooling chatter, filing or updating bug reports, editing notes,
  ledgers or prompts, and combining reviewed branches for upstream. List each
  agent (A) or commit (C) you leave out as housekeeping under "housekeeping";
  every other agent and commit goes into an item.

{existing}

{material}
"""

  BriefPrompt = """
You write a decision brief about one work item from a Claude Code session, for
{reader}, who must make the decisions themselves, from facts, without being
overloaded.

Below are the sources: what the human and the session said, the final reports
of the agents that worked on it, and the diff of its current code (it may be
cut short; the files are in the repository). The repository is your working
directory; you may read files in it, but do not run anything and do not
change anything. {spec_line}

Answer in the JSON schema you were given. "summary" is one sentence on the
outcome: what the current code does and what is left; never restate the title.

Rules:
- Every text at most 25 words. Plain words, no hype. Code in backticks.
- Write every item, in every list, for a reader who has NOT read the agents'
  reports. Say what would behave differently for {users}. Never use the
  agents' private names: scratch, test, review or case file names (say "the
  example" or "a new test" instead), internal numbering, or internal function
  names unless the function is itself the point. If an item cannot be said
  that way, leave it out.
- Describe the current code only. An earlier attempt is not the current code;
  if it matters, say so in one plain needs_review item.
- Only what the sources support. "source" is one short plain phrase that
  reads after "From", in lower case, naming the evidence: who said it and,
  if the spec, which part. Examples: "the session and the first review";
  "the agent's report; spec: Ref types (read directly)"; "the current code".
  Write "(read directly)" when you read the spec yourself. Never a time or
  date, no file paths except a source file when it is the point.
- open_decisions is the most important list and must be short. A question
  belongs there only if BOTH hold:
  1. Nothing settles it: not the spec, not the repository's conventions, not
     the instructions and skills the agents follow (CLAUDE.md, .claude/skills/),
     not the evidence in the sources. If any of these settles it, it is NOT
     open: put it under decisions_made with that rule or evidence as "why".
  2. It changes what {users} see or can do, or the project's design.
     Questions about test files, message counts, code style, an internal
     helper, or keeping a small change consistent are never open decisions.
  Write each question so someone who has not read the reports understands it.
  "recommended" is the index (from 0) of the option you recommend, or -1 if
  none of them; "reason" is the one reason, without restating the option.
  {spec_rule}
  Never write "I checked"; put that in source. If the session asked the human
  a question that meets both tests, include it; leave out questions about
  other items, tooling and housekeeping.
- Never mention logistics anywhere: PRs, pushing, branches, CI, commit hashes.
  Say "the current code" and "an earlier attempt" instead.
- needs_review: code that changed after its last review, review findings not
  addressed, claims nobody verified.
- spec_conflicts: {conflict_rule}
- bug_risks: regressions found, cases the change may break, side findings.
- The human's opinion is guidance, not the answer: report it as a source,
  never as the decision.
- Empty lists are fine. List every item that meets the bar, the most
  important first.
- open_decisions: at most 3 options, each under 10 words.

{sources}
"""
  SplitSchema* = """{"type": "object", "required": ["items", "housekeeping"], "properties": {"items": {"type": "array", "items": {"type": "object", "properties": {"title": {"type": "string"}, "id": {"type": "integer"}, "sources": {"type": "array", "items": {"type": "string"}}}, "required": ["title", "id", "sources"]}}, "housekeeping": {"type": "array", "items": {"type": "string"}}}}"""
  BriefSchema* = """{"type": "object", "required": ["summary", "open_decisions", "spec_conflicts", "needs_review", "bug_risks", "decisions_made"], "properties": {"summary": {"type": "string"}, "open_decisions": {"type": "array", "items": {"type": "object", "properties": {"question": {"type": "string"}, "reason": {"type": "string"}, "spec": {"type": "string"}, "source": {"type": "string"}, "options": {"type": "array", "items": {"type": "string"}}, "recommended": {"type": "integer"}}, "required": ["question", "reason", "spec", "source", "options", "recommended"]}}, "spec_conflicts": {"type": "array", "items": {"type": "object", "properties": {"text": {"type": "string"}, "source": {"type": "string"}}, "required": ["text", "source"]}}, "needs_review": {"type": "array", "items": {"type": "object", "properties": {"text": {"type": "string"}, "source": {"type": "string"}}, "required": ["text", "source"]}}, "bug_risks": {"type": "array", "items": {"type": "object", "properties": {"text": {"type": "string"}, "source": {"type": "string"}}, "required": ["text", "source"]}}, "decisions_made": {"type": "array", "items": {"type": "object", "properties": {"text": {"type": "string"}, "why": {"type": "string"}, "source": {"type": "string"}}, "required": ["text", "why", "source"]}}}}"""
  ModelTimeoutMs = 900_000

type Reply*[T] = object   ## what `claude -p --output-format json` prints
  answer*: Opt[T]         ## structured_output: the answer in the --json-schema shape

proc readJson*[T](dst: var Reply[T]; p: var JsonParser; u: UnknownFieldPolicy) {.untyped.} =
  for f in p.jsonFields:
    if f == "structured_output": readJson(dst.answer, p, u) else: p.skipJson()

proc modelJob*(prompt, cwd, model, schema: string): Job =
  ## One read-only `claude -p` run. --tools makes Read, Grep and Glob the only
  ## tools there are, whatever the user's settings allow; --strict-mcp-config
  ## leaves out every MCP server.
  Job(argv: @["claude", "-p", "--model", model, "--output-format", "json", "--tools", "Read,Grep,Glob",
              "--allowedTools", "Read,Grep,Glob", "--strict-mcp-config", "--no-session-persistence",
              "--json-schema", schema],
      cwd: cwd, input: prompt, timeoutMs: ModelTimeoutMs)

proc answer*[T](r: Ran): Result[T, string] {.untyped.} =
  ## The answer of a model run in its schema, else why there is none.
  if not r.started: return err[T, string](r.errors)
  if r.code != 0:
    return err[T, string]("claude exited " & $r.code & ": " & r.errors.strip.firstRunes(300))
  let reply = fromJson(r.output, Reply[T])
  if reply.isErr: return err[T, string]($reply.error(JsonError()))
  let a = reply.get(Reply[T]()).answer
  if a.isNone: return err[T, string]("the answer is not in the schema")
  ok[T, string](a.get(default(T)))

# --------------------------------------------------------------------- split

type
  SplitItem = object   ## an item as the split answers: an existing item's number, or 0 for a new one
    id: ItemId
    title: string
    sources: seq[string]   ## handles
  SplitAnswer = object
    items: seq[SplitItem]
    housekeeping: seq[string]
  Offer = object   ## a source offered to the split
    key: SourceKey
    handle: string   ## how the prompt names it: T1, A2, C3
    fingerprint: int

proc fingerprint(t: Turn): int =
  ## What makes a turn worth sorting again: it grew. Agents and commits are sorted once.
  result = 0
  for text in t.replies: result += text.runeLen

proc offers(src: Sources; ledger: Ledger): seq[Offer] =
  ## The sources not sorted yet, or grown since, each under its handle.
  var all: seq[(SourceKey, int)] = @[]
  for t in src.turns: all.add (t.key, fingerprint(t))
  for a in src.agents: all.add (a.key, 0)
  for c in src.commits: all.add (c.key, 0)
  var counts = default(array[SourceKind, int])
  result = @[]
  for (k, fp) in all:
    if ledger.seen.getOrDefault(k, -1) != fp:
      inc counts[k.kind]
      result.add Offer(key: k, handle: ($k.kind)[0].toUpperAscii & $counts[k.kind], fingerprint: fp)

proc handleOf(offers: seq[Offer]; key: SourceKey): Opt[string] =
  result = none[string]()
  for o in offers:
    if o.key == key: return some(o.handle)

proc itemOf(ledger: Ledger; key: SourceKey): Opt[ItemId] =
  result = none[ItemId]()
  for it in ledger.items:
    if key in it.sources: return some(it.id)

proc placed(ledger: Ledger; key: SourceKey): string =
  let item = ledger.itemOf(key)
  if item.isSome: " (already in item " & $item.get(ItemId(0)) & ")" else: ""

proc splitPrompt(src: Sources; ledger: Ledger; offers: seq[Offer]): string =
  var lines: seq[string] = @[]
  for t in src.turns:
    let h = offers.handleOf(t.key)
    if h.isSome:
      let said = if t.replies.len > 0: oneLine(t.replies[^1], 300) else: "(nothing yet)"
      lines.add h.get("") & " the human: \"" & oneLine(t.human, 300) & "\" The session, last: \"" &
        said & "\"" & ledger.placed(t.key)
  for a in src.agents:
    let h = offers.handleOf(a.key)
    if h.isSome:
      let report = if a.report.len > 0: oneLine(a.report, 300) else: "(none yet)"
      lines.add h.get("") & " agent \"" & a.description & "\". Its task: \"" & oneLine(a.task, 300) &
        "\" Its report: \"" & report & "\"" & ledger.placed(a.key)
  for c in src.commits:
    let h = offers.handleOf(c.key)
    if h.isSome:
      var by = ""
      if c.agent.isSome:
        let agent = SourceKey(kind: skAgent, id: c.agent.get(""))
        if offers.handleOf(agent).isSome: by = " by " & offers.handleOf(agent).get("")
        elif ledger.itemOf(agent).isSome: by = " by the agent in item " & $ledger.itemOf(agent).get(ItemId(0))
      lines.add h.get("") & " commit" & by & " in " & c.repo & ": \"" & c.subject & "\"" & ledger.placed(c.key)
  var existing: seq[string] = @[]
  for it in ledger.items: existing.add $it.id & ". " & it.title
  SplitPrompt.multiReplace([
    ("{existing}", "Existing items:\n" & (if existing.len > 0: existing.join("\n") else: "(none)")),
    ("{material}", "Material:\n" & lines.join("\n"))])

proc place(ledger: var Ledger; offers: seq[Offer]; answer: SplitAnswer) =
  ## Puts the answer's sources into the ledger. Numbers come from code: a new
  ## item gets the next free one. An agent or commit goes to one item only;
  ## handles the model made up are dropped.
  var taken: seq[SourceKey] = @[]
  for it in ledger.items:
    for k in it.sources:
      if k.kind != skTurn: taken.add k
  for got in answer.items:
    var keys: seq[SourceKey] = @[]
    for o in offers:
      if o.handle in got.sources and (o.key.kind == skTurn or o.key notin taken): keys.add o.key
    if keys.len > 0:
      var at = -1
      for i, it in ledger.items:
        if it.id == got.id: at = i
      if at < 0:
        var id = 1
        for it in ledger.items: id = max(id, int(it.id) + 1)
        let title = collapse(got.title)
        ledger.items.add LedgerItem(id: ItemId(id), title: (if title.len > 0: title else: "Untitled work"),
                                    sources: @[])
        at = ledger.items.high
      for k in keys:
        if k notin ledger.items[at].sources: ledger.items[at].sources.add k
        if k.kind != skTurn: taken.add k
  ledger.items.sort(proc (a, b: LedgerItem): int = cmp(int(a.id), int(b.id)))
  # Turns are sorted once. An agent or commit counts as sorted only when the
  # split placed it or called it housekeeping; anything it dropped is offered again.
  for o in offers:
    if o.key.kind == skTurn or o.key in taken or o.handle in answer.housekeeping:
      ledger.seen[o.key] = o.fingerprint

proc split*(desk: Desk; src: Sources; model: string): Result[Ledger, string] {.raises.} =
  ## Sorts new material into the ledger's items and saves it; the error is why
  ## the model gave no answer. Existing items keep their number and sources.
  var ledger = loadLedger(desk.id)
  let offered = offers(src, ledger)
  if offered.len > 0:
    let ran = run(modelJob(splitPrompt(src, ledger, offered), desk.cwd, model, SplitSchema))
    case answer[SplitAnswer](ran)
    of Ok(a):
      ledger.place(offered, a)
      saveLedger(desk.id, ledger)
    of Err(e): return err[Ledger, string](e)
  ok[Ledger, string](ledger)

# -------------------------------------------------------------------- briefs

proc briefPrompt*(cfg: Config; sources: string): string =
  ## The brief's prompt for the given sources, in the config's words.
  var fields = @[("{reader}", cfg.reader), ("{users}", cfg.users), ("{sources}", sources)]
  if cfg.spec.isSome:
    fields.add ("{spec_line}", "The spec, what the code must agree with, is " & cfg.spec.get("") & ".")
    fields.add ("{spec_rule}", "\"spec\" says, in one short sentence naming the part, what the spec " &
      "says that bears on this question; read it to write it. If the current code contradicts it, end " &
      "with \"; the current code contradicts it.\"; if the project already contradicts it without " &
      "this change, end with \"; the project already contradicts it.\" Then leave that conflict out " &
      "of spec_conflicts. If the spec says nothing relevant, write \"\".")
    fields.add ("{conflict_rule}", "where the current code or the project disagrees with the spec, " &
      "unless an open decision is about it.")
  else:
    fields.add ("{spec_line}", "There is no spec.")
    fields.add ("{spec_rule}", "Write \"\" for \"spec\".")
    fields.add ("{conflict_rule}", "always empty: there is no spec.")
  BriefPrompt.multiReplace(fields)

proc gather*(item: WorkItem; diffLimit = 60_000; turnLimit = 8000): string =
  ## The brief's sources as one text, oldest first.
  var parts = @["# Work item: " & item.title]
  for i in max(item.turns.len - 5, 0) ..< item.turns.len:
    let t = item.turns[i]
    parts.add "# The human (" & t.time.firstRunes(16) & ")\n" & t.human.firstRunes(3000) & "\n\n" &
      "# The session, in reply\n" & t.replies.join("\n\n").lastRunes(turnLimit)
  var agents = item.agents
  agents.sort(proc (a, b: Agent): int = cmp(a.start, b.start))
  for a in agents:
    if a.report.len > 0:
      parts.add "# Agent: " & a.description & " (" & a.start.firstRunes(16) & ")\n" & a.report
  let diff = item.code.diff
  if diff.len > 0:
    let cut = if diff.runeLen > diffLimit: "\n(cut at " & $diffLimit & " characters; read the files for the rest)"
              else: ""
    parts.add "# The current code\n```diff\n" & diff.firstRunes(diffLimit) & "\n```" & cut
  if item.code.earlier.len > 0:
    var lines: seq[string] = @[]
    for c in item.code.earlier: lines.add "- " & c.subject
    parts.add "# Earlier attempts, not part of the current code\n" & lines.join("\n")
  parts.join("\n\n")

proc inputsHash*(prompt: string): string = toHex(sha256(prompt)).substr(0, 15)

type
  BriefState* = enum bsWritten = "written", bsUnchanged = "unchanged", bsFailed = "failed"
  BriefResult* = object
    item*: ItemId
    case state*: BriefState
    of bsFailed: error*: string
    of bsWritten, bsUnchanged: discard

proc generate*(desk: Desk; items: seq[WorkItem]; only: seq[ItemId]; model: string; force: bool;
               jobs: int): seq[BriefResult] {.raises.} =
  ## One brief per item whose inputs changed (every one with force), or per
  ## item of `only`, at most `jobs` model runs at once. Results in item order;
  ## a failure is reported and the others go on.
  result = @[]
  var todo: seq[(int, string)] = @[]   # the result's index, the prompt's hash
  var work: seq[Job] = @[]
  for it in items:
    if only.len == 0 or it.id in only:
      let prompt = briefPrompt(desk.config, gather(it))
      let digest = inputsHash(prompt)
      let cached = loadBrief(desk.id, it.id)
      if force or cached.isNone or cached.get(Cached()).inputs != digest:
        todo.add (result.len, digest)
        work.add modelJob(prompt, desk.repo, model, BriefSchema)
      result.add BriefResult(item: it.id, state: bsUnchanged)
  let ran = runAll(work, jobs)
  for i, (at, digest) in todo:
    let item = result[at].item
    case answer[Brief](ran[i])
    of Ok(b):
      saveBrief(desk.id, item, Cached(inputs: digest, generated: $local(getTime()), model: model, brief: b))
      result[at] = BriefResult(item: item, state: bsWritten)
    of Err(e): result[at] = BriefResult(item: item, state: bsFailed, error: e)
