## What hitl reads, read only: Claude Code's transcripts (an undocumented
## format; this is the only module that knows it) and git.
##
## A transcript is one JSON record per line: the main session's in
## ~/.claude/projects/<project>/<session>.jsonl, each subagent's beside it in
## <session>/subagents/agent-<id>.jsonl with its description in .meta.json.

import std/[syncio, strutils, os, paths, dirs, envvars, algorithm, tables,
            json, rex, osproc, streams, monotimes, times, opt, result]
import std/posix/posix
import state

proc configDir*(): string =
  ## Claude Code's config directory: $CLAUDE_CONFIG_DIR, else ~/.claude.
  # Read on every call, not once: the tests point it at a temp directory.
  getEnv("CLAUDE_CONFIG_DIR", getEnv("HOME") & "/.claude")

proc projectsDir*(): string =
  ## Where Claude Code keeps the transcripts, one folder per project.
  configDir() & "/projects"

# ------------------------------------------------------------------- records

type
  Block* = object
    ## One block of a message's content: the fields hitl reads.
    kind*: string           ## "text", "tool_use", "tool_result", ...
    text*: string           ## a text block's text
    id*, name*: string      ## a tool use's id and tool name
    command*: string        ## a tool use's input.command (Bash)
    message*: string        ## a tool use's input.message (SubagentHandback)
    toolUseId*: string      ## a tool result's tool_use_id
  Rec* = object
    ## One transcript record: the fields hitl reads.
    kind*: string           ## its "type": "user", "assistant", "system", ...
    timestamp*, uuid*, cwd*: string
    origin*: string         ## origin.kind: "human" for a message the human typed
    promptSource*: string   ## "typed" for a message the human typed
    content*: string        ## message.content when it is a plain string
    blocks*: seq[Block]     ## message.content when it is a list

proc readBlock(n: JsonNode): Block =
  result = Block()
  for k, v in pairs(n):
    case k
    of "type": result.kind = v.getStr
    of "text": result.text = v.getStr
    of "id": result.id = v.getStr
    of "name": result.name = v.getStr
    of "tool_use_id": result.toolUseId = v.getStr
    of "input":
      if v.kind == JObject:
        for f, x in pairs(v):
          if f == "command": result.command = x.getStr
          elif f == "message": result.message = x.getStr
    else: discard

proc readRec(n: JsonNode): Rec =
  result = Rec()
  for k, v in pairs(n):
    case k
    of "type": result.kind = v.getStr
    of "timestamp": result.timestamp = v.getStr
    of "uuid": result.uuid = v.getStr
    of "cwd": result.cwd = v.getStr
    of "promptSource": result.promptSource = v.getStr
    of "origin":
      if v.kind == JObject:
        for f, x in pairs(v):
          if f == "kind": result.origin = x.getStr
    of "message":
      if v.kind == JObject:
        for f, c in pairs(v):
          if f != "content": discard
          elif c.kind == JString: result.content = c.getStr
          elif c.kind == JArray:
            for b in items(c):
              # entries that are not objects are no blocks
              if b.kind == JObject: result.blocks.add readBlock(b)
    else: discard

proc readJsonl*(path: string): seq[Rec] =
  ## Every record of a transcript, in order. Lines that are not a JSON object
  ## are skipped; a file that is missing or cannot be read has none.
  result = @[]
  let text = try: readFile(path) except: ""
  for line in text.splitLines:
    var t = parseJson(line)
    if not t.hasError and t.root.kind == JObject:
      result.add readRec(t.root)

type ToolUse* = object
  ## A tool call, with the time of the record that made it.
  timestamp*: string
  tool*: Block

proc toolUses*(recs: openArray[Rec]): seq[ToolUse] =
  ## Every tool call the session made, in order.
  result = @[]
  for r in recs:
    if r.kind == "assistant":
      for c in r.blocks:
        if c.kind == "tool_use": result.add ToolUse(timestamp: r.timestamp, tool: c)

type Said* = object
  ## A text the session wrote, with its record's time.
  timestamp*, text*: string

proc assistantTexts*(recs: openArray[Rec]): seq[Said] =
  ## (timestamp, text) for every assistant text block, in order.
  result = @[]
  for r in recs:
    if r.kind == "assistant":
      for c in r.blocks:
        if c.kind == "text" and not c.text.isEmptyOrWhitespace:
          result.add Said(timestamp: r.timestamp, text: c.text)

proc isHuman*(r: Rec): bool =
  ## A message the human typed (not a tool result or an injected prompt).
  r.kind == "user" and (r.origin == "human" or r.promptSource == "typed")

let pasted = re"</?pasted_content[^>]*>"

proc textOf*(r: Rec): string =
  ## The text of a message, without the tags that mark pasted content.
  var t = r.content
  if r.blocks.len > 0:
    var parts: seq[string] = @[]
    for x in r.blocks:
      if x.kind == "text": parts.add x.text
    t = parts.join(" ")
  result = t.replace(pasted, "").strip

proc toolResults*(recs: openArray[Rec]): Table[string, string] =
  ## {tool_use id: timestamp} for every tool result: when each call ended.
  result = initTable[string, string]()
  for r in recs:
    if r.kind == "user":
      for b in r.blocks:
        if b.kind == "tool_result": result[b.toolUseId] = r.timestamp

proc finalReport*(recs: openArray[Rec]): Opt[string] =
  ## What an agent handed back: its last SubagentHandback message, else the
  ## last text it wrote; none when it wrote nothing.
  var report = ""
  for u in toolUses(recs):
    if u.tool.name == "SubagentHandback": report = u.tool.message
  let texts = assistantTexts(recs)
  result = if report.len > 0: some(report)
           elif texts.len > 0: some(texts[^1].text)
           else: none[string]()

proc sessionCwd*(recs: openArray[Rec]): Opt[string] =
  ## The directory the session ran in: the first record that names one.
  for r in recs:
    if r.cwd.len > 0: return some(r.cwd)
  result = none[string]()

# ------------------------------------------------------------------ sessions

type Session* = object
  ## A main transcript.
  mtime*: int64      ## when it was last written, in nanoseconds
  id*: string        ## the session id
  path*: string      ## <projects>/<project>/<id>.jsonl
  project*: string   ## the project folder's name

proc sessions*(): seq[Session] =
  ## Main transcripts, newest first.
  result = @[]
  try:
    for (kind, proj) in walkDir(path(projectsDir())):
      if kind in {pcDir, pcLinkToDir}:
        for (k, p) in walkDir(proj):
          if k in {pcFile, pcLinkToFile} and ($p).endsWith(".jsonl"):
            result.add Session(mtime: getLastModificationTime($p),
                               id: extractFilename($p).changeFileExt(""), path: $p,
                               project: extractFilename($proj))
  except:
    discard   # no projects folder, or one that went away while it was read
  result.sort(proc (a, b: Session): int =
    result = cmp(b.mtime, a.mtime)
    if result == 0: result = cmp(b.id, a.id)
    if result == 0: result = cmp(b.path, a.path))

let notAlnum = re"[^A-Za-z0-9]"

proc pickSession*(spec: string): Result[Session, string] =
  ## The newest session matching spec (an id prefix or a project-name
  ## substring), else the newest one of the current directory's project, else
  ## the newest; spec "" matches none. The error says no session matches.
  let forks = companionIds()   # a fork is a full copy of the session's transcript
  var all: seq[Session] = @[]
  for s in sessions():
    if s.id notin forks: all.add s
  let here = (try: $paths.getCurrentDir() except: "").replace(notAlnum, "-")
  var hits: seq[Session] = @[]
  for s in all:
    if spec.len > 0:
      if s.id.startsWith(spec) or spec in s.project: hits.add s
    elif s.project == here:
      hits.add s
  if spec.len == 0 and hits.len == 0: hits = all
  result = if hits.len > 0: ok[Session, string](hits[0])
           elif spec.len > 0: err[Session, string]("no session matches '" & spec & "'")
           else: err[Session, string]("no Claude Code session found")

type Agent* = object
  ## A subagent, as its transcript tells it.
  id*: string          ## from its file name agent-<id>.jsonl
  recs*: seq[Rec]
  prompt*: string      ## the task it was given: its first message
  description*: string ## from its .meta.json
  start*: string       ## the time of its first record

proc agents*(sessionPath: string): seq[Agent] =
  ## The session's subagents, oldest first.
  let base = sessionPath.changeFileExt("") & "/subagents"
  var files: seq[string] = @[]
  try:
    for (k, p) in walkDir(path(base)):
      let name = extractFilename($p)
      if name.startsWith("agent-") and name.endsWith(".jsonl"): files.add $p
  except:
    discard   # no subagents folder, or one that went away while it was read
  files.sort()
  result = @[]
  for p in files:
    # a missing or unreadable .meta.json leaves the description empty
    var meta = parseJson(try: readFile(p.changeFileExt(".meta.json")) except: "")
    let description = if meta.hasError: "" else: meta{"description"}.getStr
    let recs = readJsonl(p)
    var prompt = ""
    if recs.len > 0 and recs[0].kind == "user":
      # every block's text, whatever its type, as the Python does
      prompt = recs[0].content
      if recs[0].blocks.len > 0:
        var parts: seq[string] = @[]
        for c in recs[0].blocks: parts.add c.text
        prompt = parts.join(" ")
    result.add Agent(id: extractFilename(p).changeFileExt("").substr(len("agent-")),
                     recs: recs, prompt: prompt, description: description,
                     start: if recs.len > 0: recs[0].timestamp else: "")
  result.sort(proc (a, b: Agent): int = cmp(a.start, b.start))

# ----------------------------------------------------------------------- git

type Completed* = object
  ## A child process that ran to its end.
  code*: int        ## its exit code
  output*: string   ## its stdout
  errors*: string   ## its stderr

proc run*(cmd: openArray[string]; timeout: int; input = ""; cwd = ""): Result[Completed, string] =
  ## The one way hitl runs a child process (git, claude): it gets `input` on
  ## stdin, and its output comes back as text. The child starts in its own
  ## process group; when it outlives `timeout` seconds the whole group is
  ## killed, so a `claude` or `git` that started children of its own leaves
  ## none behind, and the error says it timed out. The error also says when the
  ## child could not be started or read.
  let deadline = getMonoTime() + initDuration(seconds = timeout)
  var ran = Completed(code: -1, output: "", errors: "")
  var pid = 0
  var timedOut = false
  try:
    # poDaemon: the child calls setpgid(0, 0), a process group of its own.
    # GAP: a program that cannot be found or started is a run that exits 127,
    # not an error, because std/osproc reports a failed execve that way.
    let p = startProcess(cmd[0], workingDir = cwd, args = cmd.toOpenArray(1, cmd.high),
                         options = {poUsePath, poDaemon})
    pid = p.processID
    # GAP: a child that keeps its output open is not stopped at the timeout,
    # only once it closes it, and one that fills its stderr pipe while hitl
    # waits on stdout waits for ever, because std/osproc has no `communicate`
    # (bug-reports/120-osproc-has-no-communicate): stdout is read to its end,
    # then stderr, and only then is the time left given to waitForExit.
    p.inputStream.write(input)
    p.inputStream.close()
    ran.output = p.outputStream.readAll()
    ran.errors = p.errorStream.readAll()
    let left = (deadline - getMonoTime()).inMilliseconds
    ran.code = p.waitForExit(int(max(left, 0'i64)))
    timedOut = deadline <= getMonoTime()
    p.close()
  except:
    return err[Completed, string]("cannot run " & cmd[0])
  if timedOut:
    discard posix.kill(Pid(-pid), SIGKILL)   # the whole group
    result = err[Completed, string](cmd[0] & " timed out after " & $timeout & " s")
  else:
    result = ok[Completed, string](ran)

proc git*(wd: string; args: openArray[string]; timeout = 20): Opt[string] =
  ## Read-only git: never takes the index lock. Its output without the final
  ## newline; none when git fails, cannot run or times out.
  var cmd = @["git", "--no-optional-locks", "-C", wd]
  for a in args: cmd.add a
  let r = run(cmd, timeout)
  let ran = r.get(Completed(code: -1, output: "", errors: ""))
  result = if r.isOk and ran.code == 0: some(ran.output.strip(leading = false, chars = {'\n'}))
           else: none[string]()

let
  gitWrite = re(r"\bgit\b[^\n;&|]*\b(?:commit|cherry-pick|revert|am|rebase|merge)\b",
                {reExtended, reAllowEvil})
  cdTo = re"""(?:^|[;&|(]\s*)(?:cd|pushd)\s+[\"']?(/[^\s\"';&|)]+)"""
  gitC = re"""git\s+-C\s+[\"']?(/[^\s\"';&|)]+)"""

proc groups(s: string; r: Regex): seq[string] =
  ## The first group of every match of r in s, left to right (Python's findall).
  result = @[]
  var caps: seq[Capture] = @[]
  var start = 0
  var found = true
  while found and start <= s.len:
    let (a, b) = findBounds(s, r, caps, start)
    found = a >= 0
    if found:
      result.add capture(s, caps, 0)
      start = max(b + 1, a + 1)

type GitWrite* = object
  ## A Bash call that may make commits.
  start*: string       ## when the call was made
  done*: Opt[string]   ## when its result was recorded; none if never
  dirs*: seq[string]   ## the absolute directories its own `cd` or `git -C` names
  cwd*: Opt[string]    ## the directory the call ran in, if recorded

proc gitWrites*(recs: openArray[Rec]): seq[GitWrite] =
  ## Every Bash call that may make commits. Read from the command text, so a
  ## `git commit` quoted inside a script counts too; matching commits to the
  ## call's time window is what keeps that harmless.
  result = @[]
  let ends = toolResults(recs)
  for r in recs:
    for u in toolUses([r]):
      let cmd = if u.tool.name == "Bash": u.tool.command else: ""
      if cmd.contains(gitWrite):
        var dirs: seq[string] = @[]
        for d in groups(cmd, cdTo):
          if d notin dirs: dirs.add d
        for d in groups(cmd, gitC):
          if d notin dirs: dirs.add d
        let id = u.tool.id
        result.add GitWrite(start: u.timestamp,
                            done: if id in ends: some(ends.getOrDefault(id, "")) else: none[string](),
                            dirs: dirs, cwd: if r.cwd.len > 0: some(r.cwd) else: none[string]())
