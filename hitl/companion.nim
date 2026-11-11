## The companion: a read-only fork of the session the human can question from
## the pages' chat. This module sets it up: Claude Code's restricted mode, a
## permission profile that allows reading only, its system prompt
## (companion.md) and the directories it may read. serve.nim runs it.

import std/[syncio, strutils, os, paths, dirs, opt, result]
import state, session, config

const
  GitReads = ["log", "show", "diff", "status", "rev-parse", "blame", "grep", "ls-files",
              "reflog show"]
  ShellReads = ["cat", "head", "tail", "ls", "wc", "grep", "diff"]  # not rg: `--pre <cmd>` runs a command
  # options of allowed reads that write a file or run a command; tried against the real CLI
  ReadEscapes = ["git*--output*", "git*grep*-O*", "git*--open-files-in-pager*", "git*--ext-diff*",
                 "git*--textconv*"]
  CompanionTools* = "Read,Grep,Glob,Bash,Edit,Write,Agent"
    ## The companion's tools. With --restricted and -p, everything the
    ## profile's allow list does not name is refused, and the user's and the
    ## project's settings files are ignored.

proc setup*(sid, spath: string;
            cfg = none[Config]()): Result[(string, seq[string]), string] =
  ## The companion's working directory and its `claude` arguments: restricted
  ## mode, a permission profile that allows reading only, its system prompt,
  ## and the directories it may read: the transcripts, briefs, its scratch
  ## folder and every worktree of the session's repository. cfg none: the
  ## config in the session's working directory. The error says there is no
  ## working directory, or why the config, the prompt or the profile cannot
  ## be read or written.
  let cwd = sessionCwd(readJsonl(spath)).get("")
  if cwd.len == 0 or not dirExists(cwd):
    return err[(string, seq[string]), string]("cannot find the session's working directory")
  let loaded = if cfg.isSome: ok[Config, string](cfg.get(defaults())) else: load(cwd)
  if loaded.isErr: return err[(string, seq[string]), string](loaded.error(""))
  let c = loaded.get(defaults())
  let briefs = state("briefs", sid)
  let scratch = state("scratch", sid)  # snippets for the compare action and their caches, nothing else
  try:
    createDir(path(briefs))
    createDir(path(scratch))
  except:
    return err[(string, seq[string]), string]("cannot make " & briefs & " and " & scratch)
  var allow: seq[string] = @[]   # the compare action's commands
  var compare = ""
  if c.compare.isSome:
    let cmp = c.compare.get(Compare())
    for a in cmp.allow: allow.add expand(a, scratch)
    compare = "\n" & cmp.label & ", when the human asks for it or a fact needs it:\n" &
              expand(cmp.prompt, scratch) & "\n"
    for a in allow: compare.add "You may run `" & a & " ...`, with files in " & scratch & " only.\n"
  let md = appDir() & "/companion.md"
  let text = try: readFile(md) except: ""
  if text.len == 0: return err[(string, seq[string]), string]("cannot read " & md)
  let prompt = text.multiReplace([("{session}", sid), ("{transcripts}", parentDir(spath)),
    ("{briefs}", briefs), ("{scratch}", scratch), ("{compare}", compare),
    ("{spec}", if c.spec.len > 0: "the spec (" & c.spec & ")" else: "the project's docs")])
  # `//` marks an absolute path in a permission rule; a single `/` is relative
  # to the settings file, so `Edit(/abs/...)` never matched
  var allowed = @["Read", "Grep", "Glob", "Edit(/" & scratch & "/**)"]
  var bash: seq[string] = @[]
  for g in GitReads: bash.add "git --no-optional-locks " & g
  # reads that take no lock, so the plain form is allowed too; `git status`
  # refreshes the index and may lock it while the session commits, so it
  # keeps --no-optional-locks
  for g in GitReads:
    if g != "status": bash.add "git " & g
  for s in ShellReads: bash.add s
  for a in allow: bash.add a
  for b in bash: allowed.add "Bash(" & b & ":*)"
  var denied: seq[string] = @[]   # allowed reads with an option that writes
  for e in ReadEscapes: denied.add "Bash(" & e & ")"
  # GAP: written on one line, not indented, and non-ASCII text as it is, not
  # \u-escaped as the Python does (both are JSON), because std/json has no
  # pretty printer.
  let settings = "{\"permissions\": {\"allow\": " & quote(allowed) & ", \"deny\": " &
                 quote(denied) & "}}"
  let sfile = briefs & "/companion-settings.json"   # one per session: two servers never share it
  try:
    writeFile(sfile, settings)
  except:
    return err[(string, seq[string]), string]("cannot write " & sfile)
  var dirs = @[parentDir(spath), briefs, scratch]
  for line in git(cwd, ["worktree", "list", "--porcelain"]).get("").splitLines:
    let wt = line.substr(len("worktree "))
    if line.startsWith("worktree ") and dirExists(wt) and wt notin dirs: dirs.add wt
  var args = @["--restricted", "--tools", CompanionTools, "--settings", sfile,
               "--strict-mcp-config", "--append-system-prompt", prompt]
  for d in dirs:
    args.add "--add-dir"
    args.add d
  result = ok[(string, seq[string]), string]((cwd, args))
