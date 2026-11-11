## hitl: understand and decide on what a Claude Code session did.
##
## Reads only what already exists: the transcripts Claude Code writes and the
## git repositories and worktrees the session works in. Agents never load hitl
## and do no extra reporting. Control stays with the session.
##
##   brief    sort the session into work items and write their briefs (brief.nim)
##   serve    the review pages (pages.nim), decisions and the companion chat (serve.nim)

import std/[syncio, strutils, opt, result, smartcli]
import hitl/[state, session, config, brief, work, serve]

proc fail(message: string) {.noreturn.} =
  ## An error result: `hitl: <message>` on stderr, and exit 1.
  stderr.writeLine "hitl: " & message
  quit 1

proc runBrief(sid, spath: string; cfg: Config; numbers: seq[int]; model: string; force: bool;
              jobs: int) =
  ## Sorts the session's new material into work items, then writes the
  ## briefs whose inputs changed; says what it did, one line each.
  let src = sources(spath)
  var before: seq[int] = @[]
  case loadLedger(sid)
  of Ok(led):
    for it in led.items: before.add it.id
  of Err(e): fail(e)
  case split(sid, src, model)
  of Ok(led):
    for it in led.items:
      if it.id notin before: echo "#" & $it.id & ": new item: " & it.title
  of Err(e): fail(e)
  case collect(spath, cfg, src)
  of Ok(d):
    for (n, how) in generateAll(d, numbers, model, force, jobs): echo "#" & $n & ": " & how
  of Err(e): fail(e)

proc runServe(sid, spath: string; cfg: Config; port: int; model: string) =
  ## Serves the review pages until the process is stopped.
  case server(sid, spath, state("review", sid), port, model, some(cfg))
  of Ok(s): run(s)
  of Err(e): fail(e)

proc number(option, value: string; default: int): int =
  ## An integer option or argument; "" is its default. Any other value is an
  ## error result.
  if value.len == 0: default
  else: (try: parseInt(value) except: fail("invalid value for " & option & ": " & value))

proc main() =
  ## Reads the command line, picks the session and its config, runs the command.
  # GAP: with no command the help follows "[Error] missing arguments" and
  # hitl exits 1, where Python prints the help alone and exits 0; a bad
  # command line is told on stdout with the help and exit 1, not on stderr
  # with the usage and exit 2; and an option takes its value as --port=N or
  # --port:N, not --port N; because that is how std/smartcli parses.
  let cli = cliapp("""hitl: understand and decide on what a Claude Code session did.

Usage: hitl [options] brief [N...] | serve

Commands:
  brief N...          sort the session into work items and write their briefs (model runs, cached)
  serve               serve the review pages with decisions and a chat to the companion

Arguments:
  N...                brief: only these items' briefs

Options:
  --session=SESSION   session id prefix or project-name substring
  --config=CONFIG     config file (default: .hitl.json in the session's working directory)
  --model=MODEL       brief: the model (default opus); serve: the companion's model
  --force             brief: rewrite even if the inputs did not change
  --jobs=JOBS         brief: how many briefs may be written at once (default 4)
  --port=PORT         serve: the port (default 8765; 0: one the system picks)
  -h, --help          show this help message and exit""")
  var sid, spath = ""
  case pickSession(cli.session)
  of Ok(s):
    sid = s.id
    spath = s.path
  of Err(e): fail(e)
  var cfg = defaults()
  case config.load(sessionCwd(readJsonl(spath)).get(""), cli.config)
  of Ok(c): cfg = c
  of Err(e): fail(e)
  case cli.command
  of cmdBrief:
    var numbers: seq[int] = @[]
    for x in cli.n: numbers.add number("N", x, 0)
    runBrief(sid, spath, cfg, numbers, if cli.model.len > 0: cli.model else: "opus", cli.force,
             number("--jobs", cli.jobs, 4))
  of cmdServe:
    runServe(sid, spath, cfg, number("--port", cli.port, 8765), cli.model)
  of cmdNone:
    discard   # cliapp has refused a command line without a command

main()
