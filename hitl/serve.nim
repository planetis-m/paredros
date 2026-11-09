## The local server (ARCHITECTURE.md 6.3): the built pages, /config.js with the
## per-run token, and five POST actions that call the drafts and companion
## functions. It listens on 127.0.0.1 only and answers only requests addressed
## to that host and port (DNS rebinding); every POST needs the token and must
## come from no page or from ours.

import std/[syncio, strutils, envvars, osproc, opt, result, atomics, times, base64, crypto/sysrand]
import hashi, hashi/[bootcfg, guarded, loop, log]
import kroki
import core, items, html, review, drafts, companion

type
  Action = enum   ## the five POST actions; nothing else may be posted
    acDrafts = "/drafts", acDecide = "/decide", acSend = "/send", acWithdraw = "/withdraw", acAsk = "/ask"
  Served = object   ## set once before serving, read by every handler
    desk: Desk
    outDir: string
    token: string

  DecideRequest = object
    item: ItemId
    did: DecisionId
    question, option: string
    code, brief: Opt[string]   ## "ref" and "brief": the code tip and brief hash the page showed
  DraftRequest = object        ## /send, /withdraw
    id: DraftId
  AskRequest = object
    item: Opt[ItemId]          ## none on the index
    title, quote, question: string

  DraftsReply = object
    drafts: seq[Draft]
  DecideReply = object
    id: DraftId
    text: string
  SendReply = object
    text: string
  WithdrawReply = object
    ok: bool
  AskReply = object
    html: string
  Refusal = object
    error: string
    stale: set[Stale]

const
  RebuildAfter = 20   ## seconds: the pages are rebuilt on an index request at most this often
  ContentTypes = [(".html", "text/html"), (".css", "text/css"), (".js", "text/javascript"),
                  (".json", "application/json")]
  AskPrompt = """The human is reading the review page for work item #{n} ("{title}").
The brief for it is in {brief}.
{quote}Their question: {question}

Answer in the review page's chat. Be short and plain: what it means, whether it
matters to them and why, and whether it needs their decision or the agents
should settle it by the repository's conventions. Say what you did not check."""

var
  gServed: Frozen[Served]
  gPort: int              ## the port the server bound; atomic
  gBuiltAt: int64         ## when the pages were last built, in Unix seconds; atomic
  gAsking: bool           ## the companion is answering; atomic: one question at a time
  gCompanion: Guarded[Companion]
gCompanion = initGuarded(Companion())

proc optional(s: string): Opt[string] =
  if s.len > 0: some(s) else: none[string]()

proc readJson(dst: var DecideRequest; p: var JsonParser; u: UnknownFieldPolicy) =
  for f in p.jsonFields:
    var s = ""
    if f == "item": readJson(dst.item, p, u)
    elif f == "did": readJson(dst.did, p, u)
    elif f == "question": readJson(dst.question, p, u)
    elif f == "option": readJson(dst.option, p, u)
    elif f == "ref":
      readJson(s, p, u)
      dst.code = optional(s)
    elif f == "brief":
      readJson(s, p, u)
      dst.brief = optional(s)
    else: p.skipJson()

proc readJson(dst: var AskRequest; p: var JsonParser; u: UnknownFieldPolicy) =
  for f in p.jsonFields:
    if f == "item":
      if p.kind == jkString and p.kind != jkNull:
        var s = ""
        readJson(s, p, u)
        if s.len > 0:
          try: dst.item = some(ItemId(parseInt(s))) except: p.parseError()
      else: readJson(dst.item, p, u)
    elif f == "title": readJson(dst.title, p, u)
    elif f == "quote": readJson(dst.quote, p, u)
    elif f == "question": readJson(dst.question, p, u)
    else: p.skipJson()

proc reply[T](status: int; body: T): Response {.untyped.} =
  result = newResponse(status, toJson(body).get(""))
  result.headers.add Header(name: "Content-Type", value: "application/json")
  result.headers.add Header(name: "Cache-Control", value: "no-store")

proc refuse(status: int; why: string): Response = reply(status, Refusal(error: why))

# ------------------------------------------------------------------ checks

proc action(path: string): Opt[Action] =
  result = none[Action]()
  for a in Action:
    if path == $a: result = some(a)

proc guard(req: Request): Opt[Response] {.nimcall.} =
  ## Every request must name this host and port; every POST must be one of the
  ## actions, carry the run's token and come from no page or from ours.
  let port = $atomicLoad(gPort)
  let origin = req.header("Origin")
  result = none[Response]()
  if req.header("Host") notin ["127.0.0.1:" & port, "localhost:" & port]:
    result = some(newResponse(421))
  elif req.httpMethod == "POST" and (action(req.path).isNone or
      req.header("X-HITL-Token") != view(gServed)[].token or
      origin notin ["", "http://127.0.0.1:" & port, "http://localhost:" & port]):
    result = some(newResponse(403))

# ------------------------------------------------------------------- pages

proc rebuild() =
  ## Builds the pages again unless that was done in the last RebuildAfter
  ## seconds; a failed build leaves the last pages in place.
  var last = atomicLoad(gBuiltAt)
  let now = getTime().toUnix
  if now - last > RebuildAfter and atomicCompareExchange(gBuiltAt, last, now):
    try: discard build(view(gServed)[].desk, view(gServed)[].outDir)
    except: discard

proc page(req: Request): Response {.nimcall, raises.} =
  ## A built file: a page, hitl.css, hitl.js or tips.json.
  var path = req.path
  if path in ["/", "/index.html"]:
    path = "/index.html"
    rebuild()
  result = newResponse(404)
  for (ext, ctype) in ContentTypes:
    let body = readText(view(gServed)[].outDir & path)
    if path.endsWith(ext) and body.isSome:
      result = newResponse(200, body.get(""))
      result.headers.add Header(name: "Content-Type", value: ctype)

proc configJs(req: Request): Response {.nimcall, raises.} =
  ## The token, served only here: a page of another site cannot read it.
  result = newResponse(200, "window.HITL={token:" & toJson(view(gServed)[].token).get("\"\"") & "};")
  result.headers.add Header(name: "Content-Type", value: "text/javascript")
  result.headers.add Header(name: "Cache-Control", value: "no-store")

# ----------------------------------------------------------------- actions

proc liveTips(desk: Desk): seq[ItemTip] =
  tips(workItems(desk, sources(desk.transcript), withDiff = false))

proc listDrafts(req: Request): Response {.nimcall, raises.} =
  ## Every draft and its state, against the code tips of the last build.
  let s = view(gServed)
  var tips: seq[ItemTip] = @[]
  # Known issue: bug-reports/case-expression-opt-binding-must-be-discarded - the
  # natural `let tips = case builtTips(...) of Some(t): t ...` does not compile.
  case builtTips(s[].outDir)
  of Some(built): tips = built
  of None: tips = liveTips(s[].desk)
  reply(200, DraftsReply(drafts: drafts(s[].desk, tips)))

proc decideOne(req: Request): Response {.nimcall, raises.} =
  ## Saves the human's answer as an approved draft.
  case fromJson(req.body, DecideRequest)
  of Ok(q):
    try:
      let d = decide(view(gServed)[].desk, DecisionKey(item: q.item, did: q.did), q.question, q.option,
                     q.code, q.brief)
      result = reply(200, DecideReply(id: d.id, text: d.text))
    except: result = refuse(500, "cannot save the draft")
  of Err(e): result = refuse(400, $e)

proc send(req: Request): Response {.nimcall, raises.} =
  ## A draft's text, after the re-check: never one already pasted, never one
  ## whose facts changed. The code tips are computed now.
  case fromJson(req.body, DraftRequest)
  of Ok(q):
    let desk = view(gServed)[].desk
    result = refuse(404, "no such draft")
    for d in drafts(desk, liveTips(desk)):
      if d.id == q.id:
        case refusal(d)
        of Some(why): result = reply(409, Refusal(error: why, stale: d.stale))
        of None: result = reply(200, SendReply(text: d.text))
  of Err(e): result = refuse(400, $e)

proc withdrawOne(req: Request): Response {.nimcall, raises.} =
  ## Undo: the draft is withdrawn, its number never used again.
  case fromJson(req.body, DraftRequest)
  of Ok(q):
    try:
      withdraw(view(gServed)[].desk, q.id)
      result = reply(200, WithdrawReply(ok: true))
    except: result = refuse(500, "cannot withdraw " & $q.id)
  of Err(e): result = refuse(400, $e)

proc askPrompt(desk: Desk; q: AskRequest): string =
  let quote = q.quote.strip
  let question = q.question.strip
  AskPrompt.multiReplace([
    ("{n}", if q.item.isSome: $q.item.get(ItemId(0)) else: "?"), ("{title}", q.title),
    ("{brief}", if q.item.isSome: briefPath(desk.id, q.item.get(ItemId(0)))
                else: "(none: the human is on the index)"),
    ("{quote}", if quote.len > 0: "They selected this text on the page:\n> " & quote & "\n" else: ""),
    ("{question}", if question.len > 0: question else: "What does this mean?")])

proc companionAnswer(prompt: string): Response {.passive.} =
  ## The companion's answer, as HTML. claude runs as a child; this handler is
  ## parked until it writes, so other requests go on meanwhile.
  var c = Companion()
  withLock gCompanion:
    c = it
  var job = Job()
  try: job = askJob(c, prompt)
  except: job = Job(argv: @["claude"])   # cannot write its settings: claude answers nothing
  let running = start(job)
  case running.outputFd
  of Some(fd): discard waitReadableUntil(cint(fd), -1)
  of None: discard
  case answer(c, finish(running))
  of Ok(text):
    withLock gCompanion:
      it = c
    result = reply(200, AskReply(html: markdown(text)))
  of Err(why): result = refuse(500, why)

proc ask(req: Request): Opt[Response] {.passive.} =
  ## /ask: one question at a time; a question while another is answered is refused.
  result = none[Response]()
  if req.httpMethod == "POST" and req.path == $acAsk:
    case fromJson(req.body, AskRequest)
    of Ok(q):
      if atomicExchange(gAsking, true):
        result = some(refuse(409, "the companion is answering another question"))
      else:
        result = some(companionAnswer(askPrompt(view(gServed)[].desk, q)))
        atomicStore(gAsking, false)
    of Err(e): result = some(refuse(400, $e))

# ------------------------------------------------------------------- serve

proc openBrowser(url: string) =
  ## $BROWSER if set (each of its ':'-separated commands is tried no further
  ## than the first), else xdg-open; not waited for.
  let browser = getEnv("BROWSER").split(':')[0]
  var argv = if browser.len > 0: browser.splitWhitespace else: @["xdg-open"]
  if "%s" in browser:
    for a in argv.mitems: a = a.replace("%s", url)
  else: argv.add url
  try: discard startProcess(argv[0], args = argv.toOpenArray(1, argv.high), options = {poUsePath, poParentStreams})
  except: discard

proc announce(port: uint16) {.gcsafe.} =
  ## Called once the server listens: the port it got, the address, the browser.
  atomicStore(gPort, int(port))
  let url = "http://127.0.0.1:" & $port & "/"
  echo "serving ", url, "  (Ctrl+C to stop)"
  flushFile(stdout)   # a pipe would hold the line back
  openBrowser(url)

proc newToken(): string {.raises.} =
  ## 32 url-safe characters from 24 random bytes.
  var bytes = default(array[24, byte])
  if not urandom(bytes): raise IOError
  encode(bytes, safe = true)

proc serve*(desk: Desk; port: int; model: Opt[string]) {.raises.} =
  ## Builds the pages and serves them until hitl is stopped.
  let outDir = stateDir(sdReview, desk.id)
  discard build(desk, outDir)
  atomicStore(gBuiltAt, getTime().toUnix)
  publish(gServed, Served(desk: desk, outDir: outDir, token: newToken()))
  withLock gCompanion:
    it = initCompanion(desk, model)
  setLogLevel(LogLevel.error)   # no warning for every refused request
  addBeforeMiddleware(guard)
  get("/config.js", configJs)
  get("/**", page)
  post($acDrafts, listDrafts)
  post($acDecide, decideOne)
  post($acSend, send)
  post($acWithdraw, withdrawOne)
  addAsyncHandler(ask)
  hashi.serve(uint16(port), bindAddr = "127.0.0.1", onBound = announce)
