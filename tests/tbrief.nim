## The briefs and the ledger: an unreadable ledger, the model runs' tools and
## schema, the prompt from the config, and parsing a brief.

import std/[strutils, assertions, json, opt, result, tables]
import fixtures
import ../paredros/[config, brief]

setUp()

block an_unreadable_ledger_stops_brief_and_is_kept:
  let sid = "77777777-0000-0000-0000-000000000000"
  let p = ledgerPath(sid)
  let none = loadLedger(sid)
  assert none.isOk and none.get(Ledger(items: @[LedgerItem()])).items.len == 0 and
    none.get(Ledger()).seen.len == 0, "none yet: empty"
  for text in ["""{"items": [{"id": 1""", "[]", """{"items": {}}"""]:
    writeText(p, text)
    let led = loadLedger(sid)
    assert led.isErr and p in led.error("") and "left as it is" in led.error(""), "refused: " & text
    assert readText(p) == text, "left as it is"

block model_runs_have_only_the_read_tools_and_answer_in_the_schema:
  var log = fake(raw = """{"result": "prose", "structured_output": {"summary": "s", """ &
                       """"bug_risks": [{"text": "t", "source": "x"}]}}""")
  let got = askModel("p", tmp(), "opus", BriefSchema)
  assert got.isOk, got.error("")
  let risks = parse(got.get(default(JsonNode))).lists[BugRisks]
  assert risks.len == 1 and risks[0].text == "t" and risks[0].source == "x", "the answer"
  let argv = argvOf(log, 0)
  assert argv[argv.find("--tools") + 1] == "Read,Grep,Glob", "only the read tools"
  assert "--strict-mcp-config" in argv, "no MCP servers"
  assert argv[argv.find("--json-schema") + 1] == BriefSchema, "the schema"
  var schema = parseJson(BriefSchema)
  assert not schema.hasError, "the schema is JSON"
  assert readText(log & "/0/prompt") == "p", "the prompt on stdin"
  log = fake(raw = """{"result": "{\"summary\": \"s\"}"}""")   # no structured answer: refused
  assert askModel("p", tmp(), "opus", BriefSchema).error("") == "the answer is not in the schema"

block the_prompt_follows_the_config:
  # the defaults and the Nimony example: the prompt
  let p = promptFor(config.load(tmp() & "/nowhere").get(Config()), "x")
  assert "There is no spec." in p
  assert "for the project's users" in p
  let q = promptFor(config.load("", example()).get(Config()), "x")
  assert "for people writing Nimony code" in q
  assert "The spec, what the code must agree with, is doc/language.md." in q

block brief_parse_keeps_known_sections:
  var t = parseJson("""{"summary": "s", "bug_risks": [{"text": "t"}], "extra": 1}""")
  let b = parse(t.root)
  assert b.summary == "s" and b.lists[BugRisks].len == 1 and b.lists[BugRisks][0].text == "t"
  assert b.lists[OpenDecisions].len == 0, "a list left out is empty"

block size_counts_tests_apart:
  let d = "diff --git a/src/x.nim b/src/x.nim\n--- a/src/x.nim\n+++ b/src/x.nim\n" &
    "@@ -1,2 +1,2 @@\n-old\n+new\n+more\n" &
    "diff --git a/tests/t.nim b/tests/t.nim\n--- /dev/null\n+++ b/tests/t.nim\n" &
    "@@ -0,0 +1,3 @@\n+a\n+b\n+c\n"
  assert size(d) == "+2 −1, tests +3 −0", size(d)
  assert size(d.substr(0, d.find("diff --git a/tests") - 1)) == "+2 −1", "no test files, no tests part"
  assert size("") == ""

tearDown()
