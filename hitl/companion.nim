## The read-only companion: a fork of the session the human questions from the
## pages' chat. Its permission profile, its system prompt, and the one
## conversation a server run keeps with it.

import std/[syncio, strutils, os, dirs, paths, opt, result, crypto/sysrand, crypto/sha2]
import kroki
import core

const
  GitReads = ["log", "show", "diff", "status", "rev-parse", "blame", "grep", "ls-files", "reflog show"]
  GitWrites* = ["push", "commit", "checkout", "switch", "reset", "restore", "rebase", "merge", "cherry-pick",
                "revert", "stash", "worktree", "branch", "tag", "am", "apply", "clean", "rm", "mv", "pull",
                "fetch", "update-ref", "reflog delete", "reflog expire", "gc", "config", "notes"]
  GhWrites = ["gh pr create", "gh pr merge", "gh pr comment", "gh pr review", "gh pr edit", "gh pr close",
              "gh issue create", "gh issue comment", "gh release", "gh api"]
  AskTimeoutMs = 900_000

type
  Permissions = object
    allow, deny: seq[string]
  Settings = object   ## $STATE/briefs/<s>/companion-settings.json
    permissions: Permissions

proc newCompanionId(): SessionId {.raises.} =
  ## A session id for a new fork (a uuid4), recorded so that the fork, a full
  ## copy of the session's transcript, is never taken for the session.
  var b = default(array[16, byte])
  if not urandom(b): raise IOError
  b[6] = (b[6] and 0x0f) or 0x40
  b[8] = (b[8] and 0x3f) or 0x80
  let hex = toHex(b)
  result = SessionId(hex.substr(0, 7) & "-" & hex.substr(8, 11) & "-" & hex.substr(12, 15) & "-" &
                     hex.substr(16, 19) & "-" & hex.substr(20))
  writeAtomic(companionsFile(), readText(companionsFile()).get("") & $result & "\n")

proc companionArgs*(desk: Desk): seq[string] {.raises.} =
  ## The companion's claude arguments: its permission profile, written to a
  ## settings file, and its system prompt.
  let briefs = stateDir(sdBriefs, desk.id)
  let scratch = stateDir(sdScratch, desk.id)   # files for the compare action, nothing else
  createDir(paths.path(scratch))
  var settings = Settings(permissions: Permissions(allow: @["Read", "Grep", "Glob", "Edit(" & scratch & "/**)"]))
  for g in GitReads: settings.permissions.allow.add "Bash(git --no-optional-locks " & g & ":*)"
  var compare = ""
  case desk.config.compare
  of Some(c):
    compare = "\n" & c.label & ", when the human asks for it or a fact needs it:\n" & expand(c.prompt, scratch) & "\n"
    for a in c.allow:
      settings.permissions.allow.add "Bash(" & expand(a, scratch) & ":*)"
      compare.add "You may run `" & expand(a, scratch) & " ...`, with files in " & scratch & " only.\n"
  of None: discard
  var denied: seq[string] = @[]
  for flag in ["", " --no-optional-locks"]:
    for w in GitWrites: denied.add "git" & flag & " " & w
  denied.add "git -C"   # -C would carry a write past the rules above
  denied.add "git --no-optional-locks -C"
  for session in ["", " --session=" & desk.id.short]:
    for c in ["brief", "serve"]: denied.add getAppFilename() & session & " " & c
  for g in GhWrites: denied.add g
  for c in ["flock", "tmux", "rm", "mv", "kill", "pkill"]: denied.add c
  for c in denied: settings.permissions.deny.add "Bash(" & c & ":*)"
  for t in ["SendMessage", "TaskStop", "NotebookEdit"]: settings.permissions.deny.add t
  settings.permissions.deny.add "Edit(" & parentDir(desk.cwd) & "/**)"
  let file = briefs & "/companion-settings.json"   # one per session: two servers never share it
  writeAtomic(file, toJson(settings).get("{}"))
  let prompt = readFile(appDir() & "/companion.md").multiReplace([
    ("{session}", $desk.id), ("{transcripts}", parentDir(desk.transcript)), ("{briefs}", briefs),
    ("{scratch}", scratch), ("{compare}", compare),
    ("{spec}", if desk.config.spec.isSome: "the spec (" & desk.config.spec.get("") & ")" else: "the project's docs")])
  @["--settings", file, "--strict-mcp-config", "--append-system-prompt", prompt,
    "--add-dir", briefs, "--add-dir", scratch]

type
  Companion* = object   ## the conversation a server run keeps with the companion
    desk: Desk
    model: Opt[string]
    fork: Opt[SessionId]   ## the fork, once the first question made it
  ChatReply = object       ## what `claude -p --output-format json` prints
    text: string           ## result
    sessionId: string      ## session_id

proc readJson(dst: var ChatReply; p: var JsonParser; u: UnknownFieldPolicy) =
  for f in p.jsonFields:
    if f == "result": readJson(dst.text, p, u)
    elif f == "session_id": readJson(dst.sessionId, p, u)
    else: p.skipJson()

proc initCompanion*(desk: Desk; model: Opt[string]): Companion =
  Companion(desk: desk, model: model, fork: none[SessionId]())

proc askJob*(c: Companion; prompt: string): Job {.raises.} =
  ## The `claude -p` run that answers the prompt. The first question forks the
  ## session in its own directory (a session is resumed from there); later
  ## ones continue the fork.
  var argv = @["claude", "-p", "--output-format", "json", "--resume"]
  case c.fork
  of Some(fork): argv.add $fork
  of None:
    for a in [$c.desk.id, "--fork-session", "--session-id", $newCompanionId()]: argv.add a
  for a in companionArgs(c.desk): argv.add a
  if c.model.isSome:
    argv.add "--model"
    argv.add c.model.get("")
  Job(argv: argv, cwd: c.desk.cwd, input: prompt, timeoutMs: AskTimeoutMs)

proc answer*(c: var Companion; r: Ran): Result[string, string] =
  ## The companion's answer from its run, in markdown, or why there is none;
  ## the fork it made is kept for the next question.
  if not r.started: return err[string, string](r.errors)
  if r.code != 0:
    let why = r.errors.strip.lastRunes(400)
    return err[string, string](if why.len > 0: why else: "claude exited " & $r.code)
  case fromJson(r.output, ChatReply)
  of Ok(reply):
    if reply.sessionId.len > 0: c.fork = some(SessionId(reply.sessionId))
    result = ok[string, string](reply.text)
  of Err(e): result = err[string, string]("claude answered no JSON: " & $e)
