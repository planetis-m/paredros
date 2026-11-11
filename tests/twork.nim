## Work items (test_paredros.py WorkItemTests): sources, commit discovery, current
## code, and the ledger across runs, with the fake `claude` answering. The
## parts of these tests that build pages or save decisions come with those
## layers.

import std/[syncio, strutils, paths, dirs, assertions, opt, result, tables]
import fixtures
import ../paredros/[session, brief, work]

setUp()

proc subjects(cms: seq[Commit]): seq[string] =
  ## The commits' subjects.
  result = @[]
  for c in cms: result.add c.subject

proc titles(led: Ledger): seq[(int, string)] =
  ## The ledger's items as (id, title).
  result = @[]
  for it in led.items: result.add (it.id, it.title)

block multi_agent_session:  # WorkItemTests.test_multi_agent_session
  resetState()
  let src = sources(spathOf(Sid))
  assert src.agents.len == 2, "two agents"
  assert subjects(src.commits) == @["sem: reject the bad default"], "the fixer's commit"
  assert src.commits[0].agent.get("") == "agent:a1111111111111111", "made in the fixer's worktree"
  assert src.turns.len == 2, "two turns"
  let log = fake([("Field defaults that are calls", @["A*", "C*", "T1"])])
  discard runBrief(Sid)
  let calls = prompts(log)
  assert "C1 commit by A1 in" in calls[0], "the commit names its agent's handle"
  let d = collectNow(Sid)
  assert d.items.len == 1, "one item"
  let it = d.items[0]
  assert it.n == 1 and it.title == "Field defaults that are calls", "numbered by code"
  assert it.agents.len == 2, "both agents"
  assert "+proc a() =" in it.code.diff, "the fixer's diff"
  assert "# Agent: Fix the field default crash" in calls[1], "the brief sees the reports"
  assert "+proc a() =" in calls[1], "and the code"

block single_agent_session:  # WorkItemTests.test_single_agent_session
  resetState()
  let src = sources(spathOf(Solo))
  assert src.agents.len == 0, "no agents"
  # the amended first try is gone; the two fixes are left; the human's own commit
  # in the same checkout, with no git call of the session before it, stays out
  assert subjects(src.commits) == @["parse: accept empty input", "render: escape quotes"]
  discard fake([("Parser accepts empty input", @["C1", "T1"]),
                ("Quotes are escaped", @["C2", "T1", "T2"])])
  discard runBrief(Solo)
  var parse, render = WorkItem()
  for it in collectNow(Solo).items:
    if it.title == "Parser accepts empty input": parse = it
    elif it.title == "Quotes are escaped": render = it
  assert "+x = 2" in parse.code.diff, "the amended fix"
  assert "render.py" notin parse.code.diff, "each item shows its own commit only"
  assert "+y = 1" in render.code.diff
  assert "parse.py" notin render.code.diff
  assert render.turns.len == 2, "both turns"

block a_rebased_commit_is_the_sessions_and_its_code_is_one_diff:
  # WorkItemTests.test_a_rebased_commit_is_the_sessions_and_its_code_is_one_diff:
  # the session commits a fix, rebases it onto upstream, then commits a follow-up:
  # the item's code is both, from upstream to the follow-up
  let rb = tmp() & "/rebased"
  try: createDir(path(rb)) except: quit "no " & rb
  discard sh(rb, ["git", "init", "-q", "-b", "master"], "2026-11-01T08:00:00Z")
  discard sh(rb, ["git", "commit", "-q", "--allow-empty", "-m", "base"], "2026-11-01T08:00:00Z")
  discard sh(rb, ["git", "switch", "-q", "-c", "upstream"], "2026-11-01T08:00:00Z")
  writeText(rb & "/up.txt", "u\n")
  discard sh(rb, ["git", "add", "up.txt"])
  discard sh(rb, ["git", "commit", "-q", "-m", "upstream: news"], "2026-11-02T08:00:00Z")
  discard sh(rb, ["git", "switch", "-q", "-c", "fix", "master"], "2026-11-09T12:00:00Z")
  writeText(rb & "/fix.txt", "fix\n")
  discard sh(rb, ["git", "add", "fix.txt"])
  discard sh(rb, ["git", "commit", "-q", "-m", "fix: the bug"], "2026-11-09T12:00:00Z")
  discard sh(rb, ["git", "rebase", "-q", "upstream"], "2026-11-09T12:00:10Z")
  writeText(rb & "/fix.txt", "fix\nmore\n")
  discard sh(rb, ["git", "commit", "-q", "-am", "fix: follow-up"], "2026-11-09T12:03:00Z")
  var recs: seq[string] = @[]
  for i, (ts, cmd) in [("2026-11-09T11:59:58Z", "git commit -q -m 'fix: the bug'"),
                       ("2026-11-09T12:00:08Z", "git rebase -q upstream"),
                       ("2026-11-09T12:02:58Z", "git commit -q -am 'fix: follow-up'")]:
    recs.add assistant(ts, tool = bash("t" & $i, cmd), cwd = rb)
  writeJsonl(tmp() & "/rebased.jsonl", recs)
  let main = Transcript(owner: none[string](), recs: readJsonl(tmp() & "/rebased.jsonl"))
  let cms = sessionCommits(@[main])
  assert subjects(cms) == @["fix: the bug", "fix: follow-up"], "the rebased one, not the original"
  let code = currentCode(cms)
  assert code.earlier.len == 0, "no earlier attempts"
  assert "+fix" in code.diff and "+more" in code.diff, "both commits, one diff"
  assert "up.txt" notin code.diff, "upstream's commit is the base, not the session's"

block commits_are_matched_to_the_call_that_made_them:
  # WorkItemTests.test_commits_are_matched_to_the_call_that_made_them: one
  # repository: a long-running commit call, another session's commit right
  # after a call, and an agent's worktree that was deleted after it committed
  let rp = tmp() & "/calls"
  try: createDir(path(rp)) except: quit "no " & rp
  discard sh(rp, ["git", "init", "-q", "-b", "main"], "2026-11-01T08:00:00Z")
  discard sh(rp, ["git", "commit", "-q", "--allow-empty", "-m", "base"], "2026-11-01T08:00:00Z")
  for (msg, ts) in [("slow hook", "2026-11-09T12:02:30Z"), ("other session", "2026-11-09T12:05:30Z")]:
    discard sh(rp, ["git", "commit", "-q", "--allow-empty", "-m", msg], ts)
  let wt = tmp() & "/calls-wt"
  discard sh(rp, ["git", "worktree", "add", "-q", "-b", "fix/a", wt], "2026-11-09T12:10:00Z")
  discard sh(wt, ["git", "commit", "-q", "--allow-empty", "-m", "agent fix"],
             "2026-11-09T12:10:05Z")
  discard sh(rp, ["git", "worktree", "remove", wt])   # its HEAD reflog is gone now
  proc call(recs: var seq[string]; i: int; ts, cmd, done: string; rp = tmp() & "/calls") =
    ## A Bash call made at ts and its result at done.
    recs.add assistant(ts, tool = bash("c" & $i, cmd), cwd = rp)
    recs.add toolResult("c" & $i, done, rp)
  var main, agent: seq[string] = @[]
  # a call of 151 s
  call(main, 1, "2026-11-09T12:00:00Z", "git commit -q -m 'slow hook'", "2026-11-09T12:02:31Z")
  call(main, 2, "2026-11-09T12:05:00Z", "git commit -q -m nothing", "2026-11-09T12:05:01Z")
  call(agent, 3, "2026-11-09T12:10:04Z", "cd " & wt & " && git commit -q -m 'agent fix'",
       "2026-11-09T12:10:06Z")
  writeJsonl(tmp() & "/main.jsonl", main)
  writeJsonl(tmp() & "/agent.jsonl", agent)
  let cms = sessionCommits(@[
    Transcript(owner: none[string](), recs: readJsonl(tmp() & "/main.jsonl")),
    Transcript(owner: some("agent:a9"), recs: readJsonl(tmp() & "/agent.jsonl"))])
  assert subjects(cms) == @["slow hook", "agent fix"], "not \"other session\""
  assert cms[0].agent.isNone and cms[1].agent.get("") == "agent:a9", "each with its maker"

block page_identity_survives_new_material_and_rewritten_briefs:
  # WorkItemTests.test_page_identity_survives_new_material_and_rewritten_briefs,
  # without the saved decision and the page (they come with drafts and pages)
  resetState()
  let spath = spathOf(Solo)
  let answer = """{"summary": "s", "open_decisions": [{"question": "Escape both?", """ &
               """"options": ["yes", "no"]}]}"""
  discard fake([("Parser accepts empty input", @["C1", "T1"])], answer)
  discard runBrief(Solo)
  let led = loadLedger(Solo).get(Ledger())
  assert titles(led) == @[(1, "Parser accepts empty input")]
  let tips = codeTips(spath)
  assert tips.isOk and tips.get(initTable[int, string]()).getOrDefault(1, "").len == 12,
    "item 1's code tip"
  # the human says more; a later run rewrites every brief and the model files all it
  # is shown under a new item: only the new turn is shown, and item 1 keeps its number
  let before = readText(spath)
  writeText(spath, before & user("now the quote escaping", "2026-11-09T10:40:00Z") & "\n")
  let log = fake([("Quotes are escaped", @["C*", "T*", "A*"])], answer)
  discard runBrief(Solo, force = true)
  writeText(spath, before)
  let calls = prompts(log)
  assert "parse: accept empty input" notin calls[0], "a placed commit is not offered again"
  assert "now the quote escaping" in calls[0], "the new turn is"
  let led2 = loadLedger(Solo).get(Ledger())
  assert titles(led2) == @[(1, "Parser accepts empty input"), (2, "Quotes are escaped")]
  for k in led.items[0].sources:
    assert k in led2.items[0].sources, "item 1 keeps its sources"
  assert calls.len == 3, "the split and two briefs, rewritten"

block material_the_split_dropped_is_offered_again:
  # WorkItemTests.test_material_the_split_dropped_is_offered_again
  resetState()
  discard fake([("Parser accepts empty input", @["C1", "T1"])])   # says nothing of C2
  discard runBrief(Solo)
  var log = fake([("housekeeping", @["C*"])])
  discard runBrief(Solo)
  var calls = prompts(log)
  assert "render: escape quotes" in calls[0], "offered again"
  assert "Leave out housekeeping" in calls[0], "a rule for the model, not a filter"
  assert "parse: accept empty input" notin calls[0], "placed: not again"
  log = fake()
  discard runBrief(Solo)
  for c in prompts(log):
    assert not c.startsWith("You sort"), "housekeeping is sorted"

tearDown()
