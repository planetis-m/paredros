## test_hitl.py SecurityTests.

import std/[syncio, strutils, result]
import kroki
import fixtures
import ../hitl/[core, store, briefs, companion]

setUp()

block test_model_runs_have_only_the_read_tools_and_answer_in_the_schema:  # test_hitl.py::SecurityTests::test_model_runs_have_only_the_read_tools_and_answer_in_the_schema
  fakeModel("""{"raw": "{\"result\": \"prose\", \"structured_output\": {\"summary\": \"s\", \"bug_risks\": [{\"text\": \"t\", \"source\": \"x\"}]}}"}""")
  let got = briefAnswer(run(modelJob("p", tmp(), "opus", BriefSchema)))
  check got.isOk, "a structured answer is read"
  let b = got.get(Brief())
  check b.bug_risks.len == 1 and b.bug_risks[0].text == "t" and b.bug_risks[0].source == "x", "its entries"
  let argv = callArgv(0)
  let tools = argv.find("--tools")
  check tools >= 0 and argv[tools + 1] == "Read,Grep,Glob", "only the read tools"
  check "--strict-mcp-config" in argv, "no MCP servers"
  let schema = argv.find("--json-schema")
  check schema >= 0 and argv[schema + 1] == BriefSchema, "the brief's schema"
  fakeModel("""{"raw": "{\"result\": \"{\\\"summary\\\": \\\"s\\\"}\"}"}""")   # no structured answer: refused
  check briefAnswer(run(modelJob("p", tmp(), "opus", BriefSchema))).isErr, "refused"

type Perms = object
  allow, deny: seq[string]
type Profile = object
  permissions: Perms

block test_companion_may_run_only_reading_git:  # test_hitl.py::SecurityTests::test_companion_may_run_only_reading_git_and_hitl
  let (_, args) = companionSetup(SessionId(Sid), spathOf(Sid), "")
  let f = args[args.find("--settings") + 1]
  let perms = fromJson((try: readFile(f) except: ""), Profile).get(Profile()).permissions
  proc bashRules(rules: seq[string]): seq[string] =
    result = @[]
    for r in rules:
      if r.startsWith("Bash("): result.add r.substr(5, r.len - 4)
  let allow = bashRules(perms.allow)
  let deny = bashRules(perms.deny)
  let me = hitlPath()
  let s = " --session=" & Sid.substr(0, 7)
  var writes: seq[string] = @[]
  for f in ["", " --no-optional-locks"]:
    for w in GitWrites: writes.add "git" & f & " " & w & " x"
  for w in ["git -C /r commit -m x", "git --no-optional-locks -C /r push", "gh pr merge 3"]: writes.add w
  for f in ["", s]:
    for c in ["brief --force", "serve"]:
      writes.add me & f & " " & c
  proc matches(rules: seq[string]; cmd: string): bool =
    for r in rules:
      if cmd.startsWith(r): return true
    false
  for w in writes:
    check not matches(allow, w), "not allowed: " & w
    check matches(deny, w), "denied: " & w
  for r in ["git --no-optional-locks log -3", "git --no-optional-locks diff a b",
            "git --no-optional-locks reflog show HEAD"]:
    check matches(allow, r), "allowed: " & r
    check not matches(deny, r), "not denied: " & r
  check "Bash(git --no-optional-locks:*)" notin perms.allow, "no blanket git"

tearDown()
