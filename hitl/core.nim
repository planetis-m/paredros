## The shared base of hitl: the session it works on with its project's config,
## the state paths, the one adapter to Claude Code's transcript format, and
## the process runner with git on it. Nothing here writes, except under the
## state directory.

import std/[syncio, strutils, os, dirs, files, paths, envvars, opt, result, osproc, algorithm, rex]
from std/unicode import runeLen, runeSubStr
import kroki

type
  SessionId* = distinct string   ## a Claude Code session id (a uuid)
  StateDir* = enum               ## hitl's folders under $STATE, one per session in each
    sdReview = "review", sdBriefs = "briefs", sdDirections = "directions", sdScratch = "scratch"

func `==`*(a, b: SessionId): bool {.borrow.}
func `$`*(id: SessionId): string {.borrow.}

func short*(id: SessionId): string = string(id).substr(0, 7)
  ## The first 8 characters: the session's folder name and `--session` value.

# -------------------------------------------------------------------- paths

proc homeDir*(): string = getEnv("HOME")
proc stateRoot*(): string = getEnv("XDG_STATE_HOME", homeDir() & "/.local/state") & "/hitl"

proc stateDir*(dir: StateDir; id: SessionId): string =
  ## The one place a session's state folder is named: $STATE/<dir>/<first 8 of the id>.
  stateRoot() & "/" & $dir & "/" & id.short

proc companionsFile*(): string = stateRoot() & "/companions"
  ## The session ids of companion forks, one per line.

proc appDir*(): string =
  ## The repository the binary was built in: the nearest directory above it
  ## that holds companion.md. The pages' static files and the companion's
  ## prompt are read from there.
  result = parentDir(getAppDir())
  for dir in parentDirs(getAppDir()):
    if fileExists(dir & "/companion.md"): return dir

proc readText*(path: string): Opt[string] =
  try: some(readFile(path)) except: none[string]()

proc writeAtomic*(path, text: string) {.raises.} =
  ## Temp file, then rename: a reader gets the old file or the new one.
  createDir(paths.path(parentDir(path)))
  let tmp = parentDir(path) & "/." & extractFilename(path) & ".tmp"
  writeFile(tmp, text)
  moveFile(paths.path(tmp), paths.path(path))

# ---------------------------------------------------------------------- text

proc collapse*(s: string): string =
  ## The words of s, one space between them.
  result = ""
  for word in s.splitWhitespace:
    if result.len > 0: result.add ' '
    result.add word

proc firstRunes*(s: string; n: int): string = s.runeSubStr(0, n)
  ## At most the first n code points: a cut never splits a character.

proc lastRunes*(s: string; n: int): string = s.runeSubStr(-n)
  ## At most the last n code points.

proc oneLine*(text: string; n = 90): string =
  ## One line of at most n code points, ending in "…" when cut.
  let line = collapse(text)
  if line.runeLen <= n: line else: line.firstRunes(n - 1) & "…"

# ----------------------------------------------------------------- processes

type
  Job* = object
    argv*: seq[string]
    cwd*, input*: string
    timeoutMs*: int
  Ran* = object
    started*: bool         ## false when the program could not be started
    code*: int             ## the exit code
    output*, errors*: string
  Running = object
    job: Job
    process: Opt[Process]

proc launch(job: Job): Running =
  ## Starts the job and hands it its whole input.
  # Known issue: bug-reports/105-osproc-pipes-inherited-by-later-children. Each
  # child gets its input and the end of it before the next one starts.
  result = Running(job: job, process: none[Process]())
  try:
    let p = startProcess(job.argv[0], workingDir = job.cwd,
      args = job.argv.toOpenArray(1, job.argv.high), options = {poUsePath})
    result.process = some(p)
    p.inputStream.write(job.input)
    p.inputStream.close()
  except: discard

proc wait(r: Running): Ran =
  ## Reads what the job wrote and waits for it to end.
  # Known issue: osproc has no `communicate`, so stdout is read to its end
  # before stderr; a child that fills the stderr pipe first would wait for us.
  # The timeout applies only once both pipes are closed.
  case r.process
  of None:
    result = Ran(started: false, code: -1, errors: "cannot start " & r.job.argv[0])
  of Some(p):
    result = Ran(started: true, code: -1)
    try:
      result.output = p.outputStream.readAll()
      result.errors = p.errorStream.readAll()
      result.code = p.waitForExit(r.job.timeoutMs)
      p.close()
    except: discard

proc run*(job: Job): Ran = wait(launch(job))

proc runAll*(jobs: seq[Job]; parallel: int): seq[Ran] =
  ## Runs every job, at most `parallel` at once; the results in job order.
  result = @[]
  var running: seq[Running] = @[]
  for job in jobs:
    if running.len - result.len >= max(parallel, 1):
      result.add wait(running[result.len])
    running.add launch(job)
  while result.len < running.len:
    result.add wait(running[result.len])

proc git*(dir: string; args: openArray[string]; timeoutMs = 20_000): Opt[string] =
  ## Read-only git: never takes the index lock. None when git fails.
  var argv = @["git", "--no-optional-locks", "-C", dir]
  for a in args: argv.add a
  let r = run(Job(argv: argv, timeoutMs: timeoutMs))
  if r.started and r.code == 0: some(r.output.strip(leading = false, chars = {'\n'}))
  else: none[string]()

# --------------------------------------------------------------- transcripts
# All knowledge of Claude Code's transcript format lives in this section and
# the next two (ARCHITECTURE.md 5.1).

type
  RecKind* = enum rkOther = "other", rkUser = "user", rkAssistant = "assistant"
  BlockKind* = enum bkOther = "other", bkText = "text", bkToolUse = "tool_use"
  ToolInput* = object      ## the fields of a tool's input that hitl reads
    command*, description*, filePath*, pattern*, message*: string
  Block* = object          ## one block of a message's content
    kind*: BlockKind
    text*, name*: string
    input*: ToolInput
  Rec* = object            ## one transcript record
    kind*: RecKind
    timestamp*, uuid*, cwd*: string
    typed*: bool           ## the human typed it: origin.kind "human" or promptSource "typed"
    blocks*: seq[Block]    ## message.content; a plain string is one text block

proc readJson*(dst: var ToolInput; p: var JsonParser; u: UnknownFieldPolicy) =
  # Tools put values of any JSON type under these names: only strings are ours.
  for f in p.jsonFields:
    if p.kind != jkString: p.skipJson()
    elif f == "command": readJson(dst.command, p, u)
    elif f == "description": readJson(dst.description, p, u)
    elif f == "file_path": readJson(dst.filePath, p, u)
    elif f == "pattern": readJson(dst.pattern, p, u)
    elif f == "message": readJson(dst.message, p, u)
    else: p.skipJson()

proc readJson*(dst: var Block; p: var JsonParser; u: UnknownFieldPolicy) =
  for f in p.jsonFields:
    if f == "type": readJson(dst.kind, p, u, bkOther)
    elif f == "text": readJson(dst.text, p, u)
    elif f == "name": readJson(dst.name, p, u)
    elif f == "input": readJson(dst.input, p, u)
    else: p.skipJson()

proc readJson*(dst: var Rec; p: var JsonParser; u: UnknownFieldPolicy) =
  for f in p.jsonFields:
    if f == "type": readJson(dst.kind, p, u, rkOther)
    elif f == "timestamp": readJson(dst.timestamp, p, u)
    elif f == "uuid": readJson(dst.uuid, p, u)
    elif f == "cwd": readJson(dst.cwd, p, u)
    elif f == "promptSource":
      var source = ""
      readJson(source, p, u)
      if source == "typed": dst.typed = true
    elif f == "origin":
      for g in p.jsonFields:
        if g == "kind":
          var kind = ""
          readJson(kind, p, u)
          if kind == "human": dst.typed = true
        else: p.skipJson()
    elif f == "message":
      for g in p.jsonFields:
        if g != "content": p.skipJson()
        elif p.kind == jkString:
          dst.blocks = @[Block(kind: bkText)]
          readJson(dst.blocks[0].text, p, u)
        else: readJson(dst.blocks, p, u)
    else: p.skipJson()

proc readJsonl*(path: string): seq[Rec] =
  ## Every readable record of a transcript; unreadable lines are skipped.
  result = @[]
  for r in jsonLines[Rec](readText(path).get("")):
    if r.isOk: result.add r.get(Rec())

type Call* = object   ## a tool use, when and where it was made
  timestamp*, cwd*: string
  tool*: Block

iterator toolUses*(recs: seq[Rec]): Call =
  for r in recs:
    if r.kind == rkAssistant:
      for b in r.blocks:
        if b.kind == bkToolUse: yield Call(timestamp: r.timestamp, cwd: r.cwd, tool: b)

iterator assistantTexts*(r: Rec): string =
  ## The record's text blocks, if it is the session speaking.
  if r.kind == rkAssistant:
    for b in r.blocks:
      if b.kind == bkText and not b.text.isEmptyOrWhitespace: yield b.text

proc isHuman*(r: Rec): bool = r.kind == rkUser and r.typed
  ## A message the human typed (not a tool result or an injected prompt).

proc textOf*(r: Rec): string =
  ## The text of a message, without the tags that mark pasted content.
  var text = ""
  for b in r.blocks:
    if b.kind == bkText:
      if text.len > 0: text.add ' '
      text.add b.text
  result = ""
  var i: Natural = 0
  while i < text.len:   # drops <pasted_content ...> and </pasted_content>
    let close = text.find('>', i)
    if text[i] == '<' and close > 0 and (text.continuesWith("pasted_content", i + 1) or
        text.continuesWith("/pasted_content", i + 1)):
      i = close + 1
    else:
      result.add text[i]
      inc i
  result = result.strip

# -------------------------------------------------------------------- agents

let
  cdTarget = re"""(?:^|[;&|(]\s*)(?:cd|pushd)\s+["']?(/[^\s"';&|)]+)"""
  gitcTarget = re"""git\s+-C\s+["']?(/[^\s"';&|)]+)"""
  anyPath = re"""(/[\w./-]+)"""

iterator groups*(s: string; r: Regex): string =
  ## The first group of every match of r in s, left to right.
  var caps: seq[Capture] = @[]
  var start = 0
  while start <= s.len:
    let (a, b) = findBounds(s, r, caps, start)
    if a < 0: break
    yield capture(s, caps, 0)
    start = max(b + 1, a + 1)

iterator dirsNamed*(command: string): string =
  ## The directories a shell command enters: `cd`, `pushd` and `git -C` targets.
  for d in groups(command, cdTarget): yield d
  for d in groups(command, gitcTarget): yield d

type Agent* = object   ## a subagent, as its transcript tells it
  id*: string
  description*, task*, report*: string
  start*, last*: string    ## the times of its first and last records
  workdir*: Opt[string]    ## the directory it worked in
  recs*: seq[Rec]

proc finalReport(recs: seq[Rec]): string =
  ## The SubagentHandback message, else the last text the agent wrote.
  result = ""
  for c in toolUses(recs):
    if c.tool.name == "SubagentHandback": result = c.tool.input.message
  if result.len == 0:
    for r in recs:
      for text in assistantTexts(r): result = text

proc workdirOf(recs: seq[Rec]; task: string): Opt[string] =
  ## The directory an agent worked in: the most named `cd` or `git -C` target
  ## that exists (the first named among equals); without any, a path in its task.
  var named: seq[string] = @[]
  for c in toolUses(recs):
    if c.tool.name == "Bash":
      for d in dirsNamed(c.tool.input.command): named.add d
  if named.len == 0:
    for d in groups(task, anyPath): named.add d
  var tally: seq[(string, int)] = @[]   # in first-named order
  for d in named:
    var known = false
    for t in tally.mitems:
      if t[0] == d:
        inc t[1]
        known = true
    if not known: tally.add (d, 1)
  tally.sort(proc (a, b: (string, int)): int = cmp(b[1], a[1]))   # stable
  result = none[string]()
  for (d, _) in tally:
    let dir = d.strip(leading = false, chars = {'/', '.'})
    if dir.len > 0 and dirExists(dir): return some(dir)

type Meta = object   ## agent-<id>.meta.json
  description: string

proc agents*(transcript: string): seq[Agent] =
  ## The session's subagents, by start time.
  var files: seq[string] = @[]
  try:
    for (kind, p) in walkDir(paths.path(transcript.changeFileExt("") & "/subagents")):
      let name = extractFilename($p)
      if name.startsWith("agent-") and name.endsWith(".jsonl"): files.add $p
  except: discard
  files.sort()
  result = @[]
  for f in files:
    let recs = readJsonl(f)
    var task = ""
    if recs.len > 0 and recs[0].kind == rkUser:
      for b in recs[0].blocks:   # PORTBUG(B4): every block's text, not only text blocks
        if task.len > 0: task.add ' '
        task.add b.text
    let meta = fromJson(readText(f.changeFileExt("meta.json")).get("{}"), Meta).get(Meta())
    result.add Agent(id: extractFilename(f).changeFileExt("").substr(6),
                     description: meta.description, task: task, report: finalReport(recs),
                     start: (if recs.len > 0: recs[0].timestamp else: ""),
                     last: (if recs.len > 0: recs[^1].timestamp else: ""),
                     workdir: workdirOf(recs, task), recs: recs)
  result.sort(proc (a, b: Agent): int = cmp(a.start, b.start))

# ------------------------------------------------------------------ sessions

type Session = object
  id: SessionId
  transcript: string   ## <projects>/<project>/<id>.jsonl
  project: string
  mtime: int64

proc sessions(): seq[Session] =
  ## Main transcripts, newest first.
  let projects = getEnv("CLAUDE_CONFIG_DIR", homeDir() & "/.claude") & "/projects"
  result = @[]
  try:
    for (kind, dir) in walkDir(paths.path(projects)):
      if kind in {pcDir, pcLinkToDir}:
        for (k, f) in walkDir(dir):
          if k in {pcFile, pcLinkToFile} and ($f).endsWith(".jsonl"):
            let mtime = try: getLastModificationTime($f) except: 0'i64
            result.add Session(id: SessionId(extractFilename($f).changeFileExt("")),
                               transcript: $f, project: extractFilename($dir), mtime: mtime)
  except: discard
  result.sort(proc (a, b: Session): int =
    result = cmp(b.mtime, a.mtime)
    if result == 0: result = cmp(string(b.id), string(a.id)))

proc companionIds*(): seq[SessionId] =
  result = @[]
  for line in readText(companionsFile()).get("").splitWhitespace: result.add SessionId(line)

proc projectName(dir: string): string =
  ## Claude Code's project folder name for a directory: non-alphanumerics as '-'.
  result = dir
  for c in result.mitems:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9'}: c = '-'

proc pickSession(spec: Opt[string]): Opt[Session] =
  ## The newest session matching spec (an id prefix or a project-name
  ## substring), else the newest of the current directory's project, else the
  ## newest. Companion forks, full copies of a session, are never taken.
  let forks = companionIds()
  var all: seq[Session] = @[]
  for s in sessions():
    if s.id notin forks: all.add s
  let here = projectName(try: os.getCurrentDir() except: "")
  result = none[Session]()
  for s in all:
    let x = spec.get("")
    if (spec.isSome and (string(s.id).startsWith(x) or x in s.project)) or
        (spec.isNone and s.project == here):
      return some(s)
  if spec.isNone and all.len > 0: result = some(all[0])

# -------------------------------------------------------------------- config

type
  Compare* = object
    label*, prompt*: string
    allow*: seq[string]
  Config* = object   ## .hitl.json; every key may be left out (README, "Config")
    spec*: Opt[string]
    reader*: string = "a developer of this project"
    users*: string = "the project's users"
    compare*: Opt[Compare]

proc readConfig*(dir: string; file: Opt[string]): Result[Config, string] =
  ## The project's config: `file`, else .hitl.json in dir if there is one.
  let path = file.get(dir & "/.hitl.json")
  if not fileExists(path):
    if file.isSome: return err[Config, string]("no config file " & path)
    return ok[Config, string](Config())
  case fromJson(readText(path).get(""), Config, unknownFields = ufReject)
  of Ok(cfg):
    result = ok[Config, string](cfg)
    case cfg.compare
    of Some(c):
      if c.label.len == 0 or c.prompt.len == 0:
        result = err[Config, string]("compare in " & path & " needs a label and a prompt")
    of None: discard
  of Err(e): result = err[Config, string]("cannot read " & path & ": " & $e)

proc expand*(text, scratch: string): string =
  ## A compare text with {scratch} and {home} filled in.
  text.multiReplace([("{scratch}", scratch), ("{home}", homeDir())])

# ---------------------------------------------------------------------- desk

type Desk* = object   ## the session hitl works on, with its directory and its project's config
  id*: SessionId
  transcript*: string
  cwd*: string        ## the session's working directory
  repo*: string       ## the repository there, else the same directory
  config*: Config

proc openDesk*(session, configFile: Opt[string]): Result[Desk, string] =
  ## The session `session` names (see pickSession) and its project's config.
  let picked = pickSession(session)
  if picked.isNone:
    return err[Desk, string](if session.isSome: "no session matches " & session.get("")
                             else: "no Claude Code session found")
  let s = picked.get(Session())
  var cwd = ""
  for r in jsonLines[Rec](readText(s.transcript).get("")):
    if cwd.len == 0 and r.isOk: cwd = r.get(Rec()).cwd
  if cwd.len == 0 or not dirExists(cwd):
    return err[Desk, string]("cannot find the working directory of session " & s.id.short)
  case readConfig(cwd, configFile)
  of Ok(cfg):
    result = ok[Desk, string](Desk(id: s.id, transcript: s.transcript, cwd: cwd,
      repo: git(cwd, ["rev-parse", "--show-toplevel"]).get(cwd), config: cfg))
  of Err(e): result = err[Desk, string](e)
