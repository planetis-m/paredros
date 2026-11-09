## The project config (test_hitl.py ConfigTests); the test that --config
## reaches the pages is in treview.

import std/[os, strutils, envvars, assertions]
import fixtures
import ../hitl/[core, briefs]

setUp()
let example = (try: os.getCurrentDir() except: ".") & "/examples/nimony.hitl.json"

block defaults_without_a_file:  # ConfigTests.test_defaults_without_a_file
  let cfg = readConfig(tmp() & "/nowhere", none[string]()).get(Config(reader: "x"))
  assert cfg.spec.isNone and cfg.compare.isNone, "no spec, no compare"
  assert cfg.reader == "a developer of this project" and cfg.users == "the project's users", "the defaults"
  assert "There is no spec." in briefPrompt(cfg, "x"), "no spec line"
  assert "for the project's users" in briefPrompt(cfg, "x"), "the default users"

block the_nimony_example:  # ConfigTests.test_the_nimony_example
  let cfg = readConfig("", some(example)).get(Config())
  assert cfg.spec.get("") == "doc/language.md", "spec"
  let c = cfg.compare.get(Compare())
  assert c.label == "Compare with Nim", "compare label"
  let p = briefPrompt(cfg, "x")
  assert "for people writing Nimony code" in p, "the config's users"
  assert "The spec, what the code must agree with, is doc/language.md." in p, "the spec line"
  assert expand(c.allow[1], "/s") == getEnv("HOME") & "/Projects/Nim/bin/nim r --nimcache:/s/cache",
    "{home} and {scratch} are expanded"

block a_json_file_beside_the_session:  # ConfigTests.test_a_json_file_beside_the_session
  let d = tmp() & "/cfgdir"
  writeText(d & "/.hitl.json", """{"users": "people who type", "compare": {"label": "L", "prompt": "P"}}""")
  let cfg = readConfig(d, none[string]()).get(Config())
  assert cfg.users == "people who type" and cfg.spec.isNone, "users and spec"
  assert cfg.reader == "a developer of this project", "a key left out keeps its default"
  assert cfg.compare.get(Compare()).allow.len == 0, "allow defaults to none"

block bad_files_are_refused:  # ConfigTests.test_bad_files_are_refused
  let p = tmp() & "/bad.json"
  for text in ["""{"spek": "x"}""", """{"compare": {"label": "x"}}""", """{"spec": """, "[]",
               """{"compare": [1]}""", """{"compare": {"label": "x", "prompt": "y", "run": "z"}}"""]:
    writeText(p, text)
    assert readConfig("", some(p)).isErr, "refused: " & text
  assert readConfig("", some(tmp() & "/missing.json")).isErr, "a named file must exist"

tearDown()
