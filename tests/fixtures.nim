## Shared test fixtures, as test_hitl.py's setUpModule makes them: a
## coordinator session (a fixer commits in its own worktree, a reviewer reads
## it) and a single-agent session (two fixes, the first amended, and the
## human's own commit in the same checkout). Everything lives in one temp
## directory; the environment points hitl's state, Claude Code's config, the
## clipboard and the browser away from the real ones before anything runs.

import std/[syncio, strutils, os, paths, dirs, tempfiles, envvars, result]
import kroki
import ../hitl/core

const
  Sid* = "11111111-2222-3333-4444-555555555555"   ## a coordinator with a fixer and a reviewer
  Solo* = "99999999-8888-7777-6666-555555555555"  ## one agent, no subagents, two fixes

proc q*(s: string): string = toJson(s).get("\"\"")
  ## A JSON string literal.

proc fail*(msg: string) {.noreturn.} =
  stderr.write "FAILED: " & msg & "\n"
  quit(1)

proc check*(cond: bool; label: string) =
  if not cond: fail(label)

proc writeText*(path, text: string) =
  ensureDir(parentDir(path))
  try: writeFile(path, text) except: fail("cannot write " & path)

proc sh*(cwd: string; args: openArray[string]; date = "2026-11-09T08:05:00Z"): string =
  ## A git (or other) command with fixed author and committer dates.
  var argv = @["env", "GIT_AUTHOR_DATE=" & date, "GIT_COMMITTER_DATE=" & date,
               "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t"]
  for a in args: argv.add a
  let r = run(Job(argv: argv, cwd: cwd, timeoutMs: 30_000))
  if r.code != 0: fail(args.join(" ") & ": " & r.errors)
  r.output.strip

proc user*(text, ts: string; cwd = ""): string =
  "{\"type\": \"user\", \"timestamp\": " & q(ts) & ", \"origin\": {\"kind\": \"human\"}, \"uuid\": " &
    q("u-" & ts) & ", \"message\": {\"content\": " & q(text) & "}" &
    (if cwd.len > 0: ", \"cwd\": " & q(cwd) else: "") & "}"

proc assistantText*(ts, text: string): string =
  "{\"type\": \"assistant\", \"timestamp\": " & q(ts) & ", \"message\": {\"content\": [{\"type\": \"text\", \"text\": " &
    q(text) & "}]}}"

proc assistantTool*(ts, name, id, inputJson: string; cwd = ""): string =
  "{\"type\": \"assistant\", \"timestamp\": " & q(ts) & ", \"message\": {\"content\": [{\"type\": \"tool_use\", \"name\": " &
    q(name) & ", \"id\": " & q(id) & ", \"input\": " & inputJson & "}]}" &
    (if cwd.len > 0: ", \"cwd\": " & q(cwd) else: "") & "}"

proc writeJsonl*(path: string; recs: openArray[string]) =
  var s = ""
  for r in recs: s.add r & "\n"
  writeText(path, s)

var tmpRoot = ""   ## set once by setUp, on the test's main thread

proc tmp*(): string =
  {.cast(assumeSync).}:   # tests are single-threaded
    result = tmpRoot

proc spathOf*(sid: string): string =
  tmp() & "/claude/projects/" & (if sid == Sid: "-proj" else: "-solo") & "/" & sid & ".jsonl"

proc setUp*() =
  ## Makes the fixtures in a fresh temp directory and points the environment at it.
  var root = ""
  try: root = $createTempDir("hitl-test-", "")
  except: fail("no temp dir")
  {.cast(assumeSync).}: tmpRoot = root
  try:
    putEnv("CLAUDE_CONFIG_DIR", root & "/claude")
    putEnv("XDG_STATE_HOME", root & "/state")
    putEnv("HITL_NO_CLIPBOARD", "1")   # never touch the user's clipboard
    putEnv("BROWSER", "true")          # never open a browser
  except: fail("cannot set the environment")
  # a coordinator: a fixer commits in its own worktree, a reviewer reads it
  let repo = root & "/proj/repo"
  ensureDir(repo)
  discard sh(repo, ["git", "init", "-q", "-b", "master"], "2026-11-01T08:00:00Z")
  discard sh(repo, ["git", "commit", "-q", "--allow-empty", "-m", "base"], "2026-11-01T08:00:00Z")
  let wt = root & "/wt/f7/repo"
  discard sh(repo, ["git", "worktree", "add", "-q", "-b", "fix/f7", wt])
  writeText(wt & "/sem.nim", "proc a() =\n  discard\n")
  discard sh(wt, ["git", "add", "."])
  discard sh(wt, ["git", "commit", "-q", "-m", "sem: reject the bad default"])
  let proj = root & "/claude/projects/-proj"
  writeJsonl(proj & "/" & Sid & ".jsonl", [
    "{\"type\": \"user\", \"cwd\": " & q(repo) & ", \"timestamp\": \"2026-11-09T08:00:00Z\", \"uuid\": \"u0\", " &
      "\"origin\": {\"kind\": \"human\"}, \"message\": {\"content\": \"fix the field default crash\"}}",
    assistantText("2026-11-09T08:30:00Z", "The fix is done; the review agrees. Push it?"),
    user("looks fine, push it", "2026-11-09T08:31:00Z"),
    "{\"type\": \"system\", \"subtype\": \"turn_duration\", \"timestamp\": \"2026-11-09T08:31:05Z\"}"])
  let sub = proj & "/" & Sid & "/subagents"
  writeJsonl(sub & "/agent-a1111111111111111.jsonl", [
    "{\"type\": \"user\", \"timestamp\": \"2026-11-09T08:01:00Z\", \"message\": {\"content\": " & q("Fix it in " & wt) & "}}",
    assistantTool("2026-11-09T08:04:30Z", "Bash", "t1", "{\"command\": " & q("cd " & wt & " && git commit -q -m x") & "}"),
    assistantTool("2026-11-09T08:10:00Z", "SubagentHandback", "t2",
                  "{\"message\": " & q("## Fix\n\nThe default is **typed** in `sem`.\n\n- one\n- two\n") & "}")])
  writeText(sub & "/agent-a1111111111111111.meta.json",
            "{\"description\": \"Fix the field default crash\", \"finished\": true}")
  writeJsonl(sub & "/agent-a2222222222222222.jsonl", [
    "{\"type\": \"user\", \"timestamp\": \"2026-11-09T08:12:00Z\", \"message\": {\"content\": \"Review commit abc\"}}",
    assistantText("2026-11-09T08:20:00Z", "Verdict: well integrated.")])
  writeText(sub & "/agent-a2222222222222222.meta.json",
            "{\"description\": \"Review field default typing\", \"finished\": true}")

  # one agent, no subagents: two fixes committed in its own checkout, the first amended
  let solo = root & "/solo/app"
  ensureDir(solo)
  discard sh(solo, ["git", "init", "-q", "-b", "main"], "2026-11-01T08:00:00Z")
  discard sh(solo, ["git", "commit", "-q", "--allow-empty", "-m", "base"], "2026-11-01T08:00:00Z")
  writeText(solo & "/parse.py", "x = 1\n")
  discard sh(solo, ["git", "add", "."])
  discard sh(solo, ["git", "commit", "-q", "-m", "parse: first try"], "2026-11-09T10:05:00Z")
  writeText(solo & "/parse.py", "x = 2\n")
  discard sh(solo, ["git", "commit", "-q", "-a", "--amend", "-m", "parse: accept empty input"], "2026-11-09T10:06:00Z")
  writeText(solo & "/render.py", "y = 1\n")
  discard sh(solo, ["git", "add", "."])
  discard sh(solo, ["git", "commit", "-q", "-m", "render: escape quotes"], "2026-11-09T10:20:00Z")
  writeText(solo & "/notes.txt", "mine\n")   # the human's own commit, while the session ran
  discard sh(solo, ["git", "add", "."])
  discard sh(solo, ["git", "commit", "-q", "-m", "human: my notes"], "2026-11-09T10:25:00Z")
  writeJsonl(root & "/claude/projects/-solo/" & Solo & ".jsonl", [
    user("fix the parser on empty input, then the quote escaping", "2026-11-09T10:00:00Z", solo),
    assistantTool("2026-11-09T10:05:00Z", "Bash", "t1",
                  "{\"command\": " & q("git add . && git commit -q -m 'parse: first try'") & "}", solo),
    assistantText("2026-11-09T10:07:00Z", "The parser now accepts empty input."),
    assistantTool("2026-11-09T10:19:40Z", "Bash", "t2",
                  "{\"command\": " & q("git commit -q -am 'render: escape quotes'") & "}", solo),
    assistantText("2026-11-09T10:21:00Z", "Quotes are escaped now. Should `'` be escaped too?"),
    user("yes, both", "2026-11-09T10:30:00Z")])

proc tearDown*() =
  try: removeDir(path(tmp())) except: discard

proc hitlBin*(): string = (try: os.getCurrentDir() except: ".") & "/bin/hitl"

proc cli*(args: openArray[string]; session = Sid): Ran =
  ## The built hitl, run with --session=<first 8 of session> and args.
  var argv = @[hitlBin(), "--session=" & session.substr(0, 7)]
  for a in args: argv.add a
  run(Job(argv: argv, timeoutMs: 120_000))
