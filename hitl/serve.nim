## Serve the review pages on localhost, with a chat to the read-only companion.
##
## Standard library only. The server answers only requests addressed to
## 127.0.0.1 or localhost and its port, and requires a per-run token on every
## POST, so another web page can neither read the pages nor act on your
## behalf. It listens on every interface, though (see the GAP in `run`): a
## client on the network can read the token from /config.js. The first question forks the session (`claude -p --resume <id>
## --fork-session`); later questions continue that fork, so the companion
## keeps the conversation. The session itself is never touched.

import std/[syncio, strutils, os, envvars, osproc, json, locks, monotimes, times, unicode,
            base64, opt, result, httpserver, ioring, threadpool]
import std/crypto/sysrand
import state, session, config, render, brief, pages, drafts, companion

const
  Ask = """The human is reading the review page for work item #{n} ("{title}").
{brief}
{quote}Their question: {question}

Answer in the review page's chat ("Who you write for", "How to answer"): what it
means, whether it matters to them and why, and whether it needs their decision or
the agents should settle it by the repository's conventions."""
  Actions = ["/ask", "/decide", "/send", "/withdraw", "/drafts"]   # the only POSTs
  RebuildAfter = 20   # seconds: the index is rebuilt at most this often
  ContentTypes = [(".html", "text/html"), (".css", "text/css"), (".js", "text/javascript"),
                  (".json", "application/json")]

# ------------------------------------------------------------------- prompts

proc pageWords(b: Brief): string =
  ## A parsed brief as plain text with the page's section names, not the JSON keys.
  var lines = @[b.summary]
  for s in Section:
    let list = b.lists[s]
    if list.len > 0: lines.add "\n" & Sections[s].heading & ":"
    for i, e in list:
      lines.add $(i + 1) & ". " & (if e.question.len > 0: e.question else: e.text)
      if e.options.len > 0: lines.add "   Options: " & e.options.join("; ")
      if e.recommended >= 0 and e.recommended < e.options.len:   # as the page marks it
        lines.add "   Suggested: " & e.options[e.recommended] &
                  (if e.reason.len > 0: " (" & e.reason & ")" else: "")
      if e.spec.len > 0: lines.add "   Spec: " & e.spec
      if e.source.len > 0: lines.add "   From: " & e.source
  result = lines.join("\n")

proc briefText(sid: string; n: int; limit = 12_000): string =
  ## The item's brief as the page shows it, under the page's headings, for the
  ## question itself: the companion then starts from the page's words instead
  ## of the session's. n 0: the index page. Cut to limit characters.
  let b = if n != 0: brief.load(sid, n) else: none[Cached]()
  result = if b.isSome:
             runeSubStr("The page's brief (what they see):\n" & pageWords(b.get(Cached()).brief),
                        0, limit)
           elif n != 0: "There is no brief for it yet."
           else: "They are on the index page, not an item."

proc refused*(denials: JsonNode): seq[string] =
  ## What the permission profile refused during one answer (the run's
  ## permission_denials), one line each, for the chat.
  result = @[]
  for d in items(denials):
    var tool = "?"
    var command, file, to = ""
    for k, v in pairs(d):
      if k == "tool_name": tool = v.getStr
      elif k == "tool_input":
        for f, x in pairs(v):
          case f
          of "command": command = x.getStr
          of "file_path": file = x.getStr
          of "to": to = x.getStr
          else: discard
    let what = if command.len > 0: command elif file.len > 0: file else: to
    let line = runeSubStr(strutils.strip(tool & ": " & what, chars = {':', ' '}), 0, 300)
    if line notin result: result.add line

# ----------------------------------------------------------------- companion

type
  Server* = ref object
    ## One server run, shared by every connection: what it serves, its token,
    ## the companion's conversation and when the pages were last built.
    sid, spath, dest: string
    cfg: Opt[Config]
    model: string          # the companion's model; "" for claude's default
    token: string          # the per-run token every POST must carry
    port: int              # the port asked for; the bound one once `run` listens
    tags: HttpTags
    cwd: string            # the companion's working directory
    extra: seq[string]     # its `claude` arguments (companion.setup)
    fork: string           # the companion's fork; "" before the first question
    asking: Lock           # one question at a time, in order
    builtAt: MonoTime      # when the pages were last built
    building: Lock

proc askNow(s: Server; prompt: string; timeout: int): Result[(string, seq[string]), string] =
  ## One question to the companion while s.asking is held: its answer and
  ## what was refused during it.
  var resume = @["--resume", s.fork]
  if s.fork.len == 0:
    let id = try: newCompanionId() except: ""
    if id.len == 0:
      return err[(string, seq[string]), string]("cannot record the companion's session id")
    resume = @["--resume", s.sid, "--fork-session", "--session-id", id]
  var cmd = @["claude", "-p"]
  for a in resume: cmd.add a
  let extra = s.extra   # a copy: a location reached through a ref cannot be iterated
  for a in extra: cmd.add a
  for a in ["--output-format", "json"]: cmd.add a
  if s.model.len > 0:
    for a in ["--model", s.model]: cmd.add a
  let res = run(cmd, timeout, input = prompt, cwd = s.cwd)
  if res.isErr: return err[(string, seq[string]), string](res.error(""))
  let ran = res.get(Completed())
  if ran.code != 0:
    let why = unicode.strip(ran.errors)
    let n = runeLen(why)
    return err[(string, seq[string]), string](
      if n > 0: runeSubStr(why, max(n - 400, 0)) else: "claude exited " & $ran.code)
  # GAP: why the output is not JSON is said in std/json's words, not
  # Python's, because that is the message std/json gives.
  var answer = parseJson(ran.output)
  if answer.hasError: return err[(string, seq[string]), string](answer.errorMsg)
  let forked = answer{"session_id"}.getStr
  if forked.len > 0: s.fork = forked
  result = ok[(string, seq[string]), string]((answer{"result"}.getStr,
                                              refused(answer{"permission_denials"})))

proc ask(s: Server; prompt: string; timeout = 900): Result[(string, seq[string]), string] =
  ## The companion's answer to one question, and what the permission profile
  ## refused while it answered. The first question forks the session; later
  ## ones resume the fork. One question at a time, in order. The error says
  ## why there is no answer.
  acquire(s.asking)
  result = askNow(s, prompt, timeout)
  release(s.asking)

# --------------------------------------------------------------------- pages

proc rebuild(s: Server; force = false): Result[bool, string] =
  ## Builds the pages again unless that was done in the last RebuildAfter
  ## seconds (or force); true when they were built now. The error says why
  ## they cannot be built.
  acquire(s.building)
  result = ok[bool, string](false)
  if force or getMonoTime() - s.builtAt > initDuration(seconds = RebuildAfter):
    let built = build(s.spath, s.dest, s.cfg)
    if built.isErr:
      result = err[bool, string](built.error(""))
    else:
      s.builtAt = getMonoTime()
      result = ok[bool, string](true)
  release(s.building)

proc newToken(): Opt[string] =
  ## A per-run token: 24 random bytes, URL-safe base64 (Python's
  ## secrets.token_urlsafe(24)); none when there is no randomness.
  var bytes = default(array[24, byte])
  result = if urandom(bytes): some(encode(bytes, safe = true)) else: none[string]()

proc server*(sid, spath, dest: string; port = 8765; model = "";
             cfg = none[Config]()): Result[Server, string] =
  ## The server for session sid (transcript spath), serving the pages built
  ## into dest, not yet listening: its token made, the companion set up and
  ## the pages built. model: the companion's ("" for claude's default); cfg
  ## none: the config in the session's working directory. The error says why
  ## the companion cannot be set up or the pages cannot be built.
  let token = newToken()
  if token.isNone: return err[Server, string]("cannot make a token")
  # the companion is set up here, so a session without a working directory
  # stops the server now, not a question later
  let setup = companion.setup(sid, spath, cfg)
  if setup.isErr: return err[Server, string](setup.error(""))
  let (cwd, extra) = setup.get(("", newSeq[string]()))
  let s = Server(sid: sid, spath: spath, dest: dest, cfg: cfg, model: model,
                 token: token.get(""), port: port, tags: newHttpTags(), cwd: cwd, extra: extra,
                 fork: "", builtAt: getMonoTime())
  initLock(s.asking)
  initLock(s.building)
  let built = rebuild(s, force = true)
  if built.isErr: return err[Server, string](built.error(""))
  result = ok[Server, string](s)

# ------------------------------------------------------------------ requests

type Reply = object
  ## A response before it is sent.
  status: int
  body: string
  kind: string     # its Content-Type; "" for none
  noStore: bool    # Cache-Control: no-store

proc bare(status: int): Reply =
  ## A response with no body.
  # GAP: a refusal or a missing file (421, 403, 404, 501) has no body, where
  # Python's http.server sends an HTML error page, because std/httpserver has
  # no error pages.
  Reply(status: status, body: "", kind: "", noStore: false)

proc json(status: int; body: string): Reply =
  ## A JSON response (body is JSON text), never cached.
  Reply(status: status, body: body, kind: "application/json", noStore: true)

proc failed(why: string): Reply =
  ## A 500 that tells the page what went wrong instead of hanging it.
  json(500, "{\"error\": " & quote(runeSubStr(why, 0, 400)) & "}")

proc refusal(s: Server; c: HttpConnection): Opt[Reply] =
  ## Why the request is refused before it is looked at; none when it may go on.
  let ours = ["127.0.0.1:" & $s.port, "localhost:" & $s.port]
  let origin = c.requestHeader("Origin")
  result = none[Reply]()
  if c.meth != tag(mGet) and c.meth != tag(mHead) and c.meth != tag(mPost):
    result = some(bare(501))
  elif c.requestHeader("Host") notin ours:
    # a DNS-rebinding page reaches us under its own name: refuse every other
    # Host, on every method, HEAD included (headers say what exists)
    result = some(bare(421))
  elif c.meth == tag(mPost) and (c.path notin Actions or
      c.requestHeader("X-HITL-Token") != s.token or
      origin notin ["", "http://" & ours[0], "http://" & ours[1]]):
    result = some(bare(403))

proc file(s: Server; path: string): Reply =
  ## A built file (a page, hitl.css, hitl.js, tips.json) with its content type.
  # GAP: no Last-Modified and never a 304, as Python's SimpleHTTPRequestHandler
  # sends, and a path that climbs above the pages (`/../x`) is a 400 before
  # it gets here, not a 404, because std/httpserver has no file handler and
  # refuses such a target itself.
  let name = if path.endsWith("/"): path & "index.html" else: path
  result = bare(404)
  if fileExists(s.dest & name):
    var kind = "application/octet-stream"
    for (ext, k) in ContentTypes:
      if name.endsWith(ext): kind = k
    try:
      result = Reply(status: 200, body: readFile(s.dest & name), kind: kind, noStore: false)
    except:
      discard   # gone since: not found

proc page(s: Server; c: HttpConnection): Result[Reply, string] =
  ## A GET or HEAD: /config.js with the token, else a built file; the index
  ## is rebuilt first when it is older than RebuildAfter seconds. The error
  ## says why it cannot be rebuilt.
  let isGet = c.meth == tag(mGet)
  if isGet and c.path in ["/", "/index.html"]:
    let built = rebuild(s)
    if built.isErr: return err[Reply, string](built.error(""))
  if isGet and c.target == "/config.js":
    # only the pages' own <script> may read the token; another site's
    # <script src> passes the Host check, but its browser says cross-site
    # (no header at all: an old browser, or curl)
    let site = c.requestHeader("Sec-Fetch-Site")
    let js = "window.HITL={token:" & quote(s.token) & "};"
    result = if c.countRequestHeader("Sec-Fetch-Site") > 0 and site notin ["same-origin", "none"]:
               ok[Reply, string](bare(403))
             else:
               ok[Reply, string](Reply(status: 200, body: js, kind: "text/javascript",
                                       noStore: true))
  else:
    result = ok[Reply, string](file(s, c.path))

proc number(n: JsonNode): Opt[int] =
  ## An item number sent as a number or as its digits (Python's int()); none
  ## for anything else.
  result = case n.kind
           of JInt: some(int(n.getInt))
           of JString: (try: some(parseInt(strutils.strip(n.getStr))) except: none[int]())
           else: none[int]()

proc draftJson(st: DraftState): string =
  ## A draft's state as the page reads it.
  "{\"id\": " & quote(st.id) & ", \"decision\": " & quote(st.decision) & ", \"item\": " &
    $st.item & ", \"question\": " & quote(st.question) & ", \"option\": " & quote(st.option) &
    ", \"text\": " & quote(st.text) & ", \"delivered\": " &
    (if st.delivered.isSome: quote(st.delivered.get("")) else: "null") & ", \"stale\": " &
    quote(st.stale) & "}"

proc act(s: Server; path, body: string): Reply =
  ## One of the five POST actions: JSON in, JSON out; a failure is a 500 that
  ## says what went wrong.
  # GAP (every reply): non-ASCII text is written as it is, not \u-escaped as
  # Python's json.dumps does, and control characters other than \b \f \n \r
  # \t raw, because std/json has no ASCII mode and its `$` does not escape
  # them (bug-reports/104-json-dollar-control-chars-unescaped).
  # GAP: why a body is not JSON is said in std/json's words, not Python's.
  var q = parseJson(if body.len > 0: body else: "{}")
  if q.hasError: return failed(q.errorMsg)
  case path
  of "/drafts":
    # code tips as the last build found them; /send checks live
    let all = draftsState(s.sid, s.spath, builtTips(s.dest))
    if all.isErr: return failed(all.error(""))
    var list: seq[string] = @[]
    for st in all.get(@[]): list.add draftJson(st)
    result = json(200, "{\"drafts\": [" & list.join(", ") & "]}")
  of "/decide":
    let item = number(q{"item"})
    if item.isNone: return failed("the item is not a number")
    for k in ["did", "question", "option"]:
      if q{k}.kind != JString: return failed("no " & k)
    let dr = decide(s.sid, s.spath, item.get(0), q{"did"}.getStr, q{"question"}.getStr,
                    q{"option"}.getStr, code = q{"ref"}.getStr, brief = q{"brief"}.getStr)
    if dr.isErr: return failed(dr.error(""))
    result = json(200, "{\"id\": " & quote(dr.get(Draft()).id) & ", \"text\": " &
                       quote(dr.get(Draft()).text) & "}")
  of "/withdraw":
    let w = withdraw(s.sid, q{"id"}.getStr)
    if w.isErr: return failed(w.error(""))
    result = json(200, "{\"ok\": true}")
  of "/send":
    # the one re-check; every answer carries the draft's state
    let checked = check(s.sid, s.spath, q{"id"}.getStr)
    if checked.isErr: return failed(checked.error(""))
    let v = checked.get(Verdict())
    let st = if v.draft.isSome: draftJson(v.draft.get(DraftState())) else: "null"
    result = if v.why.isNone:
               json(200, "{\"draft\": " & st & ", \"text\": " &
                         quote(v.draft.get(DraftState()).text) & "}")
             else:
               json(if v.draft.isSome: 409 else: 404,
                    "{\"draft\": " & st & ", \"error\": " & quote(v.why.get("")) & "}")
  else:
    # /ask; no item (the index page) is 0
    let it = q{"item"}
    let n = if it.kind == JNull or (it.kind == JString and it.getStr == ""): some(0)
            else: number(it)
    if n.isNone: return failed("the item is not a number")
    let selected = unicode.strip(q{"quote"}.getStr)
    let question = q{"question"}.getStr
    # one pass, as str.format: a value that holds a {name} is not filled in again
    let prompt = Ask.multiReplace([("{n}", if n.get(0) != 0: $n.get(0) else: "?"),
      ("{title}", q{"title"}.getStr), ("{brief}", briefText(s.sid, n.get(0))),
      ("{quote}", if selected.len > 0: "They selected this text on the page:\n> " & selected & "\n"
                  else: ""),
      ("{question}", unicode.strip(if question.len > 0: question else: "What does this mean?"))])
    let answer = ask(s, prompt)
    if answer.isErr: return failed(answer.error(""))
    let (text, denied) = answer.get(("", newSeq[string]()))
    result = json(200, "{\"html\": " & quote($markdown(text)) & ", \"refused\": " &
                       quote(denied) & "}")

# ------------------------------------------------------------------- serving

proc reply(c: var HttpConnection; r: Reply; tags: HttpTags) {.passive, raises.} =
  ## Sends r. Raises the ErrorCode of a failed write.
  var m = initHttpMsg(tags)
  c.prepare(m, r.status)
  if r.kind.len > 0: m.addHeader(hContentType, r.kind)
  if r.noStore: m.addHeader(hCacheControl, "no-store")
  c.respond(m, r.body)

proc handle(c: sink HttpConnection; s: Server) {.passive.} =
  ## Every request on one connection, in order.
  # GAP: a client that goes away before its answer is written stops the whole
  # server (SIGPIPE), because std/httpserver does not ignore or suppress the
  # signal (bug-reports/114-httpserver-sigpipe-kills-process-on-gone-peer).
  while c.next():
    try:
      let refuse = refusal(s, c)
      if refuse.isSome:
        reply(c, refuse.get(bare(500)), s.tags)
      elif c.meth == tag(mPost):
        # any length, as Python reads Content-Length bytes: only the
        # pages' own script, holding the token, gets this far
        reply(c, act(s, c.path, c.readBody(limit = high(int))), s.tags)
      else:
        let r = page(s, c)
        if r.isOk:
          reply(c, r.get(bare(500)), s.tags)
        else:
          # as an exception in Python's handler: no answer, the reason on stderr
          stderr.writeLine "hitl: " & r.error("")
          c.close()
    except ErrorCode:
      c.close()   # the client went away

proc acceptLoop(listener: sink HttpServer; s: Server) {.passive.} =
  ## Gives each connection a chain of its own, so a slow answer holds up no other.
  while true:
    let c = listener.accept()
    if c.isClosed: break
    submit(delay(handle(c, s)), -1)

proc openBrowser(url: string) =
  ## Opens url in the browser: $BROWSER, else xdg-open. No browser: nothing
  ## happens; the address is printed.
  # GAP: $BROWSER is one command given the url, else xdg-open; Python's
  # webbrowser also reads a list of commands in $BROWSER, fills in %s and
  # knows the desktop's browsers, because Nimony's standard library has no
  # browser module.
  try:
    let p = startProcess(getEnv("BROWSER", "xdg-open"), args = [url],
                         options = {poUsePath, poParentStreams})
    discard p.waitForExit()
    p.close()
  except:
    discard

proc run*(s: Server) =
  ## Serves the pages until the process is stopped: listens on s.port (0: a
  ## port the system picks, written back to s.port), prints the address and
  ## opens it in the browser.
  initIoRing()
  # GAP: listens on every interface, not on 127.0.0.1 only (the Host check
  # and the token still hold), because std/httpserver's listenHttp takes no
  # address (bug-reports/113-listenhttp-cannot-choose-listen-address).
  # GAP: a port in use stops hitl with a failed assertion, not a message,
  # because std/ioring's listenTcp asserts that bind succeeds
  # (bug-reports/109-listentcp-asserts-on-busy-port).
  var listener = listenHttp(uint16(s.port), s.tags)
  s.port = int(boundPort(listener.fd))   # the Host check needs the real one when port was 0
  let url = "http://127.0.0.1:" & $s.port & "/"
  echo "serving " & url & "  (Ctrl+C to stop)"
  flushFile(stdout)   # whoever waits for the address gets it now
  openBrowser(url)
  submit(delay(acceptLoop(listener, s)), 0)
  while true: sleep(1000)   # the pool's threads serve the connections
