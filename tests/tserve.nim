## The server (test_hitl.py ServerTests, and the chat): `hitl serve` runs on a
## port the kernel picks, curl is the browser.

import std/[strutils, os, osproc, streams, times, monotimes, assertions]
import kroki
import fixtures
import ../hitl/[core, items]

setUp()

proc startServer(): (Process, string) =
  ## hitl serve on the coordinator fixture; the server and its address.
  try:
    let p = startProcess(hitlBin(), args = ["--session=" & Sid.substr(0, 7), "serve", "--port=0"],
                         options = {poStdErrToStdOut})
    let line = p.outputStream.readLine()   # serving http://127.0.0.1:<port>/  (Ctrl+C to stop)
    assert line.startsWith("serving http://127.0.0.1:"), "the address: " & line
    result = (p, "127.0.0.1:" & line.substr(len("serving http://127.0.0.1:")).split('/')[0])
  except: quit "cannot start the server"

let (server, address) = startServer()

type Reply = object
  status: int
  body: string

proc request(meth, path: string; body = ""; host = ""; token = ""; origin = ""): Reply =
  ## The request as curl makes it; host "" is the server's own address.
  # `host = address` is the natural default, but a global as a default value is
  # an undeclared identifier: bug-reports/global-let-as-parameter-default-undeclared.
  let named = if host.len > 0: host else: address
  var argv = @["curl", "-s", "--max-time", "20", "-X", meth, "-H", "Host: " & named, "-w", "\n%{http_code}"]
  if token.len > 0:
    for a in ["-H", "X-HITL-Token: " & token]: argv.add a
  if origin.len > 0:
    for a in ["-H", "Origin: " & origin]: argv.add a
  if body.len > 0:
    for a in ["-H", "Content-Type: application/json", "--data-binary", body]: argv.add a
  argv.add "http://" & address & path
  let r = run(Job(argv: argv, timeoutMs: 30_000))
  let at = r.output.rfind('\n')
  result = Reply(status: (try: parseInt(r.output.substr(at + 1)) except: -1), body: r.output.substr(0, at - 1))

let runToken = request("GET", "/config.js").body.split('"')[1]

proc post(path, body: string): Reply = request("POST", path, body, token = runToken)

block other_hosts_are_refused:  # ServerTests.test_other_hosts_are_refused
  assert request("GET", "/config.js").status == 200, "our host"
  assert request("GET", "/config.js", host = "localhost:" & address.split(':')[1]).status == 200, "localhost"
  assert request("GET", "/config.js", host = "evil.example:" & address.split(':')[1]).status == 421, "another host"
  assert request("GET", "/index.html", host = "evil.example").status == 421, "another host, no port"
  assert request("HEAD", "/index.html", host = "evil.example").status == 421, "HEAD too"
  assert request("POST", "/drafts", "{}", host = "evil.example:" & address.split(':')[1], token = runToken).status == 421,
    "a POST from another host"

block posts_need_the_token_and_our_origin:
  assert runToken.len == 32, "a token per run"
  assert request("POST", "/drafts", "{}").status == 403, "no token"
  assert request("POST", "/drafts", "{}", token = "x" & runToken).status == 403, "a wrong token"
  assert request("POST", "/drafts", "{}", token = runToken, origin = "http://evil.example").status == 403,
    "another site's page"
  assert request("POST", "/drafts", "{}", token = runToken, origin = "http://" & address).status == 200, "our page"
  assert request("POST", "/build", "{}", token = runToken).status == 403, "only the five actions"

block the_built_pages:
  let index = request("GET", "/")
  assert index.status == 200 and "<h1>Work items</h1>" in index.body, "the index"
  assert request("GET", "/hitl.js").body == readOr("static/hitl.js"), "the script"
  assert request("GET", "/tips.json").status == 200, "the code tips"
  assert request("GET", "/i99.html").status == 404, "no such page"
  assert request("GET", "/../../etc/passwd").status in [400, 404], "nothing outside the pages"

block copy_makes_the_same_checks_as_send:  # ServerTests.test_copy_makes_the_same_checks_as_send
  let spath = spathOf(Sid)
  let before = readOr(spath)
  let q = "Allow a call as a field default?"
  let did = $decisionId(q)
  writeText(briefPath(SessionId(Sid), ItemId(7)), """{"inputs": "h2", "brief": {"summary": "s"}}""")
  # the page showed brief h1; it was rewritten before Save: the saved decision is out of date
  let decide = """{"item": "7", "did": """" & did & """", "question": """" & q & """", "option": "Yes", "ref": "", "brief": """
  var r = post("/decide", decide & "\"h1\"}")
  assert r.status == 200, "saved: " & r.body
  let id = r.body.split("\"id\":\"")[1].split('"')[0]
  r = post("/send", "{\"id\": \"" & id & "\"}")
  assert r.status == 409 and "new evidence" in r.body, "out of date: " & r.body
  assert post("/decide", decide & "\"h2\"}").status == 200, "saved again"
  r = post("/send", "{\"id\": \"" & id & "\"}")
  assert r.status == 200 and ("\"text\":\"#7: " & q & "\\nMy decision: Yes.") in r.body, "copied: " & r.body
  writeText(spath, before & user("#7: " & q & "\nMy decision: Yes. (" & id & ", approved by me)",
                                 "2026-11-09T09:00:00Z") & "\n")   # pasted into the session
  assert post("/send", "{\"id\": \"" & id & "\"}").status == 409, "never copied twice"
  assert post("/send", "{\"id\": \"d99\"}").status == 404, "no such draft"
  # forged ids are refused, not written or deleted
  assert post("/decide", "{\"item\": 7, \"did\": \"x\\n- code 7 y\", \"question\": \"q\", \"option\": \"Yes\"}").status == 400,
    "a forged decision id"
  assert post("/withdraw", "{\"id\": \"../../x\"}").status == 400, "a forged draft id"
  assert post("/withdraw", "{\"id\": \"" & id & "\"}").status == 200, "Undo"
  r = post("/decide", "{\"item\": 7, \"did\": \"other\", \"question\": \"Q?\", \"option\": \"No\"}")
  assert r.status == 200 and ("\"id\":\"" & id & "\"") notin r.body, "Undo never frees a number"
  writeText(spath, before)

block the_chat_forks_once_and_keeps_answering:
  fakeModel("""{"sleepMs": 1500}""")
  var ask = Process(nil)
  try: ask = startProcess("curl", args = ["-s", "-X", "POST", "-H", "Host: " & address, "-H", "X-HITL-Token: " & runToken,
    "--data-binary", """{"question": "Why?", "quote": "the default", "item": "1", "title": "#1 T"}""",
    "http://" & address & "/ask"], options = {poUsePath})
  except: quit "no curl"
  sleep(300)
  let t0 = getMonoTime()
  assert request("GET", "/config.js").status == 200, "served while the companion thinks"
  assert inMilliseconds(getMonoTime() - t0) < 800, "without waiting for it"
  assert post("/ask", """{"question": "And?", "item": ""}""").status == 409, "one question at a time"
  let first = try: ask.outputStream.readAll() except: ""
  assert "\"html\":\"<p>ok</p>\"" in first, "the answer, as HTML: " & first
  let prompt = calls()[^1]
  assert "work item #1 (\"#1 T\")" in prompt and "> the default" in prompt and "Their question: Why?" in prompt,
    "the question in context"
  var argv = callArgv(calls().high)
  assert "--fork-session" in argv and "--strict-mcp-config" in argv, "a read-only fork"
  fakeModel("{}")
  assert post("/ask", """{"question": "And?", "item": ""}""").status == 200, "the next question"
  argv = callArgv(0)
  assert argv[argv.find("--resume") + 1] == "fork-0" and "--fork-session" notin argv, "continues the fork"
  assert "(none: the human is on the index)" in calls()[0], "asked from the index"

try:
  server.terminate()
  discard server.waitForExit()
except: discard
tearDown()
