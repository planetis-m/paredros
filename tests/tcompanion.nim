## The companion's setup (test_paredros.py): ReviewTests.test_companion_setup_builds_its_arguments
## and SecurityTests.test_companion_may_run_only_reads. The refusals come with
## serve.

import std/[syncio, strutils, os, paths, envvars, assertions, json, opt, result]
import fixtures
import ../paredros/[state, config, companion]

setUp()

proc after(args: seq[string]; flag: string): string =
  ## The argument after flag.
  args[args.find(flag) + 1]

proc rules(args: seq[string]; kind: string): seq[string] =
  ## The profile's allow or deny rules, from the settings file in args.
  result = @[]
  var t = parseJson(readText(after(args, "--settings")))
  assert not t.hasError, "the settings are JSON"
  for k, perms in pairs(t.root):
    for k2, list in pairs(perms):
      if k2 == kind:
        for r in items(list): result.add r.getStr

proc argsOf(r: Result[(string, seq[string]), string]): (string, seq[string]) =
  ## The working directory and arguments setup returned; a test cannot go on without them.
  if r.isErr: quit r.error("")
  var none: seq[string] = @[]
  result = r.get(("", none))

proc real(p: string): string =
  ## p with its symbolic links resolved.
  try: expandFilename(p) except: p

block companion_setup_builds_its_arguments:
  # ReviewTests.test_companion_setup_builds_its_arguments
  resetState()
  let spath = spathOf(Sid)
  let (cwd, args) = argsOf(setup(Sid, spath))
  assert cwd == tmp() & "/proj/repo", "the session's working directory"
  assert "--strict-mcp-config" in args, "no MCP tools"
  assert "--restricted" in args, "the user's and project's settings ignored"
  assert after(args, "--tools") == CompanionTools
  var dirs: seq[string] = @[]
  for i, a in args:
    if a == "--add-dir": dirs.add real(args[i + 1])
  assert real(parentDir(spath)) in dirs, "the transcripts"
  assert real(tmp() & "/wt/f7/repo") in dirs, "the fixer's worktree"
  let scratch = state("scratch", Sid)
  let allow = rules(args, "allow")
  assert "Edit(/" & scratch & "/**)" in allow, "`//`: an absolute path"
  for a in allow: assert "bin/paredros" notin a, "no paredros command: " & a
  let system = after(args, "--append-system-prompt")
  assert "Compare" notin system, "no config: no compare action"
  assert "{" notin system
  assert Sid in system and scratch in system, "filled in"
  let args2 = argsOf(setup(Sid, spath, some(config.load("", example()).get(Config()))))[1]
  let home = getEnv("HOME")
  assert "Bash(" & home & "/Projects/Nim/bin/nim r --nimcache:" & scratch & "/cache:*)" in
    rules(args2, "allow")
  assert "Compare with Nim, when the human asks" in after(args2, "--append-system-prompt")
  # no working directory is an error
  let lost = tmp() & "/claude/projects/-lost/" & Solo & ".jsonl"
  writeJsonl(lost, [user("hi", "2026-11-09T10:00:00Z", tmp() & "/gone")])
  assert setup(Solo, lost).error("") == "cannot find the session's working directory"

block companion_may_run_only_reads:  # SecurityTests.test_companion_may_run_only_reads
  resetState()
  let args = argsOf(setup(Sid, spathOf(Sid)))[1]
  var allow, deny: seq[string] = @[]
  for r in rules(args, "allow"):
    if r.startsWith("Bash("): allow.add r.substr(5, r.len - 4)
  for r in rules(args, "deny"):
    if r.startsWith("Bash("): deny.add r.substr(5, r.len - 4)
  let me = (try: $paths.getCurrentDir() except: ".") & "/bin/paredros"
  # with --restricted and -p, what no allow rule names is refused (checked against the real CLI)
  var writes: seq[string] = @[]
  for f in ["", " --no-optional-locks"]:
    for w in ["push", "commit", "checkout", "reset", "rebase", "stash", "worktree", "branch",
              "config"]:
      writes.add "git" & f & " " & w & " x"
  for w in ["git -C /r commit -m x", "git --no-optional-locks -C /r push", "gh pr merge 3",
            me & " brief --force", "rm -rf x", "touch f", "sed -i s/a/b/ f"]:
    writes.add w
  for w in writes:
    for a in allow: assert not w.startsWith(a), w
  for r in ["git --no-optional-locks log -3", "git --no-optional-locks diff a b", "git diff a b",
            "git log --oneline", "git grep -n x", "cat a.txt", "ls -la",
            "git --no-optional-locks reflog show HEAD"]:
    var allowed = false
    for a in allow:
      if r.startsWith(a): allowed = true
    assert allowed, r
    for d in deny: assert not r.startsWith(d), r
  let all = rules(args, "allow")
  assert "Bash(git --no-optional-locks:*)" notin all
  assert "Bash(git status:*)" notin all, "takes the index lock; flagged form only"
  # options of allowed reads that write or run a command (wildcard rules, checked
  # against the real CLI): only the profile's own patterns are tested here
  for rule in ["Bash(git*--output*)", "Bash(git*grep*-O*)", "Bash(git*--open-files-in-pager*)"]:
    assert rule in rules(args, "deny"), rule
  for a in allow: assert not a.startsWith("rg"), a

tearDown()
