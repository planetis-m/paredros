## The shared base of hitl: state paths, the project config, the one adapter to
## Claude Code's transcript format, git, the process runner and the agents.
## Everything here is read only, except the state directory.

import std/[syncio, strutils, os, paths, dirs, files, envvars, times, tables, opt, result, osproc,
            monotimes, algorithm, rex, sha1]
from std/unicode import runeLen, runeSubStr, validateUtf8
import kroki

type
  SessionId* = distinct string   ## a Claude Code session id (a uuid)
  StateKind* = enum              ## the folders under $STATE, one per session
    skReview = "review", skBriefs = "briefs", skDirections = "directions", skScratch = "scratch"

proc `==`*(a, b: SessionId): bool {.borrow.}
proc `$`*(s: SessionId): string {.borrow.}
proc short*(s: SessionId): string = string(s).substr(0, 7)
  ## The first 8 characters: the session's folder name and `--session` value.

# ------------------------------------------------------------------- errors

proc die*(msg: string) {.noreturn.} =
  ## sys.exit(msg): the message on stderr, exit code 1.
  stderr.write msg & "\n"
  quit(1)

proc quoted*(s: string): string =
  ## Python's repr() of a string, for the messages that quote one.
  let q = if '\'' in s and '"' notin s: '"' else: '\''
  result = $q
  for c in s:
    if c == '\\': result.add "\\\\"
    elif c == '\n': result.add "\\n"
    elif c == '\r': result.add "\\r"
    elif c == '\t': result.add "\\t"
    elif c == q: result.add "\\" & c
    elif c < ' ' or c == '\x7f': result.add "\\x" & toHex(ord(c), 2).toLowerAscii
    else: result.add c
  result.add q

# -------------------------------------------------------------------- paths

proc homeDir*(): string = getEnv("HOME")

proc claudeDir*(): string = getEnv("CLAUDE_CONFIG_DIR", homeDir() & "/.claude")
proc projectsDir*(): string = claudeDir() & "/projects"
proc stateRoot*(): string = getEnv("XDG_STATE_HOME", homeDir() & "/.local/state") & "/hitl"

proc state*(kind: StateKind; sid: SessionId): string =
  ## The one place a session's state folder is named: $STATE/<kind>/<first 8 of the id>.
  stateRoot() & "/" & $kind & "/" & sid.short

proc companionsFile*(): string = stateRoot() & "/companions"
  ## session ids of companion forks, one per line

proc appDir*(): string =
  ## The repository the binary was built in: bin/hitl -> its parent. The
  ## pages' static files and the companion prompt are read from there.
  parentDir(parentDir(getAppFilename()))

proc ensureDir*(dir: string) =
  try: createDir(path(dir))
  except: discard

proc writeAtomic*(path, text: string) =
  ## Temp file, then rename: a reader gets the old file or the new one.
  let tmp = parentDir(path) & "/." & extractFilename(path) & ".tmp"
  try:
    writeFile(tmp, text)
    moveFile(paths.path(tmp), paths.path(path))
  except:
    die("hitl: cannot write " & path)

proc readText*(path: string): Opt[string] =
  try: some(readFile(path)) except: none[string]()

proc isDir*(path: string): bool = dirExists(path)

# ------------------------------------------------------------------ strings

proc fixUtf8*(s: string): string =
  ## Python's errors="replace": an invalid UTF-8 byte becomes U+FFFD.
  if validateUtf8(s) < 0: return s
  result = ""
  var pos = 0
  while pos < s.len:
    let c = ord(s[pos])
    let n = if c < 0x80: 1 elif c shr 5 == 0b110: 2 elif c shr 4 == 0b1110: 3
            elif c shr 3 == 0b11110: 4 else: 0
    if n > 0 and pos + n <= s.len and validateUtf8(s.substr(pos, pos + n - 1)) < 0:
      result.add s.substr(pos, pos + n - 1)
      pos += n
    else:
      result.add "\xEF\xBF\xBD"
      inc pos

proc runeSlice*(s: string; first, last: int): string =
  ## s[first:last] on code points, Python's slice: negative counts from the end.
  let n = s.runeLen
  var a = if first < 0: max(n + first, 0) else: min(first, n)
  var b = if last < 0: max(n + last, 0) else: min(last, n)
  if b <= a: return ""
  result = s.runeSubStr(a, b - a)

proc runeHead*(s: string; n: int): string = runeSlice(s, 0, n)
proc runeTail*(s: string; n: int): string =
  ## s[-n:]
  if n <= 0: s else: runeSlice(s, -n, high(int))

proc collapse*(s: string): string =
  ## " ".join(s.split())
  result = ""
  for w in s.splitWhitespace:
    if result.len > 0: result.add ' '
    result.add w

proc short*(text: string; n = 90): string =
  let t = collapse(text)
  if t.runeLen <= n: t else: t.runeHead(n - 1) & "…"

proc padRight*(s: string; n: int): string =
  ## f"{s:<n}"
  s & repeat(' ', max(n - s.runeLen, 0))

proc padLeft*(s: string; n: int): string =
  ## f"{s:>n}"
  repeat(' ', max(n - s.runeLen, 0)) & s

proc ago*(seconds: float): string =
  let s = int(seconds)
  if s < 90: $s & "s" elif s < 5400: $(s div 60) & "m" else: $(s div 3600) & "h"

proc nowSeconds*(): float =
  let t = getTime()
  float(t.seconds) + float(t.nanosecond) / 1e9

proc mtimeSeconds*(path: string): float =
  let ns = try: getLastModificationTime(path) except: 0'i64
  float(ns) / 1e9

proc localStamp*(withSeconds = false; sep = ' '): string =
  ## time.strftime("%Y-%m-%d %H:%M") in local time; with seconds and "T" for briefs.
  let t = local(getTime())
  result = $t.year & "-" & align($ord(t.month), 2, '0') & "-" & align($t.monthday, 2, '0') &
    $sep & align($t.hour, 2, '0') & ":" & align($t.minute, 2, '0')
  if withSeconds: result.add ":" & align($t.second, 2, '0')

# ------------------------------------------------------------------ process

type
  Job* = object
    argv*: seq[string]
    cwd*, input*: string
    timeoutMs*: int
  Ran* = object
    code*: int             ## exit code; -1 when it could not start
    output*, errors*: string
    started*: bool
  Running = object
    p: Process
    ok: bool

proc launch(j: Job): Running =
  ## Starts the job and hands it its whole input.
  # Known issue: bug-reports/105-osproc-pipes-inherited-by-later-children. Each
  # child gets its input and the end of it before the next one starts.
  result = Running(ok: false)
  try:
    result.p = startProcess(j.argv[0], workingDir = j.cwd, args = j.argv.toOpenArray(1, j.argv.high),
                            options = {poUsePath})
    result.ok = true
    let inp = result.p.inputStream
    if j.input.len > 0: inp.write(j.input)
    inp.close()
  except: discard

proc collect(r: Running; j: Job): Ran =
  ## Reads what the job wrote and waits for it to end.
  # Known issue: osproc has no `communicate`, so stdout is read to its end before
  # stderr; a child that fills the stderr pipe first would wait for us. The
  # timeout applies only once both pipes are closed.
  if not r.ok: return Ran(code: -1, errors: "cannot start " & j.argv[0])
  result = Ran(code: -1, started: true)
  try:
    result.output = fixUtf8(r.p.outputStream.readAll())
    result.errors = fixUtf8(r.p.errorStream.readAll())
    result.code = r.p.waitForExit(j.timeoutMs)
    r.p.close()
  except: discard

proc run*(j: Job): Ran = collect(launch(j), j)

proc runAll*(jobs: seq[Job]; parallel: int): seq[Ran] =
  ## Runs every job, at most `parallel` at once; results in job order.
  result = newSeq[Ran](jobs.len)
  var running: seq[Running] = @[]
  var next, done = 0
  while done < jobs.len:
    while next < jobs.len and next - done < max(parallel, 1):
      running.add launch(jobs[next])
      inc next
    result[done] = collect(running[done], jobs[done])
    inc done

proc git*(wd: string; args: openArray[string]; timeoutMs = 20_000): Opt[string] =
  ## Read-only git: never takes the index lock. None when git fails.
  var argv = @["git", "--no-optional-locks", "-C", wd]
  for a in args: argv.add a
  let r = run(Job(argv: argv, timeoutMs: timeoutMs))
  if r.started and r.code == 0: some(r.output.strip(leading = false, chars = {'\n'}))
  else: none[string]()

# --------------------------------------------------------------- transcripts

type
  RecKind* = enum rkOther, rkUser, rkAssistant
  BlockKind* = enum bkOther, bkText, bkToolUse
  Input* = object          ## the tool_use input fields hitl reads
    command*, description*, filePath*, pattern*, message*: string
  Block* = object
    kind*: BlockKind
    text*, name*: string
    input*: Input
  ContentKind* = enum ckNone, ckText, ckBlocks
  Rec* = object            ## one transcript line
    kind*: RecKind
    timestamp*, uuid*, cwd*: string
    human*: bool           ## origin.kind == "human" or promptSource == "typed"
    case content*: ContentKind
    of ckNone: discard
    of ckText: text*: string
    of ckBlocks: blocks*: seq[Block]
  Call* = object           ## a tool use and when it was made
    timestamp*: string
    tool*: Block

proc str(dst: var string; p: var JsonParser) =
  ## A string field; any other JSON type reads as absent, as Python's `.get` sees it.
  if p.kind == jkString: readJson(dst, p, ufSkip) else: p.skipJson()

proc readJson*(dst: var Input; p: var JsonParser; u: UnknownFieldPolicy) =
  if p.kind != jkObject:
    p.skipJson()
    return
  for f in p.jsonFields:
    if f == "command": str(dst.command, p)
    elif f == "description": str(dst.description, p)
    elif f == "file_path": str(dst.filePath, p)
    elif f == "pattern": str(dst.pattern, p)
    elif f == "message": str(dst.message, p)
    else: p.skipJson()

proc readJson*(dst: var Block; p: var JsonParser; u: UnknownFieldPolicy) =
  if p.kind != jkObject:
    p.skipJson()
    return
  for f in p.jsonFields:
    if f == "type":
      var t = ""
      str(t, p)
      dst.kind = if t == "text": bkText elif t == "tool_use": bkToolUse else: bkOther
    elif f == "text": str(dst.text, p)
    elif f == "name": str(dst.name, p)
    elif f == "input": readJson(dst.input, p, u)
    else: p.skipJson()

proc readJson*(dst: var Rec; p: var JsonParser; u: UnknownFieldPolicy) =
  if p.kind != jkObject:
    p.parseError()
    return
  var originHuman, typed = false
  for f in p.jsonFields:
    if f == "type":
      var t = ""
      str(t, p)
      dst.kind = if t == "user": rkUser elif t == "assistant": rkAssistant else: rkOther
    elif f == "timestamp": str(dst.timestamp, p)
    elif f == "uuid": str(dst.uuid, p)
    elif f == "cwd": str(dst.cwd, p)
    elif f == "promptSource":
      var s = ""
      str(s, p)
      typed = s == "typed"
    elif f == "origin":
      if p.kind == jkObject:
        for g in p.jsonFields:
          if g == "kind":
            var k = ""
            str(k, p)
            originHuman = k == "human"
          else: p.skipJson()
      else: p.skipJson()
    elif f == "message":
      if p.kind == jkObject:
        for g in p.jsonFields:
          if g == "content":
            case p.kind
            of jkString:
              var s = ""
              readJson(s, p, u)
              dst = Rec(kind: dst.kind, timestamp: dst.timestamp, uuid: dst.uuid, cwd: dst.cwd,
                        content: ckText, text: s)
            of jkArray:
              var bs: seq[Block] = @[]
              readJson(bs, p, u)
              dst = Rec(kind: dst.kind, timestamp: dst.timestamp, uuid: dst.uuid, cwd: dst.cwd,
                        content: ckBlocks, blocks: bs)
            else: p.skipJson()
          else: p.skipJson()
      else: p.skipJson()
    else: p.skipJson()
  dst.human = originHuman or typed

proc readJsonl*(path: string): seq[Rec] =
  ## Every readable record of a transcript; unreadable lines are skipped.
  result = @[]
  let text = readText(path)
  if text.isNone: return
  for r in jsonLines[Rec](fixUtf8(text.get(""))):
    if r.isOk: result.add r.get(Rec())

iterator blocksOf(r: Rec): Block =
  if r.content == ckBlocks:
    for b in r.blocks: yield b

iterator toolUses*(recs: seq[Rec]): Call =
  for r in recs:
    if r.kind == rkAssistant:
      for b in r.blocksOf:
        if b.kind == bkToolUse: yield Call(timestamp: r.timestamp, tool: b)

iterator assistantTexts*(recs: seq[Rec]): (string, string) =
  ## (timestamp, text) for every assistant text block, in order.
  for r in recs:
    if r.kind == rkAssistant:
      for b in r.blocksOf:
        if b.kind == bkText and b.text.strip.len > 0: yield (r.timestamp, b.text)

proc isHuman*(r: Rec): bool =
  ## A message the human typed (not a tool result or an injected prompt).
  r.kind == rkUser and r.human

proc stripPasted(t: string): string =
  ## re.sub(r"</?pasted_content[^>]*>", "", t)
  result = ""
  var i: Natural = 0
  while i < t.len:
    if t[i] == '<':
      var j: Natural = i + 1
      if j < t.len and t[j] == '/': inc j
      if t.continuesWith("pasted_content", j):
        let close = t.find('>', j)
        if close >= 0:
          i = close + 1
          continue
    result.add t[i]
    inc i

proc textOf*(r: Rec): string =
  var t = ""
  case r.content
  of ckText: t = r.text
  of ckBlocks:
    var parts: seq[string] = @[]
    for b in r.blocks:
      if b.kind == bkText: parts.add b.text
    t = parts.join(" ")
  of ckNone: discard
  stripPasted(t).strip

proc sessionCwd*(recs: seq[Rec]): Opt[string] =
  for r in recs:
    if r.cwd.len > 0: return some(r.cwd)
  none[string]()

# ------------------------------------------------------------------ sessions

type
  Session* = object
    mtime*: float
    id*: SessionId
    path*, project*: string

proc sessions*(): seq[Session] =
  ## Main transcripts, newest first.
  result = @[]
  if not isDir(projectsDir()): return
  try:
    for (kind, pp) in walkDir(path(projectsDir())):
      if kind notin {pcDir, pcLinkToDir}: continue
      let proj = $pp
      for (k2, fp) in walkDir(pp):
        let p = $fp
        if k2 in {pcFile, pcLinkToFile} and p.endsWith(".jsonl"):
          let name = extractFilename(p)
          result.add Session(mtime: mtimeSeconds(p), id: SessionId(name.substr(0, name.len - 7)),
                             path: p, project: extractFilename(proj))
  except: discard
  result.sort(proc (a, b: Session): int =
    result = cmp(b.mtime, a.mtime)
    if result == 0: result = cmp(string(b.id), string(a.id))
    if result == 0: result = cmp(b.path, a.path)
    if result == 0: result = cmp(b.project, a.project))

proc companionIds*(): seq[string] =
  result = @[]
  let t = readText(companionsFile())
  if t.isSome:
    for w in t.get("").splitWhitespace: result.add w

proc projectName*(dir: string): string =
  ## re.sub(r"[^A-Za-z0-9]", "-", dir)
  result = dir
  for c in result.mitems:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9'}: c = '-'

proc pickSession*(spec: string): Session =
  ## The newest session matching spec (an id prefix or a project-name substring),
  ## else the newest one of the current directory's project, else the newest.
  let forks = companionIds()   # a fork is a full copy of the session's transcript
  var all: seq[Session] = @[]
  for s in sessions():
    if $s.id notin forks: all.add s
  var hits: seq[Session] = @[]
  if spec.len > 0:
    for s in all:
      if ($s.id).startsWith(spec) or spec in s.project: hits.add s
  else:
    let here = projectName(try: os.getCurrentDir() except: "")
    for s in all:
      if s.project == here: hits.add s
    if hits.len == 0: hits = all
  if hits.len == 0:
    die(if spec.len > 0: "hitl: no session matches " & quoted(spec) else: "hitl: no Claude Code session found")
  hits[0]

# -------------------------------------------------------------------- config

type
  Compare* = object
    label*, prompt*: string
    allow*: seq[string]
  Config* = object
    spec*: string
    reader*: string = "a developer of this project"
    users*: string = "the project's users"
    compare*: Opt[Compare]

proc readConfig*(cwd: string; configFile: string): Result[Config, string] =
  ## The project's optional settings (README, "Config"); every key may be left out.
  ## The error is the message hitl exits with.
  let p = if configFile.len > 0: configFile else: (if cwd.len > 0: cwd else: ".") & "/.hitl.json"
  if not fileExists(p):
    if configFile.len > 0: return err[Config, string]("hitl: no config file " & p)
    return ok[Config, string](Config())
  let text = readText(p)
  if text.isNone: return err[Config, string]("hitl: cannot read " & p)
  var cfg = Config()
  case fromJson(text.get(""), Config, unknownFields = ufReject)
  of Ok(c): cfg = c
  of Err(e): return err[Config, string]("hitl: cannot read " & p & ": " & $e)
  if cfg.compare.isSome:
    let c = cfg.compare.get(Compare())
    if c.label.len == 0 or c.prompt.len == 0:
      return err[Config, string]("hitl: compare in " & p & " needs a label and a prompt")
  ok[Config, string](cfg)

proc loadConfig*(cwd: string; configFile: string): Config =
  case readConfig(cwd, configFile)
  of Ok(c): result = c
  of Err(e): die(e)

proc expand*(text, scratch: string): string =
  text.replace("{scratch}", scratch).replace("{home}", homeDir())

# --------------------------------------------------------------------- agents

let
  cdRe = re"""(?:^|[;&|(]\s*)(?:cd|pushd)\s+["']?(/[^\s"';&|)]+)"""
  gitcRe = re"""git\s+-C\s+["']?(/[^\s"';&|)]+)"""
  pathRe = re"""(/[\w./-]+)"""

proc findAllGroup*(s: string; r: Regex): seq[string] =
  ## Python's re.findall for a pattern with one group.
  result = @[]
  var start = 0
  var caps: seq[Capture] = @[]
  while start <= s.len:
    let (a, b) = findBounds(s, r, caps, start)
    if a < 0: break
    result.add capture(s, caps, 0)
    start = if b >= a: b + 1 else: a + 1

proc cdTargets*(cmd: string): seq[string] = findAllGroup(cmd, cdRe)
proc gitcTargets*(cmd: string): seq[string] = findAllGroup(cmd, gitcRe)

proc describeCall*(c: Block): string =
  let i = c.input
  let detail = if i.description.len > 0: i.description elif i.command.len > 0: i.command
               elif i.filePath.len > 0: i.filePath else: i.pattern
  c.name & ": " & short(detail, 70)

proc workdirOf*(recs: seq[Rec]; prompt: string): Opt[string] =
  ## The directory an agent worked in: the most named `cd`/`git -C` target that exists.
  var count = initTable[string, int]()   # insertion-ordered, as Counter
  for c in toolUses(recs):
    if c.tool.name == "Bash":
      for d in cdTargets(c.tool.input.command): count[d] = count.getOrDefault(d) + 1
      for d in gitcTargets(c.tool.input.command): count[d] = count.getOrDefault(d) + 1
  if count.len == 0:
    for d in findAllGroup(prompt, pathRe): count[d] = count.getOrDefault(d) + 1
  var order: seq[(string, int, int)] = @[]   # most_common: by count, then first seen
  var k = 0
  for d, n in count:
    order.add (d, n, k)
    inc k
  order.sort(proc (a, b: (string, int, int)): int =
    result = cmp(b[1], a[1])
    if result == 0: result = cmp(a[2], b[2]))
  for (d, _, _) in order:
    let path = d.strip(leading = false, chars = {'/', '.'})
    if path.len == 0: return none[string]()   # Path("").is_dir(): the empty, falsy workdir
    if isDir(path): return some(path)
  none[string]()

type
  AgentState* = enum asDone = "done", asRunning = "running", asQuiet = "quiet"
  Agent* = object
    id*, path*, prompt*, description*, label*, start*: string
    recs*: seq[Rec]
    calls*: seq[Call]
    finished*: bool
    age*: float
    workdir*: Opt[string]
    # filled by review.sources
    report*: string
    top*: Opt[string]
    endTime*: float
  GitSummary* = object
    top*, branch*, ahead*: string
    dirty*: int
  Meta = object
    description: string
    finished: bool

proc readJson(dst: var Meta; p: var JsonParser; u: UnknownFieldPolicy) =
  if p.kind != jkObject:
    p.parseError()
    return
  for f in p.jsonFields:
    if f == "description": str(dst.description, p)
    elif f == "finished" and p.kind == jkBool: readJson(dst.finished, p, u)
    else: p.skipJson()

const QuietAfter* = 1800.0  ## seconds without transcript writes before "quiet"; sweeps run long

proc finalReport*(recs: seq[Rec]): string =
  result = ""
  for c in toolUses(recs):
    if c.tool.name == "SubagentHandback": result = c.tool.input.message
  if result.len > 0: return
  for (_, t) in assistantTexts(recs): result = t

proc pathParts(p: string): seq[string] =
  ## Path(p).parts
  result = @["/"]
  for x in p.split('/'):
    if x.len > 0: result.add x

proc commonSplitLen(a, b: string): int =
  ## len(os.path.commonpath([a, b]).split(os.sep)) for absolute paths
  let pa = pathParts(a)
  let pb = pathParts(b)
  var n = 0
  while n < min(pa.len, pb.len) and pa[n] == pb[n]: inc n
  result = if n <= 1: 2 else: n   # "/" splits into ['', '']; "/a/b" into ['', 'a', 'b']

proc agents*(sessionPath: string): seq[Agent] =
  let base = sessionPath.substr(0, sessionPath.len - 7) & "/subagents"
  result = @[]
  var files: seq[string] = @[]
  if isDir(base):
    try:
      for (k, fp) in walkDir(path(base)):
        let p = $fp
        let name = extractFilename(p)
        if k in {pcFile, pcLinkToFile} and name.startsWith("agent-") and name.endsWith(".jsonl"):
          files.add p
    except: discard
  files.sort()
  for p in files:
    let name = extractFilename(p)
    let aid = name.substr(6, name.len - 7)
    var meta = Meta()
    let mt = readText(p.substr(0, p.len - 7) & ".meta.json")
    if mt.isSome:
      meta = fromJson(mt.get(""), Meta).get(Meta())
    let recs = readJsonl(p)
    var calls: seq[Call] = @[]
    for c in toolUses(recs): calls.add c
    var prompt = ""
    if recs.len > 0 and recs[0].kind == rkUser:
      case recs[0].content
      of ckText: prompt = recs[0].text
      of ckBlocks:
        var parts: seq[string] = @[]
        for b in recs[0].blocks: parts.add b.text   # PORTBUG(B4): every block's text, not only text blocks
        prompt = parts.join(" ")
      of ckNone: discard
    var handedBack = false
    for c in calls:
      if c.tool.name == "SubagentHandback": handedBack = true
    let wd = workdirOf(recs, prompt)
    result.add Agent(id: aid, path: p, recs: recs, calls: calls, prompt: prompt,
                     description: meta.description, finished: meta.finished or handedBack,
                     age: nowSeconds() - mtimeSeconds(p),
                     start: (if recs.len > 0: recs[0].timestamp else: ""),
                     workdir: wd, label: (if wd.isSome: extractFilename(wd.get("")) else: aid.substr(0, 7)))
  result.sort(proc (a, b: Agent): int = cmp(a.start, b.start))   # stable, as Python's sort
  # Name each agent by the first part of its worktree path that differs from
  # the closest other worktree: ~/wt/f45/repo beside ~/wt/f31/repo is f45.
  var wds: seq[string] = @[]
  for a in result:
    if a.workdir.isSome and a.workdir.get("") notin wds: wds.add a.workdir.get("")
  if wds.len > 1:
    for a in result.mitems:
      if a.workdir.isSome:
        let wd = a.workdir.get("")
        let parts = pathParts(wd)
        var shared = 0
        for o in wds:
          if o != wd: shared = max(shared, commonSplitLen(wd, o))
        a.label = if shared < parts.len: parts[shared] else: parts[^1]

proc stateOf*(a: Agent): AgentState =
  if a.finished: asDone elif a.age < QuietAfter: asRunning else: asQuiet

proc gitSummary*(wd: Opt[string]): Opt[GitSummary] =
  if wd.isNone or git(wd.get(""), ["rev-parse", "--git-dir"]).isNone: return none[GitSummary]()
  let top = git(wd.get(""), ["rev-parse", "--show-toplevel"]).get(wd.get(""))
  var branch = git(top, ["branch", "--show-current"]).get("")
  if branch.len == 0: branch = "(detached)"
  var ahead = git(top, ["rev-list", "--count", "HEAD", "--not", "--remotes"]).get("")
  if ahead.len == 0: ahead = "?"
  let dirty = git(top, ["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all"]).get("")
  some(GitSummary(top: top, branch: branch, ahead: ahead,
                  dirty: if dirty.len > 0: dirty.splitLines.len else: 0))

proc resolve*(sessionPath, spec: string): Agent =
  ## The agent for a label or id prefix; a relaunched label means its running agent.
  let ags = agents(sessionPath)
  var found: seq[Agent] = @[]
  for a in ags:
    if a.label == spec: found.add a
  if found.len == 0:
    for a in ags:
      if a.id.startsWith(spec): found.add a
  if found.len > 1:
    var running: seq[Agent] = @[]
    for a in found:
      if not a.finished: running.add a
    found = if running.len > 0: running else: @[found[^1]]
  if found.len == 1: return found[0]
  var names: seq[string] = @[]
  for a in ags: names.add a.label & "(" & a.id.substr(0, 7) & ")"
  die("hitl: " & quoted(spec) & " matches " & $found.len & " agents; known: " & names.join(", "))

proc decisionId*(question: string): string =
  ## Stable id of a decision across brief rewrites with the same question.
  var st = newSha1State()
  st.update(collapse(question))
  ($SecureHash(st.finalize())).toLowerAscii.substr(0, 9)
