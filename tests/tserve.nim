## The server, and the companion's refusals reported once each.
## `paredros serve --port=0` runs on the coordinator fixture, on a port the
## system picks; curl is the browser, and the fake `claude` is the companion.

import std/[syncio, strutils, os, paths, osproc, streams, envvars, assertions, json, opt, result]
import fixtures
import ../paredros/[state, session, brief, serve]

setUp()
resetState()

# the companion's every answer: "ok", in a fork, with two refusals of the same call
let log = fake(raw = """{"result": "ok", "session_id": "fork-1", "permission_denials": [""" &
  """{"tool_name": "Bash", "tool_input": {"command": "rm x"}}, """ &
  """{"tool_name": "Bash", "tool_input": {"command": "rm x"}}]}""")

proc start(): (Process, string) =
  ## `paredros serve --port=0` on the coordinator fixture: the server and the
  ## line it printed first.
  try:
    let bin = $paths.getCurrentDir() & "/bin/paredros"
    let p = startProcess(bin, args = ["--session=" & Sid.substr(0, 7), "serve", "--port=0"],
                         options = {poStdErrToStdOut})
    result = (p, p.outputStream.readLine())
  except:
    quit "cannot start the server"

let (server, first) = start()
let port = first.substr(len("serving http://127.0.0.1:")).split('/')[0]

type Reply = object
  status: int
  body: string
  json: bool   # its Content-Type is application/json

proc request(meth, path: string; body = ""; host = ""; headers: openArray[string] = [];
             token = ""): Reply =
  ## The request as curl makes it; host "": the server's own address.
  var argv = @["curl", "-s", "--max-time", "20", "-H",
               "Host: " & (if host.len > 0: host else: "127.0.0.1:" & port),
               "-w", "\n%{http_code} %{content_type}"]
  # curl waits for a body that never comes after a HEAD unless told it is one
  if meth == "HEAD":
    argv.add "-I"
  else:
    argv.add "-X"
    argv.add meth
  if token.len > 0:
    argv.add "-H"
    argv.add "X-PAREDROS-Token: " & token
  for h in headers:
    argv.add "-H"
    argv.add h
  if body.len > 0:
    argv.add "--data-binary"
    argv.add body
  argv.add "http://127.0.0.1:" & port & path
  let ran = run(argv, 60).get(Completed(code: -1, output: "", errors: ""))
  let at = ran.output.rfind('\n')
  let tail = ran.output.substr(at + 1).split(' ')
  result = Reply(status: (try: parseInt(tail[0]) except: -1), body: ran.output.substr(0, at - 1),
                 json: tail.len > 1 and tail[1] == "application/json")

proc tokenOf(js: string): string =
  ## The token in /config.js.
  js.split('"')[1]

let runToken = tokenOf(request("GET", "/config.js").body)

proc post(path, body: string): Reply =
  ## A POST from the pages: with the token.
  request("POST", path, body, token = runToken)

proc idOf(body: string): string =
  ## The "id" of a JSON reply.
  var t = parseJson(body)
  result = t{"id"}.getStr

block run_prints_the_bound_port:
  assert first.startsWith("serving http://127.0.0.1:") and first.endsWith("/  (Ctrl+C to stop)"),
    "the address: " & first
  assert port.len > 0 and port != "0", "the bound port, not 0"
  assert request("GET", "/").status == 200, "served there"

block other_hosts_are_refused:
  assert request("GET", "/config.js").status == 200
  assert request("GET", "/config.js", host = "localhost:" & port).status == 200
  assert request("GET", "/config.js", host = "evil.example:" & port).status == 421
  assert request("GET", "/index.html", host = "evil.example").status == 421
  assert request("POST", "/drafts", "{}", host = "evil.example:" & port,
                 token = runToken).status == 421
  assert request("HEAD", "/index.html", host = "evil.example:" & port).status == 421
  assert request("HEAD", "/index.html").status == 200

block another_site_cannot_read_the_token:
  proc get(site: openArray[string]): (int, bool) =
    ## /config.js with these headers: the status, and whether the token came.
    let r = request("GET", "/config.js", headers = site)
    result = (r.status, runToken in r.body)
  assert get(["Sec-Fetch-Site: cross-site"]) == (403, false), "<script src> elsewhere"
  assert get(["Sec-Fetch-Site: same-site"]) == (403, false)
  assert get(["Sec-Fetch-Site: same-origin"]) == (200, true), "the pages themselves"
  assert get([]) == (200, true), "no header: an old browser, curl"

block posts_need_the_token_and_our_origin:
  assert runToken.len == 32, "a token per run, as token_urlsafe(24)"
  assert request("POST", "/drafts", "{}").status == 403, "no token"
  assert request("POST", "/drafts", "{}", token = "x" & runToken).status == 403, "a wrong token"
  assert request("POST", "/drafts", "{}", headers = ["Origin: http://evil.example"],
                 token = runToken).status == 403, "another site's page"
  let ours = request("POST", "/drafts", "{}", headers = ["Origin: http://127.0.0.1:" & port],
                     token = runToken)
  assert ours.status == 200 and ours.json and ours.body == "{\"drafts\": []}", "our page"
  assert post("/build", "{}").status == 403, "only the five actions"

block the_built_pages:
  let index = request("GET", "/")
  assert index.status == 200 and "Work items" in index.body, "the index"
  assert request("GET", "/paredros.js").body == readText("static/paredros.js"), "the script"
  assert request("GET", "/tips.json").json, "the code tips, as JSON"
  assert request("GET", "/i99.html").status == 404, "no such page"

block copy_makes_the_same_checks_as_send:
  let spath = spathOf(Sid)
  let before = readText(spath)
  let q = "Allow a call as a field default?"
  let did = decisionId(q)
  try:
    writeJson(cachePath(Sid, 7), """{"inputs": "h2", "brief": {"summary": "s"}}""")
  except:
    quit "cannot write the brief"
  # the page showed brief h1; it was rewritten before Save: the saved decision is out of date
  let decide = "{\"item\": 7, \"did\": " & quote(did) & ", \"question\": " & quote(q) &
               ", \"option\": \"Yes\", \"brief\": "
  var r = post("/decide", decide & "\"h1\"}")
  assert r.status == 200, "saved: " & r.body
  let id = idOf(r.body)
  r = post("/send", "{\"id\": " & quote(id) & "}")
  assert r.status == 409, "out of date: " & r.body
  assert "\"stale\": [\"New evidence.\"]" in r.body, "the page repaints from it: " & r.body
  discard post("/decide", decide & "\"h2\"}")
  r = post("/send", "{\"id\": " & quote(id) & "}")
  var sent = parseJson(r.body)
  assert r.status == 200 and sent{"text"}.getStr.splitLines[0] == "#7: " & q, "copied: " & r.body
  writeText(spath, before & user(sent{"text"}.getStr, "2026-11-09T09:00:00Z") & "\n")  # pasted
  r = post("/send", "{\"id\": " & quote(id) & "}")
  assert r.status == 409 and "\"delivered\": \"2026-11-09T09:00" in r.body,
    "already sent: " & r.body
  r = post("/send", "{\"id\": \"d99\"}")
  assert r.status == 404 and r.body == "{\"draft\": null, \"error\": \"no such draft\"}", r.body
  # forged ids are refused, not written or deleted
  assert post("/decide", "{\"item\": 7, \"did\": \"x\\n- code 7 y\", \"question\": " & quote(q) &
              ", \"option\": \"Yes\"}").status == 500, "a forged decision id"
  assert post("/withdraw", "{\"id\": \"../../x\"}").status == 500, "a forged draft id"
  assert post("/withdraw", "{\"id\": " & quote(id) & "}").status == 200, "Undo"
  r = post("/decide", "{\"item\": 7, \"did\": \"other\", \"question\": " & quote(q) &
           ", \"option\": \"No\"}")
  assert idOf(r.body) != id, "Undo never frees a number"
  writeText(spath, before)

block the_question_carries_the_pages_brief:
  try:
    writeJson(cachePath(Sid, 8), """{"inputs": "h", "brief": {""" &
      """"summary": "The parser now accepts `{}`.", """ &
      """"open_decisions": [{"question": "Allow it?", """ &
      """"options": ["Yes", "No"], "recommended": 1, "reason": "Nim 2 rejects it.", """ &
      """"source": "fixer"}]}}""")
  except:
    quit "cannot write the brief"
  var r = post("/ask", """{"item": 8, "title": "t", "question": "why?"}""")
  var answer = parseJson(r.body)
  var refusals: seq[string] = @[]
  for x in items(answer{"refused"}): refusals.add x.getStr
  assert r.status == 200 and refusals == @["Bash: rm x"],
    "the chat shows what was refused, once: " & r.body
  assert answer{"html"}.getStr == "<p>ok</p>", "the answer, as HTML"
  let asked = prompts(log)
  assert "The parser now accepts `{}`." in asked[0], "the page's words, in the question itself"
  assert "Who you write for" in asked[0]
  assert "Suggested: No (Nim 2 rejects it.)" in asked[0], "the option the page marks"
  assert "work item #8 (\"t\")" in asked[0] and "Their question: why?" in asked[0]
  let argv = argvOf(log, 0)
  assert "--fork-session" in argv and argv[argv.find("--resume") + 1] == Sid, "the session, forked"
  assert "--restricted" in argv and "--strict-mcp-config" in argv, "the companion's profile"
  r = post("/ask", """{"item": 9, "title": "t", "question": "why?"}""")
  assert r.status == 200
  assert "no brief for it yet" in prompts(log)[1]
  let again = argvOf(log, 1)
  assert again[again.find("--resume") + 1] == "fork-1" and "--fork-session" notin again,
    "later questions continue the fork"
  r = post("/ask", """{"item": "", "quote": " the default ", "question": ""}""")
  assert "work item #? (\"\")" in prompts(log)[2] and "on the index page" in prompts(log)[2]
  assert "They selected this text on the page:\n> the default\n" in prompts(log)[2]
  assert "Their question: What does this mean?" in prompts(log)[2]

block refusals_are_reported_once_each:
  var t = parseJson("""[{"tool_name": "Bash", "tool_input": {"command": "git diff --output=x"}},
    {"tool_name": "Bash", "tool_input": {"command": "git diff --output=x"}},
    {"tool_name": "Edit", "tool_input": {"file_path": "/r/a.nim"}}]""")
  assert refused(t.root) == @["Bash: git diff --output=x", "Edit: /r/a.nim"]

try:
  server.terminate()
  discard server.waitForExit()
  server.close()
except:
  discard
tearDown()
