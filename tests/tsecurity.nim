## What the model runs and the companion may do (test_hitl.py SecurityTests).

import std/[strutils, os, assertions]
import kroki
import fixtures
import ../hitl/[core, items, briefs, companion]

setUp()

block model_runs_have_only_the_read_tools_and_answer_in_the_schema:  # SecurityTests.test_model_runs_have_only_the_read_tools_and_answer_in_the_schema
  fakeModel("""{"raw": "{\"result\": \"prose\", \"structured_output\": {\"summary\": \"s\", \"bug_risks\": [{\"text\": \"t\", \"source\": \"x\"}]}}"}""")
  let got = answer[Brief](run(modelJob("p", tmp(), "opus", BriefSchema)))
  assert got.isOk, "a structured answer is read"
  let risks = got.get(Brief()).entries[secBugRisks]
  assert risks.len == 1 and risks[0].text == "t" and risks[0].source == "x", "its entries"
  let argv = callArgv(0)
  let tools = argv.find("--tools")
  assert tools >= 0 and argv[tools + 1] == "Read,Grep,Glob", "only the read tools"
  assert "--strict-mcp-config" in argv, "no MCP servers"
  let schema = argv.find("--json-schema")
  assert schema >= 0 and argv[schema + 1] == BriefSchema, "the brief's schema"
  fakeModel("""{"raw": "{\"result\": \"{\\\"summary\\\": \\\"s\\\"}\"}"}""")   # no structured answer: refused
  assert answer[Brief](run(modelJob("p", tmp(), "opus", BriefSchema))).isErr, "refused"

type
  Permissions = object
    allow, deny: seq[string]
  Settings = object
    permissions: Permissions

proc bashRules(rules: seq[string]): seq[string] =
  result = @[]
  for r in rules:
    if r.startsWith("Bash("): result.add r.substr(5, r.len - 4)

proc matches(rules: seq[string]; command: string): bool =
  result = false
  for r in rules:
    if command.startsWith(r): return true

block companion_may_run_only_reading_git:  # SecurityTests.test_companion_may_run_only_reading_git_and_hitl
  var args: seq[string] = @[]
  try: args = companionArgs(deskOf(Sid))
  except: quit "no companion arguments"
  let perms = fromJson(readOr(args[args.find("--settings") + 1]), Settings).get(Settings()).permissions
  let allow = bashRules(perms.allow)
  let deny = bashRules(perms.deny)
  var writes: seq[string] = @[]
  for flag in ["", " --no-optional-locks"]:
    for w in GitWrites: writes.add "git" & flag & " " & w & " x"
  for w in ["git -C /r commit -m x", "git --no-optional-locks -C /r push", "gh pr merge 3"]: writes.add w
  for session in ["", " --session=" & Sid.substr(0, 7)]:
    for c in ["brief --force", "serve"]: writes.add getAppFilename() & session & " " & c
  for w in writes:
    assert not matches(allow, w), "not allowed: " & w
    assert matches(deny, w), "denied: " & w
  for r in ["git --no-optional-locks log -3", "git --no-optional-locks diff a b",
            "git --no-optional-locks reflog show HEAD"]:
    assert matches(allow, r), "allowed: " & r
    assert not matches(deny, r), "not denied: " & r
  assert "Bash(git --no-optional-locks:*)" notin perms.allow, "no blanket git"

tearDown()
