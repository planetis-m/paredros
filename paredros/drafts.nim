## Saved decisions ("drafts"): each one a JSON record in
## $STATE/directions/<s>/d<N>.json, written when the human saves an answer on
## a page (that is the approval), re-checked against the current code and
## brief before its text leaves paredros, and delivered when the human pastes its
## text, which ends `(<tag>, approved by me)`, into the session.

import std/[syncio, strutils, os, paths, dirs, files, algorithm, tables, json, opt, result]
import std/crypto/sha2
import state, session, brief, work

type
  Draft* = object
    ## A saved decision: the record `decide` wrote, with its id, its key and
    ## the text that is pasted into the session.
    id*: string            ## "d<N>", the file's name
    item*: int             ## the work item's number
    did*: string           ## the decision's id (brief.decisionId)
    question*, option*: string
    code*: string          ## the item's code tip the page showed; "" for none
    brief*: string         ## the inputs hash of the brief the page showed; "" for none
    decision*: string      ## "<item>:<did>"
    tag*: string           ## six hex digits of the session and the id: what the pasted
                           ## text carries, so no other session's draft can match it
    text*: string          ## "<question>\nMy decision: <option>. (<tag>, approved by me)"
  DraftState* = object
    ## A draft as the page shows it.
    id*, decision*: string
    item*: int
    question*, option*, text*: string
    delivered*: Opt[string]  ## when the human pasted it into the session; none if not yet
    stale*: seq[string]      ## what changed since it was saved; empty once delivered
  Verdict* = object
    ## The re-check before a draft's text leaves paredros.
    draft*: Opt[DraftState]  ## the draft's state; none when there is no such draft
    why*: Opt[string]        ## why it may not go now; none when it may

# ------------------------------------------------------------------- helpers

proc number(stem: string): int =
  ## N of a file name's stem "d<N>"; -1 when it is no draft's.
  # GAP: only ASCII digits make a draft number, not other Unicode digits,
  # because std/unicode has no digit test (README, Limitations). A number
  # too big for an int is no draft's either.
  result = -1
  if stem.len > 1 and stem[0] == 'd' and allCharsInSet(stem.substr(1), Digits):
    result = try: parseInt(stem.substr(1)) except: -1

proc orNull(s: string): string =
  ## s as a JSON string; null when it is "".
  if s.len > 0: quote(s) else: "null"

# -------------------------------------------------------------------- drafts

proc readDraft(sid, p: string): Result[Draft, string] =
  ## The draft in file p, as `decide` wrote it: {item, did, question, option,
  ## code, brief}, with its id, its key and the text that is pasted into the
  ## session. The error says why the file is no draft.
  let id = extractFilename(p).changeFileExt("")
  let text = try: readFile(p) except: ""
  var tree = parseJson(text, p)
  if tree.hasError: return err[Draft, string]("cannot read " & p & ": " & tree.errorMsg)
  var dr = Draft(id: id, item: 0, did: "", question: "", option: "", code: "", brief: "",
                 decision: "", tag: "", text: "")
  var have: seq[string] = @[]   # the keys the text is built from
  if tree.root.kind == JObject:
    for k, v in pairs(tree.root):
      case k
      of "item":
        if v.kind == JInt:
          dr.item = int(v.getInt)
          have.add k
      of "did", "question", "option":
        if v.kind == JString: have.add k
        if k == "did": dr.did = v.getStr
        elif k == "question": dr.question = v.getStr
        else: dr.option = v.getStr
      # null, written for none, reads as ""
      of "code": dr.code = v.getStr
      of "brief": dr.brief = v.getStr
      else: discard
  for k in ["item", "did", "question", "option"]:
    if k notin have: return err[Draft, string](p & " has no " & k)
  dr.decision = $dr.item & ":" & dr.did
  dr.tag = toHex(sha256(sid & "/" & id)).substr(0, 5).toLowerAscii
  dr.text = dr.question & "\nMy decision: " & dr.option & ". (" & dr.tag & ", approved by me)"
  result = ok[Draft, string](dr)

proc allDrafts*(sid: string): Result[seq[Draft], string] =
  ## The session's drafts, by number; withdrawn ones and files of other
  ## formats are none. The error says which draft cannot be read.
  var found: seq[(int, string)] = @[]
  try:
    for (kind, p) in walkDir(path(state("directions", sid))):
      let name = extractFilename($p)
      let n = number(name.changeFileExt(""))
      if name.endsWith(".json") and n >= 0: found.add (n, $p)
  except:
    discard   # no drafts yet
  found.sort(proc (a, b: (int, string)): int = cmp(a[0], b[0]))
  var drafts: seq[Draft] = @[]
  for (n, p) in found:
    let dr = readDraft(sid, p)
    if dr.isErr: return err[seq[Draft], string](dr.error(""))
    drafts.add dr.get(Draft())
  result = ok[seq[Draft], string](drafts)

proc deliveredAt(dr: Draft; recs: seq[Rec]): Opt[string] =
  ## When the human pasted the draft into the session: the time of the first
  ## message they typed that holds "(<tag>,"; none if they did not.
  # A message with no time counts as not delivered.
  let tag = "(" & dr.tag & ","
  for r in recs:
    if isHuman(r) and tag in textOf(r) and r.timestamp.len > 0: return some(r.timestamp)
  result = none[string]()

proc decide*(sid, spath: string; item: int; did, question, option: string; code = "";
             brief = ""): Result[Draft, string] =
  ## Writes (or rewrites) the approved draft for one decision, in the human's
  ## words, and returns it. Saving on the page is the approval; code and brief
  ## are what the page showed ("" for none). The error says the decision id
  ## is bad, or why the draft cannot be read or written.
  # GAP: a did with non-ASCII letters or digits is refused, because
  # std/unicode has no digit test and std/rex's \w is ASCII (README,
  # Limitations).
  if did.len == 0 or not allCharsInSet(did, IdentChars):
    return err[Draft, string]("bad decision id")
  let recs = readJsonl(spath)
  let d = state("directions", sid)
  try:
    createDir(path(d))
  except:
    return err[Draft, string]("cannot make " & d)
  let all = allDrafts(sid)
  if all.isErr: return err[Draft, string](all.error(""))
  var mine = ""   # the decision's last draft not yet sent: saving again rewrites it
  for x in all.get(@[]):
    if x.decision == $item & ":" & did and deliveredAt(x, recs).isNone: mine = x.id
  # a number is never reused, not even after Discard: withdrawn drafts keep theirs
  var used = 0
  try:
    for (kind, p) in walkDir(path(d)):
      let name = extractFilename($p)
      if '.' in name: used = max(used, number(name.changeFileExt("")))
  except:
    return err[Draft, string]("cannot read " & d)
  let name = if mine.len > 0: mine else: "d" & $(used + 1)
  let p = d & "/" & name & ".json"
  # Joined from its members, not std/json's toJson, which has no null: code
  # and brief are null when the page showed none.
  # GAP: written on one line, not indented, because std/json has no pretty
  # printer (README, Limitations).
  let record = "{\"item\":" & $item & ",\"did\":" & quote(did) & ",\"question\":" &
    quote(collapse(question)) & ",\"option\":" & quote(collapse(option)) & ",\"code\":" &
    orNull(code) & ",\"brief\":" & orNull(brief) & "}"
  try:
    writeAtomic(p, record)
  except:
    return err[Draft, string]("cannot write " & p)
  result = readDraft(sid, p)

proc withdraw*(sid, spath, name: string): Result[bool, string] =
  ## Discard: draft `name` becomes d<N>.withdrawn, so its number is never
  ## reused. True when there was such a draft. The error says the id is bad,
  ## the draft already reached the session (it has the answer, so the draft
  ## stays), or the file cannot be renamed.
  if number(name) < 0: return err[bool, string]("bad draft id")
  let p = state("directions", sid) & "/" & name
  result = ok[bool, string](false)
  if fileExists(p & ".json"):
    let dr = readDraft(sid, p & ".json")
    if dr.isErr: return err[bool, string](dr.error(""))
    if deliveredAt(dr.get(Draft()), readJsonl(spath)).isSome:
      return err[bool, string]("already sent to the session")
    try:
      moveFile(path(p & ".json"), path(p & ".withdrawn"))
      result = ok[bool, string](true)
    except:
      result = err[bool, string]("cannot withdraw " & name)

# ------------------------------------------------------------------- checks

proc staleFacts(dr: Draft; sid: string; tips: Table[int, string]): seq[string] =
  ## What changed since the decision was saved, as the page says it: the
  ## item's code (tips: {item: its code tip}) and the evidence of its brief.
  result = @[]
  if dr.code.len > 0 and tips.getOrDefault(dr.item, "") != dr.code:
    result.add "The code changed."
  if dr.brief.len > 0:
    let now = load(sid, dr.item)
    # no brief, or one that cannot be read, is new evidence too
    if now.isNone or now.get(Cached()).inputs != dr.brief: result.add "New evidence."

proc draftsState*(sid, spath: string;
                  tips = none[Table[int, string]]()): Result[seq[DraftState], string] =
  ## Every draft as the page shows it: whether it reached the session and
  ## what changed since. tips: the items' code tips as the last page build
  ## found them; else they are computed now, and only if a draft that is not
  ## sent yet records its code. The error says why a draft, the config or the
  ## ledger cannot be read.
  let recs = readJsonl(spath)
  let all = allDrafts(sid)
  if all.isErr: return err[seq[DraftState], string](all.error(""))
  var known = tips
  var states: seq[DraftState] = @[]
  for dr in all.get(@[]):
    let sent = deliveredAt(dr, recs)
    if sent.isNone and dr.code.len > 0 and known.isNone:
      let now = codeTips(spath)
      if now.isErr: return err[seq[DraftState], string](now.error(""))
      known = some(now.get(initTable[int, string]()))
    states.add DraftState(id: dr.id, decision: dr.decision, item: dr.item, question: dr.question,
                       option: dr.option, text: dr.text, delivered: sent,
                       stale: if sent.isSome: @[]
                              else: staleFacts(dr, sid, known.get(initTable[int, string]())))
  result = ok[seq[DraftState], string](states)

proc check*(sid, spath, name: string): Result[Verdict, string] =
  ## The one re-check before a draft's text leaves paredros (Copy on a page): its
  ## state, and why it may not go now (none when it may). The error says why
  ## the drafts cannot be read.
  let all = draftsState(sid, spath)
  if all.isErr: return err[Verdict, string](all.error(""))
  var v = Verdict(draft: none[DraftState](), why: some("no such draft"))
  for st in all.get(@[]):
    if st.id == name:
      v.draft = some(st)
      v.why = if st.delivered.isSome:
                some("already sent to the session at " & st.delivered.get("").substr(0, 15))
              elif st.stale.len > 0:
                some("the facts changed since you decided; save it again on its page")
              else:
                none[string]()
  result = ok[Verdict, string](v)
