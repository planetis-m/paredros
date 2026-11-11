## Shared test fixtures: a coordinator session (a fixer commits in its own
## worktree, a reviewer reads it) and a single-agent session (two fixes, the
## first amended, and the human's own commit in the same checkout). Everything
## lives in one temp directory; setUp points paredros's state and Claude
## Code's config there before anything runs, so no test touches the real
## ~/.local/state or ~/.claude.

import std/[syncio, strutils, os, paths, dirs, tempfiles, envvars, json, opt, result]
import ../paredros/[state, session, config, brief, work]

const
  Sid* = "11111111-2222-3333-4444-555555555555"   ## a coordinator with a fixer and a reviewer
  Solo* = "99999999-8888-7777-6666-555555555555"  ## one agent, no subagents, two fixes

# ------------------------------------------------------------------- helpers

proc tmp*(): string =
  ## The fixtures' temp directory.
  # The environment holds it: setUp put Claude Code's config dir right in it.
  parentDir(getEnv("CLAUDE_CONFIG_DIR"))

proc writeText*(p, text: string) =
  ## Writes a file, making its directory first; a test cannot go on without it.
  try:
    createDir(path(parentDir(p)))
    writeFile(p, text)
  except:
    quit "cannot write " & p

proc readText*(p: string): string =
  ## The file's text; "" when it cannot be read.
  try: readFile(p) except: ""

proc sh*(cwd: string; cmd: openArray[string]; date = "2026-11-09T08:05:00Z"): string =
  ## A command (git) run in cwd with fixed author and committer: its output,
  ## stripped. A failure ends the test run.
  var argv = @["env", "GIT_AUTHOR_DATE=" & date, "GIT_COMMITTER_DATE=" & date,
               "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
               "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t"]
  for a in cmd: argv.add a
  let ran = run(argv, 60, cwd = cwd)
  let r = ran.get(Completed(code: -1, output: "", errors: ran.error("")))
  if r.code != 0: quit cmd.join(" ") & ": " & r.errors
  result = r.output.strip

# ----------------------------------------------------- transcript records

proc obj*(fields: openArray[(string, string)]): string =
  ## A JSON object of the given members; each value is JSON text already.
  result = "{"
  for i, (k, v) in fields:
    if i > 0: result.add ", "
    result.add quote(k) & ": " & v
  result.add "}"

proc user*(text, ts: string; cwd = ""): string =
  ## A message the human typed, with cwd if given.
  var f = @[("type", quote"user"), ("timestamp", quote(ts)), ("origin", obj([("kind", quote"human")])),
            ("uuid", quote("u-" & ts)), ("message", obj([("content", quote(text))]))]
  if cwd.len > 0: f.add ("cwd", quote(cwd))
  result = obj(f)

proc tool*(name, id: string; input: openArray[(string, string)]): string =
  ## A tool_use block's members (name, id, input) for assistant().
  obj([("type", quote"tool_use"), ("name", quote(name)), ("id", quote(id)), ("input", obj(input))])

proc bash*(id, command: string): string =
  ## A Bash tool use, for assistant().
  tool("Bash", id, [("command", quote(command))])

proc assistant*(ts: string; text = ""; tool = ""; cwd = ""): string =
  ## A record of the session speaking: a text
  ## block, a tool_use block (see tool and bash), or both; with cwd if given.
  var content: seq[string] = @[]
  if text.len > 0: content.add obj([("type", quote"text"), ("text", quote(text))])
  if tool.len > 0: content.add tool
  var f = @[("type", quote"assistant"), ("timestamp", quote(ts)),
            ("message", obj([("content", "[" & content.join(", ") & "]")]))]
  if cwd.len > 0: f.add ("cwd", quote(cwd))
  result = obj(f)

proc toolResult*(id, ts: string; cwd = ""): string =
  ## The record of a tool call's result, made at ts.
  var f = @[("type", quote"user"), ("timestamp", quote(ts)),
            ("message", obj([("content", "[" & obj([("type", quote"tool_result"),
              ("tool_use_id", quote(id)), ("content", quote"ok")]) & "]")]))]
  if cwd.len > 0: f.add ("cwd", quote(cwd))
  result = obj(f)

proc writeJsonl*(p: string; recs: openArray[string]) =
  ## A transcript: one record per line.
  var text = ""
  for r in recs: text.add r & "\n"
  writeText(p, text)

proc spathOf*(sid: string): string =
  ## The fixture session's transcript, in whichever project holds it.
  result = ""
  try:
    for (k, proj) in walkDir(path(tmp() & "/claude/projects")):
      if fileExists($proj & "/" & sid & ".jsonl"): result = $proj & "/" & sid & ".jsonl"
  except:
    discard
  if result.len == 0: quit "no transcript for " & sid

proc repo*(): string =
  ## The repository; tests/run runs the tests from it.
  (try: $paths.getCurrentDir() except: ".")

proc example*(): string =
  ## examples/nimony.paredros.json; tests/run runs the tests from the repository.
  (try: $paths.getCurrentDir() except: ".") & "/examples/nimony.paredros.json"

proc resetState*() =
  ## Every test that writes briefs, drafts or pages starts without any.
  try: removeDir(path(outDir())) except: discard

# ------------------------------------------------------------- the model

proc fake*(split: openArray[(string, seq[string])] = []; brief = ""; raw = ""): string =
  ## Puts the fake `claude` (tests/fakeclaude.nim) first on PATH: split names
  ## each new item's title (an existing item's number) and its handles, "C*"
  ## for every commit, and "housekeeping" the handles left out; brief is the
  ## briefs' answer, JSON text; raw, when given, is the whole answer to every
  ## call. Returns the fresh directory the calls are recorded in.
  var n = 1
  while dirExists(tmp() & "/calls-" & $n): inc n
  result = tmp() & "/calls-" & $n
  try: createDir(path(result)) except: quit "no " & result
  var items: seq[string] = @[]
  var housekeeping = "[]"
  for (key, handles) in split:
    var hs: seq[string] = @[]
    for h in handles: hs.add quote(h)
    if key == "housekeeping":
      housekeeping = "[" & hs.join(", ") & "]"
    elif key.len > 0 and key.allCharsInSet(Digits):
      items.add obj([("id", key), ("handles", "[" & hs.join(", ") & "]")])
    else:
      items.add obj([("title", quote(key)), ("handles", "[" & hs.join(", ") & "]")])
  writeText(tmp() & "/plan.json", obj([("split", "[" & items.join(", ") & "]"),
    ("housekeeping", housekeeping), ("brief", quote(brief)), ("raw", quote(raw))]))
  let bin = (try: $paths.getCurrentDir() except: ".") & "/nimcache/tests/bin"
  try:
    putEnv("FAKE_PLAN", tmp() & "/plan.json")
    putEnv("FAKE_LOG", result)
    if not getEnv("PATH").startsWith(bin & ":"): putEnv("PATH", bin & ":" & getEnv("PATH"))
  except:
    quit "cannot set the environment"

proc prompts*(log: string): seq[string] =
  ## What each call recorded in log got on stdin, in the order they started.
  result = @[]
  var n = 0
  while fileExists(log & "/" & $n & "/prompt"):
    result.add readText(log & "/" & $n & "/prompt")
    inc n

proc argvOf*(log: string; n: int): seq[string] =
  ## The arguments call n recorded in log was given.
  result = @[]
  var t = parseJson(readText(log & "/" & $n & "/argv"))
  if not t.hasError and t.root.kind == JArray:
    for a in items(t.root): result.add a.getStr

proc runBrief*(sid: string; force = false): seq[(int, string)] =
  ## What `paredros brief` does for the fixture session: sort its new material,
  ## then write the briefs. An error ends the
  ## test run.
  let spath = spathOf(sid)
  let src = sources(spath)
  let cfg = config.load(src.cwd)
  if cfg.isErr: quit cfg.error("")
  let led = split(sid, src)
  if led.isErr: quit led.error("")
  let d = collect(spath, cfg.get(defaults()), src)
  if d.isErr: quit d.error("")
  result = generateAll(d.get(Work()), force = force)

proc collectNow*(sid: string): Work =
  ## work.collect of the fixture session, read now. An error ends the test run.
  let spath = spathOf(sid)
  let src = sources(spath)
  let d = collect(spath, config.load(src.cwd).get(defaults()), src)
  if d.isErr: quit d.error("")
  result = d.get(Work())

# ------------------------------------------------------------------- setUp

proc setUp*() =
  ## Makes the fixtures in a fresh temp directory and points the environment at it.
  var root = ""
  try:
    root = $createTempDir("paredros-test-", "")
  except:
    quit "no temp dir"
  try:
    putEnv("CLAUDE_CONFIG_DIR", root & "/claude")
    putEnv("XDG_STATE_HOME", root & "/state")  # briefs and drafts go here
    putEnv("PAREDROS_NO_CLIPBOARD", "1")           # never touch the user's clipboard
  except:
    quit "cannot set the environment"

  # a coordinator: a fixer commits in its own worktree, a reviewer reads it
  let repo = root & "/proj/repo"
  try: createDir(path(repo)) except: quit "no " & repo
  discard sh(repo, ["git", "init", "-q", "-b", "master"], "2026-11-01T08:00:00Z")
  discard sh(repo, ["git", "commit", "-q", "--allow-empty", "-m", "base"], "2026-11-01T08:00:00Z")
  let wt = root & "/wt/f7/repo"
  discard sh(repo, ["git", "worktree", "add", "-q", "-b", "fix/f7", wt])
  writeText(wt & "/sem.nim", "proc a() =\n  discard\n")
  discard sh(wt, ["git", "add", "."])
  discard sh(wt, ["git", "commit", "-q", "-m", "sem: reject the bad default"])
  let proj = root & "/claude/projects/-proj"
  writeJsonl(proj & "/" & Sid & ".jsonl", [
    user("fix the field default crash", "2026-11-09T08:00:00Z", repo).replace(
      "\"uuid\": \"u-2026-11-09T08:00:00Z\"", "\"uuid\": \"u0\""),
    assistant("2026-11-09T08:30:00Z", "The fix is done; the review agrees. Push it?"),
    user("looks fine, push it", "2026-11-09T08:31:00Z"),
    obj([("type", quote"system"), ("subtype", quote"turn_duration"), ("timestamp", quote"2026-11-09T08:31:05Z")])])
  let sub = proj & "/" & Sid & "/subagents"
  writeJsonl(sub & "/agent-a1111111111111111.jsonl", [
    obj([("type", quote"user"), ("timestamp", quote"2026-11-09T08:01:00Z"),
         ("message", obj([("content", quote("Fix it in " & wt))]))]),
    assistant("2026-11-09T08:04:30Z", tool = bash("t1", "cd " & wt & " && git commit -q -m x")),
    assistant("2026-11-09T08:10:00Z", tool = tool("SubagentHandback", "t2", [("message",
      quote("## Fix\n\nThe default is **typed** in `sem`.\n\n- one\n- two\n"))]))])
  writeText(sub & "/agent-a1111111111111111.meta.json",
            obj([("description", quote"Fix the field default crash"), ("finished", "true")]))
  writeJsonl(sub & "/agent-a2222222222222222.jsonl", [
    obj([("type", quote"user"), ("timestamp", quote"2026-11-09T08:12:00Z"),
         ("message", obj([("content", quote"Review commit abc")]))]),
    assistant("2026-11-09T08:20:00Z", "Verdict: well integrated.")])
  writeText(sub & "/agent-a2222222222222222.meta.json",
            obj([("description", quote"Review field default typing"), ("finished", "true")]))

  # one agent, no subagents: two fixes committed in its own checkout, the first amended
  let solo = root & "/solo/app"
  try: createDir(path(solo)) except: quit "no " & solo
  discard sh(solo, ["git", "init", "-q", "-b", "main"], "2026-11-01T08:00:00Z")
  discard sh(solo, ["git", "commit", "-q", "--allow-empty", "-m", "base"], "2026-11-01T08:00:00Z")
  writeText(solo & "/parse.py", "x = 1\n")
  discard sh(solo, ["git", "add", "."])
  discard sh(solo, ["git", "commit", "-q", "-m", "parse: first try"], "2026-11-09T10:05:00Z")
  writeText(solo & "/parse.py", "x = 2\n")
  discard sh(solo, ["git", "commit", "-q", "-a", "--amend", "-m", "parse: accept empty input"],
             "2026-11-09T10:06:00Z")
  writeText(solo & "/render.py", "y = 1\n")
  discard sh(solo, ["git", "add", "."])
  discard sh(solo, ["git", "commit", "-q", "-m", "render: escape quotes"], "2026-11-09T10:20:00Z")
  writeText(solo & "/notes.txt", "mine\n")   # the human's own commit, while the session ran
  discard sh(solo, ["git", "add", "."])
  discard sh(solo, ["git", "commit", "-q", "-m", "human: my notes"], "2026-11-09T10:25:00Z")
  writeJsonl(root & "/claude/projects/-solo/" & Solo & ".jsonl", [
    user("fix the parser on empty input, then the quote escaping", "2026-11-09T10:00:00Z", solo),
    assistant("2026-11-09T10:05:00Z", tool = bash("t1", "git add . && git commit -q -m 'parse: first try'"),
              cwd = solo),
    assistant("2026-11-09T10:07:00Z", "The parser now accepts empty input."),
    assistant("2026-11-09T10:19:40Z", tool = bash("t2", "git commit -q -am 'render: escape quotes'"),
              cwd = solo),
    assistant("2026-11-09T10:21:00Z", "Quotes are escaped now. Should `'` be escaped too?"),
    user("yes, both", "2026-11-09T10:30:00Z")])

proc tearDown*() =
  ## Removes the temp directory.
  try: removeDir(path(tmp())) except: discard
