## The review pages: one per work item and an index, built from `work.collect`
## and the briefs, all HTML through render.nim. Built around the decision
## briefs and the code; no logistics (PRs, branches, pushes, timelines). The
## design is frozen in DESIGN.md; change it there first. The pages share
## static/hitl.css and static/hitl.js, which `build` copies beside them.

import std/[syncio, strutils, os, paths, dirs, tables, algorithm, json, rex, times, unicode,
            opt, result]
import state, config, render, brief, work

let
  bubble* = svg("<path d=\"M10 3.5c4.1 0 7 2.5 7 5.6s-2.9 5.6-7 5.6c-.8 0-1.6-.1-2.3-.3L4 " &
                "16.2l.9-3.1C3.7 12.1 3 10.7 3 9.1 3 6 5.9 3.5 10 3.5z\"/>", 18)
    ## The chat icon, on the chat buttons and the compare button.
  back* = svg("<path d=\"M12.5 4.5L7 10l5.5 5.5\"/>", 16, "2")
    ## The way back to the index.
  fwd = svg("<path d=\"M7.5 4.5L13 10l-5.5 5.5\"/>", 16, "2")
    ## The way on, at the end of a page.

const Cross = "<path d=\"M5.5 5.5l9 9M14.5 5.5l-9 9\"/>"   # the close and unquote icons

proc button(attrs: openArray[Attr]; children: openArray[Html]): Html =
  ## A <button type="button"> with the attributes after its type.
  var all = @[attr("type", "button")]
  for a in attrs: all.add a
  result = tag("button", all, children)

let chatHtml = join([
  tag("button", [attr("id", "hitl-ask"), attr("class", "filled"), attr("type", "button"),
                 attr("title", "Ctrl+Shift+A")], bubble, "Ask about this"),
  tag("button", [attr("id", "hitl-open"), attr("type", "button"),
                 attr("title", "Ctrl+Shift+A asks about selected text")], bubble, "Ask"),
  tag("aside", [attr("id", "hitl-chat"), attr("aria-labelledby", "hitl-title"),
                attr("aria-hidden", "true")],
      tag("header", [], tag("h2", [attr("id", "hitl-title")], "Chat"),
          tag("button", [attr("id", "hitl-close"), attr("type", "button"),
                         attr("aria-label", "Close chat")], svg(Cross, 18))),
      tag("div", [attr("id", "hitl-log"), attr("role", "log"), attr("aria-live", "polite")]),
      tag("div", [attr("id", "hitl-form")],
          tag("div", [attr("id", "hitl-qbox")], tag("blockquote", [attr("id", "hitl-quote")]),
              tag("button", [attr("id", "hitl-unquote"), attr("type", "button"),
                             attr("aria-label", "Remove quote")], svg(Cross, 16))),
          tag("label", [attr("class", "sr"), attr("for", "hitl-q")], "Your question"),
          tag("textarea", [attr("id", "hitl-q"), attr("placeholder", "Ask a question")]),
          tag("div", [attr("class", "row")], tag("span", [], "Ctrl+Enter to send"),
              tag("button", [attr("id", "hitl-send"), attr("class", "filled"),
                             attr("type", "button")], "Send"))))])
  ## The chat: its two open buttons and its panel, on every page.

proc page*(title: string; body: Html; wide = false; item = none[int]();
           head = Html("")): Html =
  ## A whole page: the head (`head` added to it), the body in <main>, the chat
  ## and the scripts. `wide` is the index's layout; `item` an item page's
  ## number.
  let kind = if wide: some("wide") elif item.isSome: some("item") else: none[string]()
  result = join([raw("<!doctype html>"), tag("html", [attr("lang", "en")],
    tag("head", [], tag("meta", [attr("charset", "utf-8")]),
        tag("meta", [attr("name", "viewport"),
                     attr("content", "width=device-width,initial-scale=1")]),
        tag("title", [], title), head,
        tag("link", [attr("rel", "stylesheet"), attr("href", "hitl.css")])),
    tag("body", [attr("data-item", if item.isSome: $item.get(0) else: "")],
        tag("main", [attr("class", kind)], body),
        chatHtml, tag("script", [attr("src", "config.js")]),
        tag("script", [attr("src", "hitl.js")])))])

proc plural(n: int; word: string): string =
  ## "1 file", "2 files".
  $n & " " & word & (if n != 1: "s" else: "")

# ------------------------------------------------------------------ sources

# GAP: a clock time right after `:`, `.`, `/` or `-` (Python leaves `x-10:01`)
# or right before `:` (`1:23:4` loses `1:23`) is taken out, `\s` is ASCII
# white space and `\d` ASCII digits, because std/rex has no lookaround and no
# Unicode classes: pages.py's `(?<![\w:./-])` and `(?![\w:])` are `\b` here.
let
  clock = re"(?:\b(?:at|on)\s+)?(?:\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2},?\s+)?\b\d{1,2}:\d{2}(?::\d{2})?\b"
  emptyBrackets = re"\(\s*\)|\[\s*\]"
  spaceBefore = re"\s+([,;)])"
  # GAP: of separators in a row (`(,)`), only the first is taken out, so
  # `(10:01, 10:05)` leaves `,)` where Python leaves `)`, because std/rex has
  # no lookahead: pages.py's `([(,;])\s*(?=[,;)])` keeps the next separator
  # here by matching it, so it is not looked at again.
  beforeSeparator = re"[(,;]\s*([,;)])"
  spaces = re"\s\s+"

proc untimed(s: string): string =
  ## The evidence pointer without its clock time: "fixer 10:01" -> "fixer";
  ## each part once: "fixer 07:35; fixer 10:37" -> "fixer".
  var t = s.replace(clock, "").replace(emptyBrackets, "")
  t = subGroup(subGroup(t, spaceBefore), beforeSeparator)
  var parts: seq[string] = @[]
  for p in t.replace(spaces, " ").split(';'):
    let part = p.strip(chars = {' ', ','})
    if part.len > 0 and part notin parts: parts.add part
  result = parts.join("; ")

proc source*(e: Entry): Html =
  ## "From <source>" under an entry, without clock times; nothing when it has
  ## no source.
  let s = untimed(e.source)
  result = if s.len > 0: tag("p", [attr("class", "src")], "From ", inline(s)) else: Html("")

# ---------------------------------------------------------------- decisions

let own* = tag("li", [attr("class", "own"), attr("role", "radio"), attr("aria-checked", "false"),
                      attr("aria-label", "Your own answer"), attr("hidden", true)],
               tag("textarea", [attr("class", "own-t"), attr("rows", 1),
                                attr("enterkeyhint", "done"), attr("aria-label", "Your own answer"),
                                attr("placeholder", "Type your answer")]))
  ## The last radio: its field is where you focus it, and focusing or typing
  ## selects it.

const
  ExplainQ = "Explain these options and what each would mean for {users}. Be short."
  GrillQ = "Grill me on this decision before I choose: check the facts the options rest on " &
           "against {against}. Only the points that could change my choice."

proc qact(cfg: Config): Html =
  ## The two chat helpers under a decision: explain the options, grill me.
  let against = if cfg.spec.len > 0: "the spec and the evidence" else: "the evidence"
  result = tag("div", [attr("class", "qact"), attr("hidden", true)],
               button([attr("class", "tb explain"),
                       attr("data-q", ExplainQ.replace("{users}", cfg.users))],
                      [toHtml("Explain the options")]),
               button([attr("class", "tb grill"),
                       attr("data-q", GrillQ.replace("{against}", against))],
                      [toHtml("Grill me")]))

let qstate = tag("div", [attr("class", "qstate"), attr("aria-live", "polite"),
                          attr("hidden", true)])
  ## Where hitl.js says what became of a decision.

proc optButton(o: string; mark = false; why = ""): Html =
  ## One option of a decision, a radio; `mark` says it is the suggested one,
  ## with `why`.
  button([attr("class", "opt"), attr("role", "radio"), attr("aria-checked", "false"),
          attr("data-opt", o), attr("disabled", true)],
         [tag("span", [attr("class", "ot")], inline(o)),
          if mark: tag("span", [attr("class", "mark")], "Suggested") else: Html(""),
          if why.len > 0: tag("span", [attr("class", "why")], inline(why)) else: Html("")])

proc decisionHtml(e: Entry; item: Opt[int]; reference: string; cfg: Config;
                   inputs = ""): Html =
  ## The question, then the options as an inset group ending in a field for
  ## your own answer (hitl.js: li.q[data-did], button.opt[data-opt], li.own,
  ## .qstate, .qact), then the spec line, the source and the two chat helpers.
  ## `reference` is the item's code tip, `inputs` its brief's hash.
  let k = e.recommended   # the suggested option; none when it is not one of them
  let suggested = k >= 0 and k < e.options.len
  let did = decisionId(e.question)
  let n = if item.isSome: $item.get(0) else: ""
  let qid = "q" & n & "-" & did
  var opts: seq[Html] = @[]
  for i, o in e.options:
    let mark = suggested and i == k
    opts.add tag("li", [attr("role", "none")],
                 optButton(o, mark = mark, why = if mark: e.reason else: ""))
  result = tag("li", [attr("class", "q"), attr("data-item", n), attr("data-did", did),
                      attr("data-ref", reference), attr("data-brief", inputs),
                      attr("data-question", e.question)],
    tag("p", [attr("class", "text"), attr("id", qid)], inline(e.question)),
    tag("ul", [attr("class", "opts"), attr("role", "radiogroup"), attr("aria-labelledby", qid)],
        opts, own),
    qstate,
    # the brief recommends none of the options: its reason, quietly
    if not suggested and e.reason.len > 0:
      tag("p", [attr("class", "rec")], tag("span", [attr("class", "l")], "Suggested"),
          inline(e.reason))
    else: Html(""),
    if e.spec.len > 0:
      tag("p", [attr("class", "spec")], tag("span", [attr("class", "l")], "Spec"), inline(e.spec))
    else: Html(""),
    source(e), qact(cfg))

proc itemsHtml*(key: string; entries: seq[Entry]; cfg: Config; item = none[int]();
                reference = ""; inputs = ""): Html =
  ## A section's entries as a list; open decisions as decisions, with one note
  ## when the config has a spec and a decision has no spec line.
  var lis: seq[Html] = @[]
  for e in entries:
    if key == "open_decisions":
      # Options are buttons: when served, choosing one and saving writes your
      # decision as a draft for the session. Opened as a file they are inert.
      lis.add decisionHtml(e, item, reference, cfg, inputs)
    else:
      lis.add tag("li", [], tag("p", [attr("class", "text")], inline(e.text)),
                  if e.why.len > 0:
                    tag("p", [attr("class", "why")], tag("span", [attr("class", "sr")], "Why: "),
                        inline(e.why))
                  else: Html(""),
                  source(e))
  var unsaid = false
  for e in entries:
    if e.spec.len == 0: unsaid = true
  var note = Html("")
  if key == "open_decisions" and cfg.spec.len > 0 and unsaid:
    # one note instead of "The spec does not say" under every decision
    note = tag("p", [attr("class", "dnote")], "No Spec line means the spec says nothing on it.")
  result = join([if lis.len > 0: tag("ul", [attr("class", "items")], lis) else: Html(""), note])

proc sectionHtml*(key, title: string; n: int; inner: Html; label = ""): Html =
  ## A section in its fixed place, with every entry and its exact count
  ## (`label` instead, when given); an empty one is just its heading, saying
  ## none.
  let count = if label.len > 0: label elif n != 0: $n else: "none"
  let head = tag("div", [attr("class", "sh")], tag("h2", [], title),
                 tag("span", [attr("class", "c")], count))
  result = tag("section", [attr("id", key), attr("class", if n != 0: "s" else: "s z")], head,
               if n != 0: inner else: Html(""))

# --------------------------------------------------------------- item pages

proc itemPage(r: WorkItem; d: Work; prev, next: Opt[int];
               titles: Table[int, string]): Html =
  ## The same sections in the same order on every item page, in one column;
  ## only the code is wider.
  let cfg = d.config
  var sections: seq[Html] = @[]
  if r.brief.isSome:
    let b = r.brief.get(Brief())
    for s in Section:
      let (key, heading) = Sections[s]
      sections.add sectionHtml(key, heading, b.lists[s].len,
                               itemsHtml(key, b.lists[s], cfg, some(r.n), r.code.tip, r.inputs))
  let (diff, files) = render.diff(r.code.diff)
  let code = if files > 0: sectionHtml("code", "The code", files, diff, plural(files, "file"))
             else: tag("section", [attr("id", "code"), attr("class", "s z")],
                       tag("div", [attr("class", "sh")], tag("h2", [], "The code")),
                       tag("p", [attr("class", "nocode")], "No code changes."))

  # The top holds only the way out; the way on is the row at the end. Previous
  # and next stay reachable by Alt+Left / Alt+Right through <link rel> in the head.
  var rels: seq[Html] = @[]
  for (rel, n) in [("prev", prev), ("next", next)]:
    if n.isSome:
      rels.add tag("link", [attr("rel", rel), attr("href", "i" & $n.get(0) & ".html")])
  var finish = Html("")
  if next.isSome:
    let nxt = next.get(0)
    let t = titles.getOrDefault(nxt, "")
    finish = tag("a", [attr("href", "i" & $nxt & ".html"),
                       attr("title", "#" & $nxt & " " & t.replace("`", "") & " (Alt+Right)")],
                 tag("span", [attr("class", "et")], tag("span", [attr("class", "k")], "Next item"),
                     tag("span", [attr("class", "t")],
                         tag("span", [attr("class", "no")], "#" & $nxt), inline(t))),
                 fwd)
  else:
    finish = tag("a", [attr("href", "index.html")],
                 tag("span", [attr("class", "et")], tag("span", [attr("class", "t")], "All items")),
                 fwd)
  var acts = Html("")
  if cfg.compare.isSome:
    let cmp = cfg.compare.get(Compare())
    acts = tag("div", [attr("class", "hitl-acts")],
               tag("button", [attr("class", "soft"), attr("type", "button"),
                              attr("data-ask", expand(cmp.prompt, state("scratch", d.session))),
                              attr("hidden", true)], bubble, cmp.label))
  let summary = if r.brief.isSome:
                  tag("p", [attr("class", "summary")], inline(r.brief.get(Brief()).summary))
                else: tag("p", [attr("class", "summary nobrief")], "No brief yet. Run ",
                          tag("code", [], "hitl brief " & $r.n), ".")
  let body = join([tag("nav", [attr("class", "top"), attr("aria-label", "Items")],
                       tag("a", [attr("href", "index.html")], back, "All items")),
                   tag("header", [attr("class", "head")],
                       tag("div", [attr("class", "n")], "Item #" & $r.n),
                       tag("h1", [], inline(r.title)), summary, acts),
                   join(sections), code,
                   tag("nav", [attr("class", "end"), attr("aria-label", "Next item")], finish)])
  result = page("#" & $r.n & " " & r.title, body, item = some(r.n), head = join(rels))

# --------------------------------------------------------------------- index

const Lanes = [("decide", "Waiting for your decision"),
                ("review", "Needs another review"),
                ("clear", "Nothing open")]
  ## The index's lanes, each key with its heading; the order never changes.

proc lane*(b: Brief): string =
  ## The first lane that applies to an item with brief b.
  result = if b.lists[OpenDecisions].len > 0: "decide"
           elif b.lists[SpecConflicts].len > 0 or b.lists[NeedsReview].len > 0: "review"
           else: "clear"

proc card*(r: WorkItem; b: Opt[Brief]; lane: string): Html =
  ## One link per item: number, title, and only in the decision lane the exact
  ## number of decisions. Every card keeps the line's space, so all are one
  ## height.
  let sub = if b.isNone: "No brief yet"
            elif lane == "decide": plural(b.get(Brief()).lists[OpenDecisions].len, "decision")
            else: ""
  result = tag("li", [], tag("a", [attr("class", "card"), attr("href", "i" & $r.n & ".html")],
                             tag("span", [attr("class", "no")], "#" & $r.n),
                             tag("span", [attr("class", "tt")], inline(r.title)),
                             tag("span", [attr("class", "sub")], sub)))

const MonthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
                    "Dec"]   # strftime's %b in the C locale

proc updated*(d: Work): string =
  ## "Nimony, updated 17:57" (the project's directory name); the date only
  ## when the data is not from today.
  # GAP: a first letter whose capital is two letters (ß) gets one, because
  # std/unicode maps one rune to one rune.
  let t = d.generated
  let today = local(getTime())
  let clock = ($t).substr(11, 15)   # HH:MM; std/times has no format
  let sameDay = t.year == today.year and t.month == today.month and t.monthday == today.monthday
  let at = if sameDay: clock
           else: MonthNames[ord(t.month) - 1] & " " & $t.monthday & " " & clock
  result = capitalize(extractFilename(d.repo)) & ", updated " & at

proc indexPage(d: Work): Html =
  ## Three lanes, always in the same order, grouping the items by what they
  ## need from you; item-number order inside each lane.
  var reps = d.items
  reps.sort(proc (a, b: WorkItem): int = cmp(a.n, b.n))
  var board: seq[Html] = @[]
  for (key, title) in Lanes:
    var cards: seq[Html] = @[]
    for r in reps:
      # no brief yet: it needs reading first
      let at = if r.brief.isNone: "review" else: lane(r.brief.get(Brief()))
      if at == key: cards.add card(r, r.brief, key)
    board.add tag("section", [attr("class", "lane lane-" & key & (if cards.len > 0: "" else: " z")),
                              attr("aria-labelledby", "lane-" & key)],
                  tag("div", [attr("class", "sh")], tag("h2", [attr("id", "lane-" & key)], title),
                      tag("span", [attr("class", "c")], if cards.len > 0: $cards.len else: "none")),
                  if cards.len > 0: tag("ul", [attr("class", "cards")], cards) else: Html(""))
  # Where the data comes from and when it was read is status, not content: one
  # quiet line at the end, not above the title.
  let empty = if reps.len == 0: tag("p", [attr("class", "nocode")], "No work items yet. Run ",
                                    tag("code", [], "hitl brief"), ".")
              else: Html("")
  let body = join([tag("h1", [], "Work items"), empty,
                   tag("section", [attr("id", "hitl-decisions"), attr("hidden", true),
                                   attr("aria-labelledby", "hitl-dh")],
                       tag("div", [attr("class", "dh")],
                           tag("h2", [attr("id", "hitl-dh")], "Your decisions")),
                       tag("ul"), tag("p", [attr("class", "dsent"), attr("hidden", true)])),
                   join(board), tag("p", [attr("class", "built")], updated(d))])
  result = page("Work items", body, wide = true)

# --------------------------------------------------------------------- build

proc builtTips*(dest: string): Opt[Table[int, string]] =
  ## {item: code tip} as the last build into dest found them, for the page's
  ## stale marks; none when there is no build or its tips.json cannot be read.
  let text = try: readFile(dest & "/tips.json") except: ""
  var tree = parseJson(text)
  if tree.hasError or tree.root.kind != JObject: return none[Table[int, string]]()
  var tips = initTable[int, string]()
  var good = true   # every key is a number
  for k, v in pairs(tree.root):
    # GAP: a key is a number in ASCII digits only (Python's int() also takes
    # other Unicode digits, `_` and white space around), because std/unicode
    # has no digit test.
    try:
      tips[parseInt(k)] = v.getStr
    except:
      good = false
  result = if good: some(tips) else: none[Table[int, string]]()

proc build*(spath, dest: string; cfg = none[Config]()): Result[string, string] =
  ## Writes the session's pages into dest: one per item and the index, the
  ## pages' CSS and JS beside them, and tips.json (each item's code tip).
  ## Only pages of items that are gone are deleted; nothing else in dest.
  ## cfg none: the config in the session's working directory. Returns the
  ## index's path; the error says why the config or the ledger cannot be read
  ## or a file cannot be written.
  let src = sources(spath)
  let loaded = if cfg.isSome: ok[Config, string](cfg.get(defaults())) else: config.load(src.cwd)
  if loaded.isErr: return err[string, string](loaded.error(""))
  let got = collect(spath, loaded.get(defaults()), src)
  if got.isErr: return err[string, string](got.error(""))
  let d = got.get(Work())
  var nums: seq[int] = @[]
  var titles = initTable[int, string]()
  for r in d.items:
    nums.add r.n
    titles[r.n] = r.title
  nums.sort()
  var doing = "make " & dest   # what is being done, for the error
  try:
    createDir(path(dest))
    # GAP: a page number is ASCII digits only (Python's \d and int() take any
    # Unicode digit), because std/unicode has no digit test.
    var gone: seq[string] = @[]
    for (kind, f) in walkDir(path(dest)):
      let name = extractFilename($f)
      let stem = name.changeFileExt("")
      if name.endsWith(".html") and stem.len > 1 and stem[0] == 'i' and
          allCharsInSet(stem.substr(1), Digits) and parseInt(stem.substr(1)) notin titles:
        gone.add $f
    for f in gone:
      doing = "delete " & f
      removeFile(path(f))
    for r in d.items:
      let i = nums.find(r.n)
      let prev = if i > 0: some(nums[i - 1]) else: none[int]()
      let next = if i + 1 < nums.len: some(nums[i + 1]) else: none[int]()
      doing = "write " & dest & "/i" & $r.n & ".html"
      writeAtomic(dest & "/i" & $r.n & ".html", $itemPage(r, d, prev, next, titles))
    # the pages' CSS and JS, beside them so file mode works too
    let assets = appDir() & "/static"
    doing = "read " & assets
    for (kind, f) in walkDir(path(assets)):
      if kind == pcFile:
        doing = "copy " & $f
        writeAtomic(dest & "/" & extractFilename($f), readFile($f))
    # {item: tip} is a Table, which std/json's toJson cannot write
    # (bug-reports/112-json-tojson-table-field-fails-in-json-nim): the object
    # is joined from its members, spaced as Python's json.dumps writes it
    var tips: seq[string] = @[]
    for r in d.items: tips.add quote($r.n) & ": " & quote(r.code.tip)
    doing = "write " & dest & "/tips.json"
    writeAtomic(dest & "/tips.json", "{" & tips.join(", ") & "}")
    doing = "write " & dest & "/index.html"
    writeAtomic(dest & "/index.html", $indexPage(d))
  except ErrorCode as e:
    return err[string, string]("cannot " & doing & " (" & $e & ")")
  result = ok[string, string](dest & "/index.html")
