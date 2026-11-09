## The read-only companion: a fork of the session the human can question. Its
## permission profile and its system prompt, for the chat in `hitl serve`.

import std/[syncio, os, strutils, opt, result, tables, osproc, crypto/sysrand]
import kroki
import core

const
  GitReads = ["log", "show", "diff", "status", "rev-parse", "blame", "grep", "ls-files", "reflog show"]
  GitWrites* = ["push", "commit", "checkout", "switch", "reset", "restore", "rebase", "merge", "cherry-pick",
                "revert", "stash", "worktree", "branch", "tag", "am", "apply", "clean", "rm", "mv", "pull",
                "fetch", "update-ref", "reflog delete", "reflog expire", "gc", "config", "notes"]
  GhWrites = ["gh pr create", "gh pr merge", "gh pr comment", "gh pr review", "gh pr edit", "gh pr close",
              "gh issue create", "gh issue comment", "gh release", "gh api"]

type
  Permissions = object
    allow, deny: seq[string]
  Settings = object   ## $STATE/briefs/<s>/companion-settings.json
    permissions: Permissions

proc newCompanionId*(): string =
  ## A session id for a new companion fork (a uuid4), recorded so it is never
  ## taken for the session.
  var b = default(array[16, byte])
  discard urandom(b)
  b[6] = (b[6] and 0x0f) or 0x40
  b[8] = (b[8] and 0x3f) or 0x80
  var hex = ""
  for x in b: hex.add toHex(int(x), 2).toLowerAscii
  result = hex.substr(0, 7) & "-" & hex.substr(8, 11) & "-" & hex.substr(12, 15) & "-" &
           hex.substr(16, 19) & "-" & hex.substr(20)
  ensureDir(stateRoot())
  let old = readText(companionsFile()).get("")
  try: writeFile(companionsFile(), old & result & "\n")
  except: die("hitl: cannot write " & companionsFile())

proc hitlPath*(): string = getAppFilename()
  ## The hitl binary, as the companion's deny rules name it.

proc companionSetup*(sid: SessionId; spath, configFile: string): (string, seq[string]) =
  ## The companion's working directory and its claude arguments (settings file and
  ## system prompt).
  let cwd = sessionCwd(readJsonl(spath)).get("")
  if cwd.len == 0 or not isDir(cwd): die("hitl: cannot find the session's working directory")
  let cfg = loadConfig(cwd, configFile)
  let me = hitlPath()
  let briefs = state(skBriefs, sid)
  ensureDir(briefs)
  let scratch = state(skScratch, sid)   # snippets for the compare action and their caches, nothing else
  ensureDir(scratch)
  var allow: seq[string] = @[]
  var compare = ""
  if cfg.compare.isSome:
    let c = cfg.compare.get(Compare())
    for a in c.allow: allow.add expand(a, scratch)
    compare = "\n" & c.label & ", when the human asks for it or a fact needs it:\n" & expand(c.prompt, scratch) & "\n"
    for a in allow: compare.add "You may run `" & a & " ...`, with files in " & scratch & " only.\n"
  let spec = if cfg.spec.len > 0: "the spec (" & cfg.spec & ")" else: "the project's docs"
  let prompt = readText(appDir() & "/companion.md").get("")
  if prompt.len == 0: die("hitl: cannot read " & appDir() & "/companion.md")
  let brief = fill(prompt, [("session", $sid), ("transcripts", parentDir(spath)), ("briefs", briefs), ("scratch", scratch),
                              ("compare", compare), ("spec", spec)])
  var settings = Settings(permissions: Permissions(allow: @["Read", "Grep", "Glob", "Edit(" & scratch & "/**)"]))
  for g in GitReads: settings.permissions.allow.add "Bash(git --no-optional-locks " & g & ":*)"
  for a in allow: settings.permissions.allow.add "Bash(" & a & ":*)"
  var no: seq[string] = @[]
  for s in ["", " --no-optional-locks"]:
    for w in GitWrites: no.add "git" & s & " " & w
  no.add "git -C"   # -C would carry a write past the rules above
  no.add "git --no-optional-locks -C"
  for s in ["", " --session=" & sid.short]:
    for c in ["brief", "serve"]: no.add me & s & " " & c
  for g in GhWrites: no.add g
  for c in ["flock", "tmux", "rm", "mv", "kill", "pkill"]: no.add c
  for c in no: settings.permissions.deny.add "Bash(" & c & ":*)"
  for t in ["SendMessage", "TaskStop", "NotebookEdit"]: settings.permissions.deny.add t
  settings.permissions.deny.add "Edit(" & parentDir(cwd) & "/**)"
  let sfile = briefs & "/companion-settings.json"   # one per session: two servers never share it
  try: writeFile(sfile, toJson(settings).get("{}"))
  except: die("hitl: cannot write " & sfile)
  (cwd, @["--settings", sfile, "--strict-mcp-config", "--append-system-prompt", brief,
          "--add-dir", briefs, "--add-dir", scratch])
