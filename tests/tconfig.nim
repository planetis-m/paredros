## The project config. The asserts on the brief's prompt are in tbrief; the
## CLI's are in tcli.

import std/[strutils, envvars, assertions, opt, result]
import fixtures
import ../paredros/config

setUp()

block defaults_without_a_file:
  let cfg = load(tmp() & "/nowhere").get(Config(reader: "x"))
  let d = defaults()
  assert cfg.spec == d.spec and cfg.reader == d.reader and cfg.users == d.users, "the defaults"
  assert cfg.compare.isNone, "no compare"
  assert d.spec == "" and d.reader == "a developer of this project" and
    d.users == "the project's users", "the default values"

block the_nimony_example:
  let cfg = load("", example()).get(Config())
  assert cfg.spec == "doc/language.md", "spec"
  let c = cfg.compare.get(Compare())
  assert c.label == "Compare with Nim", "compare label"
  assert expand(c.allow[1], "/s") == getEnv("HOME") & "/Projects/Nim/bin/nim r --nimcache:/s/cache",
    "{home} and {scratch} are expanded"

block a_json_file_beside_the_session:
  let d = tmp() & "/cfgdir"
  writeText(d & "/.paredros.json",
            """{"users": "people who type", "compare": {"label": "L", "prompt": "P"}}""")
  let cfg = load(d).get(Config())
  assert cfg.users == "people who type" and cfg.spec == "", "users and spec"
  assert cfg.compare.isSome and cfg.compare.get(Compare(allow: @["x"])).allow.len == 0,
    "allow defaults to none"

block bad_files_are_refused:
  let p = tmp() & "/bad.json"
  for text in ["""{"spek": "x"}""", """{"compare": {"label": "x"}}""", """{"spec": """, "[]",
               """{"compare": [1]}""", """{"compare": {"label": "x", "prompt": "y", "run": "z"}}"""]:
    writeText(p, text)
    assert load("", p).isErr, "refused: " & text
  let missing = load("", tmp() & "/missing.json")   # --config names a missing file
  assert missing.isErr and missing.error("").startsWith("no config file"), "a named file must exist"
  writeText(p, """{"spek": "x"}""")
  assert load("", p).error("") == "unknown key 'spek' in " & p, "the message names the key"

tearDown()
