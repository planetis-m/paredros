## Work items and their decision briefs, written by read-only model runs.
##
## `hitl brief` first sorts the session's new material (turns, agents, commits)
## into work items, then writes one short, sourced brief per item: decisions made
## and why, spec conflicts, what needs another review, what could cause more bugs,
## and open decisions. Every item names its source.
##
## An item's number is given by this code, never by the model, and is kept in a
## ledger: a source once sorted stays in its item, and later runs only sort what
## is new. So a page, and the decisions saved against it, keep their number when
## briefs are rewritten. Briefs are cached by a hash of their inputs and
## rewritten only when those change.

import std/[syncio, strutils, tables, opt, result, algorithm, crypto/sha2]
from std/unicode import runeLen
import kroki
import core, store, review, prompts

const
  SplitSchema* = """{"type": "object", "required": ["items", "housekeeping"], "properties": {"items": {"type": "array", "items": {"type": "object", "properties": {"title": {"type": "string"}, "id": {"type": "integer"}, "sources": {"type": "array", "items": {"type": "string"}}}, "required": ["title", "id", "sources"]}}, "housekeeping": {"type": "array", "items": {"type": "string"}}}}"""
  BriefSchema* = """{"type": "object", "required": ["summary", "open_decisions", "spec_conflicts", "needs_review", "bug_risks", "decisions_made"], "properties": {"summary": {"type": "string"}, "open_decisions": {"type": "array", "items": {"type": "object", "properties": {"question": {"type": "string"}, "reason": {"type": "string"}, "spec": {"type": "string"}, "source": {"type": "string"}, "options": {"type": "array", "items": {"type": "string"}}, "recommended": {"type": "integer"}}, "required": ["question", "reason", "spec", "source", "options", "recommended"]}}, "spec_conflicts": {"type": "array", "items": {"type": "object", "properties": {"text": {"type": "string"}, "source": {"type": "string"}}, "required": ["text", "source"]}}, "needs_review": {"type": "array", "items": {"type": "object", "properties": {"text": {"type": "string"}, "source": {"type": "string"}}, "required": ["text", "source"]}}, "bug_risks": {"type": "array", "items": {"type": "object", "properties": {"text": {"type": "string"}, "source": {"type": "string"}}, "required": ["text", "source"]}}, "decisions_made": {"type": "array", "items": {"type": "object", "properties": {"text": {"type": "string"}, "why": {"type": "string"}, "source": {"type": "string"}}, "required": ["text", "why", "source"]}}}}"""
  ModelTimeoutMs = 900_000

type
  SplitItem* = object
    id*: int
    title*: string
    sources*: seq[string]
  SplitAnswer* = object
    items*: seq[SplitItem]
    housekeeping*: seq[string]
  SplitOut = object        ## `claude -p --output-format json` for the split
    structured_output: Opt[SplitAnswer]
  BriefOut = object        ## and for a brief
    structured_output: Opt[Brief]
  BriefState* = enum bsWritten = "written", bsUnchanged = "unchanged", bsFailed = "failed"
  BriefResult* = object
    n*: int
    state*: BriefState
    error*: string

proc fill*(text: string; fields: openArray[(string, string)]): string =
  ## str.format with named fields, in one pass: a value is never filled again.
  result = ""
  var i: Natural = 0
  while i < text.len:
    if text[i] == '{':
      let close = text.find('}', i + 1)
      if close > i:
        let name = text.substr(i + 1, close - 1)
        var hit = false
        for (k, v) in fields:
          if k == name:
            result.add v
            hit = true
            break
        if hit:
          i = close + 1
          continue
    result.add text[i]
    inc i

proc promptFor*(cfg: Config; sources: string): string =
  if cfg.spec.len > 0:
    fill(BriefPrompt, [("reader", cfg.reader), ("users", cfg.users), ("sources", sources),
      ("spec_line", "The spec, what the code must agree with, is " & cfg.spec & "."),
      ("spec_rule", "\"spec\" says, in one short sentence naming the part, what the spec says that bears on " &
                    "this question; read it to write it. If the current code contradicts it, end with \"; the " &
                    "current code contradicts it.\"; if the project already contradicts it without this " &
                    "change, end with \"; the project already contradicts it.\" Then leave that conflict out " &
                    "of spec_conflicts. If the spec says nothing relevant, write \"\"."),
      ("conflict_rule", "where the current code or the project disagrees with the spec, unless an open " &
                        "decision is about it.")])
  else:
    fill(BriefPrompt, [("reader", cfg.reader), ("users", cfg.users), ("sources", sources),
      ("spec_line", "There is no spec."), ("spec_rule", "Write \"\" for \"spec\"."),
      ("conflict_rule", "always empty: there is no spec.")])

# -------------------------------------------------------------------- model

proc modelJob*(prompt, cwd, model, schema: string): Job =
  ## One read-only `claude -p` run. --tools makes Read, Grep and Glob the only
  ## tools there are, whatever the user's settings allow; --strict-mcp-config
  ## leaves out every MCP server.
  Job(argv: @["claude", "-p", "--model", model, "--output-format", "json", "--tools", "Read,Grep,Glob",
              "--allowedTools", "Read,Grep,Glob", "--strict-mcp-config", "--no-session-persistence",
              "--json-schema", schema],
      cwd: cwd, input: prompt, timeoutMs: ModelTimeoutMs)

proc failure(r: Ran): string =
  ## Why a model run failed, or "" when it ran.
  if not r.started: r.errors
  elif r.code != 0: "claude exited " & $r.code & ": " & runeHead(r.errors.strip, 300)
  else: ""

proc splitAnswer*(r: Ran): Result[SplitAnswer, string] =
  ## The split's answer, an object in its JSON schema.
  let why = failure(r)
  if why.len > 0: return err[SplitAnswer, string](why)
  case fromJson(r.output, SplitOut)
  of Ok(o):
    if o.structured_output.isNone: return err[SplitAnswer, string]("the answer is not in the schema")
    result = ok[SplitAnswer, string](o.structured_output.get(SplitAnswer()))
  of Err(e): result = err[SplitAnswer, string]($e)

proc briefAnswer*(r: Ran): Result[Brief, string] =
  ## A brief's answer, an object in its JSON schema.
  let why = failure(r)
  if why.len > 0: return err[Brief, string](why)
  case fromJson(r.output, BriefOut)
  of Ok(o):
    if o.structured_output.isNone: return err[Brief, string]("the answer is not in the schema")
    result = ok[Brief, string](o.structured_output.get(Brief()))
  of Err(e): result = err[Brief, string]($e)

# ----------------------------------------------------------------- ledger

proc fingerprint(key: string; texts: seq[string]): int =
  ## What makes a source worth sorting again: a turn that grew. Agents and commits are sorted once.
  result = 0
  if key.startsWith("turn:"):
    for t in texts: result += t.runeLen

type Material = object   ## one source offered to the split
  key, line: string
  fp: int
  agent: Opt[string]     ## a commit's agent key

proc split*(d: Collected; model = "opus"): Ledger =
  ## Sorts new material into the ledger's items; returns the ledger. Existing items
  ## keep their number and their sources; new ones get the next free numbers.
  var led = loadLedger(d.session)
  var all: seq[Material] = @[]
  for t in d.sources.turns: all.add Material(key: t.key, fp: fingerprint(t.key, t.texts))
  for a in d.sources.agents: all.add Material(key: a.key, fp: 0)
  for c in d.sources.commits: all.add Material(key: c.key, fp: 0, agent: c.agent)
  var new: seq[Material] = @[]
  for x in all:
    if x.key notin led.seen or led.seen.getOrDefault(x.key, -1) != x.fp: new.add x
  if new.len == 0: return led
  var handle = initTable[string, string]()
  var counts = initTable[char, int]()
  for x in new:
    let kind = x.key[0].toUpperAscii
    counts[kind] = counts.getOrDefault(kind, 0) + 1
    handle[x.key] = $kind & $counts.getOrDefault(kind, 0)
  var where = initTable[string, int]()
  for it in led.items:
    for k in it.sources: where[k] = it.id
  var turnBy = initTable[string, Turn]()
  for t in d.sources.turns: turnBy[t.key] = t
  var agentBy = initTable[string, Agent]()
  for a in d.sources.agents: agentBy[a.key] = a
  var commitBy = initTable[string, Commit]()
  for c in d.sources.commits: commitBy[c.key] = c
  var lines: seq[string] = @[]
  for x in new:
    let h = handle.getOrDefault(x.key, "")
    var line = ""
    if x.key.startsWith("turn:"):
      let t = turnBy.getOrDefault(x.key, Turn())
      let said = if t.texts.len > 0: short(t.texts[^1], 300) else: "(nothing yet)"
      line = h & " the human: \"" & short(t.human, 300) & "\" The session, last: \"" & said & "\""
    elif x.key.startsWith("agent:"):
      let a = agentBy.getOrDefault(x.key, Agent())
      let report = short(a.report, 300)
      line = h & " agent \"" & a.description & "\". Its task: \"" & short(a.prompt, 300) &
        "\" Its report: \"" & (if report.len > 0: report else: "(none yet)") & "\""
    else:
      let c = commitBy.getOrDefault(x.key, Commit())
      var by = ""
      if c.agent.isSome:
        let ak = c.agent.get("")
        if ak in handle: by = " by " & handle.getOrDefault(ak, "")
        elif ak in where: by = " by the agent in item " & $where.getOrDefault(ak, 0)
      line = h & " commit" & by & " in " & c.repo & ": \"" & c.subject & "\""
    if x.key in where: line.add " (already in item " & $where.getOrDefault(x.key, 0) & ")"
    lines.add line
  var existing: seq[string] = @[]
  for it in led.items: existing.add $it.id & ". " & it.title
  let prompt = fill(SplitPrompt, [
    ("existing", "Existing items:\n" & (if existing.len > 0: existing.join("\n") else: "(none)")),
    ("material", "Material:\n" & lines.join("\n"))])
  let ran = run(modelJob(prompt, d.cwd, model, SplitSchema))
  var answer = SplitAnswer()
  case splitAnswer(ran)
  of Ok(a): answer = a
  of Err(e): die("hitl: " & e)
  var byHandle = initTable[string, string]()
  for k, h in handle: byHandle[h] = k
  var items = initTable[int, LedgerItem]()
  for it in led.items: items[it.id] = it
  var taken: seq[string] = @[]
  for it in led.items:
    for k in it.sources:
      if not k.startsWith("turn:"): taken.add k
  for got in answer.items:
    var keys: seq[string] = @[]
    for h in got.sources:   # handles only: no made-up keys
      if h in byHandle:
        let k = byHandle.getOrDefault(h, "")
        if k.startsWith("turn:") or k notin taken: keys.add k
    if keys.len == 0: continue
    var id = got.id
    if id notin items:   # numbers come from code: a new item gets the next free one
      id = 1
      for n, _ in items: id = max(id, n + 1)
      let title = collapse(got.title)
      items[id] = LedgerItem(id: id, title: (if title.len > 0: title else: "Untitled work"), sources: @[])
    var it = items.getOrDefault(id, LedgerItem())
    var add: seq[string] = @[]
    for k in keys:
      if k notin it.sources: add.add k
    for k in add: it.sources.add k
    items[id] = it
    for k in keys:
      if not k.startsWith("turn:"): taken.add k
  # Turns are sorted once. An agent or commit counts as sorted only when the split
  # placed it or called it housekeeping; anything it dropped is offered again.
  var skipped: seq[string] = @[]
  for h in answer.housekeeping:
    if h in byHandle: skipped.add byHandle.getOrDefault(h, "")
  var ids: seq[int] = @[]
  for n, _ in items: ids.add n
  ids.sort()
  var sorted: seq[LedgerItem] = @[]
  for n in ids: sorted.add items.getOrDefault(n, LedgerItem())
  led.items = sorted
  for x in new:
    if x.key.startsWith("turn:") or x.key in taken or x.key in skipped: led.seen[x.key] = x.fp
  saveLedger(d.session, led)
  led

# ----------------------------------------------------------------- briefs

proc gather*(r: WorkItem; diffLimit = 60_000; turnLimit = 8000): string =
  ## The brief's inputs as one text, oldest first.
  var parts = @["# Work item: " & r.title]
  let first = max(r.turns.len - 5, 0)
  for i in first ..< r.turns.len:
    let t = r.turns[i]
    let said = t.texts.join("\n\n")
    parts.add "# The human (" & runeHead(t.time, 16) & ")\n" & runeHead(t.human, 3000) & "\n\n" &
      "# The session, in reply\n" & runeTail(said, turnLimit)
  var ags = r.agents
  ags.sort(proc (a, b: Agent): int = cmp(a.start, b.start))
  for a in ags:
    if a.report.len > 0:
      parts.add "# Agent: " & a.description & " (" & runeHead(a.start, 16) & ")\n" & a.report
  let code = r.code
  if code.diff.len > 0:
    let cut = if code.diff.runeLen > diffLimit: "\n(cut at " & $diffLimit & " characters; read the files for the rest)" else: ""
    parts.add "# The current code\n```diff\n" & runeHead(code.diff, diffLimit) & "\n```" & cut
  if code.earlier.len > 0:
    var lines: seq[string] = @[]
    for c in code.earlier: lines.add "- " & c.subject
    parts.add "# Earlier attempts, not part of the current code\n" & lines.join("\n")
  parts.join("\n\n")

proc inputsHash*(prompt: string): string = toHex(sha256(prompt)).toLowerAscii.substr(0, 15)

proc generateAll*(d: Collected; numbers: seq[int]; model = "opus"; force = false; jobs = 4): seq[BriefResult] =
  ## One brief per item whose inputs changed (or every one with force), at most
  ## `jobs` model runs at once. Results in item order; a failure is reported and
  ## the others go on.
  result = @[]
  var todo: seq[(int, string, string)] = @[]   # item, prompt, inputs hash
  for r in d.items:
    if numbers.len > 0 and r.n notin numbers: continue
    let prompt = promptFor(d.config, gather(r))
    let digest = inputsHash(prompt)
    let cached = load(d.session, r.n)
    if cached.isSome and cached.get(Cached()).inputs == digest and not force:
      result.add BriefResult(n: r.n, state: bsUnchanged)
    else:
      result.add BriefResult(n: r.n, state: bsWritten)
      todo.add (r.n, prompt, digest)
  var work: seq[Job] = @[]
  for (_, prompt, _) in todo: work.add modelJob(prompt, d.repo, model, BriefSchema)
  let ran = runAll(work, jobs)
  for i, (n, _, digest) in todo:
    for x in result.mitems:
      if x.n != n: continue
      case briefAnswer(ran[i])
      of Ok(b):
        save(d.session, n, Cached(inputs: digest, generated: localStamp(withSeconds = true, sep = 'T'),
                                  model: model, brief: b))
      of Err(e):
        x.state = bsFailed
        x.error = e
