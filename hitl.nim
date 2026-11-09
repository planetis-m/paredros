## hitl: review and decide on what a Claude Code session did: one agent, or a
## coordinator and its subagents.
##
## Reads only what already exists: the transcripts Claude Code writes and the git
## repositories and worktrees the session works in. Agents never load hitl and do
## no extra reporting. Control stays with the session.

import std/[syncio, strutils, opt, result, smartcli]
import hitl/[core, items, briefs]

proc optional(value: string): Opt[string] =
  ## An option's value; smartcli gives "" for an option left out.
  if value.len > 0: some(value) else: none[string]()

proc number(option, value: string; default: int): int =
  ## An integer option; any other value ends hitl.
  if value.len == 0: default
  else: (try: parseInt(value) except: quit "hitl: invalid value for " & option & ": " & value)

proc brief(desk: Desk; only: seq[ItemId]; model: string; force: bool; jobs: int) {.raises.} =
  ## Sorts new material into work items, then writes the briefs whose inputs changed.
  let src = sources(desk.transcript)
  var known: seq[ItemId] = @[]
  for it in loadLedger(desk.id).items: known.add it.id
  case split(desk, src, model)
  of Ok(ledger):
    for it in ledger.items:
      if it.id notin known: echo "#", $it.id, ": new item: ", it.title
  of Err(e): quit "hitl: " & e
  for r in generate(desk, workItems(desk, src), only, model, force, jobs):
    case r.state
    of bsFailed: echo "#", $r.item, ": failed: ", r.error
    of bsWritten, bsUnchanged: echo "#", $r.item, ": ", r.state

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
  var desk = Desk()
  case openDesk(optional(cli.session), optional(cli.config))
  of Ok(d): desk = d
  of Err(e): quit "hitl: " & e
  case cli.command
  of cmdBrief:
    var only: seq[ItemId] = @[]
    for x in cli.item: only.add ItemId(number("ITEM", x, 0))
    try: brief(desk, only, optional(cli.model).get("opus"), cli.force, number("--jobs", cli.jobs, 4))
    except ErrorCode as e: quit "hitl: cannot write the briefs: " & $e
  of cmdServe: quit "hitl: serve is not ported yet"
  of cmdNone: discard   # cliapp has already refused a command line without one

main()
