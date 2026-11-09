## test_hitl.py WorkItemTests: sources, the split into items, and the briefs'
## inputs, on the coordinator and single-agent fixtures with the fake claude.

import std/[strutils, opt, tables]
import fixtures
import ../hitl/[core, store, review]

setUp()

proc subjects(cs: seq[Commit]): seq[string] =
  result = @[]
  for c in cs: result.add c.subject

proc byTitle(d: Collected; title: string): WorkItem =
  for it in d.items:
    if it.title == title: return it
  fail("no item " & title)

block test_multi_agent_session:  # test_hitl.py::WorkItemTests::test_multi_agent_session
  resetState()
  let src = sources(spathOf(Sid))
  check src.agents.len == 2, "two agents"
  check subjects(src.commits) == @["sem: reject the bad default"], "the fixer's commit only"
  check src.commits[0].agent.get("") == "agent:a1111111111111111", "made in the fixer's worktree"
  check src.turns.len == 2, "two turns"
  fakeModel("""{"split": [{"title": "Field defaults that are calls", "handles": ["A*", "C*", "T1"]}]}""")
  discard cli(["brief"])
  let prompts = calls()
  check prompts.len == 2, "one split and one brief"
  check "C1 commit by A1 in" in prompts[0], "the split names the commit's agent"
  let items = collect(spathOf(Sid), "").items
  check items.len == 1 and items[0].n == 1 and items[0].title == "Field defaults that are calls", "one item"
  check items[0].agents.len == 2, "both agents"
  check "+proc a() =" in items[0].code.diff, "the item's code"
  check "# Agent: Fix the field default crash" in prompts[1], "the brief sees the reports"
  check "+proc a() =" in prompts[1], "and the code"

block test_single_agent_session:  # test_hitl.py::WorkItemTests::test_single_agent_session (pages: treview)
  resetState()
  let spath = spathOf(Solo)
  let src = sources(spath)
  check src.agents.len == 0, "no agents"
  # the amended first try is gone; the two fixes are left; the human's own commit
  # in the same checkout, with no git call of the session before it, stays out
  check subjects(src.commits) == @["parse: accept empty input", "render: escape quotes"], "the session's commits"
  fakeModel("""{"split": [{"title": "Parser accepts empty input", "handles": ["C1", "T1"]},
                          {"title": "Quotes are escaped", "handles": ["C2", "T1", "T2"]}]}""")
  discard cli(["brief"], Solo)
  let d = collect(spath, "")
  let parse = byTitle(d, "Parser accepts empty input")
  let render = byTitle(d, "Quotes are escaped")
  check "+x = 2" in parse.code.diff, "the parser's code"
  check "render.py" notin parse.code.diff, "each item shows its own commit only"
  check "+y = 1" in render.code.diff, "the renderer's code"
  check "parse.py" notin render.code.diff, "and only its own"
  check render.turns.len == 2, "two turns"

block test_material_the_split_dropped_is_offered_again:  # test_hitl.py::WorkItemTests::test_material_the_split_dropped_is_offered_again
  resetState()
  fakeModel("""{"split": [{"title": "Parser accepts empty input", "handles": ["C1", "T1"]}]}""")   # says nothing of C2
  discard cli(["brief"], Solo)
  fakeModel("""{"housekeeping": ["C*"]}""")
  discard cli(["brief"], Solo)
  var prompts = calls()
  check "render: escape quotes" in prompts[0], "offered again"
  check "Leave out housekeeping" in prompts[0], "a rule for the model, not a filter"
  check "parse: accept empty input" notin prompts[0], "placed: not again"
  fakeModel("{}")
  discard cli(["brief"], Solo)
  for p in calls():
    check not p.startsWith("You sort"), "housekeeping is sorted"

tearDown()
