#? stdtmpl(conc = " &~ ", toString = "val", emit = "put result,") | standard
### The review pages, built around the decision briefs and the code. No
### logistics: no PRs, branches, pushes or timelines. The design is frozen in
### DESIGN.md; change it there first. The pages share static/hitl.css and
### static/hitl.js, which review.build copies beside them.
#import std/[strutils, opt]
#import core, items, html
#
#proc svg*(paths: string; size = 16; stroke = "1.6"; cls = ""): string =
#  ## An icon in the SF Symbols manner: a 20-unit grid, round caps, beside a word.
#  result = ""
#  let c = if cls.len > 0: " class=\"" & cls & "\"" else: ""
<svg${c} width="${size}" height="${size}" viewBox="0 0 20 20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="${stroke}" stroke-linecap="round" stroke-linejoin="round">${paths}</svg>
#end proc
#
#const
#  BubblePath = "<path d=\"M10 3.5c4.1 0 7 2.5 7 5.6s-2.9 5.6-7 5.6c-.8 0-1.6-.1-2.3-.3L4 16.2l.9-3.1C3.7 12.1 3 10.7 3 9.1 3 6 5.9 3.5 10 3.5z\"/>"
#  BackPath = "<path d=\"M12.5 4.5L7 10l5.5 5.5\"/>"
#  FwdPath = "<path d=\"M7.5 4.5L13 10l-5.5 5.5\"/>"
#  ClosePath = "<path d=\"M5.5 5.5l9 9M14.5 5.5l-9 9\"/>"
#  ExplainQ = "Explain these options and what each would mean for {users}. Be short."
#  GrillQ = "Grill me on this decision before I choose: check the facts the options rest on against {against}. At most three points."
#end const
#
#proc bubble*(): string =
#  result = svg(BubblePath, 18)
#end proc
#proc chev*(): string =
#  result = svg(FwdPath, 16, "2", "chev")
#end proc
#
#proc chatHtml(): string =
#  result = ""
<button id="hitl-ask" type="button" title="Ctrl+Shift+A">${bubble()}Ask about this</button>
<button id="hitl-open" type="button" title="Ctrl+Shift+A asks about selected text">${bubble()}Ask</button>
<aside id="hitl-chat" aria-labelledby="hitl-title" aria-hidden="true"><header><h2 id="hitl-title">Chat</h2>
<button id="hitl-close" type="button" aria-label="Close chat">${svg(ClosePath, 18)}</button></header>
<div id="hitl-log" role="log" aria-live="polite"></div><div id="hitl-form">
<div id="hitl-qbox"><blockquote id="hitl-quote"></blockquote>
<button id="hitl-unquote" type="button" aria-label="Remove quote">${svg(ClosePath, 16)}</button></div>
<label class="sr" for="hitl-q">Your question</label>
<textarea id="hitl-q" placeholder="Ask a question"></textarea>
<div class="row"><span>Ctrl+Enter to send</span>
<button id="hitl-send" type="button">Send</button></div></div></aside>
#end proc
#
#proc page(title, body: string; cls = ""; item = ""; head = ""): string =
#  result = ""
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>${head}<link rel="stylesheet" href="hitl.css"></head>
<body data-item="${item}"><main${cls}>${body}</main>
${chatHtml()}<script src="config.js"></script><script src="hitl.js"></script></body></html>
#end proc
#
#proc source(s: string): string =
#  result = ""
#  let t = untimed(s)
#  if t.len > 0:
<p class="src">From ${inline(t)}</p>
#  end if
#end proc
#
#proc qact(cfg: Config): string =
#  result = ""
#  let against = if cfg.spec.isSome: "the spec and the evidence" else: "the evidence"
#  let explain = ExplainQ.replace("{users}", cfg.users)
#  let grill = GrillQ.replace("{against}", against)
<div class="qact" hidden><button type="button" class="tb explain" data-q="${esc(explain)}">Explain the options</button>
<button type="button" class="tb grill" data-q="${esc(grill)}">Grill me</button></div>
#end proc
#
#proc optButton(o: string; mark: bool; why: string): string =
#  result = ""
<button type="button" class="opt" role="radio" aria-checked="false" data-opt="${esc(o)}" disabled>
<span class="ot">${inline(o)}</span>
#  if mark:
<span class="mark">Suggested</span>
#  end if
#  if why.len > 0:
<span class="why">${inline(why)}</span>
#  end if
</button>
#end proc
#
#proc decisionHtml*(i: Decision; item: ItemId; tip: string; cfg: Config; inputs: string): string =
#  ## The question, then the options as an inset group ending in a field for your
#  ## own answer (hitl.js: li.q[data-did], button.opt[data-opt], li.own, .qstate,
#  ## .qact), then the spec line, the source and the two chat helpers.
#  result = ""
#  let k = i.recommended.get(-1)
#  let marked = k >= 0 and k < i.options.len
#  let did = $decisionId(i.question)
#  let qid = "q" & $item & "-" & did
<li class="q" data-item="${item}" data-did="${did}" data-ref="${esc(tip)}" data-brief="${esc(inputs)}" data-question="${esc(i.question)}">
<p class="text" id="${qid}">${inline(i.question)}</p><ul class="opts" role="radiogroup" aria-labelledby="${qid}">
#  for n, o in i.options:
<li role="none">${optButton(o, marked and n == k, (if marked and n == k: i.reason else: ""))}</li>
#  end for
<li class="own" role="radio" aria-checked="false" aria-label="Your own answer" hidden>
<textarea class="own-t" rows="1" enterkeyhint="done" aria-label="Your own answer" placeholder="Type your answer"></textarea></li>
</ul><div class="qstate" aria-live="polite" hidden></div>
#  if not marked and i.reason.len > 0:
#    # the brief recommends none of the options: its reason, quietly
<p class="rec"><span class="l">Suggested</span>${inline(i.reason)}</p>
#  end if
#  if i.spec.len > 0:
<p class="spec"><span class="l">Spec</span>${inline(i.spec)}</p>
#  end if
${source(i.source)}${qact(cfg)}</li>
#end proc
#
#proc decisionsHtml*(ds: seq[Decision]; cfg: Config; item: ItemId; tip, inputs: string): string =
#  result = ""
#  var noSpec = false
#  if ds.len > 0:
<ul class="items">
#    for d in ds:
#      if d.spec.len == 0:
#        noSpec = true
#      end if
${decisionHtml(d, item, tip, cfg, inputs)}
#    end for
</ul>
#  end if
#  if cfg.spec.isSome and noSpec:
#    # one note instead of "The spec does not say" under every decision
<p class="dnote">No Spec line means the spec says nothing on it.</p>
#  end if
#end proc
#
#proc entriesHtml*(es: seq[Entry]): string =
#  result = ""
#  if es.len > 0:
<ul class="items">
#    for e in es:
<li><p class="text">${inline(e.text)}</p>
#      if e.why.len > 0:
<p class="why"><span class="sr">Why: </span>${inline(e.why)}</p>
#      end if
${source(e.source)}</li>
#    end for
</ul>
#  end if
#end proc
#
#proc sectionHtml*(id, title: string; n: int; inner: string; label = ""): string =
#  ## A section in its fixed place, with every entry and its exact count; an
#  ## empty one is just its heading, saying none.
#  result = ""
#  if n == 0:
<section id="${id}" class="s z"><div class="sh"><h2>${title}</h2><span class="c">none</span></div></section>
#  else:
#    let count = if label.len > 0: label else: $n
<section id="${id}" class="s"><div class="sh"><h2>${title}</h2><span class="c">${count}</span></div>${inner}</section>
#  end if
#end proc
#
#proc diffRows(rows: seq[string]): string =
#  result = ""
#  var old, new = 0
#  for line in rows:
#    let h = hunk(line)
#    if h.isSome:
#      old = h.get(Hunk()).old
#      new = h.get(Hunk()).new
#      let title = h.get(Hunk()).title.strip
#      let label = if title.len > 0: esc(title) else: "&nbsp;"
<tr class="hunk"><td></td><td></td><td></td><td>${label}</td></tr>
#    elif line.startsWith("+"):
<tr class="add"><td></td><td>${new}</td><td class="sig">+</td><td>${esc(line.substr(1))}</td></tr>
#      inc new
#    elif line.startsWith("-"):
<tr class="rem"><td>${old}</td><td></td><td class="sig">−</td><td>${esc(line.substr(1))}</td></tr>
#      inc old
#    elif line.startsWith("\\"):
#      discard
#    else:
<tr><td>${old}</td><td>${new}</td><td class="sig"></td><td>${esc(line.substr(1))}</td></tr>
#      inc old
#      inc new
#    end if
#  end for
#end proc
#
#proc renderDiff*(files: seq[DiffFile]): string =
#  ## One fold per file; every file starts closed.
#  result = ""
#  var first = true
#  for f in files:
#    if not first:
#      result.add "\n"
#    end if
#    first = false
<details class="file"><summary>${chev()}<span class="path">${esc(f.path)}</span>
<span class="stat"><ins>+${f.added}</ins> <del>−${f.removed}</del></span></summary>
<div class="scroll"><table class="diff">${diffRows(f.rows)}</table></div></details>
#  end for
#end proc
#
#proc itemBody(items: seq[WorkItem]; at: int; desk: Desk; b: Opt[Cached]): string =
#  result = ""
#  let r = items[at]
#  let cfg = desk.config
#  let tip = r.code.tip
<nav class="top" aria-label="Items"><a href="index.html">${svg(BackPath, 16, "2")}All items</a></nav>
<header class="head"><div class="n">Item #${r.id}</div><h1>${inline(r.title)}</h1>
#  case b
#  of Some(c):
<p class="summary">${inline(c.brief.summary)}</p>
#  of None:
<p class="summary nobrief">No brief yet. Run <code>hitl brief ${r.id}</code>.</p>
#  end case
#  case cfg.compare
#  of Some(cmp):
<div class="hitl-acts"><button class="soft" type="button" data-ask="${esc(expand(cmp.prompt, stateDir(sdScratch, desk.id)))}" hidden>
${bubble()}${esc(cmp.label)}</button></div>
#  of None:
#    discard
#  end case
</header>
#  case b
#  of Some(c):
#    for s in Section:
#      let inner = if s == secDecisions: decisionsHtml(c.brief.decisions, cfg, r.id, tip, c.inputs) else: entriesHtml(c.brief.entries[s])
${sectionHtml($s, SectionTitles[s], c.brief.count(s), inner)}
#    end for
#  of None:
#    discard
#  end case
#  let files = diffFiles(r.code.diff)
#  if files.len > 0:
${sectionHtml("code", "The code", files.len, renderDiff(files), plural(files.len, "file"))}
#  else:
<section id="code" class="s z"><div class="sh"><h2>The code</h2></div><p class="nocode">No code changes.</p></section>
#  end if
<nav class="end" aria-label="Next item">
#  if at + 1 < items.len:
#    let next = items[at + 1]
#    let hint = "#" & $next.id & " " & next.title.replace("`", "") & " (Alt+Right)"
<a href="i${next.id}.html" title="${esc(hint)}"><span class="et"><span class="k">Next item</span>
<span class="t"><span class="no">#${next.id}</span>${inline(next.title)}</span></span>${svg(FwdPath, 16, "2")}</a>
#  else:
<a href="index.html"><span class="et"><span class="t">All items</span></span>${svg(FwdPath, 16, "2")}</a>
#  end if
</nav>
#end proc
#
#proc itemPage*(items: seq[WorkItem]; at: int; desk: Desk; b: Opt[Cached]): string =
#  ## The same sections in the same order on every item page, in one column;
#  ## only the code is wider. The top holds only the way out; the way on is the
#  ## row at the end. Previous and next stay reachable by Alt+Left / Alt+Right
#  ## through <link rel> in the head.
#  var rels = ""
#  if at > 0:
#    rels.add "<link rel=\"prev\" href=\"i" & $items[at - 1].id & ".html\">"
#  end if
#  if at + 1 < items.len:
#    rels.add "<link rel=\"next\" href=\"i" & $items[at + 1].id & ".html\">"
#  end if
#  let r = items[at]
#  result = page("#" & $r.id & " " & r.title, itemBody(items, at, desk, b), " class=\"item\"", $r.id, rels)
#end proc
#
#proc card*(id: ItemId; title, status: string): string =
#  ## One link per item: number, title, and only in the decision lane the exact
#  ## number of decisions. Every card keeps the line's space, so all are one height.
#  result = ""
<li><a class="card" href="i${id}.html"><span class="no">#${id}</span>
<span class="tt">${inline(title)}</span><span class="sub">${status}</span></a></li>
#end proc
#
#proc indexBody(items: seq[WorkItem]; briefs: seq[Opt[Cached]]; built: string): string =
#  result = ""
<h1>Work items</h1>
#  if items.len == 0:
<p class="nocode">No work items yet. Run <code>hitl brief</code>.</p>
#  end if
<section id="hitl-decisions" hidden aria-labelledby="hitl-dh">
<div class="dh"><h2 id="hitl-dh">Your decisions</h2></div>
<ul></ul><p class="dsent" hidden></p></section>
#  for lane in Lane:
#    var cards = ""
#    var count = 0
#    for i, r in items:
#      if laneOf(briefs[i]) == lane:
#        inc count
#        cards.add card(r.id, r.title, cardStatus(briefs[i]))
#      end if
#    end for
#    let z = if count > 0: "" else: " z"
#    let c = if count > 0: $count else: "none"
<section class="lane lane-${$lane}${z}" aria-labelledby="lane-${$lane}">
<div class="ch"><h2 id="lane-${$lane}">${LaneTitles[lane]}</h2><span class="c">${c}</span></div>
#    if count > 0:
<ul class="cards">${cards}</ul>
#    end if
</section>
#  end for
<p class="built">${esc(built)}</p>
#end proc
#
#proc indexPage*(items: seq[WorkItem]; briefs: seq[Opt[Cached]]; built: string): string =
#  ## Three lanes, always in the same order, grouping the items by what they
#  ## need from you; item-number order inside each lane.
#  result = page("Work items", indexBody(items, briefs, built), " class=\"wide\"")
#end proc
