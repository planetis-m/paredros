## Work items and what they are made of: the session's sources (turns, agents
## and the commits it made), the ledger that sorts them into numbered items,
## each item's current code, and the cached briefs. Everything is read from
## transcripts and git; the only files written are the ledger and the briefs
## under $STATE/briefs/<s>/.

import std/[syncio, strutils, os, tables, hashes, opt, result, algorithm, rex, times, sha1, crypto/sha2]
import kroki
import core

type
  ItemId* = distinct int   ## a work item's number: given by code, never reused

func `==`*(a, b: ItemId): bool {.borrow.}
func `<`*(a, b: ItemId): bool {.borrow.}
func `<=`*(a, b: ItemId): bool {.borrow.}
func `$`*(id: ItemId): string {.borrow.}
func hash*(id: ItemId): Hash {.borrow.}

proc readJson*(dst: var ItemId; p: var JsonParser; u: UnknownFieldPolicy) =
  ## A number; the pages send it as a numeric string too.
  var n = 0
  if p.kind == jkString:
    var s = ""
    readJson(s, p, u)
    try: n = parseInt(s) except: p.parseError()
  else: readJson(n, p, u)
  dst = ItemId(n)

proc writeJson*(w: var JsonWriter; id: ItemId) = writeJson(w, int(id))

# -------------------------------------------------------------- source keys

type
  SourceKind* = enum skTurn = "turn", skAgent = "agent", skCommit = "commit"
  SourceKey* = object   ## a source's identity, stable for the life of the transcript and repository
    kind*: SourceKind
    id*: string         ## the turn's uuid, the agent's id, the commit's sha

func `==`*(a, b: SourceKey): bool = a.kind == b.kind and a.id == b.id
func hash*(k: SourceKey): Hash = !$(hash(k.kind) !& hash(k.id))
func `$`*(k: SourceKey): string = $k.kind & ":" & k.id

proc toSourceKey(s: string): Opt[SourceKey] =
  ## "turn:<uuid>", "agent:<id>" or "commit:<sha>".
  result = none[SourceKey]()
  let colon = s.find(':')
  for kind in SourceKind:
    if colon > 0 and s.substr(0, colon - 1) == $kind:
      result = some(SourceKey(kind: kind, id: s.substr(colon + 1)))

proc readJson*(dst: var SourceKey; p: var JsonParser; u: UnknownFieldPolicy) =
  var s = ""
  readJson(s, p, u)
  let k = toSourceKey(s)
  if k.isSome: dst = k.get(SourceKey()) else: p.parseError()

proc writeJson*(w: var JsonWriter; k: SourceKey) = w.escapeJson($k)

proc readJson*(dst: var Table[SourceKey, int]; p: var JsonParser; u: UnknownFieldPolicy) =
  for name in p.jsonFields:
    let k = toSourceKey($name)
    var n = 0
    readJson(n, p, u)
    if k.isSome: dst[k.get(SourceKey())] = n else: p.parseError()

proc writeJson*(w: var JsonWriter; t: Table[SourceKey, int]) =
  w.write "{"
  var comma = false
  for k, n in t:
    if comma: w.write ","
    comma = true
    w.escapeJson($k)
    w.write ":"
    writeJson(w, n)
  w.write "}"

proc saveJson[T](path: string; value: T) {.raises, untyped.} =
  let json = toJson(value)
  if json.isErr: raise ValueError
  writeAtomic(path, json.get(""))

# ------------------------------------------------------------------- sources

type
  Turn* = object   ## what the human typed, and everything the session said until the next one
    id*: string    ## the message's uuid, else its time
    time*, human*: string
    replies*: seq[string]
  Commit* = object
    sha*, subject*: string
    repo*: string            ## the worktree it was made in
    common*: string          ## the repository's common git dir: worktrees of one repository share it
    time*: int64
    parents*: seq[string]
    agent*: Opt[string]      ## the id of the agent that made it
  Sources* = object
    turns*: seq[Turn]
    agents*: seq[Agent]
    commits*: seq[Commit]

func key*(t: Turn): SourceKey = SourceKey(kind: skTurn, id: t.id)
func key*(a: Agent): SourceKey = SourceKey(kind: skAgent, id: a.id)
func key*(c: Commit): SourceKey = SourceKey(kind: skCommit, id: c.sha)

proc epoch(time: string): int64 =
  ## A transcript time ("2026-11-09T08:01:00.123Z", UTC) in Unix seconds; 0 if it is not one.
  result = 0
  try:
    let month = parseInt(time.substr(5, 6))
    if time.len >= 19 and month in 1..12:
      result = initDateTime(parseInt(time.substr(0, 3)), Month(month), int32(parseInt(time.substr(8, 9))),
        int32(parseInt(time.substr(11, 12))), int32(parseInt(time.substr(14, 15))),
        int32(parseInt(time.substr(17, 18)))).toTime.toUnix
  except: discard

proc turns(recs: seq[Rec]): seq[Turn] =
  ## The main transcript cut at each message the human typed.
  result = @[]
  for r in recs:
    let said = if isHuman(r): textOf(r) else: ""
    if said.len > 0:
      result.add Turn(id: (if r.uuid.len > 0: r.uuid else: r.timestamp), time: r.timestamp,
                      human: said, replies: @[])
    elif result.len > 0:
      for text in assistantTexts(r): result[^1].replies.add text

const OwnWindow = 120   ## seconds after one of the session's committing git calls in which its commits land
  # PORTBUG(B1): review.py:58 - commits are found by reflog time in every worktree
  # the session committed in; another session's commit inside the window is taken.

let
  # A git command that can make commits: \bgit\b[^\n;&|]*\b(?:commit|...)\b.
  # Known issue: bug-reports/106-rex-word-boundary-after-repetition - a \b right
  # after the repetition never matches, so the character before the subcommand
  # is written as the non-word character that \b stands for there (approved, D8).
  committing = re(r"\bgit\b[^\n;&|]*[^\w\n;&|](?:commit|cherry-pick|revert|am|rebase|merge)\b",
                  {reExtended, reAllowEvil})
  # reflog entries that made a commit: commit, amend, merge with conflicts,
  # cherry-pick, revert, am, rebase steps
  madeCommit = re(r"(?:commit|cherry-pick|revert|am|rebase\ (?:-i\ )?\((?:pick|reword|edit|squash|fixup|continue)\))\b")

proc commitCalls(transcripts: seq[seq[Rec]]): Table[string, seq[int64]] =
  ## The times of the session's git commands that can make commits, by
  ## repository: the command's own `cd` or `git -C` targets, else its directory.
  result = initTable[string, seq[int64]]()
  for recs in transcripts:
    for c in toolUses(recs):
      if c.tool.name == "Bash" and c.tool.input.command.contains(committing):
        var dirs: seq[string] = @[]
        for d in dirsNamed(c.tool.input.command):
          if d notin dirs: dirs.add d
        if dirs.len == 0: dirs.add c.cwd
        for d in dirs:
          let top = if dirExists(d): git(d, ["rev-parse", "--show-toplevel"]) else: none[string]()
          if top.isSome: result.mgetOrPut(top.get(""), @[]).add epoch(c.timestamp)

proc reflogTime(selector: string): int64 =
  ## The time in a `--date=unix` reflog selector: HEAD@{1762675500}.
  let open = selector.find("@{")
  result = try: parseBiggestInt(selector.substr(open + 2, selector.len - 2)) except: 0'i64

proc sessionCommits(transcripts: seq[seq[Rec]]): seq[Commit] =
  ## The commits the session made, oldest first: HEAD reflog entries that made a
  ## commit in a worktree where the session ran a committing git command, within
  ## OwnWindow after such a call (so the human's and other sessions' commits there
  ## stay out), and still reachable from a ref, so commits replaced by an amend or
  ## a rebase drop out.
  let calls = commitCalls(transcripts)
  var tops: seq[string] = @[]
  for top, _ in calls: tops.add top
  tops.sort()
  var reachable = initTable[string, seq[string]]()   # by common git dir
  result = @[]
  for top in tops:
    let times = calls.getOrDefault(top, @[])
    var first = times[0]
    for t in times: first = min(first, t)
    let common = git(top, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).get("")
    if common notin reachable:
      reachable[common] = git(top, ["rev-list", "--all", "--since=" & $(first - 60)],
                              60_000).get("").splitWhitespace
    for line in git(top, ["reflog", "show", "--date=unix", "--format=%H%x09%gd%x09%gs", "HEAD"]).get("").splitLines:
      let f = line.split('\t', 2)
      if f.len == 3 and f[2].match(madeCommit) and f[0] in reachable.getOrDefault(common, @[]):
        let at = reflogTime(f[1])
        var ours, known = false
        for t in times:
          if t - 5 <= at and at <= t + OwnWindow: ours = true
        for c in result:
          if c.sha == f[0]: known = true
        if ours and not known:
          result.add Commit(sha: f[0], repo: top, common: common, time: at, agent: none[string]())
  for c in result.mitems:
    let info = git(c.repo, ["log", "-1", "--format=%s%x09%P", c.sha]).get("").split('\t', 1)
    c.subject = info[0]
    c.parents = if info.len > 1: info[1].splitWhitespace else: @[]
  result.sort(proc (a, b: Commit): int = cmp(a.time, b.time))

proc sources*(transcript: string): Sources =
  ## What a work item can be made of, each under a stable key.
  let recs = readJsonl(transcript)
  result = Sources(turns: turns(recs), agents: agents(transcript), commits: @[])
  var transcripts = @[recs]
  for a in result.agents: transcripts.add a.recs
  result.commits = sessionCommits(transcripts)
  for a in result.agents:   # made in an agent's worktree while it ran: that agent's commit
    let top = if a.workdir.isSome: git(a.workdir.get(""), ["rev-parse", "--show-toplevel"])
              else: none[string]()
    for c in result.commits.mitems:
      if c.agent.isNone and top.isSome and c.repo == top.get("") and
          epoch(a.start) <= c.time and c.time <= epoch(a.last) + 5:
        c.agent = some(a.id)

# -------------------------------------------------------------------- ledger

type
  LedgerItem* = object
    id*: ItemId
    title*: string
    sources*: seq[SourceKey]
  Ledger* = object   ## $STATE/briefs/<s>/items.json: the work items, by number
    items*: seq[LedgerItem]
    seen*: Table[SourceKey, int]   ## every sorted source and its fingerprint

proc ledgerPath(id: SessionId): string = stateDir(sdBriefs, id) & "/items.json"

proc loadLedger*(id: SessionId): Ledger =
  fromJson(readText(ledgerPath(id)).get("{}"), Ledger).get(Ledger())

proc saveLedger*(id: SessionId; ledger: Ledger) {.raises.} = saveJson(ledgerPath(id), ledger)

# -------------------------------------------------------------------- briefs

type
  Section* = enum   ## a brief's lists, in page order, spelled as in its JSON
    secDecisions = "open_decisions", secSpecConflicts = "spec_conflicts",
    secNeedsReview = "needs_review", secBugRisks = "bug_risks", secDecisionsMade = "decisions_made"
  EntrySection* = range[secSpecConflicts..secDecisionsMade]
  DecisionId* = distinct string   ## a decision's id: it follows the question
  Decision* = object
    question*, reason*, spec*, source*: string
    options*: seq[string]
    recommended*: Opt[int]   ## the index of the recommended option; any other value recommends none
  Entry* = object
    text*, why*, source*: string
  Brief* = object
    summary*: string
    decisions*: seq[Decision]                  ## open_decisions
    entries*: array[EntrySection, seq[Entry]]  ## the other four lists
  Cached* = object   ## $STATE/briefs/<s>/i<N>.json
    inputs*: string  ## a hash of the brief's whole prompt: the cache key
    generated*, model*: string
    brief*: Brief

func `==`*(a, b: DecisionId): bool {.borrow.}
func `$`*(id: DecisionId): string {.borrow.}

proc decisionId*(question: string): DecisionId =
  ## The first 10 hex digits of the sha1 of the question, its whitespace collapsed.
  var h = newSha1State()
  h.update(collapse(question))
  DecisionId(toHex(h.finalize()).substr(0, 9))

proc toDecisionId*(s: string): Opt[DecisionId] =
  ## A decision id as a request names it: word characters only.
  result = none[DecisionId]()
  if s.len > 0 and s.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}):
    result = some(DecisionId(s))

proc readJson*(dst: var DecisionId; p: var JsonParser; u: UnknownFieldPolicy) =
  var s = ""
  readJson(s, p, u)
  let id = toDecisionId(s)
  if id.isSome: dst = id.get(DecisionId("")) else: p.parseError()

proc writeJson*(w: var JsonWriter; id: DecisionId) = w.escapeJson(string(id))

proc readJson*(dst: var Brief; p: var JsonParser; u: UnknownFieldPolicy) =
  ## The summary and the five lists; anything else is dropped.
  for f in p.jsonFields:
    var known = true
    if f == "summary": readJson(dst.summary, p, u)
    elif f == $secDecisions: readJson(dst.decisions, p, u)
    else:
      known = false
      for s in secSpecConflicts..secDecisionsMade:
        if f == $s:
          readJson(dst.entries[s], p, u)
          known = true
    if not known: p.skipJson()

proc writeJson*(w: var JsonWriter; b: Brief) =
  w.write "{\"summary\":"
  writeJson(w, b.summary)
  w.write ",\"" & $secDecisions & "\":"
  writeJson(w, b.decisions)
  for s in secSpecConflicts..secDecisionsMade:
    w.write ",\"" & $s & "\":"
    writeJson(w, b.entries[s])
  w.write "}"

proc count*(b: Brief; s: Section): int =
  ## The number of entries in a section: its exact total.
  if s == secDecisions: b.decisions.len else: b.entries[s].len

proc briefPath*(id: SessionId; item: ItemId): string =
  stateDir(sdBriefs, id) & "/i" & $item & ".json"

proc loadBrief*(id: SessionId; item: ItemId): Opt[Cached] =
  ## The cached brief of an item, if there is a readable one.
  case fromJson(readText(briefPath(id, item)).get(""), Cached)
  of Ok(c): result = some(c)
  of Err(_): result = none[Cached]()

proc saveBrief*(id: SessionId; item: ItemId; c: Cached) {.raises.} =
  saveJson(briefPath(id, item), c)

# -------------------------------------------------------------- current code

type
  Code* = object   ## an item's current code
    commits*: seq[Commit]   ## the newest commit per repository and those it builds on
    earlier*: seq[Commit]   ## the item's other commits: earlier attempts
    tip*: string            ## the sorted 12-character shas of the heads, comma-joined
    diff*: string
  WorkItem* = object
    id*: ItemId
    title*: string
    turns*: seq[Turn]
    agents*: seq[Agent]
    code*: Code
  ItemTip* = object   ## an item's code tip, as tips.json and the stale check hold it
    item*: ItemId
    tip*: string

const
  DiffLimit = 600_000   ## characters of diff per item
  EmptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

proc find(commits: seq[Commit]; sha: string): int =
  result = -1
  for i, c in commits:
    if c.sha == sha: return i

proc isBuiltOn(c: Commit; others: seq[Commit]): bool =
  ## Some commit of others has c as a parent.
  result = false
  for o in others:
    if c.sha in o.parents: return true

proc currentCode(commits: seq[Commit]; withDiff: bool): Code =
  ## The code an item has now, per repository (worktrees of one repository are
  ## one): its newest commit, every commit of the item that is an ancestor of
  ## it, and the diff of each unbroken run of them. The item's other commits are
  ## earlier attempts.
  result = Code()
  var commons: seq[string] = @[]
  for c in commits:
    if c.common notin commons: commons.add c.common
  var diffs: seq[string] = @[]
  for common in commons:
    var mine: seq[Commit] = @[]
    for c in commits:
      if c.common == common: mine.add c
    let repo = mine[0].repo
    var newest = mine[0]
    for c in mine:
      if c.time > newest.time: newest = c
    var kept: seq[Commit] = @[]
    for c in mine:
      if c.sha == newest.sha or git(repo, ["merge-base", "--is-ancestor", c.sha, newest.sha]).isSome:
        kept.add c
      else: result.earlier.add c
    for c in kept:   # each run ends at a commit no other kept commit builds on
      if withDiff and not c.isBuiltOn(kept):
        var first = c
        while first.parents.len > 0 and kept.find(first.parents[0]) >= 0:
          first = kept[kept.find(first.parents[0])]
        let base = if first.parents.len > 0: first.parents[0] else: EmptyTree
        diffs.add git(repo, ["diff", "--no-color", "--no-ext-diff", "-M", base, c.sha], 60_000).get("")
      result.commits.add c
  var heads: seq[string] = @[]
  for c in result.commits:
    if not c.isBuiltOn(result.commits): heads.add c.sha.substr(0, 11)
  heads.sort()
  result.tip = heads.join(",")
  result.diff = diffs.join("\n").firstRunes(DiffLimit)

proc workItems*(desk: Desk; src: Sources; withDiff = true): seq[WorkItem] =
  ## The session's work items, as the ledger sorts its sources.
  result = @[]
  for it in loadLedger(desk.id).items:
    var item = WorkItem(id: it.id, title: it.title, turns: @[], agents: @[])
    var commits: seq[Commit] = @[]
    for k in it.sources:
      case k.kind
      of skTurn:
        for t in src.turns:
          if t.id == k.id: item.turns.add t
      of skAgent:
        for a in src.agents:
          if a.id == k.id: item.agents.add a
      of skCommit:
        for c in src.commits:
          if c.sha == k.id: commits.add c
    if commits.len > 0: item.code = currentCode(commits, withDiff)
    result.add item

proc tips*(items: seq[WorkItem]): seq[ItemTip] =
  result = @[]
  for it in items: result.add ItemTip(item: it.id, tip: it.code.tip)

proc tipOf*(tips: seq[ItemTip]; item: ItemId): Opt[string] =
  result = none[string]()
  for t in tips:
    if t.item == item: return some(t.tip)
