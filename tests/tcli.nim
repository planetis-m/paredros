## The command line (test_hitl.py): ConfigTests.test_the_script_passes_its_config_on,
## run with the fake `claude`; an error result ends hitl with its message and
## exit status 1; no command prints the help.

import std/[syncio, strutils, os, paths, envvars, assertions, opt, result]
import fixtures
import ../hitl/session

setUp()

proc hitl(args: openArray[string]): Completed =
  ## bin/hitl run with args, as a user runs it.
  var argv = @[(try: $paths.getCurrentDir() except: ".") & "/bin/hitl"]
  for a in args: argv.add a
  let ran = run(argv, 120)
  if ran.isErr: quit ran.error("")
  result = ran.get(Completed())

block the_script_passes_its_config_on:  # ConfigTests.test_the_script_passes_its_config_on
  # run as a program, hitl must hand --config to the modules that use it
  try: putEnv("XDG_STATE_HOME", tmp() & "/script-state") except: quit "cannot set the environment"
  let log = fake([("T", @["C1", "C2", "T1", "T2"])])
  let r = hitl(["--session=" & Solo.substr(0, 7), "--config=" & example(), "brief"])
  assert r.code == 0, r.output & r.errors
  var told = false
  for p in prompts(log):
    if "people writing Nimony code" in p: told = true
  assert told, "the config's users in the prompt"
  assert r.output == "#1: new item: T\n#1: written\n", "what it did: " & r.output
  assert dirExists(tmp() & "/script-state/hitl/briefs/" & Solo.substr(0, 7)),
    "the state it was given"
  try: putEnv("XDG_STATE_HOME", tmp() & "/state") except: quit "cannot set the environment"

block errors_end_hitl_with_their_message:
  var r = hitl(["--session=nomatch", "brief"])
  assert r.code == 1 and r.errors == "hitl: no session matches 'nomatch'\n", r.errors
  r = hitl(["--session=" & Sid.substr(0, 7), "--config=" & tmp() & "/missing.json", "serve"])
  assert r.code == 1 and r.errors == "hitl: no config file " & tmp() & "/missing.json\n", r.errors
  writeText(tmp() & "/bad.json", "{\"spek\": \"x\"}")
  r = hitl(["--session=" & Sid.substr(0, 7), "--config=" & tmp() & "/bad.json", "brief"])
  assert r.code == 1 and r.errors.startsWith("hitl: unknown key 'spek'"), r.errors
  r = hitl(["--session=" & Sid.substr(0, 7), "brief", "x"])
  assert r.code == 1 and r.errors == "hitl: invalid value for N: x\n", r.errors
  # the companion is set up when the server starts: a session without a
  # working directory stops it there
  writeJsonl(tmp() & "/claude/projects/-nowhere/88888888-0000-0000-0000-000000000000.jsonl",
             [user("hello", "2026-11-09T08:00:00Z")])
  r = hitl(["--session=88888888", "serve", "--port=0"])
  assert r.code == 1 and r.errors == "hitl: cannot find the session's working directory\n",
    r.errors

block no_command_prints_the_help:
  let r = hitl(["--session=" & Sid.substr(0, 7)])
  assert "Usage: hitl [options] brief [N...] | serve" in r.output, r.output
  assert "--port=PORT" in r.output and "--jobs=JOBS" in r.output, "every option"
  # exit status 1 after "[Error] missing arguments", where Python exits 0
  # (the GAP in hitl.nim)
  assert r.code == 1

tearDown()
