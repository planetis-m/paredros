## test_hitl.py's draft and companion tests: ReviewTests.test_only_page_decisions_are_drafts,
## test_decisions_draft_stale_and_delivered, test_companion_setup_builds_its_arguments, and
## WorkItemTests.test_page_identity_survives_new_material_and_rewritten_briefs.

import std/[syncio, strutils, os, opt, tables, result, envvars]
import kroki
import fixtures
import ../hitl/[core, store, review, drafts, companion]

setUp()
let example = (try: os.getCurrentDir() except: ".") & "/examples/nimony.hitl.json"
let sid = SessionId(Sid)
let solo = SessionId(Solo)

proc readOr(p: string): string = (try: readFile(p) except: "")

proc stateOf(s: SessionId; spath, id: string): DraftState =
  for x in draftsState(s, spath, "", initTable[int, string]()):
    if x.id == id: return x
  fail("no draft " & id)

proc briefJson(inputs: string): string = "{\"inputs\": \"" & inputs & "\", \"brief\": {\"summary\": \"s\"}}"

type Perms = object
  allow, deny: seq[string]
type Profile = object
  permissions: Perms

proc profile(args: seq[string]): Perms =
  let f = args[args.find("--settings") + 1]
  fromJson(readOr(f), Profile).get(Profile()).permissions

block test_only_page_decisions_are_drafts:  # test_hitl.py::ReviewTests::test_only_page_decisions_are_drafts
  resetState()
  let d = draftDir(sid)
  writeText(d & "/d1.md", "status: draft\nfacts:\n- ref master 0000000\n---\nDrop f7. (d1, approved by me)\n")
  check allDrafts(sid).len == 0, "an old companion draft is no decision"
  let dr = decide(sid, spathOf(Sid), 7, "abc", "Q?", "Yes").get(Draft())
  check dr.id == "d2", "the next number"
  check not readOr(dr.path).startsWith("status:"), "saving is the approval"

block test_decisions_draft_stale_and_delivered:  # test_hitl.py::ReviewTests::test_decisions_draft_stale_and_delivered
  resetState()
  let spath = spathOf(Sid)
  let before = readOr(spath)
  let p = cachePath(sid, 7)
  writeText(p, briefJson("h1"))
  let q = "Allow a call as a field default?"
  let did = decisionId(q)
  let dr = decide(sid, spath, 7, did, q, "Yes", brief = "h1").get(Draft())
  check "My decision: Yes. (d" in dr.text, "the draft text"
  var st = stateOf(sid, spath, dr.id)
  check st.stale.len == 0 and st.delivered.isNone, "fresh"
  let again = decide(sid, spath, 7, did, q, "No", brief = "h1").get(Draft())
  check again.id == dr.id, "choosing again rewrites the same draft"
  check "My decision: No. (d" in again.text, "with the new answer"
  writeText(p, briefJson("h2"))
  st = stateOf(sid, spath, dr.id)
  var evidence = false
  for m in st.stale:
    if "new evidence" in m: evidence = true
  check evidence, "a rewritten brief makes it stale"
  discard decide(sid, spath, 7, did, q, "No", brief = "h2")   # Save again: the same draft,
  check stateOf(sid, spath, dr.id).stale.len == 0, "resting on today's facts"
  discard decide(sid, spath, 7, did, q, "No", code = "0123abcd", brief = "h2")
  check "The code changed after you chose." in stateOf(sid, spath, dr.id).stale, "item 7 has no such code"
  writeText(p, briefJson("h3"))
  writeText(spath, before & user(again.text, "2026-11-09T09:00:00Z") & "\n")   # the human pasted it
  st = stateOf(sid, spath, dr.id)
  check runeHead(st.delivered.get(""), 16) == "2026-11-09T09:00", "delivered"
  check st.stale.len == 0, "a delivered draft is never stale"
  writeText(spath, before)

block test_companion_setup_builds_its_arguments:  # test_hitl.py::ReviewTests::test_companion_setup_builds_its_arguments
  resetState()
  var (cwd, args) = companionSetup(sid, spathOf(Sid), "")
  check cwd == tmp() & "/proj/repo", "the session's directory"
  var perms = profile(args)
  check "Bash(git push:*)" in perms.deny, "git push is denied"
  check "--strict-mcp-config" in args, "no MCP tools"
  for r in perms.allow:
    check not ("directions" in r and "list" notin r), "only directions list: " & r
  let system = args[args.find("--append-system-prompt") + 1]
  check "Compare" notin system, "no config: no compare action"
  check "{" notin system, "every field filled"
  (cwd, args) = companionSetup(sid, spathOf(Sid), example)
  perms = profile(args)
  let scratch = tmp() & "/state/hitl/scratch/" & Sid.substr(0, 7)
  check "Bash(" & getEnv("HOME") & "/Projects/Nim/bin/nim r --nimcache:" & scratch & "/cache:*)" in perms.allow,
    "the compare command"
  check "Compare with Nim, when the human asks" in args[args.find("--append-system-prompt") + 1], "the compare action"

block test_page_identity_survives_new_material_and_rewritten_briefs:  # test_hitl.py::WorkItemTests::test_page_identity_survives_new_material_and_rewritten_briefs
  resetState()
  let spath = spathOf(Solo)
  let answer = """{"summary": "s", "open_decisions": [{"question": "Escape both?", "options": ["yes", "no"]}]}"""
  fakeModel("""{"split": [{"title": "Parser accepts empty input", "handles": ["C1", "T1"]}], "brief": """ & answer & "}")
  discard cli(["brief"], Solo)
  let led = loadLedger(solo)
  check led.items.len == 1 and led.items[0].id == 1 and led.items[0].title == "Parser accepts empty input", "one item"
  let did = decisionId("Escape both?")
  let dr = decide(solo, spath, 1, did, "Escape both?", "yes",
                  code = codeTips(spath, "").getOrDefault(1, "")).get(Draft())
  # the human says more; a later run rewrites every brief and the model files all it
  # is shown under a new item: only the new turn is shown, and item 1 keeps its number
  let before = readOr(spath)
  writeText(spath, before & user("now the quote escaping", "2026-11-09T10:40:00Z") & "\n")
  fakeModel("""{"split": [{"title": "Quotes are escaped", "handles": ["C*", "T*", "A*"]}], "brief": """ & answer & "}")
  discard cli(["brief", "--force"], Solo)
  let prompts = calls()
  check "parse: accept empty input" notin prompts[0], "placed material is not offered again"
  check "now the quote escaping" in prompts[0], "the new turn is"
  let led2 = loadLedger(solo)
  check led2.items.len == 2 and led2.items[0].id == 1 and led2.items[0].title == "Parser accepts empty input" and
    led2.items[1].id == 2 and led2.items[1].title == "Quotes are escaped", "item 1 keeps its number"
  for k in led.items[0].sources:
    check k in led2.items[0].sources, "a source stays in its item"
  check stateOf(solo, spath, dr.id).stale.len == 0, "same code, same evidence: the decision holds"
  let dir = tmp() & "/id-out"
  discard cli(["review", "--out=" & dir], Solo)
  check "data-item=\"1\" data-did=\"" & did & "\"" in readOr(dir & "/i1.html"), "the decision keeps its id"
  writeText(spath, before)

tearDown()
