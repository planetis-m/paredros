## hitl: review and decide on what a Claude Code session did: one agent, or a
## coordinator and its subagents.
##
## Reads only what already exists: the transcripts Claude Code writes and the git
## repositories and worktrees the session works in. Agents never load hitl and do
## no extra reporting. Control stays with the session.

import std/[syncio, strutils, opt, tables, smartcli]
import hitl/[core, store, review, briefs]

type Options = object   ## the parsed command line, as the commands use it
  session, config: string

proc intOption(name, value: string; default: int): int =
  ## An integer option as argparse's type=int reads it.
  if value.len == 0: return default
  result = try: parseInt(value.strip) except: die("hitl: invalid value for " & name & ": " & value)

# ------------------------------------------------------------------- commands

proc cmdBrief(o: Options; items: seq[string]; model: string; force: bool; jobs: int) =
  var numbers: seq[int] = @[]
  for x in items: numbers.add intOption("N", x, 0)
  let s = pickSession(o.session)
  var d = collect(s.path, o.config, withDiff = false)
  var before: seq[int] = @[]
  for it in loadLedger(d.session).items: before.add it.id
  let led = split(d, model)
  for it in led.items:
    if it.id notin before: echo "#", it.id, ": new item: ", it.title
  d = collect(s.path, o.config)
  for r in generateAll(d, numbers, model, force, jobs):
    echo "#", r.n, ": ", (if r.state == bsFailed: "failed: " & r.error else: $r.state)

proc notYet(what: string) = die("hitl: " & what & " is not ported yet")

# ------------------------------------------------------------------------ main

proc main() =
  let cli = cliapp("""hitl
Review and decide on what a Claude Code session did: one agent, or a coordinator and its subagents.

Usage: hitl [options] brief|serve

Commands:
  brief ITEM...       sort the session into work items and write their briefs (model runs, cached)
  serve               build the review pages and serve them, with your decisions and a chat

Options:
  --session=S       session id prefix or project-name substring
  --config=FILE     config file (default: .hitl.json in the session's working directory)
  --model=M         brief: the model (default opus); serve: the companion's model
  --force           brief: rewrite even if the inputs did not change
  --jobs=N          brief: parallel brief runs (default 4)
  --port=N          serve: the port (default 8765)
  -h, --help        show this help and exit""")
  let o = Options(session: cli.session, config: cli.config)
  case cli.command
  of cmdBrief: cmdBrief(o, cli.item, (if cli.model.len > 0: cli.model else: "opus"), cli.force,
                        intOption("--jobs", cli.jobs, 4))
  of cmdServe: notYet("serve")
  of cmdNone: discard   # cliapp has already refused a command line without one

main()
