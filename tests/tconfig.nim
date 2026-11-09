## test_hitl.py ConfigTests. The prompt and page parts of these tests follow in
## tconfig_briefs once briefs and pages are ported.

import std/[os, strutils, opt, result, envvars]
import fixtures
import ../hitl/core

setUp()
let example = (try: os.getCurrentDir() except: ".") & "/examples/nimony.hitl.json"

block test_defaults_without_a_file:  # test_hitl.py::ConfigTests::test_defaults_without_a_file
  let cfg = readConfig(tmp() & "/nowhere", "").get(Config(spec: "x"))
  check cfg.spec == "" and cfg.reader == "a developer of this project" and
    cfg.users == "the project's users" and cfg.compare.isNone, "the defaults"

block test_the_nimony_example:  # test_hitl.py::ConfigTests::test_the_nimony_example
  let cfg = readConfig("", example).get(Config())
  check cfg.spec == "doc/language.md", "spec"
  let c = cfg.compare.get(Compare())
  check c.label == "Compare with Nim", "compare label"
  check expand(c.allow[1], "/s") == getEnv("HOME") & "/Projects/Nim/bin/nim r --nimcache:/s/cache",
    "{home} and {scratch} are expanded"

block test_a_json_file_beside_the_session:  # test_hitl.py::ConfigTests::test_a_json_file_beside_the_session
  let d = tmp() & "/cfgdir"
  writeText(d & "/.hitl.json", """{"users": "people who type", "compare": {"label": "L", "prompt": "P"}}""")
  let cfg = readConfig(d, "").get(Config())
  check cfg.users == "people who type" and cfg.spec == "", "users and spec"
  check cfg.compare.get(Compare()).allow.len == 0, "allow defaults to none"

block test_bad_files_are_refused:  # test_hitl.py::ConfigTests::test_bad_files_are_refused
  let p = tmp() & "/bad.json"
  for text in ["""{"spek": "x"}""", """{"compare": {"label": "x"}}""", """{"spec": """, "[]",
               """{"compare": [1]}""", """{"compare": {"label": "x", "prompt": "y", "run": "z"}}"""]:
    writeText(p, text)
    check readConfig("", p).isErr, "refused: " & text
  check readConfig("", tmp() & "/missing.json").isErr, "a named file must exist"

tearDown()
