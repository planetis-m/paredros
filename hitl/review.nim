## Work items and the pages built from them, from what already exists.
##
## Sources, all read-only:
## - the session's transcripts: the main one, cut into turns at each message the
##   human typed, and each subagent's description and final report
## - git: the commits the session made (sessionCommits)
## - the work-item ledger and the briefs that `hitl brief` writes (store.nim)
##
## A work item is one piece of work the human may want to review or decide on: a
## bug fixed, a module ported, a feature. `hitl brief` sorts the session's turns,
## agents and commits into items; an item's number never changes once given.

import std/[syncio, os, paths, dirs, files, strutils, tables, opt, result, algorithm, rex, times]
import kroki
from std/unicode import runeLen
import core, store, model, pages
export model

const
  DiffLimit = 600_000   ## characters of diff per item
  EmptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  OwnWindow = 120       ## seconds after one of the session's committing git calls in which its commits land
  # PORTBUG(B1): review.py:58 - commits are found by reflog time in every worktree
  # the session committed in; another session's commit inside the window is taken.

# --------------------------------------------------------------------- time

proc daysFromCivil(y, m, d: int): int =
  let y2 = if m <= 2: y - 1 else: y
  let era = (if y2 >= 0: y2 else: y2 - 399) div 400
  let yoe = y2 - era * 400
  let doy = (153 * (if m > 2: m - 3 else: m + 9) + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

proc epoch*(ts: string): float =
  ## ISO time from a transcript (UTC, 'Z') as epoch seconds; 0 when unreadable.
  ## datetime.fromisoformat: YYYY-MM-DD[THH:MM[:SS[.ffffff]]][Z|+HH:MM]
  proc num(s: string; a, b: int; v: var int): bool =
    if b > s.len: return false
    v = 0
    for i in a ..< b:
      if s[i] notin Digits: return false
      v = v * 10 + ord(s[i]) - ord('0')
    true
  var y, mo, d, h, mi, se = 0
  if not (num(ts, 0, 4, y) and ts.len >= 10 and ts[4] == '-' and num(ts, 5, 7, mo) and
          ts[7] == '-' and num(ts, 8, 10, d)): return 0.0
  if mo < 1 or mo > 12 or d < 1 or d > 31: return 0.0
  var i = 10
  var frac = 0.0
  var offset = 0
  var hasZone = false
  if i < ts.len and ts[i] in {'T', ' '}:
    if not (num(ts, i + 1, i + 3, h) and i + 3 < ts.len + 1): return 0.0
    if not (i + 3 < ts.len and ts[i + 3] == ':' and num(ts, i + 4, i + 6, mi)): return 0.0
    i += 6
    if i < ts.len and ts[i] == ':':
      if not num(ts, i + 1, i + 3, se): return 0.0
      i += 3
      if i < ts.len and ts[i] in {'.', ','}:
        var k = i + 1
        var scale = 0.1
        while k < ts.len and ts[k] in Digits:
          frac += float(ord(ts[k]) - ord('0')) * scale
          scale /= 10
          inc k
        if k == i + 1: return 0.0
        i = k
  if i < ts.len:
    if ts[i] == 'Z' and i + 1 == ts.len:
      hasZone = true
    elif ts[i] in {'+', '-'}:
      var oh, om = 0
      if not (num(ts, i + 1, i + 3, oh) and i + 3 < ts.len and ts[i + 3] == ':' and num(ts, i + 4, i + 6, om)):
        return 0.0
      offset = (oh * 3600 + om * 60) * (if ts[i] == '-': -1 else: 1)
      hasZone = true
    else: return 0.0
  if h > 23 or mi > 59 or se > 59: return 0.0
  var t = float(daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se) + frac - float(offset)
  if not hasZone:   # a naive time is local time, as in Python
    t -= float(local(fromUnix(int64(t))).offsetEast)
  t

# -------------------------------------------------------------------- turns

proc turns*(recs: seq[Rec]): seq[Turn] =
  ## The main transcript cut at each message the human typed: what they said and
  ## everything the session said until the next one.
  result = @[]
  for r in recs:
    if isHuman(r) and textOf(r).len > 0:
      result.add Turn(key: "turn:" & (if r.uuid.len > 0: r.uuid else: r.timestamp), time: r.timestamp,
                      human: textOf(r), texts: @[])
    elif r.kind == rkAssistant and result.len > 0:
      for (_, t) in assistantTexts(@[r]): result[^1].texts.add t

# ------------------------------------------------------------------- commits

let
  # review.GIT_WRITE: \bgit\b[^\n;&|]*\b(?:commit|cherry-pick|revert|am|rebase|merge)\b
  # Known issue: bug-reports/106-rex-word-boundary-after-repetition - a \b right
  # after the repetition never matches, so the character before the subcommand
  # is written as the non-word character that \b stands for there (approved).
  gitWrite = re(r"\bgit\b[^\n;&|]*[^\w\n;&|](?:commit|cherry-pick|revert|am|rebase|merge)\b",
                {reExtended, reAllowEvil})
  # reflog entries that made a commit: commit, amend, merge with conflicts, cherry-pick, revert, am, rebase steps
  made = re(r"(?:commit|cherry-pick|revert|am|rebase\ (?:-i\ )?\((?:pick|reword|edit|squash|fixup|continue)\))\b")
  selector = re(r"@\{(\d+)\}")

type GitCall = object
  dir: string
  time: float

proc gitCalls(transcripts: seq[seq[Rec]]): seq[GitCall] =
  ## Every git command the session ran that can make commits: the command's own
  ## `cd` or `git -C` targets, else the directory it ran in.
  result = @[]
  for recs in transcripts:
    for r in recs:
      for c in toolUses(@[r]):
        let cmd = if c.tool.name == "Bash": c.tool.input.command else: ""
        if cmd.contains(gitWrite):
          var dirs: seq[string] = @[]
          for d in cdTargets(cmd):
            if d notin dirs: dirs.add d
          for d in gitcTargets(cmd):
            if d notin dirs: dirs.add d
          if dirs.len == 0 and r.cwd.len > 0: dirs.add r.cwd
          for d in dirs: result.add GitCall(dir: d, time: epoch(c.timestamp))

proc sessionCommits*(transcripts: seq[seq[Rec]]): seq[Commit] =
  ## The commits the session made, oldest first: HEAD reflog entries that made a
  ## commit in a worktree where the session ran a committing git command, within
  ## OwnWindow after such a call (so the human's and other sessions' commits there
  ## stay out), and still reachable from a ref, so commits replaced by an amend or
  ## a rebase drop out.
  var calls = initTable[string, seq[float]]()
  for c in gitCalls(transcripts):
    let top = if isDir(c.dir): git(c.dir, ["rev-parse", "--show-toplevel"]) else: none[string]()
    if top.isSome:
      let t = top.get("")
      calls.mgetOrPut(t, @[]).add c.time
  var tops: seq[string] = @[]
  for t, _ in calls: tops.add t
  tops.sort()
  var live = initTable[string, seq[string]]()
  var found: seq[Commit] = @[]
  for top in tops:
    let times = calls.getOrDefault(top, @[])
    let common = git(top, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).get("")
    if common notin live:
      var first = times[0]
      for t in times: first = min(first, t)
      live[common] = git(top, ["rev-list", "--all", "--since=" & $(int(first) - 60)], 60_000).get("").splitWhitespace
    let reflog = git(top, ["reflog", "show", "--date=unix", "--format=%H%x09%gd%x09%gs", "HEAD"]).get("")
    for line in reflog.splitLines:
      let parts = line.split('\t', 2)
      let sha = parts[0]
      let sel = if parts.len > 1: parts[1] else: ""
      let msg = if parts.len > 2: parts[2] else: ""
      var caps: seq[Capture] = @[]
      var whenAt = 0
      let (a, _) = findBounds(sel, selector, caps, 0)
      if a >= 0: whenAt = try: parseInt(capture(sel, caps, 0)) except: 0
      var ours = false
      for t in times:
        if t - 5 <= float(whenAt) and float(whenAt) <= t + float(OwnWindow): ours = true
      if msg.match(made) and sha in live.getOrDefault(common, @[]) and ours:
        var known = false
        for f in found:
          if f.sha == sha: known = true
        if not known:
          found.add Commit(key: "commit:" & sha, sha: sha, repo: top, common: common, time: whenAt)
  for c in found.mitems:
    let info = git(c.repo, ["log", "-1", "--format=%s%x09%P", c.sha]).get("\t")
    let tab = info.find('\t')
    c.subject = if tab >= 0: info.substr(0, tab - 1) else: info
    c.parents = if tab >= 0: info.substr(tab + 1).splitWhitespace else: @[]
  result = found
  result.sort(proc (a, b: Commit): int = cmp(a.time, b.time))

# ------------------------------------------------------------------- sources

proc sources*(spath: string): Sources =
  ## What a work item can be made of, each under a stable key: turns, agents, commits.
  let recs = readJsonl(spath)
  var ags = agents(spath)
  var transcripts = @[recs]
  for a in ags: transcripts.add a.recs
  var cms = sessionCommits(transcripts)
  for a in ags.mitems:
    a.report = finalReport(a.recs)
    a.top = if a.workdir.isSome: git(a.workdir.get(""), ["rev-parse", "--show-toplevel"]) else: none[string]()
    a.endTime = 0.0
    for r in a.recs:
      if r.timestamp.len > 0: a.endTime = max(a.endTime, epoch(r.timestamp))
  for c in cms.mitems:
    # made in an agent's worktree while that agent ran: that agent's commit
    for a in ags:
      if a.top.isSome and a.top.get("") == c.repo and epoch(a.start) <= float(c.time) and
          float(c.time) <= a.endTime + 5:
        c.agent = some(a.key)
        break
  Sources(recs: recs, turns: turns(recs), agents: ags, commits: cms)

proc builds(c: Commit; on: seq[Commit]): bool =
  ## Some commit of `on` has `c` as a parent.
  for o in on:
    if c.sha in o.parents: return true
  false

proc currentCode*(commits: seq[Commit]; withDiff = true): Code =
  ## The code an item has now, per repository (worktrees of one repository are
  ## one): its newest commit, every commit of the item that is an ancestor of it,
  ## and the diff of each unbroken run of them. The item's other commits are
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
    var tip = mine[0]
    for c in mine:
      if c.time > tip.time: tip = c
    var keep: seq[Commit] = @[]
    for c in mine:
      if c.sha == tip.sha or git(repo, ["merge-base", "--is-ancestor", c.sha, tip.sha]).isSome: keep.add c
      else: result.earlier.add c
    for c in keep: result.commits.add c
    var shas: seq[string] = @[]
    for c in keep: shas.add c.sha
    for c in keep:   # each run ends at a commit no other kept commit builds on
      if not withDiff or c.builds(keep): continue
      var first = c
      while first.parents.len > 0 and first.parents[0] in shas:
        for o in keep:
          if o.sha == first.parents[0]:
            first = o
            break
      let base = if first.parents.len > 0: first.parents[0] else: EmptyTree
      diffs.add git(repo, ["diff", "--no-color", "--no-ext-diff", "-M", base, c.sha], 60_000).get("")
  var tips: seq[string] = @[]
  for c in result.commits:
    if not c.builds(result.commits): tips.add c.sha.substr(0, 11)
  tips.sort()
  result.tip = tips.join(",")
  result.diff = runeHead(diffs.join("\n"), DiffLimit)

proc collect*(spath: string; configFile: string; withDiff = true): Collected =
  ## The session's sources and its work items, as the ledger sorts them.
  let src = sources(spath)
  let sid = SessionId(extractFilename(spath).substr(0, extractFilename(spath).len - 7))
  let cwd = sessionCwd(src.recs).get(homeDir())
  var turnBy = initTable[string, Turn]()
  for t in src.turns: turnBy[t.key] = t
  var agentBy = initTable[string, Agent]()
  for a in src.agents: agentBy[a.key] = a
  var commitBy = initTable[string, Commit]()
  for c in src.commits: commitBy[c.key] = c
  var items: seq[WorkItem] = @[]
  for it in loadLedger(sid).items:
    var w = WorkItem(n: it.id, title: it.title)
    var cms: seq[Commit] = @[]
    for k in it.sources:
      if k in turnBy: w.turns.add turnBy.getOrDefault(k, Turn())
      elif k in agentBy: w.agents.add agentBy.getOrDefault(k, Agent())
      elif k in commitBy: cms.add commitBy.getOrDefault(k, Commit())
    w.code = if cms.len > 0: currentCode(cms, withDiff) else: Code()
    items.add w
  Collected(session: sid, cwd: cwd, repo: git(cwd, ["rev-parse", "--show-toplevel"]).get(cwd),
            config: loadConfig(cwd, configFile), sources: src, items: items,
            generated: localStamp())

proc codeTips*(spath, configFile: string): Table[int, string] =
  ## {item: the tip of its current code}, for the stale check of saved decisions.
  result = initTable[int, string]()
  for it in collect(spath, configFile, withDiff = false).items: result[it.n] = it.code.tip

# --------------------------------------------------------------------- build

const MonthAbbr = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

proc updated*(d: Collected): string =
  ## 'Nimony, updated 17:57' (the project's directory name); the date only when
  ## the data is not from today.
  let name = extractFilename(d.repo)
  let title = name.substr(0, 0).toUpperAscii & name.substr(1)
  let g = d.generated   # "YYYY-MM-DD HH:MM", local time
  if g.substr(0, 9) == localStamp().substr(0, 9): return title & ", updated " & g.substr(11)
  let m = try: parseInt(g.substr(5, 6)) except: 0
  let day = try: parseInt(g.substr(8, 9)) except: 0
  if m < 1 or m > 12: return title
  title & ", updated " & MonthAbbr[m - 1] & " " & $day & " " & g.substr(11)

proc staticDir*(): string = appDir() & "/static"

proc build*(spath, configFile, outDir: string): string =
  ## Writes the pages into outDir and returns the index's path. Deletes only pages
  ## of items that are gone; every file is written atomically.
  let d = collect(spath, configFile)
  ensureDir(outDir)
  var nums: seq[int] = @[]
  var titles = initTable[int, string]()
  for r in d.items:
    nums.add r.n
    titles[r.n] = r.title
  nums.sort()
  try:
    for (kind, p) in walkDir(path(outDir)):   # only pages of items that are gone; nothing else in out
      let name = extractFilename($p)
      if name.startsWith("i") and name.endsWith(".html") and name.len > 6 and
          name.substr(1, name.len - 6).allCharsInSet(Digits):
        let n = try: parseInt(name.substr(1, name.len - 6)) except: -1
        if n notin titles: removeFile(p)
  except: discard
  var briefs = initTable[int, Cached]()
  for r in d.items:
    let b = load(d.session, r.n)
    if b.isSome: briefs[r.n] = b.get(Cached())
  for r in d.items:
    let i = nums.find(r.n)
    let prev = if i > 0: nums[i - 1] else: 0
    let nxt = if i + 1 < nums.len: nums[i + 1] else: 0
    let b = if r.n in briefs: some(briefs.getOrDefault(r.n, Cached())) else: none[Cached]()
    writeAtomic(outDir & "/i" & $r.n & ".html",
                itemPage(r, d, b, prev, nxt, titles.getOrDefault(nxt, "")))
  try:
    for (kind, p) in walkDir(path(staticDir())):   # the pages' CSS and JS, beside them so file mode works too
      writeAtomic(outDir & "/" & extractFilename($p), readFile($p))
  except: die("hitl: cannot read " & staticDir())
  var tips = initTable[string, string]()
  for r in d.items: tips[$r.n] = r.code.tip
  writeAtomic(outDir & "/tips.json", toJson(tips).get("{}"))
  result = outDir & "/index.html"
  writeAtomic(result, indexPage(d, briefs, updated(d)))

proc builtTips*(outDir: string): Opt[Table[int, string]] =
  ## {item: code tip} as the last build found them, for the page's stale marks.
  let t = readText(outDir & "/tips.json")
  if t.isNone: return none[Table[int, string]]()
  case fromJson(t.get(""), Table[string, string])
  of Ok(raw):
    var tips = initTable[int, string]()
    for k, v in raw:
      let n = try: parseInt(k) except: return none[Table[int, string]]()
      tips[n] = v
    result = some(tips)
  of Err(_): result = none[Table[int, string]]()
