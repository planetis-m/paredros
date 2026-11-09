## Decisions and the companion's setup (test_hitl.py ReviewTests.test_only_page_decisions_are_drafts,
## test_decisions_draft_stale_and_delivered, test_companion_setup_builds_its_arguments, and
## WorkItemTests.test_page_identity_survives_new_material_and_rewritten_briefs).

import std/[strutils, os, envvars, assertions]
import kroki
import fixtures
import ../hitl/[core, items, review, drafts, companion]

setUp()
let example = (try: os.getCurrentDir() except: ".") & "/examples/nimony.hitl.json"

proc liveTips(desk: Desk): seq[ItemTip] =
  tips(workItems(desk, sources(desk.transcript), withDiff = false))

proc draft(desk: Desk; id: DraftId): Draft =
  ## The draft as the page's Copy finds it: facts checked against the code now.
  result = Draft()
  var found = false
  for d in drafts(desk, liveTips(desk)):
    if d.id == id:
      result = d
      found = true
  assert found, "no draft " & $id

proc save(desk: Desk; item: int; question, option: string; code, brief = none[string]()): Draft =
  let key = DecisionKey(item: ItemId(item), did: decisionId(question))
  try: result = decide(desk, key, question, option, code, brief)
  except: quit "cannot save a decision"

proc briefJson(inputs: string): string = "{\"inputs\": \"" & inputs & "\", \"brief\": {\"summary\": \"s\"}}"

type
  Permissions = object
    allow, deny: seq[string]
  Settings = object
    permissions: Permissions

proc profile(args: seq[string]): Permissions =
  fromJson(readOr(args[args.find("--settings") + 1]), Settings).get(Settings()).permissions

block only_page_decisions_are_drafts:  # ReviewTests.test_only_page_decisions_are_drafts
  resetState()
  let desk = deskOf(Sid)
  writeText(draftDir(desk.id) & "/d1.md", "status: draft\nfacts:\n- ref master 0000000\n---\nDrop f7. (d1, approved by me)\n")
  assert drafts(desk, @[]).len == 0, "an old companion draft is no decision"
  let d = save(desk, 7, "Q?", "Yes")
  assert $d.id == "d2", "the next number"
  assert not readOr(draftDir(desk.id) & "/d2.md").startsWith("status:"), "saving is the approval"

block decisions_draft_stale_and_delivered:  # ReviewTests.test_decisions_draft_stale_and_delivered
  resetState()
  let desk = deskOf(Sid)
  let before = readOr(desk.transcript)
  let p = briefPath(desk.id, ItemId(7))
  writeText(p, briefJson("h1"))
  let q = "Allow a call as a field default?"
  let d = save(desk, 7, q, "Yes", brief = some("h1"))
  assert "My decision: Yes. (d" in d.text, "the draft text"
  var now = draft(desk, d.id)
  assert now.stale.len == 0 and now.delivered.isNone and refusal(now).isNone, "fresh"
  let again = save(desk, 7, q, "No", brief = some("h1"))
  assert again.id == d.id, "choosing again rewrites the same draft"
  assert "My decision: No. (d" in again.text, "with the new answer"
  writeText(p, briefJson("h2"))
  now = draft(desk, d.id)
  assert now.stale == {staleBrief} and refusal(now).isSome, "a rewritten brief makes it stale"
  discard save(desk, 7, q, "No", brief = some("h2"))   # Save again: the same draft,
  assert draft(desk, d.id).stale.len == 0, "resting on today's facts"
  discard save(desk, 7, q, "No", code = some("0123abcd"), brief = some("h2"))
  assert draft(desk, d.id).stale == {staleCode}, "item 7 has no such code"
  try: withdraw(desk, d.id)
  except: quit "cannot withdraw"
  assert drafts(desk, @[]).len == 0, "Undo withdraws it"
  assert $save(desk, 7, q, "Yes").id == "d2", "and its number is never used again"
  writeText(p, briefJson("h3"))
  writeText(desk.transcript, before & user(again.text.replace("(d1,", "(d2,"), "2026-11-09T09:00:00Z") & "\n")
  now = draft(desk, DraftId(2))   # the human pasted it
  assert now.delivered.get("").firstRunes(16) == "2026-11-09T09:00", "delivered"
  assert now.stale.len == 0, "a delivered draft is never stale"
  assert refusal(now).get("").startsWith("already sent"), "nor copied again"
  writeText(desk.transcript, before)

block companion_setup_builds_its_arguments:  # ReviewTests.test_companion_setup_builds_its_arguments
  resetState()
  var args: seq[string] = @[]
  try: args = companionArgs(deskOf(Sid))
  except: quit "no companion arguments"
  var perms = profile(args)
  assert "Bash(git push:*)" in perms.deny, "git push is denied"
  assert "--strict-mcp-config" in args, "no MCP tools"
  for r in perms.allow:
    assert getAppFilename() notin r, "no hitl command: " & r
  let system = args[args.find("--append-system-prompt") + 1]
  assert "Compare" notin system, "no config: no compare action"
  assert "{" notin system, "every field filled"
  try: args = companionArgs(deskOf(Sid, some(example)))
  except: quit "no companion arguments"
  perms = profile(args)
  let scratch = tmp() & "/state/hitl/scratch/" & Sid.substr(0, 7)
  assert "Bash(" & getEnv("HOME") & "/Projects/Nim/bin/nim r --nimcache:" & scratch & "/cache:*)" in perms.allow,
    "the compare command"
  assert "Compare with Nim, when the human asks" in args[args.find("--append-system-prompt") + 1], "the compare action"

block page_identity_survives_new_material_and_rewritten_briefs:  # WorkItemTests.test_page_identity_survives_new_material_and_rewritten_briefs
  resetState()
  let desk = deskOf(Solo)
  let answer = """{"summary": "s", "open_decisions": [{"question": "Escape both?", "options": ["yes", "no"]}]}"""
  fakeModel("""{"split": [{"title": "Parser accepts empty input", "handles": ["C1", "T1"]}], "brief": """ & answer & "}")
  discard cli(["brief"], Solo)
  let ledger = loadLedger(desk.id)
  assert ledger.items.len == 1 and ledger.items[0].id == ItemId(1) and
    ledger.items[0].title == "Parser accepts empty input", "one item"
  let d = save(desk, 1, "Escape both?", "yes", code = tipOf(liveTips(desk), ItemId(1)))
  # the human says more; a later run rewrites every brief and the model files all it
  # is shown under a new item: only the new turn is shown, and item 1 keeps its number
  let before = readOr(desk.transcript)
  writeText(desk.transcript, before & user("now the quote escaping", "2026-11-09T10:40:00Z") & "\n")
  fakeModel("""{"split": [{"title": "Quotes are escaped", "handles": ["C*", "T*", "A*"]}], "brief": """ & answer & "}")
  discard cli(["brief", "--force"], Solo)
  let prompts = calls()
  assert "parse: accept empty input" notin prompts[0], "placed material is not offered again"
  assert "now the quote escaping" in prompts[0], "the new turn is"
  let later = loadLedger(desk.id)
  assert later.items.len == 2 and later.items[0].id == ItemId(1) and
    later.items[0].title == "Parser accepts empty input" and later.items[1].id == ItemId(2) and
    later.items[1].title == "Quotes are escaped", "item 1 keeps its number"
  for k in ledger.items[0].sources:
    assert k in later.items[0].sources, "a source stays in its item"
  assert draft(desk, d.id).stale.len == 0, "same code, same evidence: the decision holds"
  let dir = tmp() & "/id-out"
  try: discard build(desk, dir)
  except: quit "the build failed"
  assert "data-item=\"1\" data-did=\"" & $decisionId("Escape both?") & "\"" in readOr(dir & "/i1.html"),
    "the decision keeps its id"
  writeText(desk.transcript, before)

tearDown()
