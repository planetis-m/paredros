## Sources, the split into work items and the briefs' inputs (test_hitl.py
## WorkItemTests), on the coordinator and single-agent fixtures with the fake
## claude.

import std/[strutils, assertions]
import fixtures
import ../hitl/[core, items]

setUp()

proc subjects(cs: seq[Commit]): seq[string] =
  result = @[]
  for c in cs: result.add c.subject

proc byTitle(items: seq[WorkItem]; title: string): WorkItem =
  result = WorkItem()
  var found = false
  for it in items:
    if it.title == title:
      result = it
      found = true
  assert found, "no item " & title

block multi_agent_session:  # WorkItemTests.test_multi_agent_session
  resetState()
  let src = sources(spathOf(Sid))
  assert src.agents.len == 2, "two agents"
  assert subjects(src.commits) == @["sem: reject the bad default"], "the fixer's commit only"
  assert src.commits[0].agent.get("") == "a1111111111111111", "made in the fixer's worktree"
  assert src.turns.len == 2, "two turns"
  fakeModel("""{"split": [{"title": "Field defaults that are calls", "handles": ["A*", "C*", "T1"]}]}""")
  discard cli(["brief"])
  let prompts = calls()
  assert prompts.len == 2, "one split and one brief"
  assert "C1 commit by A1 in" in prompts[0], "the split names the commit's agent"
  let items = workItems(deskOf(Sid), sources(spathOf(Sid)))
  assert items.len == 1 and items[0].id == ItemId(1) and items[0].title == "Field defaults that are calls",
    "one item"
  assert items[0].agents.len == 2, "both agents"
  assert "+proc a() =" in items[0].code.diff, "the item's code"
  assert "# Agent: Fix the field default crash" in prompts[1], "the brief sees the reports"
  assert "+proc a() =" in prompts[1], "and the code"

block single_agent_session:  # WorkItemTests.test_single_agent_session (pages: treview)
  resetState()
  let src = sources(spathOf(Solo))
  assert src.agents.len == 0, "no agents"
  # the amended first try is gone; the two fixes are left; the human's own commit
  # in the same checkout, with no git call of the session before it, stays out
  assert subjects(src.commits) == @["parse: accept empty input", "render: escape quotes"],
    "the session's commits"
  fakeModel("""{"split": [{"title": "Parser accepts empty input", "handles": ["C1", "T1"]},
                          {"title": "Quotes are escaped", "handles": ["C2", "T1", "T2"]}]}""")
  discard cli(["brief"], Solo)
  let items = workItems(deskOf(Solo), src)
  let parse = byTitle(items, "Parser accepts empty input")
  let render = byTitle(items, "Quotes are escaped")
  assert "+x = 2" in parse.code.diff, "the parser's code"
  assert "render.py" notin parse.code.diff, "each item shows its own commit only"
  assert "+y = 1" in render.code.diff, "the renderer's code"
  assert "parse.py" notin render.code.diff, "and only its own"
  assert render.turns.len == 2, "two turns"

block material_the_split_dropped_is_offered_again:  # WorkItemTests.test_material_the_split_dropped_is_offered_again
  resetState()
  fakeModel("""{"split": [{"title": "Parser accepts empty input", "handles": ["C1", "T1"]}]}""")   # says nothing of C2
  discard cli(["brief"], Solo)
  fakeModel("""{"housekeeping": ["C*"]}""")
  discard cli(["brief"], Solo)
  let prompts = calls()
  assert "render: escape quotes" in prompts[0], "offered again"
  assert "Leave out housekeeping" in prompts[0], "a rule for the model, not a filter"
  assert "parse: accept empty input" notin prompts[0], "placed: not again"
  fakeModel("{}")
  discard cli(["brief"], Solo)
  for p in calls():
    assert not p.startsWith("You sort"), "housekeeping is sorted"

tearDown()
