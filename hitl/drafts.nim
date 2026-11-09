## Your saved decisions ("directions"): written only by saving on a page, which
## is the approval; re-checked against the facts you saw before their text
## leaves hitl by the page's Copy; delivered when the
## session's transcript shows you pasted them.

import std/[syncio, os, paths, dirs, files, strutils, tables, opt, result, algorithm, envvars]
import core, store, review

type
  FactKind* = enum fkBrief = "brief", fkCode = "code"
  Fact* = object   ## "- code <item> <tip>" or "- brief <item> <inputs hash>"
    kind*: FactKind
    item*, value*: string
  Draft* = object  ## $STATE/directions/<s>/d<N>.md
    id*, path*, text*: string
    facts*: seq[Fact]
    decision*: Opt[string]   ## "<item>:<decision id>"
    option*: Opt[string]
  DraftState* = object   ## a draft as /drafts and the re-check report it
    id*: string
    decision*: Opt[string]
    option*: Opt[string]
    text*: string
    delivered*: Opt[string]
    stale*: seq[string]

proc isDraftId*(s: string): bool =
  ## re.fullmatch(r"d\d+", s)
  s.len > 1 and s[0] == 'd' and s.substr(1).allCharsInSet(Digits)

proc isWordId(s: string): bool =
  ## re.fullmatch(r"\w+", s)
  if s.len == 0: return false
  for c in s:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}: return false
  true

proc readDraft*(path: string): Draft =
  let all = readText(path).get("")
  let at = all.find("\n---\n")
  let head = if at >= 0: all.substr(0, at - 1) else: all
  let text = if at >= 0: all.substr(at + 5) else: ""
  result = Draft(id: extractFilename(path).changeFileExt(""), path: path, text: text.strip)
  for line in head.splitLines:
    if not line.startsWith("-"): continue
    let words = line.substr(1).splitWhitespace
    if words.len >= 2 and words[0] in ["brief", "code"]:
      result.facts.add Fact(kind: (if words[0] == "brief": fkBrief else: fkCode), item: words[1],
                            value: (if words.len >= 3: words[2] else: ""))
    elif words.len >= 2 and words[0] == "decision" and result.decision.isNone:
      let colon = words[1].find(':')
      if colon > 0 and words[1].substr(0, colon - 1).allCharsInSet(Digits) and isWordId(words[1].substr(colon + 1)):
        result.decision = some(words[1])
    elif words.len >= 2 and words[0] == "option" and result.option.isNone:
      result.option = some(line.substr(line.find("option") + 6).strip)

proc draftDir*(sid: SessionId): string = state(skDirections, sid)

proc allDrafts*(sid: SessionId): seq[Draft] =
  ## The drafts saved on a page, by number; older companion drafts have no decision.
  result = @[]
  try:
    for (kind, p) in walkDir(path(draftDir(sid))):
      let name = extractFilename($p)
      if name.endsWith(".md") and isDraftId(name.substr(0, name.len - 4)):
        let dr = readDraft($p)
        if dr.decision.isSome: result.add dr
  except: discard
  result.sort(proc (a, b: Draft): int =
    cmp((try: parseInt(a.id.substr(1)) except: 0), (try: parseInt(b.id.substr(1)) except: 0)))

proc deliveredAt*(dr: Draft; recs: seq[Rec]): Opt[string] =
  ## When the human pasted the draft into the session, if they did.
  let tag = "(" & dr.id & ","
  for r in recs:
    if isHuman(r) and tag in textOf(r): return some(r.timestamp)
  none[string]()

proc delivered(sentAt: Opt[string]): bool = sentAt.get("").len > 0

proc decide*(sid: SessionId; spath: string; item: int; did, question, option: string;
             code = ""; brief = ""): Result[Draft, string] =
  ## Writes (or rewrites) the approved draft for one decision, in the human's words.
  ## Saving on the page is the approval; code and brief are what the page showed.
  if not isWordId(did): return err[Draft, string]("bad decision id")
  let recs = readJsonl(spath)
  let d = draftDir(sid)
  ensureDir(d)
  let key = $item & ":" & did
  var mine: seq[Draft] = @[]
  for x in allDrafts(sid):
    if x.decision.get("") == key and not delivered(deliveredAt(x, recs)): mine.add x
  # a number is never reused, not even after Undo: withdrawn drafts keep theirs
  var used = 0
  try:
    for (kind, p) in walkDir(path(d)):
      let name = extractFilename($p)
      let stem = if '.' in name: name.substr(0, name.find('.') - 1) else: name
      if isDraftId(stem): used = max(used, (try: parseInt(stem.substr(1)) except: 0))
  except: discard
  let name = if mine.len > 0: mine[^1].id else: "d" & $(used + 1)
  var facts = @["- decision " & key, "- option " & collapse(option)]
  if code.len > 0: facts.add "- code " & $item & " " & code
  if brief.len > 0: facts.add "- brief " & $item & " " & brief   # new evidence makes the decision stale
  let text = "#" & $item & ": " & collapse(question) & "\nMy decision: " & collapse(option) & ". (" & name &
             ", approved by me)"
  writeAtomic(d & "/" & name & ".md", "facts:\n" & facts.join("\n") & "\n---\n" & text & "\n")
  ok[Draft, string](readDraft(d & "/" & name & ".md"))

proc withdraw*(sid: SessionId; name: string): Result[bool, string] =
  ## Undo: the draft becomes d<N>.withdrawn, so its number is never reused.
  if not isDraftId(name): return err[bool, string]("bad draft id")
  let p = draftDir(sid) & "/" & name & ".md"
  if fileExists(p):
    try: moveFile(path(p), path(draftDir(sid) & "/" & name & ".withdrawn"))
    except: return err[bool, string]("cannot withdraw " & name)
  ok[bool, string](true)

proc staleFacts*(dr: Draft; spath, configFile: string; tips: var Table[int, string]): seq[string] =
  ## What changed since the decision was saved. tips caches the items' code tips.
  result = @[]
  for f in dr.facts:
    let isNum = f.item.len > 0 and f.item.allCharsInSet(Digits)
    let n = if isNum: (try: parseInt(f.item) except: -1) else: -1
    case f.kind
    of fkCode:
      if tips.len == 0: tips = codeTips(spath, configFile)
      if isNum and (n notin tips or tips.getOrDefault(n, "") != f.value):
        result.add "The code changed after you chose."
    of fkBrief:
      let now = if isNum: load(SessionId(extractFilename(parentDir(dr.path))), n) else: none[Cached]()
      if now.isNone or now.get(Cached()).inputs != f.value:
        result.add "There is new evidence since you chose."

proc draftsState*(sid: SessionId; spath, configFile: string; tips: Table[int, string]): seq[DraftState] =
  ## Every draft with whether it reached the session and what changed since.
  ## tips: the items' code tips as the last page build found them; else computed now.
  let recs = readJsonl(spath)
  var t = tips
  result = @[]
  for dr in allDrafts(sid):
    let sentAt = deliveredAt(dr, recs)
    result.add DraftState(id: dr.id, decision: dr.decision, option: dr.option, text: dr.text,
                          delivered: sentAt,
                          stale: (if delivered(sentAt): @[] else: staleFacts(dr, spath, configFile, t)))

proc check*(sid: SessionId; spath, configFile, name: string; st: var Opt[DraftState]): string =
  ## The one re-check before a draft's text leaves hitl, by the page's Copy:
  ## "" when it may go now, else why not; st is the draft's state when there is one.
  st = none[DraftState]()
  for x in draftsState(sid, spath, configFile, initTable[int, string]()):
    if x.id == name: st = some(x)
  if st.isNone: return "no such draft"
  let x = st.get(DraftState())
  if delivered(x.delivered): return "already sent to the session at " & runeHead(x.delivered.get(""), 16)
  if x.stale.len > 0: return "the facts changed since you decided; save it again on its page"
  ""
