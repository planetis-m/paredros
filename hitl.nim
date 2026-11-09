## hitl: read-only views of a Claude Code session: one agent, or a coordinator
## and its subagents.
##
## Reads only what already exists: the transcripts Claude Code writes and the git
## repositories and worktrees the session works in. Agents never load hitl and do
## no extra reporting. Control stays with the session.

import std/[syncio, strutils, opt, tables, smartcli]
import hitl/[core, store, review, briefs, drafts, companion]

type Options = object   ## the parsed command line, as the commands use it
  session, config: string

proc intOption(name, value: string; default: int): int =
  ## An integer option as argparse's type=int reads it.
  if value.len == 0: return default
  result = try: parseInt(value.strip) except: die("hitl: invalid value for " & name & ": " & value)

# ------------------------------------------------------------------- commands

proc cmdStatus(o: Options) =
  let s = pickSession(o.session)
  let recs = readJsonl(s.path)
  echo "session ", s.id.short, "  ", s.project, "  last write ", ago(nowSeconds() - s.mtime), " ago"
  var last = "-"
  for c in toolUses(recs): last = describeCall(c.tool)
  echo "  main      session      last: ", last
  let ags = agents(s.path)
  if ags.len == 0: echo "  (no subagents)"
  for a in ags:
    var st = $stateOf(a)
    if stateOf(a) == asQuiet: st = "QUIET " & ago(a.age)
    var gtxt = ""
    let g = gitSummary(a.workdir)
    if g.isSome:
      let x = g.get(GitSummary())
      gtxt = x.branch & " +" & x.ahead & (if x.dirty > 0: " dirty:" & $x.dirty else: "")
    echo "  ", padRight(a.label, 9), " ", a.id.substr(0, 7), "  ", padRight(st, 9), " ",
      padLeft(ago(a.age), 4), "  ", padRight(gtxt, 28), " ", short(a.description, 40)
    if not a.finished and a.calls.len > 0:
      echo "            last: ", describeCall(a.calls[^1].tool)

proc cmdShow(o: Options; agent: string; n: int) =
  let s = pickSession(o.session)
  let a = resolve(s.path, agent)
  echo "# ", a.label, " (", a.id, ")  ", a.description
  echo "state: ", stateOf(a), "; last write ", ago(a.age), " ago; transcript ", a.path
  let g = gitSummary(a.workdir)
  if g.isSome:
    let x = g.get(GitSummary())
    echo "\n## ", x.top, "  branch ", x.branch, ", ", x.ahead, " unpushed commit(s), ", x.dirty,
      " modified file(s)"
    let ahead = try: parseInt(x.ahead) except: 0   # "?" when git could not count
    if ahead > 0:
      echo git(x.top, ["log", "--stat", "--format=%h %s", "-n", $min(ahead, 10), "HEAD"]).get("None")
  echo "\n## last actions"
  # Python's calls[-n:]: n = 0 means all of them
  let first = if n > 0: max(a.calls.len - n, 0) elif n == 0: 0 else: min(-n, a.calls.len)
  for i in first ..< a.calls.len:
    let c = a.calls[i]
    echo "  ", runeSlice(c.timestamp, 11, 19), "  ", describeCall(c.tool)
  let report = finalReport(a.recs)
  if report.len > 0:
    echo "\n## ", (if a.finished: "final report" else: "latest message")
    echo report

proc cmdReview(o: Options; outDir: string; open: bool) =
  let s = pickSession(o.session)
  let dir = if outDir.len > 0: pyPath(outDir) else: state(skReview, s.id)
  let index = build(s.path, o.config, dir)
  echo index
  if open:
    # PORTBUG(B5): hitl.py:341 - Path.as_uri() refuses a relative --out
    if not index.startsWith("/"): die("hitl: relative path can't be expressed as a file URI")
    openBrowser(fileUri(index))

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

proc cmdDirections(o: Options; words: seq[string]) =
  let action = if words.len > 0: words[0] else: "list"
  if action notin ["list", "send"] or words.len > 2:
    die("hitl: invalid choice for directions: " & words.join(" ") & " (choose from list, send DRAFT)")
  let draft = if words.len > 1: words[1] else: ""
  let s = pickSession(o.session)
  let recs = readJsonl(s.path)
  var tips = initTable[int, string]()
  if action == "list":
    let items = allDrafts(s.id)
    if items.len == 0: echo "no saved decisions in ", draftDir(s.id)
    for dr in items:
      let sentAt = deliveredAt(dr, recs)
      let said = if sentAt.get("").len > 0: "delivered " & runeHead(sentAt.get(""), 16) else: "saved"
      echo padRight(dr.id, 4), " ", padRight(said, 22), " ", short(dr.text, 70)
      if sentAt.get("").len == 0:
        for x in staleFacts(dr, s.path, o.config, tips): echo "       changed: ", x
    return
  var st = none[DraftState]()
  let why = check(s.id, s.path, o.config, draft, st)
  if why.len > 0:
    for x in st.get(DraftState()).stale: echo "  - ", x
    die("hitl: " & (if draft.len > 0: draft else: "None") & ": " & why & "; not sent")
  let text = st.get(DraftState()).text
  echo text
  if copyToClipboard(text): echo "\n(copied; paste it into the session when it is between turns)"
  else: echo "\n(paste the text above into the session when it is between turns)"

proc notYet(what: string) = die("hitl: " & what & " is not ported yet")

# ------------------------------------------------------------------------ main

proc main() =
  let cli = cliapp("""hitl
Read-only views of a Claude Code session: one agent, or a coordinator and its subagents.

Usage: hitl [options] status|show|review|brief|companion|serve|directions

Commands:
  status              one line per agent
  show AGENT          one agent: commits, last actions, final report
  review              build the HTML review pages and print the index path
  brief ITEM...       sort the session into work items and write their briefs (model runs, cached)
  companion ASK...    talk to a read-only fork of the session
  serve               serve the review pages with a chat to the companion
  directions ARG...   list your saved decisions (list), or re-check and copy one (send DRAFT)

Options:
  --session=S       session id prefix or project-name substring
  --config=FILE     config file (default: .hitl.json in the session's working directory)
  -n, --n=N         show: how many last actions (default 8)
  --open            review: open the index in the browser
  --out=DIR         review: output directory (default ~/.local/state/hitl/review/<session>)
  --model=M         brief: the model (default opus); companion, serve: the model
  --force           brief: rewrite even if the inputs did not change
  --jobs=N          brief: parallel brief runs (default 4)
  --port=N          serve: the port (default 8765)
  -h, --help        show this help and exit""")
  let o = Options(session: cli.session, config: cli.config)
  case cli.command
  of cmdStatus: cmdStatus(o)
  of cmdShow: cmdShow(o, cli.agent, intOption("-n", cli.n, 8))
  of cmdReview: cmdReview(o, cli.out, cli.open)
  of cmdBrief: cmdBrief(o, cli.item, (if cli.model.len > 0: cli.model else: "opus"), cli.force,
                        intOption("--jobs", cli.jobs, 4))
  of cmdCompanion:
    let s = pickSession(o.session)
    quit(runCompanion(s.id, s.path, o.config, cli.model, cli.ask))
  of cmdServe: notYet("serve")
  of cmdDirections: cmdDirections(o, cli.arg)
  of cmdNone: discard   # cliapp has already refused a command line without one

main()
