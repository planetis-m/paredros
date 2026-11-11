## Work items and their decision briefs, written by read-only model runs.
##
## `hitl brief` first sorts the session's new material (turns, agents,
## commits) into work items, then writes one short, sourced brief per item:
## decisions made and why, spec conflicts, what needs another review, what
## could cause more bugs, and open decisions. Every item names its source.
##
## An item's number is given by this code, never by the model, and is kept in
## a ledger: a source once sorted stays in its item, and later runs only sort
## what is new. So a page, and the decisions saved against it, keep their
## number when briefs are rewritten. Briefs are cached by a hash of their
## inputs and rewritten only when those change.
##
## The material itself (turns, agents, commits, a work item's current code)
## is read by work.nim; its types are declared here, where it is sorted and
## briefed.

import std/[syncio, strutils, os, paths, dirs, tables, algorithm, json, opt, result, times,
            sha1, unicode]
import std/crypto/sha2
import state, session, config

type
  Section* {.pure.} = enum
    ## The lists of a brief, in the order the page shows them.
    OpenDecisions, SpecConflicts, NeedsReview, BugRisks, DecisionsMade

const Sections*: array[Section, tuple[key, heading: string]] = [
  ("open_decisions", "Decisions for you"),
  ("spec_conflicts", "Contradicts the spec"),
  ("needs_review", "Needs another review"),
  ("bug_risks", "Could cause more bugs"),
  ("decisions_made", "Decisions made")]
  ## Each list's key in the brief's JSON and its heading on the page.

const Split* = """You sort the material of a Claude Code session into work items, for a human who
reviews the work. A work item is one piece of work they may want to review or
decide on: a bug fixed, a module or file ported, a feature, a design change.

Below are the existing items, then material not yet sorted (or grown since).
Each line starts with a handle. Answer with "items" (each: an existing item's
id, or 0 for a new item with a title; and the handles of its sources) and
"housekeeping" (the handles you leave out as housekeeping).

Rules:
- Put material in an existing item (its id) when it continues that work: a
  review of it, a redo, a follow-up commit. Otherwise start a new item (id 0)
  with a title: a few plain words naming the thing, short enough for one line
  of a card, sentence case, no numbers or handles.
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
  ## The split's prompt; {existing} and {material} are filled in.

const Prompt* = """You write a decision brief about one work item from a Claude Code session, for
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
- Each text is one or two plain sentences the reader can take in at a glance;
  the page shows many of them. No hype. Code in backticks.
- Write every item, in every list, for a reader who has not read the agents'
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
  belongs there only if both hold:
  1. Nothing settles it: not the spec, not the repository's conventions, not
     the instructions and skills the agents follow (CLAUDE.md, .claude/skills/),
     not the evidence in the sources. If any of these settles it, it is not
     open: put it under decisions_made with that rule or evidence as "why".
  2. It changes what {users} see or can do, or the project's design.
     Questions about test files, message counts, code style, an internal
     helper, or keeping a small change consistent are never open decisions.
  Write each question so someone who has not read the reports understands it.
  "recommended" is the index (from 0) of the option you recommend, or -1 if
  none of them; "reason" is the one reason, without restating the option.
  {spec_rule}
  What you checked yourself belongs in source. If the session asked the human
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
- open_decisions: at most 3 options, each a short label: the page shows them as
  buttons and the reasoning goes in "reason".

{sources}
"""
  ## The brief's prompt; filled in by `promptFor`.

# The answers' JSON schemas, as the text `claude --json-schema` is given:
# json.dumps of brief.py's SPLIT_SCHEMA and BRIEF_SCHEMA, so the model runs
# get the same argument.
const
  SplitSchema* = """{"type": "object", "required": ["items", "housekeeping"], """ &
    """"properties": {"items": {"type": "array", "items": {"type": "object", "properties": """ &
    """{"title": {"type": "string"}, "id": {"type": "integer"}, "sources": {"type": "array", """ &
    """"items": {"type": "string"}}}, "required": ["title", "id", "sources"]}}, """ &
    """"housekeeping": {"type": "array", "items": {"type": "string"}}}}"""
    ## The split's answer: items (an id, or 0 and a title; source handles) and housekeeping.
  BriefSchema* = """{"type": "object", "required": ["summary", "open_decisions", """ &
    """"spec_conflicts", "needs_review", "bug_risks", "decisions_made"], "properties": """ &
    """{"summary": {"type": "string"}, "open_decisions": {"type": "array", "items": """ &
    """{"type": "object", "properties": {"question": {"type": "string"}, "reason": """ &
    """{"type": "string"}, "spec": {"type": "string"}, "source": {"type": "string"}, """ &
    """"options": {"type": "array", "items": {"type": "string"}}, "recommended": """ &
    """{"type": "integer"}}, "required": ["question", "reason", "spec", "source", "options", """ &
    """"recommended"]}}, "spec_conflicts": {"type": "array", "items": {"type": "object", """ &
    """"properties": {"text": {"type": "string"}, "source": {"type": "string"}}, "required": """ &
    """["text", "source"]}}, "needs_review": {"type": "array", "items": {"type": "object", """ &
    """"properties": {"text": {"type": "string"}, "source": {"type": "string"}}, "required": """ &
    """["text", "source"]}}, "bug_risks": {"type": "array", "items": {"type": "object", """ &
    """"properties": {"text": {"type": "string"}, "source": {"type": "string"}}, "required": """ &
    """["text", "source"]}}, "decisions_made": {"type": "array", "items": {"type": "object", """ &
    """"properties": {"text": {"type": "string"}, "why": {"type": "string"}, "source": """ &
    """{"type": "string"}}, "required": ["text", "why", "source"]}}}}"""
    ## A brief: the summary and the five lists.

# ------------------------------------------------------------------ material

type
  Turn* = object
    ## The main transcript from one message the human typed to the next.
    key*: string           ## "turn:<uuid>"
    time*: string          ## the message's timestamp
    human*: string         ## what the human typed
    texts*: seq[string]    ## everything the session wrote until the next one
  Worker* = object
    ## A subagent as a source.
    key*: string           ## "agent:<id>"
    agent*: Agent          ## its transcript, task, description and start
    report*: string        ## what it handed back; "" when nothing yet
  Commit* = object
    ## A commit the session made.
    key*: string           ## "commit:<sha>"
    sha*: string
    repo*: string          ## the top of the checkout it was found from
    common*: string        ## its repository's common git directory
    time*: int64           ## when it was made, in epoch seconds
    agent*: Opt[string]    ## the key of the agent that made it; none for the main session
    subject*: string
    parents*: seq[string]
  Sources* = object
    ## What a work item can be made of, each under a stable key.
    recs*: seq[Rec]        ## the main transcript
    cwd*: string           ## the directory the session ran in
    turns*: seq[Turn]
    agents*: seq[Worker]
    commits*: seq[Commit]  ## oldest first
  Code* = object
    ## A work item's current code.
    commits*: seq[Commit]  ## the commits it is made of
    earlier*: seq[Commit]  ## the item's other commits: earlier attempts
    tip*: string           ## the sorted short shas of its head commits, comma-joined
    diff*: string          ## the diff of each unbroken run of its commits

  Entry* = object
    ## One entry of a brief's list; the fields its list does not use are empty.
    text*: string          ## a finding
    why*: string           ## why a decision was made
    question*: string      ## an open decision's question
    options*: seq[string]  ## its options
    recommended*: int      ## the index of the option recommended; -1 for none
    reason*: string        ## the reason for it
    spec*: string          ## what the spec says that bears on it
    source*: string        ## the evidence, a phrase that reads after "From"
  Brief* = object
    ## A brief as the page reads it.
    summary*: string
    lists*: array[Section, seq[Entry]]
  Cached* = object
    ## A brief as its cache file holds it.
    inputs*: string        ## the hash of its prompt
    generated*: string     ## when it was written, local time
    model*: string
    brief*: Brief

  WorkItem* = object
    ## A work item with its sources and its cached brief.
    n*: int                ## its number in the ledger
    title*: string
    brief*: Opt[Brief]     ## none until one is written
    inputs*: string        ## the hash the cached brief was written from; "" for none
    turns*: seq[Turn]
    agents*: seq[Worker]
    code*: Code
  Work* = object
    ## The session's sources and its work items (work.collect).
    session*: string       ## the session id
    cwd*: string           ## the directory the session ran in
    repo*: string          ## the top of its checkout, else cwd
    config*: Config
    sources*: Sources
    items*: seq[WorkItem]
    generated*: DateTime   ## when this was read

proc promptFor*(cfg: Config; sources: string): string =
  ## The brief's prompt for these sources, in the config's words.
  var specLine, specRule, conflictRule: string
  if cfg.spec.len > 0:
    specLine = "The spec, what the code must agree with, is " & cfg.spec & "."
    specRule = "\"spec\" says, in one short sentence naming the part, what the spec says " &
      "that bears on this question; read it to write it. If the current code contradicts " &
      "it, end with \"; the current code contradicts it.\"; if the project already " &
      "contradicts it without this change, end with \"; the project already contradicts " &
      "it.\" Then leave that conflict out of spec_conflicts. If the spec says nothing " &
      "relevant, write \"\"."
    conflictRule = "where the current code or the project disagrees with the spec, unless " &
      "an open decision is about it."
  else:
    specLine = "There is no spec."
    specRule = "Write \"\" for \"spec\"."
    conflictRule = "always empty: there is no spec."
  # one pass, as str.format: a value that holds a {name} is not filled in again
  result = Prompt.multiReplace([("{reader}", cfg.reader), ("{users}", cfg.users),
                                ("{sources}", sources), ("{spec_line}", specLine),
                                ("{spec_rule}", specRule), ("{conflict_rule}", conflictRule)])

# --------------------------------------------------------------------- model

proc askModel*(prompt, cwd, model, schema: string; timeout = 900): Result[JsonNode, string] =
  ## One read-only `claude -p` run; its answer, the object in the given JSON
  ## schema (structured_output). The error says why there is none.
  # --tools makes Read, Grep and Glob the only tools there are, whatever the
  # user's settings allow; --strict-mcp-config leaves out every MCP server
  let cmd = ["claude", "-p", "--model", model, "--output-format", "json", "--tools",
             "Read,Grep,Glob", "--allowedTools", "Read,Grep,Glob", "--strict-mcp-config",
             "--no-session-persistence", "--json-schema", schema]
  let res = run(cmd, timeout, input = prompt, cwd = cwd)
  if res.isErr: return err[JsonNode, string](res.error(""))
  let ran = res.get(Completed())
  if ran.code != 0:
    return err[JsonNode, string]("claude exited " & $ran.code & ": " &
                                 runeSubStr(unicode.strip(ran.errors), 0, 300))
  # GAP: why the output is not JSON is said in std/json's words, not
  # Python's, because that is the message std/json gives.
  var answer = parseJson(ran.output)
  if answer.hasError: return err[JsonNode, string](answer.errorMsg)
  let got = answer{"structured_output"}
  result = if got.kind == JObject: ok[JsonNode, string](got)
           else: err[JsonNode, string]("the answer is not in the schema")

proc short*(text: string; n = 90): string =
  ## The text on one line, its white space collapsed, cut to n characters
  ## with an ellipsis.
  let t = collapse(text)
  result = if runeLen(t) <= n: t else: runeSubStr(t, 0, n - 1) & "…"

proc decisionId*(question: string): string =
  ## The stable id of a decision across brief rewrites with the same question:
  ## the first 10 hex digits of the SHA-1 of the question, white space collapsed.
  var h = newSha1State()
  h.update(collapse(question))
  result = toHex(h.finalize()).substr(0, 9)

proc writeJson*(p, json: string) {.raises.} =
  ## Writes JSON text to p whole, making its directory first. Raises the
  ## ErrorCode of a failed write.
  createDir(path(parentDir(p)))
  writeAtomic(p, json)   # a page build never reads a half-written file

# -------------------------------------------------------------------- ledger

type
  LedgerItem* = object
    ## A work item as the ledger keeps it.
    id*: int               ## its number, given by code
    title*: string
    sources*: seq[string]  ## the keys of its sources
  Ledger* = object
    ## The work items and what is sorted.
    items*: seq[LedgerItem]    ## by id
    seen*: Table[string, int]  ## every key sorted, with its fingerprint

proc ledgerPath*(sid: string): string =
  ## The ledger's file.
  state("briefs", sid) & "/items.json"

proc loadLedger*(sid: string): Result[Ledger, string] =
  ## The work items and what is sorted. None yet: empty. Unreadable: an error,
  ## never empty, which would number the items from 1 again and break every
  ## page and saved decision; the file is left as it is.
  let p = ledgerPath(sid)
  if not fileExists(p):
    return ok[Ledger, string](Ledger(items: @[], seen: initTable[string, int]()))
  var text = ""
  try:
    text = readFile(p)
  except ErrorCode as e:
    return err[Ledger, string]("cannot read the work items in " & p & " (" & $e &
                               "); it is left as it is")
  var tree = parseJson(text)
  if tree.hasError:
    return err[Ledger, string]("cannot read the work items in " & p & " (" & tree.errorMsg &
                               "); it is left as it is")
  let top = tree.root
  var list, seen = top   # the members; top itself until they are found
  if top.kind == JObject:
    for k, v in pairs(top):
      if k == "items": list = v
      elif k == "seen": seen = v
  if top.kind != JObject or list.kind != JArray or seen.kind != JObject:
    return err[Ledger, string](p & " does not hold work items; it is left as it is")
  var led = Ledger(items: @[], seen: initTable[string, int]())
  for it in items(list):
    var item = LedgerItem(id: 0, title: "", sources: @[])
    if it.kind == JObject:
      for k, v in pairs(it):
        case k
        of "id": item.id = int(v.getInt)
        of "title": item.title = v.getStr
        of "sources":
          if v.kind == JArray:
            for s in items(v): item.sources.add s.getStr
        else: discard
    led.items.add item
  for k, v in pairs(seen):
    # a fingerprint that is not a number matches none: the source is sorted again
    led.seen[k] = int(v.getInt(-1))
  result = ok[Ledger, string](led)

proc ledgerJson(led: Ledger): string =
  ## The ledger as its file holds it.
  var items: seq[string] = @[]
  for it in led.items:
    items.add "{\"id\": " & $it.id & ", \"title\": " & quote(it.title) &
      ", \"sources\": " & quote(it.sources) & "}"
  var seen: seq[string] = @[]
  for k, v in pairs(led.seen): seen.add quote(k) & ": " & $v
  # GAP: written on one line, where Python indents, because std/json has no
  # pretty printer; non-ASCII text is written as it is, where Python escapes it.
  result = "{\"items\": [" & items.join(", ") & "], \"seen\": {" & seen.join(", ") & "}}"

proc fingerprint(key: string; texts: seq[string]): int =
  ## What makes a source worth sorting again: a turn that grew. Agents and
  ## commits are sorted once.
  result = 0
  if key.startsWith("turn:"):
    for t in texts: result += runeLen(t)

type Offer = object
  ## A source offered to the split.
  key: string
  fingerprint: int
  line: string        # how the prompt shows it

proc split*(sid: string; src: Sources; model = "opus"): Result[Ledger, string] =
  ## Sorts the session's new material (work.sources) into the ledger's items
  ## and saves the ledger; returns it. Existing items keep their number and
  ## their sources; new ones get the next free numbers. The error says why the
  ## ledger cannot be read or written, or why the model gave no answer.
  let loaded = loadLedger(sid)
  if loaded.isErr: return loaded
  var led = loaded.get(Ledger())
  var where = initTable[string, int]()   # a sorted source's item
  for it in led.items:
    for k in it.sources: where[k] = it.id
  proc clip(t: string): string = short(t, 300)
  # what is new, each under a handle: turns T1, T2, ..., then agents, then
  # commits, whose line names the handle of the agent that made them
  var new: seq[Offer] = @[]
  var handle = initTable[string, string]()
  for t in src.turns:
    let fp = fingerprint(t.key, t.texts)
    if led.seen.getOrDefault(t.key, -1) != fp:
      handle[t.key] = "T" & $(new.len + 1)
      let said = if t.texts.len > 0: clip(t.texts[^1]) else: "(nothing yet)"
      new.add Offer(key: t.key, fingerprint: fp, line: handle.getOrDefault(t.key, "") &
                    " the human: \"" & clip(t.human) & "\" The session, last: \"" & said & "\"")
  var count = 0
  for a in src.agents:
    if led.seen.getOrDefault(a.key, -1) != 0:
      inc count
      handle[a.key] = "A" & $count
      let report = clip(a.report)
      new.add Offer(key: a.key, fingerprint: 0, line: handle.getOrDefault(a.key, "") &
                    " agent \"" & a.agent.description & "\". Its task: \"" & clip(a.agent.prompt) &
                    "\" Its report: \"" & (if report.len > 0: report else: "(none yet)") & "\"")
  count = 0
  for c in src.commits:
    if led.seen.getOrDefault(c.key, -1) != 0:
      inc count
      handle[c.key] = "C" & $count
      let agent = c.agent.get("")
      let by = if agent in handle: " by " & handle.getOrDefault(agent, "")
               elif agent in where: " by the agent in item " & $where.getOrDefault(agent, 0)
               else: ""
      new.add Offer(key: c.key, fingerprint: 0, line: handle.getOrDefault(c.key, "") &
                    " commit" & by & " in " & c.repo & ": \"" & c.subject & "\"")
  if new.len == 0: return ok[Ledger, string](led)
  var lines: seq[string] = @[]
  for x in new:
    var line = x.line
    if x.key in where: line.add " (already in item " & $where.getOrDefault(x.key, 0) & ")"
    lines.add line
  var titles: seq[string] = @[]
  for it in led.items: titles.add $it.id & ". " & it.title
  let existing = "Existing items:\n" & (if titles.len > 0: titles.join("\n") else: "(none)")
  let asked = askModel(Split.multiReplace([("{existing}", existing),
                                           ("{material}", "Material:\n" & lines.join("\n"))]),
                       src.cwd, model, SplitSchema)
  if asked.isErr: return err[Ledger, string](asked.error(""))
  let answer = asked.get(default(JsonNode))
  var byHandle = initTable[string, string]()
  for k, h in pairs(handle): byHandle[h] = k
  var taken: seq[string] = @[]   # agents and commits in an item
  for it in led.items:
    for k in it.sources:
      if not k.startsWith("turn:"): taken.add k
  var housekeeping: seq[string] = @[]
  var got: seq[JsonNode] = @[]
  for k, v in pairs(answer):
    if k == "items" and v.kind == JArray:
      for x in items(v): got.add x
    elif k == "housekeeping" and v.kind == JArray:
      for h in items(v): housekeeping.add h.getStr
  for g in got:
    var id = 0
    var title = ""
    var keys: seq[string] = @[]
    if g.kind == JObject:
      for k, v in pairs(g):
        case k
        of "id": id = int(v.getInt)
        of "title": title = v.getStr
        of "sources":
          if v.kind == JArray:
            for h in items(v):
              # handles only: no made-up keys
              let key = byHandle.getOrDefault(h.getStr, "")
              if key.len > 0 and (key.startsWith("turn:") or key notin taken): keys.add key
        else: discard
    if keys.len > 0:
      var at = -1
      for i, it in led.items:
        if it.id == id: at = i
      if at < 0:   # numbers come from code: a new item gets the next free one
        var n = 0
        for it in led.items: n = max(n, it.id)
        let words = collapse(title)
        led.items.add LedgerItem(id: n + 1, title: (if words.len > 0: words else: "Untitled work"),
                                 sources: @[])
        at = led.items.high
      var adding: seq[string] = @[]
      for k in keys:
        if k notin led.items[at].sources: adding.add k
      for k in adding: led.items[at].sources.add k
      for k in keys:
        if not k.startsWith("turn:"): taken.add k
  # Turns are sorted once. An agent or commit counts as sorted only when the
  # split placed it or called it housekeeping; anything it dropped is offered again.
  var skipped: seq[string] = @[]
  for h in housekeeping:
    if h in byHandle: skipped.add byHandle.getOrDefault(h, "")
  for x in new:
    if x.key.startsWith("turn:") or x.key in taken or x.key in skipped:
      led.seen[x.key] = x.fingerprint
  led.items.sort(proc (a, b: LedgerItem): int = cmp(a.id, b.id))
  try:
    writeJson(ledgerPath(sid), ledgerJson(led))
  except ErrorCode as e:
    return err[Ledger, string]("cannot write the work items to " & ledgerPath(sid) &
                               " (" & $e & ")")
  result = ok[Ledger, string](led)

# -------------------------------------------------------------------- briefs

proc gather*(r: WorkItem; diffLimit = 60_000; turnLimit = 8000): string =
  ## The brief's inputs as one text, oldest first.
  var parts = @["# Work item: " & r.title]
  for i in max(r.turns.len - 5, 0) ..< r.turns.len:
    let t = r.turns[i]
    parts.add "# The human (" & runeSubStr(t.time, 0, 16) & ")\n" & runeSubStr(t.human, 0, 3000) &
      "\n\n# The session, in reply\n" & runeSubStr(t.texts.join("\n\n"), -turnLimit)
  var agents = r.agents
  agents.sort(proc (a, b: Worker): int = cmp(a.agent.start, b.agent.start))
  for a in agents:
    if a.report.len > 0:
      parts.add "# Agent: " & a.agent.description & " (" & runeSubStr(a.agent.start, 0, 16) &
        ")\n" & a.report
  let diff = r.code.diff
  if diff.len > 0:
    let cut = if runeLen(diff) > diffLimit:
                "\n(cut at " & $diffLimit & " characters; read the files for the rest)"
              else: ""
    parts.add "# The current code\n```diff\n" & runeSubStr(diff, 0, diffLimit) & "\n```" & cut
  if r.code.earlier.len > 0:
    var lines: seq[string] = @[]
    for c in r.code.earlier: lines.add "- " & c.subject
    parts.add "# Earlier attempts, not part of the current code\n" & lines.join("\n")
  result = parts.join("\n\n")

proc cachePath*(sid: string; n: int): string =
  ## The cache file of item n's brief.
  state("briefs", sid) & "/i" & $n & ".json"

proc entry(n: JsonNode): Entry =
  ## One entry of a brief's list, as the model or the cache wrote it.
  result = Entry(options: @[], recommended: -1)
  for k, v in pairs(n):
    case k
    of "text": result.text = v.getStr
    of "why": result.why = v.getStr
    of "question": result.question = v.getStr
    of "reason": result.reason = v.getStr
    of "spec": result.spec = v.getStr
    of "source": result.source = v.getStr
    of "recommended":
      # anything but a number recommends none
      if v.kind == JInt: result.recommended = int(v.getInt)
    of "options":
      if v.kind == JArray:
        for o in items(v): result.options.add o.getStr
    else: discard

proc parse*(b: JsonNode): Brief =
  ## The brief as the page reads it: the summary and the five lists, nothing else.
  result = Brief(summary: "")
  if b.kind == JObject:
    for k, v in pairs(b):
      if k == "summary": result.summary = v.getStr
      for s in Section:
        if k == Sections[s].key and v.kind == JArray:
          result.lists[s] = @[]
          for e in items(v):
            if e.kind == JObject: result.lists[s].add entry(e)

proc load*(sid: string; n: int): Opt[Cached] =
  ## Item n's cached brief; none when there is none or it cannot be read.
  let text = try: readFile(cachePath(sid, n)) except: ""
  var tree = parseJson(text)
  if tree.hasError or tree.root.kind != JObject: return none[Cached]()
  var c = Cached(inputs: "", generated: "", model: "", brief: Brief(summary: ""))
  for k, v in pairs(tree.root):
    case k
    of "inputs": c.inputs = v.getStr
    of "generated": c.generated = v.getStr
    of "model": c.model = v.getStr
    of "brief": c.brief = parse(v)
    else: discard
  result = some(c)

proc cachedJson(c: Cached): string =
  ## A cached brief as its file holds it: each entry with its list's fields.
  # GAP: on one line, as ledgerJson.
  var lists: seq[string] = @[]
  for s in Section:
    var entries: seq[string] = @[]
    for e in c.brief.lists[s]:
      entries.add(case s
        of OpenDecisions:
          "{\"question\": " & quote(e.question) & ", \"reason\": " & quote(e.reason) &
            ", \"spec\": " & quote(e.spec) & ", \"source\": " & quote(e.source) &
            ", \"options\": " & quote(e.options) & ", \"recommended\": " & $e.recommended & "}"
        of DecisionsMade:
          "{\"text\": " & quote(e.text) & ", \"why\": " & quote(e.why) & ", \"source\": " &
            quote(e.source) & "}"
        else:
          "{\"text\": " & quote(e.text) & ", \"source\": " & quote(e.source) & "}")
    lists.add quote(Sections[s].key) & ": [" & entries.join(", ") & "]"
  result = "{\"inputs\": " & quote(c.inputs) & ", \"generated\": " & quote(c.generated) &
    ", \"model\": " & quote(c.model) & ", \"brief\": {\"summary\": " & quote(c.brief.summary) &
    ", " & lists.join(", ") & "}}"

proc generate*(r: WorkItem; d: Work; model = "opus";
               force = false): Result[(Cached, bool), string] =
  ## Item r's brief: the cached one when its inputs did not change (and not
  ## force), else a new one from the model, written to the cache. True when
  ## it is new. The error says why no brief was written.
  let prompt = promptFor(d.config, gather(r))
  let digest = toHex(sha256(prompt)).substr(0, 15)
  let cached = load(d.session, r.n)
  if cached.isSome and cached.get(Cached()).inputs == digest and not force:
    return ok[(Cached, bool), string]((cached.get(Cached()), false))
  let answer = askModel(prompt, d.repo, model, BriefSchema)
  if answer.isErr: return err[(Cached, bool), string](answer.error(""))
  # local time without its zone, as time.strftime("%Y-%m-%dT%H:%M:%S")
  let brief = Cached(inputs: digest, generated: ($local(getTime())).substr(0, 18), model: model,
                     brief: parse(answer.get(default(JsonNode))))
  try:
    writeJson(cachePath(d.session, r.n), cachedJson(brief))
  except ErrorCode as e:
    return err[(Cached, bool), string]("cannot write " & cachePath(d.session, r.n) &
                                       " (" & $e & ")")
  result = ok[(Cached, bool), string]((brief, true))

proc generateAll*(d: Work; numbers: seq[int] = @[]; model = "opus"; force = false;
                  jobs = 4): seq[(int, string)] =
  ## Every item's brief (or only those numbered): (item, "written" |
  ## "unchanged" | "failed: <why>"), in item order. A failure is reported and
  ## the others go on. `jobs` is how many model runs may go at once.
  # GAP: the model runs go one after another, whatever `jobs` says, because
  # model runs started at once from std/parfor's `||` wait on each other for
  # ever: std/osproc's children inherit each other's pipes on Linux
  # (bug-reports/105-osproc-pipes-inherited-by-later-children).
  result = @[]
  for r in d.items:
    if numbers.len == 0 or r.n in numbers:
      let g = generate(r, d, model, force)
      result.add (r.n, if g.isErr: "failed: " & g.error("")
                       elif g.get((Cached(), false))[1]: "written"
                       else: "unchanged")
