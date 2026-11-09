## Your saved decisions: written only by saving on a page, which is the
## approval; re-checked against the facts you saw before their text leaves
## hitl by the page's Copy; delivered when the session's transcript shows you
## pasted them. The draft file's text is a contract (ARCHITECTURE.md 4.4).

import std/[strutils, os, dirs, files, paths, opt, algorithm]
import kroki
import core, items

type
  DraftId* = distinct int   ## d<N>: never reused, not even after Undo
  DecisionKey* = object     ## "<item>:<decision id>": which decision a draft answers
    item*: ItemId
    did*: DecisionId
  Stale* = enum   ## a fact that no longer holds; the page reads these words
    staleCode = "The code changed after you chose."
    staleBrief = "There is new evidence since you chose."
  Draft* = object   ## $STATE/directions/<s>/d<N>.md, and what changed since
    id*: DraftId
    decision*: DecisionKey
    option*: string             ## the answer
    code*, brief*: Opt[string]  ## the code tip and the brief's inputs hash the page showed
    text*: string               ## what the human pastes into the session
    delivered*: Opt[string]     ## when the human pasted it
    stale*: set[Stale]

func `==`*(a, b: DraftId): bool {.borrow.}
func `<`*(a, b: DraftId): bool {.borrow.}
func `$`*(id: DraftId): string = "d" & $int(id)
func `$`*(k: DecisionKey): string = $k.item & ":" & $k.did

proc toDraftId*(s: string): Opt[DraftId] =
  ## "d3".
  result = none[DraftId]()
  if s.len > 1 and s[0] == 'd' and s.substr(1).allCharsInSet(Digits):
    try: result = some(DraftId(parseInt(s.substr(1)))) except: discard

proc readJson*(dst: var DraftId; p: var JsonParser; u: UnknownFieldPolicy) =
  var s = ""
  readJson(s, p, u)
  let id = toDraftId(s)
  if id.isSome: dst = id.get(DraftId(0)) else: p.parseError()

proc writeJson*(w: var JsonWriter; id: DraftId) = w.escapeJson($id)
proc writeJson*(w: var JsonWriter; k: DecisionKey) = w.escapeJson($k)

proc draftDir*(id: SessionId): string = stateDir(sdDirections, id)

proc readDraft(path: string): Opt[Draft] =
  ## A draft saved on a page: one with a `decision` fact. Older companion
  ## drafts have none and are left out.
  result = none[Draft]()
  let file = readText(path).get("")
  let id = toDraftId(extractFilename(path).changeFileExt(""))
  let rule = file.find("\n---\n")
  if id.isNone or rule < 0 or not path.endsWith(".md"): return
  var d = Draft(id: id.get(DraftId(0)), text: file.substr(rule + 5).strip)
  var key = none[DecisionKey]()
  for line in file.substr(0, rule - 1).splitLines:
    let words = line.substr(1).splitWhitespace
    if line.startsWith("-") and words.len >= 2:
      case words[0]
      of "decision":
        let colon = words[1].find(':')
        let did = toDecisionId(words[1].substr(colon + 1))
        let item = try: parseInt(words[1].substr(0, colon - 1)) except: -1
        if key.isNone and colon > 0 and item >= 0 and did.isSome:
          key = some(DecisionKey(item: ItemId(item), did: did.get(DecisionId(""))))
      of "option": d.option = line.substr(line.find("option") + len("option")).strip
      of "code": d.code = some(if words.len > 2: words[2] else: "")
      of "brief": d.brief = some(if words.len > 2: words[2] else: "")
      else: discard
  if key.isSome:
    d.decision = key.get(DecisionKey())
    result = some(d)

proc deliveredAt(d: Draft; recs: seq[Rec]): Opt[string] =
  ## When the human pasted the draft into the session, if they did.
  result = none[string]()
  let tag = "(" & $d.id & ","
  for r in recs:
    if isHuman(r) and tag in textOf(r): return some(r.timestamp)

proc drafts*(desk: Desk; tips: seq[ItemTip]): seq[Draft] =
  ## Every draft saved on a page, by number, with whether it reached the session
  ## and, if not, which of its facts changed since: tips are the items' code
  ## tips to compare with.
  result = @[]
  try:
    for (kind, p) in walkDir(paths.path(draftDir(desk.id))):
      let d = readDraft($p)
      if d.isSome: result.add d.get(Draft())
  except: discard
  result.sort(proc (a, b: Draft): int = cmp(int(a.id), int(b.id)))
  let recs = readJsonl(desk.transcript)
  for d in result.mitems:
    d.delivered = deliveredAt(d, recs)
    if d.delivered.isNone:
      let tip = tipOf(tips, d.decision.item)
      if d.code.isSome and (tip.isNone or tip.get("") != d.code.get("")): d.stale.incl staleCode
      let now = loadBrief(desk.id, d.decision.item)
      if d.brief.isSome and (now.isNone or now.get(Cached()).inputs != d.brief.get("")):
        d.stale.incl staleBrief

proc refusal*(d: Draft): Opt[string] =
  ## Why the draft's text may not leave hitl now, if it may not: the one
  ## re-check before Copy.
  if d.delivered.isSome:
    result = some("already sent to the session at " & d.delivered.get("").firstRunes(16))
  elif d.stale.len > 0:
    result = some("the facts changed since you decided; save it again on its page")
  else: result = none[string]()

proc decide*(desk: Desk; key: DecisionKey; question, option: string;
             code, brief: Opt[string]): Draft {.raises.} =
  ## Writes (or rewrites) the approved draft for one decision, in the human's
  ## words. Saving on the page is the approval; code and brief are what the
  ## page showed. Returns the draft as written.
  let dir = draftDir(desk.id)
  createDir(paths.path(dir))
  let recs = readJsonl(desk.transcript)
  var id = none[DraftId]()   # the decision's undelivered draft, rewritten
  var used = 0               # numbers in use, withdrawn drafts' too
  for (kind, p) in walkDir(paths.path(dir)):
    let n = toDraftId(extractFilename($p).split('.')[0])
    if n.isSome: used = max(used, int(n.get(DraftId(0))))
    case readDraft($p)
    of Some(d):
      if d.decision == key and deliveredAt(d, recs).isNone and int(d.id) > int(id.get(DraftId(0))):
        id = some(d.id)
    of None: discard
  var d = Draft(id: id.get(DraftId(used + 1)), decision: key, option: collapse(option), code: code,
                brief: brief)
  d.text = "#" & $key.item & ": " & collapse(question) & "\nMy decision: " & d.option & ". (" & $d.id &
           ", approved by me)"
  var facts = "facts:\n- decision " & $key & "\n- option " & d.option & "\n"
  if code.isSome: facts.add "- code " & $key.item & " " & code.get("") & "\n"
  if brief.isSome: facts.add "- brief " & $key.item & " " & brief.get("") & "\n"   # new evidence makes it stale
  writeAtomic(dir & "/" & $d.id & ".md", facts & "---\n" & d.text & "\n")
  d

proc withdraw*(desk: Desk; id: DraftId) {.raises.} =
  ## Undo: the draft becomes d<N>.withdrawn, so its number is never reused.
  let p = draftDir(desk.id) & "/" & $id
  if fileExists(p & ".md"): moveFile(paths.path(p & ".md"), paths.path(p & ".withdrawn"))
