## test_hitl.py SecurityTests. The companion's profile test follows with the companion.

import std/[strutils, result]
import fixtures
import ../hitl/[core, store, briefs]

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

tearDown()
