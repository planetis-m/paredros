## The work a session did, as data: its sources (turns, agents, commits, each
## under a stable key), the commits matched to the git calls that made them,
## each work item's current code, and `collect`, which joins them with the
## ledger and the briefs. Read only: transcripts and git, through session.nim.

import std/[strutils, parseutils, os, envvars, tables, sets, algorithm, rex, times, opt, result]
import session, config, brief

const EmptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# reflog entries that made a commit: commit, amend, merge with conflicts,
# cherry-pick, revert, am, rebase steps (no \b after "rebase (pick)": its ")"
# is followed by ":", so \b would never match)
let made = re(r"^(?:(?:commit|cherry-pick|revert|am)\b|rebase(?:\ -i)?\ \((?:pick|reword|edit|squash|fixup|continue)\))",
              {reExtended, reAllowEvil})
let reflogTime = re"@\{(\d+)\}$"

proc digits(s: string; at, n: int): int =
  ## The n digits at s[at] as a number; -1 when they are not n digits.
  result = -1
  if at >= 0 and at + n <= s.len and allCharsInSet(s.substr(at, at + n - 1), Digits):
    var v: BiggestInt = 0
    discard parseBiggestInt(s.toOpenArray(at, at + n - 1), v)
    result = int(v)

proc epoch*(ts: string): float =
  ## ISO time from a transcript (UTC, 'Z') or git (with offset) as epoch
  ## seconds; 0 when it is not one.
  # GAP: only YYYY-MM-DDTHH:MM:SS, with a fraction, then Z, ±HH:MM or no zone,
  # is read (Python's fromisoformat reads more forms), and a time with no zone
  # is taken as UTC where Python takes the local zone, because std/times has
  # no parse (bug-reports/119-times-cannot-parse-a-date).
  result = 0.0
  let (y, mo, d) = (digits(ts, 0, 4), digits(ts, 5, 2), digits(ts, 8, 2))
  let (h, mi, s) = (digits(ts, 11, 2), digits(ts, 14, 2), digits(ts, 17, 2))
  var ok = ts.len >= 19 and ts[4] == '-' and ts[7] == '-' and ts[10] in {'T', ' '} and
    ts[13] == ':' and ts[16] == ':' and y >= 1 and mo in 1..12 and h in 0..23 and
    mi in 0..59 and s in 0..59
  ok = ok and d in 1..int(getDaysInMonth(Month(mo), y))
  var fraction = 0.0
  var i = 19   # after the seconds: a fraction, then the zone
  if ok and i < ts.len and ts[i] == '.':
    inc i
    ok = i < ts.len and ts[i] in Digits
    var scale = 0.1
    while i < ts.len and ts[i] in Digits:
      fraction += scale * float(ord(ts[i]) - ord('0'))
      scale /= 10
      inc i
  var offset = 0   # the zone's offset east of UTC, in seconds
  if not ok or i == ts.len or (i == ts.len - 1 and ts[i] == 'Z'):
    discard
  elif i == ts.len - 6 and ts[i] in {'+', '-'} and ts[i + 3] == ':' and
      digits(ts, i + 1, 2) in 0..23 and digits(ts, i + 4, 2) in 0..59:
    offset = (digits(ts, i + 1, 2) * 60 + digits(ts, i + 4, 2)) * 60
    if ts[i] == '-': offset = -offset
  else:
    ok = false
  if ok:
    let t = initDateTime(y, Month(mo), int32(d), int32(h), int32(mi), int32(s)).toTime
    result = float(t.toUnix - offset) + fraction

proc turns*(recs: seq[Rec]): seq[Turn] =
  ## The main transcript cut at each message the human typed: what they said
  ## and everything the session said until the next one.
  result = @[]
  for r in recs:
    if isHuman(r) and textOf(r).len > 0:
      result.add Turn(key: "turn:" & (if r.uuid.len > 0: r.uuid else: r.timestamp),
                      time: r.timestamp, human: textOf(r), texts: @[])
    elif r.kind == "assistant" and result.len > 0:
      for t in assistantTexts([r]): result[^1].texts.add t.text

const
  Slack = 2.0      # seconds around a call: reflog times are whole seconds
  NoResult = 120.0 # a call with no recorded result (cut off, or still running) counts this long

type
  Transcript* = object
    ## A transcript of the session, with whose it is.
    owner*: Opt[string]  ## none for the main session, else the agent's key
    recs*: seq[Rec]
  GitCall* = object
    ## A git command that can make commits.
    dir*: string         ## where it ran
    start*, finish*: float  ## the call and its recorded result, in epoch seconds
    owner*: Opt[string]  ## whose transcript made it

proc gitCalls*(transcripts: seq[Transcript]): seq[GitCall] =
  ## Every git command that can make commits, per transcript, so a commit is
  ## matched to the call that made it. The directory is the command's own
  ## `cd` or `git -C` target where it still exists, else the directory the
  ## transcript ran in (a deleted worktree's branch reflogs live on in its
  ## repository).
  result = @[]
  for t in transcripts:
    for w in gitWrites(t.recs):
      let start = epoch(w.start)
      let finish = if w.done.isSome: epoch(w.done.get("")) else: start + NoResult
      var dirs: seq[string] = @[]
      for d in w.dirs:
        if dirExists(d) and d notin dirs: dirs.add d
      if dirs.len == 0 and w.cwd.isSome: dirs.add w.cwd.get("")
      for d in dirs:
        result.add GitCall(dir: d, start: start, finish: finish, owner: t.owner)

proc sessionCommits*(transcripts: seq[Transcript]): seq[Commit] =
  ## The commits the session made, oldest first, each with the transcript
  ## that made it ("agent"). Every reflog of the repository (each worktree's
  ## HEAD and each branch, so a deleted worktree's commits are still found)
  ## is read once; an entry counts when it made a commit during one of the
  ## session's committing calls in that repository (so the human's and other
  ## sessions' commits stay out) and is still reachable from a ref (so
  ## commits replaced by an amend or a rebase drop out).
  var calls = initTable[string, seq[GitCall]]()   # per common git directory, in first-seen order
  var tops = initTable[string, string]()
  for c in gitCalls(transcripts):
    let common = git(c.dir, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).get("")
    if common.len > 0:
      if common notin calls:
        calls[common] = @[]
        let top = git(c.dir, ["rev-parse", "--show-toplevel"]).get("")
        tops[common] = if top.len > 0: top else: c.dir
      calls.getOrQuit(common).add c
  var found: seq[Commit] = @[]
  var shas = initHashSet[string]()
  for common, wins in pairs(calls):
    let top = tops.getOrDefault(common, "")
    var first = wins[0].start
    for w in wins: first = min(first, w.start)
    var live = initHashSet[string]()   # what a ref still reaches
    let since = "--since=" & $(int(first) - 60)
    for sha in git(top, ["rev-list", "--all", since], 60).get("").splitWhitespace: live.incl sha
    var byEnd = wins
    byEnd.sort(proc (a, b: GitCall): int = cmp(a.finish, b.finish))
    let log = git(top, ["log", "-g", "--all", "--date=unix", "--format=%H%x09%gd%x09%gs"],
                  60).get("")
    for line in log.splitLines:
      var parts = line.split('\t', 2)
      while parts.len < 3: parts.add ""
      let (sha, sel, msg) = (parts[0], parts[1], parts[2])
      var caps: seq[Capture] = @[]
      let at = findBounds(sel, reflogTime, caps)[0]
      let time = if at >= 0: (try: parseBiggestInt(capture(sel, caps, 0)) except: 0'i64) else: 0'i64
      if sha notin shas and msg.startsWith(made) and sha in live:
        var owner = none[string]()
        var hit = false
        for w in byEnd:
          if not hit and w.start - Slack <= float(time) and float(time) <= w.finish + Slack:
            owner = w.owner
            hit = true
        if hit:
          shas.incl sha
          found.add Commit(key: "", sha: sha, repo: top, common: common, time: time, agent: owner,
                           subject: "", parents: @[])
  for c in mitems(found):
    let line = git(c.repo, ["log", "-1", "--format=%s%x09%P", c.sha]).get("\t")
    let tab = line.rfind('\t')
    c.subject = line.substr(0, tab - 1)
    c.parents = line.substr(tab + 1).splitWhitespace
  found.sort(proc (a, b: Commit): int = cmp(a.time, b.time))
  result = found

proc sources*(spath: string): Sources =
  ## What a work item can be made of, each under a stable key: turns, agents,
  ## commits; and the directory the session ran in.
  let recs = readJsonl(spath)
  var transcripts = @[Transcript(owner: none[string](), recs: recs)]
  var workers: seq[Worker] = @[]
  for a in agents(spath):
    let key = "agent:" & a.id
    workers.add Worker(key: key, agent: a, report: finalReport(a.recs).get(""))
    transcripts.add Transcript(owner: some(key), recs: a.recs)
  var commits = sessionCommits(transcripts)
  for c in mitems(commits): c.key = "commit:" & c.sha
  result = Sources(recs: recs, cwd: sessionCwd(recs).get(getEnv("HOME")), turns: turns(recs),
                   agents: workers, commits: commits)

proc isParent(c: Commit; others: seq[Commit]): bool =
  ## Whether another of these commits builds on c.
  result = false
  for o in others:
    if c.sha in o.parents: result = true

proc currentCode*(commits: seq[Commit]; diff = true): Code =
  ## The code an item has now, per repository (worktrees of one repository
  ## are one): its newest commit, every commit of the item that is an
  ## ancestor of it, and the diff of each unbroken run of them. The item's
  ## other commits are earlier attempts.
  var cur, earlier: seq[Commit] = @[]
  var diffs: seq[string] = @[]
  var commons: seq[string] = @[]
  for c in commits:
    if c.common notin commons: commons.add c.common
  for common in commons:
    var mine: seq[Commit] = @[]
    for c in commits:
      if c.common == common: mine.add c
    let repo = mine[0].repo
    var tip = 0   # the newest; the first of those made in the same second
    for i, c in mine:
      if c.time > mine[tip].time: tip = i
    var keep: seq[Commit] = @[]
    for i, c in mine:
      if i == tip or git(repo, ["merge-base", "--is-ancestor", c.sha, mine[tip].sha]).isSome:
        keep.add c
      else:
        earlier.add c
    for c in keep: cur.add c
    for c in keep:   # each run ends at a commit no other kept commit builds on
      if diff and not isParent(c, keep):
        var first = c
        var more = true
        while more:
          more = false
          if first.parents.len > 0:
            for o in keep:
              if not more and o.sha == first.parents[0]:
                first = o
                more = true
        let base = if first.parents.len > 0: first.parents[0] else: EmptyTree
        diffs.add git(repo, ["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff",
                             "-M", base, c.sha], 60).get("")
  var tips: seq[string] = @[]
  for c in cur:
    if not isParent(c, cur): tips.add c.sha.substr(0, 11)
  tips.sort()
  result = Code(commits: cur, earlier: earlier, tip: tips.join(","), diff: diffs.join("\n"))

proc collect*(spath: string; cfg: Config; src: Sources; diff = true): Result[Work, string] =
  ## The session's sources and its work items, as the ledger sorts them, each
  ## with its cached brief and that brief's inputs hash. The error says why
  ## the ledger cannot be read.
  let sid = extractFilename(spath).changeFileExt("")
  let led = loadLedger(sid)
  if led.isErr: return err[Work, string](led.error(""))
  var byKey = initTable[string, (char, int)]()   # a source's kind and place in src
  for i, t in src.turns: byKey[t.key] = ('t', i)
  for i, a in src.agents: byKey[a.key] = ('a', i)
  for i, c in src.commits: byKey[c.key] = ('c', i)
  var items: seq[WorkItem] = @[]
  for it in led.get(Ledger()).items:
    var r = WorkItem(n: it.id, title: it.title, brief: none[Brief](), inputs: "", turns: @[],
                     agents: @[], code: Code(commits: @[], earlier: @[], tip: "", diff: ""))
    var cms: seq[Commit] = @[]
    for k in it.sources:
      if k in byKey:
        let (kind, i) = byKey.getOrDefault(k, (' ', 0))
        case kind
        of 't': r.turns.add src.turns[i]
        of 'a': r.agents.add src.agents[i]
        else: cms.add src.commits[i]
    let cached = load(sid, it.id)
    if cached.isSome:
      r.brief = some(cached.get(Cached()).brief)
      r.inputs = cached.get(Cached()).inputs
    if cms.len > 0: r.code = currentCode(cms, diff)
    items.add r
  let top = git(src.cwd, ["rev-parse", "--show-toplevel"]).get("")
  result = ok[Work, string](Work(session: sid, cwd: src.cwd,
                                 repo: if top.len > 0: top else: src.cwd, config: cfg,
                                 sources: src, items: items, generated: local(getTime())))

proc codeTips*(spath: string): Result[Table[int, string], string] =
  ## {item: the tip of its current code}, for the stale check of saved
  ## decisions. The error says why the config or the ledger cannot be read.
  let src = sources(spath)
  let cfg = config.load(src.cwd)
  if cfg.isErr: return err[Table[int, string], string](cfg.error(""))
  let d = collect(spath, cfg.get(defaults()), src, diff = false)
  if d.isErr: return err[Table[int, string], string](d.error(""))
  var tips = initTable[int, string]()
  for r in d.get(Work()).items: tips[r.n] = r.code.tip
  result = ok[Table[int, string], string](tips)
