## Saved decisions (test_hitl.py): ReviewTests.test_a_draft_is_a_record_and_its_text_is_derived,
## ReviewTests.test_decisions_draft_stale_and_delivered, and the decision parts
## of WorkItemTests.test_page_identity_survives_new_material_and_rewritten_briefs
## (its ledger parts are in twork; the page comes with pages).

import std/[syncio, strutils, os, assertions, json, opt, result, tables]
import fixtures
import ../hitl/[state, brief, work, drafts]

setUp()

proc stateOf(sid, spath, id: string): DraftState =
  ## The draft's state as the page shows it; a test cannot go on without it.
  let all = draftsState(sid, spath)
  if all.isErr: quit all.error("")
  result = DraftState()
  var found = false
  for st in all.get(@[]):
    if st.id == id:
      result = st
      found = true
  if not found: quit "no draft " & id

proc writeCache(sid: string; n: int; inputs: string) =
  ## Item n's cached brief, with these inputs and the summary "s".
  try:
    writeJson(cachePath(sid, n), "{\"inputs\": " & quote(inputs) & ", \"brief\": {\"summary\": \"s\"}}")
  except:
    quit "cannot write the brief"

block a_draft_is_a_record_and_its_text_is_derived:
  # ReviewTests.test_a_draft_is_a_record_and_its_text_is_derived
  resetState()
  let d = state("directions", Sid)
  writeText(d & "/d1.md", "status: draft\nfacts:\n- ref master 0\n---\nDrop f7. (d1, approved by me)\n")
  let none = allDrafts(Sid)
  assert none.isOk and none.get(@[Draft()]).len == 0, "an old-format file is no draft"
  let dr = decide(Sid, spathOf(Sid), 7, "abc", "Q\nwith a line?", "Yes")
  assert dr.isOk, dr.error("")
  assert dr.get(Draft()).id == "d2", "numbers are never reused"
  var rec = parseJson(readText(d & "/d2.json"))
  assert not rec.hasError, "the record is JSON"
  var keys: seq[string] = @[]
  for k, v in pairs(rec.root):
    keys.add k
    case k
    of "item": assert v.kind == JInt and v.getInt == 7
    of "did": assert v.getStr == "abc"
    of "question": assert v.getStr == "Q with a line?", "a newline cannot become a fact line"
    of "option": assert v.getStr == "Yes"
    of "code", "brief": assert v.kind == JNull, k & " is null"
    else: discard
  assert keys == @["item", "did", "question", "option", "code", "brief"], "the record's keys"
  assert dr.get(Draft()).text == "#7: Q with a line?\nMy decision: Yes. (d2, approved by me)"
  let w = withdraw(Sid, "d2")
  assert w.isOk and w.get(false), "withdrawn"
  assert fileExists(d & "/d2.withdrawn"), "kept as d2.withdrawn"
  let again = decide(Sid, spathOf(Sid), 7, "abc", "Q?", "No")
  assert again.get(Draft()).id == "d3", "a withdrawn number is not reused"
  # bad input is an error, not an exception
  assert decide(Sid, spathOf(Sid), 7, "a-b", "Q?", "No").error("") == "bad decision id"
  assert decide(Sid, spathOf(Sid), 7, "", "Q?", "No").error("") == "bad decision id"
  assert withdraw(Sid, "../x").error("") == "bad draft id"
  assert withdraw(Sid, "d9").get(true) == false, "no such draft: nothing withdrawn"

block decisions_draft_stale_and_delivered:
  # ReviewTests.test_decisions_draft_stale_and_delivered
  resetState()
  let spath = spathOf(Sid)
  let before = readText(spath)
  writeCache(Sid, 7, "h1")
  let q = "Allow a call as a field default?"
  let did = decisionId(q)
  let dr = decide(Sid, spath, 7, did, q, "Yes", brief = "h1").get(Draft())
  assert "My decision: Yes. (d" in dr.text
  var st = stateOf(Sid, spath, dr.id)
  assert st.stale.len == 0 and st.delivered.isNone, "fresh and not sent"
  let again = decide(Sid, spath, 7, did, q, "No", brief = "h1").get(Draft())
  assert again.id == dr.id, "choosing again rewrites the same draft"
  assert "My decision: No. (d" in again.text
  writeCache(Sid, 7, "h2")
  assert stateOf(Sid, spath, dr.id).stale == @["New evidence."]
  discard decide(Sid, spath, 7, did, q, "No", brief = "h2")   # Save again: the same draft,
  assert stateOf(Sid, spath, dr.id).stale.len == 0, "resting on today's facts"
  discard decide(Sid, spath, 7, did, q, "No", code = "0123abcd", brief = "h2")
  assert "The code changed." in stateOf(Sid, spath, dr.id).stale, "item 7 has no such code"
  let v = check(Sid, spath, dr.id).get(Verdict())
  assert v.draft.isSome and
    v.why.get("") == "the facts changed since you decided; save it again on its page"
  writeCache(Sid, 7, "h3")
  writeText(spath, before & user(again.text, "2026-11-09T09:00:00Z") & "\n")   # the human pasted it
  st = stateOf(Sid, spath, dr.id)
  assert st.delivered.get("").substr(0, 15) == "2026-11-09T09:00"
  assert st.stale.len == 0, "a delivered draft is never stale"
  let sent = check(Sid, spath, dr.id).get(Verdict())
  assert sent.why.get("") == "already sent to the session at 2026-11-09T09:00"
  let none = check(Sid, spath, "d99").get(Verdict())
  assert none.draft.isNone and none.why.get("") == "no such draft"
  # a decision delivered is done: deciding it again makes a new draft
  let next = decide(Sid, spath, 7, did, q, "Yes").get(Draft())
  assert next.id != dr.id, "a new draft"
  let ok = check(Sid, spath, next.id).get(Verdict())
  assert ok.draft.isSome and ok.why.isNone, "it may go"
  writeText(spath, before)

block a_decision_holds_across_a_new_brief:
  # WorkItemTests.test_page_identity_survives_new_material_and_rewritten_briefs:
  # the decision saved on item 1 holds when a later run files new material
  # under a new item and rewrites every brief
  resetState()
  let spath = spathOf(Solo)
  let answer = """{"summary": "s", "open_decisions": [{"question": "Escape both?", """ &
               """"options": ["yes", "no"]}]}"""
  discard fake([("Parser accepts empty input", @["C1", "T1"])], answer)
  discard runBrief(Solo)
  let did = decisionId("Escape both?")
  let tip = codeTips(spath).get(initTable[int, string]()).getOrDefault(1, "")
  assert tip.len == 12, "item 1's code tip"
  let dr = decide(Solo, spath, 1, did, "Escape both?", "yes", code = tip).get(Draft())
  let before = readText(spath)
  writeText(spath, before & user("now the quote escaping", "2026-11-09T10:40:00Z") & "\n")
  discard fake([("Quotes are escaped", @["C*", "T*", "A*"])], answer)
  discard runBrief(Solo, force = true)
  assert stateOf(Solo, spath, dr.id).stale.len == 0, "same code, same evidence: the decision holds"
  writeText(spath, before)

tearDown()
