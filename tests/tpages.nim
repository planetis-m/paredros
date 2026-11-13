## The pages: the page script, what an item page shows, the lanes, every
## brief entry on the page, a single-agent session's page, and page identity
## across new material and rewritten briefs.

import std/[syncio, strutils, os, envvars, assertions, json, opt, result, tables]
import fixtures
import ../paredros/[state, session, config, render, brief, work, pages]

setUp()

proc buildInto(sid, dest: string; cfg = none[Config]()): string =
  ## Builds the session's pages into dest and returns dest; a test cannot go
  ## on without them.
  let built = build(spathOf(sid), dest, cfg)
  if built.isErr: quit built.error("")
  result = dest

proc parsed(json: string): Brief =
  ## brief.parse of JSON text.
  var t = parseJson(json)
  if t.hasError: quit t.errorMsg
  result = parse(t.root)

proc between(s, a, b: string): string =
  ## The text of s after the first a, up to the next b.
  let rest = s.substr(s.find(a) + a.len)
  result = rest.substr(0, rest.find(b) - 1)

block the_page_script_parses:
  if findExe("node").len > 0:
    let r = run(["node", "--check", repo() & "/static/paredros.js"], 60)
    assert r.isOk and r.get(Completed()).code == 0, r.get(Completed()).errors
  else:
    echo "skipped the_page_script_parses: node is not installed"

block build_shows_brief_code_and_sources:
  resetState()
  let dest = tmp() & "/out"
  assert "No work items yet" in readText(buildInto(Sid, dest) & "/index.html")
  discard fake([("Field defaults that are calls", @["A*", "C*"])])
  discard runBrief(Sid)
  try:
    writeJson(cachePath(Sid, 1), """{"inputs": "x", "brief": {""" &
      """"summary": "The default is typed in sem.", "open_decisions": [""" &
      """{"question": "Allow a call as a field default?", "options": ["yes", "no"], """ &
      """"recommended": 0, "reason": "Nim 2 allows it.", "source": "fixer 10:01"}], """ &
      """"spec_conflicts": [], "needs_review": [""" &
      """{"text": "changed after review", "source": "diff"}], """ &
      """"bug_risks": [], "decisions_made": []}}""")
  except:
    quit "cannot write the brief"
  discard buildInto(Sid, dest)
  let index = readText(dest & "/index.html")
  var page = readText(dest & "/i1.html")
  assert "The default is **typed**" notin page, "agent prose stays off the page"
  assert """<tr class="add"><td></td><td>1</td><td class="sig">+</td><td>proc a() =</td></tr>""" in
    page
  assert "PR" notin page, "no logistics"
  let decide = between(index, "id=\"lane-decide\"", "id=\"lane-review\"")
  let did = decisionId("Allow a call as a field default?")
  assert "<a class=\"card\" href=\"i1.html\">" in decide
  assert "<span class=\"sub\">1 decision</span>" in decide
  assert "Could cause more bugs" notin index, "no other counts"
  assert "Copy all" notin index
  assert "<span class=\"mark\">Suggested</span><span class=\"why\">Nim 2 allows it.</span>" in page
  assert readText(dest & "/paredros.js") == readText(repo() & "/static/paredros.js")
  assert "<link rel=\"stylesheet\" href=\"paredros.css\">" in page
  assert "<p class=\"src\">From fixer</p>" in page, "no clock times"
  let qid = "q1-" & did   # the answers are one radio group
  assert "<p class=\"text\" id=\"" & qid & "\">" in page
  assert "<ul class=\"opts\" role=\"radiogroup\" aria-labelledby=\"" & qid & "\">" in page
  assert page.split("class=\"opt\" role=\"radio\" aria-checked=\"false\"").len - 1 == 2
  assert """<li class="own" role="radio" aria-checked="false" aria-label="Your own answer" """ &
    "hidden>" in page
  assert "<div class=\"n\">Item #1 · +" in page, "the eyebrow carries the diff's size"
  assert """<nav class="end" aria-label="Next item"><a href="index.html">""" in page,
    "the last item"
  assert """<nav class="top" aria-label="Items"><a href="index.html">""" in page, "the way out only"
  assert "Next" notin between(page, "<nav class=\"top\"", "</nav>")
  assert "rel=\"prev\"" notin page, "the only item: no neighbours"
  assert "<p class=\"built\">Repo, updated " in index
  for s in Section:   # every section, every time
    assert "<h2>" & Sections[s].heading & "</h2>" in page
  assert """<section id="spec_conflicts" class="s z"><div class="sh"><h2>Contradicts the spec""" &
    """</h2><span class="c">0</span></div></section>""" in page, "empty sections stay, saying so"
  # no config: no spec note, no compare button; the helpers speak of the project's users
  assert "No Spec line" notin page
  assert "class=\"paredros-acts\"" notin page
  assert "would mean for the project&#x27;s users" in page
  let cfg = config.load("", example())
  assert cfg.isOk, cfg.error("")
  page = readText(buildInto(Sid, dest, some(cfg.get(defaults()))) & "/i1.html")
  assert "No Spec line means the spec says nothing on it." in page
  assert $bubble & "Compare with Nim</button>" in page
  assert getEnv("HOME") & "/Projects/Nim/bin/nim r --nimcache:" & outDir() & "/scratch/" &
    Sid.substr(0, 7) & "/cache" in page
  assert "would mean for people writing Nimony code" in page

block lanes:
  assert lane(parsed("""{"open_decisions": [{}], "needs_review": [{}]}""")) == "decide"
  assert lane(parsed("""{"needs_review": [{}]}""")) == "review"
  assert lane(parsed("""{"spec_conflicts": [{}]}""")) == "review"
  assert lane(parsed("""{"bug_risks": [{}]}""")) == "clear"

block briefs_and_pages_hold_every_entry:
  var risks, qs: seq[string] = @[]
  for i in 0 ..< 5: risks.add "{\"text\": \"risk " & $i & "\", \"source\": \"the diff\"}"
  for i in 0 ..< 4:
    qs.add """{"question": "Q""" & $i & """?", "options": ["yes", "no"], "recommended": -1, """ &
      """"reason": "Wait.", "spec": "", "source": "s"}"""
  let b = parsed("""{"summary": "s", "open_decisions": [""" & qs.join(", ") &
                 """], "bug_risks": [""" & risks.join(", ") & """], "more": {"bug_risks": 2}}""")
  assert b.lists[BugRisks].len == 5 and b.lists[OpenDecisions].len == 4, "no cap"
  let r = WorkItem(n: 63, title: "T")
  assert "<span class=\"sub\">4 decisions</span>" in $card(r, some(b), "decide"), "the exact count"
  assert "<span class=\"sub\">No brief yet</span>" in $card(r, none[Brief](), "review")
  assert "<span class=\"sub\"></span>" in $card(r, some(b), "clear")
  let cfg = config.load(tmp() & "/nowhere").get(Config())
  let s = $sectionHtml("bug_risks", "Could cause more bugs", 5,
                       itemsHtml("bug_risks", b.lists[BugRisks], cfg))
  assert "<span class=\"c\">5</span>" in s
  assert s.split("<p class=\"text\">risk ").len - 1 == 5
  assert "more not shown" notin s
  let page = $itemsHtml("open_decisions", b.lists[OpenDecisions], cfg, item = some(63),
                        reference = "t", inputs = "h")
  assert page.split("<li class=\"q\"").len - 1 == 4
  assert "data-ref=\"t\" data-brief=\"h\"" in page
  assert "Suggested</span><span" notin page, "none recommended: no option marked,"
  assert "<p class=\"rec\"><span class=\"l\">Suggested</span>Wait.</p>" in page, "the reason alone"

block single_agent_session:   # its page
  resetState()
  discard fake([("Parser accepts empty input", @["C1", "T1"]),
                ("Quotes are escaped", @["C2", "T1", "T2"])])
  discard runBrief(Solo)
  var n = 0
  for it in collectNow(Solo).items:
    if it.title == "Parser accepts empty input": n = it.n
  assert fileExists(buildInto(Solo, tmp() & "/solo-out") & "/i" & $n & ".html")

block page_identity_survives_new_material_and_rewritten_briefs:
  # item 1 keeps its number and its decision's id
  resetState()
  let spath = spathOf(Solo)
  let answer = """{"summary": "s", "open_decisions": [{"question": "Escape both?", """ &
               """"options": ["yes", "no"]}]}"""
  discard fake([("Parser accepts empty input", @["C1", "T1"])], answer)
  discard runBrief(Solo)
  let did = decisionId("Escape both?")
  let before = readText(spath)
  writeText(spath, before & user("now the quote escaping", "2026-11-09T10:40:00Z") & "\n")
  discard fake([("Quotes are escaped", @["C*", "T*", "A*"])], answer)
  discard runBrief(Solo, force = true)
  let page = readText(buildInto(Solo, tmp() & "/id-out") & "/i1.html")
  writeText(spath, before)
  assert "data-item=\"1\" data-did=\"" & did & "\"" in page

block build_deletes_only_pages_of_items_that_are_gone:
  # pages.build: a page of an item no longer in the ledger goes; other files stay
  let dest = tmp() & "/id-out"
  writeText(dest & "/i99.html", "old")
  writeText(dest & "/notes.html", "mine")
  discard buildInto(Solo, dest)
  assert not fileExists(dest & "/i99.html") and fileExists(dest & "/notes.html")
  assert fileExists(dest & "/i1.html") and fileExists(dest & "/i2.html")
  let tips = builtTips(dest)
  assert tips.isSome and tips.get(initTable[int, string]()).len == 2, "tips.json holds both items"

tearDown()
