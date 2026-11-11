## Shared test fixtures, as test_hitl.py's setUpModule makes them: a
## coordinator session (a fixer commits in its own worktree, a reviewer reads
## it) and a single-agent session (two fixes, the first amended, and the
## human's own commit in the same checkout). Everything lives in one temp
## directory; setUp points hitl's state and Claude Code's config there before
## anything runs, so no test touches the real ~/.local/state or ~/.claude.

import std/[syncio, strutils, os, paths, dirs, tempfiles, envvars, json, opt, result]
import ../hitl/[state, session]

const
  Sid* = "11111111-2222-3333-4444-555555555555"   ## a coordinator with a fixer and a reviewer
  Solo* = "99999999-8888-7777-6666-555555555555"  ## one agent, no subagents, two fixes

# ------------------------------------------------------------------- helpers

proc tmp*(): string =
  ## The fixtures' temp directory (test_hitl.py's TMP).
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

proc str*(s: string): string =
  ## s as a JSON string.
  var t = toJson(s)
  result = $t

proc obj*(fields: openArray[(string, string)]): string =
  ## A JSON object of the given members; each value is JSON text already.
  result = "{"
  for i, (k, v) in fields:
    if i > 0: result.add ", "
    result.add str(k) & ": " & v
  result.add "}"

proc user*(text, ts: string; cwd = ""): string =
  ## A message the human typed (test_hitl.py's user()), with cwd if given.
  var f = @[("type", str"user"), ("timestamp", str(ts)), ("origin", obj([("kind", str"human")])),
            ("uuid", str("u-" & ts)), ("message", obj([("content", str(text))]))]
  if cwd.len > 0: f.add ("cwd", str(cwd))
  result = obj(f)

proc tool*(name, id: string; input: openArray[(string, string)]): string =
  ## A tool_use block's members (name, id, input) for assistant().
  obj([("type", str"tool_use"), ("name", str(name)), ("id", str(id)), ("input", obj(input))])

proc bash*(id, command: string): string =
  ## A Bash tool use, for assistant().
  tool("Bash", id, [("command", str(command))])

proc assistant*(ts: string; text = ""; tool = ""; cwd = ""): string =
  ## A record of the session speaking (test_hitl.py's assistant()): a text
  ## block, a tool_use block (see tool and bash), or both; with cwd if given.
  var content: seq[string] = @[]
  if text.len > 0: content.add obj([("type", str"text"), ("text", str(text))])
  if tool.len > 0: content.add tool
  var f = @[("type", str"assistant"), ("timestamp", str(ts)),
            ("message", obj([("content", "[" & content.join(", ") & "]")]))]
  if cwd.len > 0: f.add ("cwd", str(cwd))
  result = obj(f)

proc toolResult*(id, ts: string; cwd = ""): string =
  ## The record of a tool call's result, made at ts.
  var f = @[("type", str"user"), ("timestamp", str(ts)),
            ("message", obj([("content", "[" & obj([("type", str"tool_result"),
              ("tool_use_id", str(id)), ("content", str"ok")]) & "]")]))]
  if cwd.len > 0: f.add ("cwd", str(cwd))
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

proc example*(): string =
  ## examples/nimony.hitl.json; tests/run runs the tests from the repository.
  (try: $paths.getCurrentDir() except: ".") & "/examples/nimony.hitl.json"

proc resetState*() =
  ## Every test that writes briefs, drafts or pages starts without any.
  try: removeDir(path(outDir())) except: discard

# ------------------------------------------------------------------- setUp

proc setUp*() =
  ## Makes the fixtures in a fresh temp directory and points the environment at it.
  var root = ""
  try:
    root = $createTempDir("hitl-test-", "")
  except:
    quit "no temp dir"
  try:
    putEnv("CLAUDE_CONFIG_DIR", root & "/claude")
    putEnv("XDG_STATE_HOME", root & "/state")  # briefs and drafts go here
    putEnv("HITL_NO_CLIPBOARD", "1")           # never touch the user's clipboard
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
    obj([("type", str"system"), ("subtype", str"turn_duration"), ("timestamp", str"2026-11-09T08:31:05Z")])])
  let sub = proj & "/" & Sid & "/subagents"
  writeJsonl(sub & "/agent-a1111111111111111.jsonl", [
    obj([("type", str"user"), ("timestamp", str"2026-11-09T08:01:00Z"),
         ("message", obj([("content", str("Fix it in " & wt))]))]),
    assistant("2026-11-09T08:04:30Z", tool = bash("t1", "cd " & wt & " && git commit -q -m x")),
    assistant("2026-11-09T08:10:00Z", tool = tool("SubagentHandback", "t2", [("message",
      str("## Fix\n\nThe default is **typed** in `sem`.\n\n- one\n- two\n"))]))])
  writeText(sub & "/agent-a1111111111111111.meta.json",
            obj([("description", str"Fix the field default crash"), ("finished", "true")]))
  writeJsonl(sub & "/agent-a2222222222222222.jsonl", [
    obj([("type", str"user"), ("timestamp", str"2026-11-09T08:12:00Z"),
         ("message", obj([("content", str"Review commit abc")]))]),
    assistant("2026-11-09T08:20:00Z", "Verdict: well integrated.")])
  writeText(sub & "/agent-a2222222222222222.meta.json",
            obj([("description", str"Review field default typing"), ("finished", "true")]))

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
