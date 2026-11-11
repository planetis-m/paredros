## Child processes (test_paredros.py ProcessTests) and the transcript reading the
## later layers build on, on the shared fixtures. The ledger test of
## ProcessTests comes with brief.nim.

import std/[strutils, os, assertions, opt, result]
import std/posix/posix
import fixtures
import ../paredros/[state, session]

setUp()

block a_timeout_leaves_no_child_behind:  # ProcessTests.test_a_timeout_leaves_no_child_behind
  let pidfile = tmp() & "/grandchild.pid"
  # the child starts a child of its own and waits
  let r = run(["sh", "-c", "sleep 30 & echo $! > " & pidfile & "; wait"], 1)
  assert r.isErr and "timed out" in r.error(""), "a timeout is an error"
  let pid = try: parseInt(readText(pidfile).strip) except: -1
  var gone = false
  for i in 0..<50:   # killed with its group, then reaped by init
    if not gone:
      gone = posix.kill(Pid(pid), 0) != 0
      if not gone: os.sleep(50)
  assert gone, "process " & $pid & " outlived the timeout"
  let ran = run(["sh", "-c", "cat; echo err >&2"], 5, input = "in")
  assert ran.isOk and ran.get(Completed()).output == "in", "input in, output out"
  assert ran.get(Completed()).errors == "err\n", "stderr apart"

# The checks below are not in test_paredros.py: they hold the fixtures to what
# test_paredros.py's work tests read from them through session.py.

block the_coordinator_session:
  let spath = spathOf(Sid)
  let recs = readJsonl(spath)
  assert recs.len == 4, "four records"
  assert sessionCwd(recs).get("") == tmp() & "/proj/repo", "the working directory"
  assert isHuman(recs[0]) and textOf(recs[0]) == "fix the field default crash", "a typed message"
  assert not isHuman(recs[1]), "the session speaking"
  let ags = agents(spath)
  assert ags.len == 2, "two agents"
  assert ags[0].id == "a1111111111111111" and ags[0].description == "Fix the field default crash"
  assert ags[0].prompt == "Fix it in " & tmp() & "/wt/f7/repo", "the task"
  assert finalReport(ags[0].recs).get("").startsWith("## Fix"), "the handback"
  assert finalReport(ags[1].recs).get("") == "Verdict: well integrated.", "the last text"
  let w = gitWrites(ags[0].recs)
  assert w.len == 1 and w[0].dirs == @[tmp() & "/wt/f7/repo"] and w[0].done.isNone,
    "the fixer's commit call, in its worktree, never answered"

block the_solo_session:
  let recs = readJsonl(spathOf(Solo))
  let w = gitWrites(recs)
  assert w.len == 2 and w[0].dirs.len == 0 and w[0].cwd.get("") == tmp() & "/solo/app",
    "two commit calls in the checkout"
  assert agents(spathOf(Solo)).len == 0, "no agents"
  let s = pickSession(Solo.substr(0, 7))
  assert s.isOk and s.get(Session()).path == spathOf(Solo), "picked by id prefix"
  assert pickSession("-solo").get(Session()).id == Solo, "picked by project"
  assert pickSession("nothing-like-it").error("") == "no session matches 'nothing-like-it'"

block companion_forks_are_never_picked:
  let sid = try: newCompanionId() except: ""
  assert sid.len == 36 and sid[14] == '4', "a version 4 uuid"
  writeText(projectsDir() & "/-proj/" & sid & ".jsonl", readText(spathOf(Sid)))
  assert sid in companionIds(), "recorded"
  assert pickSession(sid.substr(0, 7)).isErr, "a fork is not a session"

block calls_matched_to_results:
  let recs = readJsonl("")
  assert recs.len == 0, "no file, no records"
  writeJsonl(tmp() & "/calls.jsonl", [assistant("2026-11-09T12:00:00Z",
    tool = bash("c1", "git -C /r commit -q -m x; cd /s && git merge y")),
    toolResult("c1", "2026-11-09T12:00:05Z")])
  let w = gitWrites(readJsonl(tmp() & "/calls.jsonl"))
  assert w.len == 1 and w[0].done.get("") == "2026-11-09T12:00:05Z", "ended at its result"
  assert w[0].dirs == @["/s", "/r"], "cd targets, then git -C targets"
  assert git(tmp() & "/solo/app", ["log", "-1", "--format=%s"]).get("") == "human: my notes"
  assert git(tmp() & "/nowhere", ["log"]).isNone, "git failed"

tearDown()
