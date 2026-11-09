## test_hitl.py ReviewTests (pages), ConfigTests.test_the_script_passes_its_config_on
## and the page part of WorkItemTests.test_single_agent_session. The draft and
## companion tests of ReviewTests are in tdrafts.

import std/[syncio, strutils, os, opt, tables, envvars, result]
import kroki
import fixtures
import ../hitl/[core, store, review, pages, html]

setUp()
let example = (try: os.getCurrentDir() except: ".") & "/examples/nimony.hitl.json"

proc readOr(p: string): string = (try: readFile(p) except: "")

proc build(config = ""): string =
  let dir = tmp() & "/out"
  var args: seq[string] = @[]
  if config.len > 0: args.add "--config=" & config
  args.add "review"
  args.add "--out=" & dir
  let r = cli(args)
  check r.code == 0, "review ran: " & r.errors
  dir

proc briefOf(json: string): Brief = fromJson(json, Brief).get(Brief())

block test_the_page_script_parses:  # test_hitl.py::ReviewTests::test_the_page_script_parses
  let node = run(Job(argv: @["node", "--check", "static/hitl.js"], timeoutMs: 60_000))
  if node.started and node.code != 127:
    check node.code == 0, "hitl.js parses: " & node.errors

block test_build_shows_brief_code_and_sources:  # test_hitl.py::ReviewTests::test_build_shows_brief_code_and_sources
  resetState()
  var dir = build()
  check "No work items yet" in readOr(dir & "/index.html"), "no items yet"
  fakeModel("""{"split": [{"title": "Field defaults that are calls", "handles": ["A*", "C*"]}]}""")
  discard cli(["brief"])
  save(SessionId(Sid), 1, Cached(inputs: "x", brief: briefOf("""{
    "summary": "The default is typed in sem.",
    "open_decisions": [{"question": "Allow a call as a field default?", "options": ["yes", "no"],
                        "recommended": 0, "reason": "Nim 2 allows it.", "source": "fixer 10:01"}],
    "spec_conflicts": [], "needs_review": [{"text": "changed after review", "source": "diff"}],
    "bug_risks": [], "decisions_made": []}""")))
  dir = build()
  let index = readOr(dir & "/index.html")
  var page = readOr(dir & "/i1.html")
  check "The default is **typed**" notin page, "agent prose stays off the page"
  check """<tr class="add"><td></td><td>1</td><td class="sig">+</td><td>proc a() =</td></tr>""" in page, "the diff"
  check "PR" notin page, "no logistics"
  let decide = index.split("id=\"lane-decide\"")[1].split("id=\"lane-review\"")[0]
  let did = decisionId("Allow a call as a field default?")
  check "<a class=\"card\" href=\"i1.html\">" in decide, "the card in the decision lane"
  check "<span class=\"sub\">1 decision</span>" in decide, "its count"
  check "Could cause more bugs" notin index, "no other counts"
  check "Copy all" notin index, "no Copy all"
  check "<span class=\"mark\">Suggested</span><span class=\"why\">Nim 2 allows it.</span>" in page, "the suggestion"
  check readOr(dir & "/hitl.js") == readOr("static/hitl.js"), "the script beside the pages"
  check "<link rel=\"stylesheet\" href=\"hitl.css\">" in page, "the stylesheet"
  check "<p class=\"src\">From fixer</p>" in page, "no clock times"
  let qid = "q1-" & did   # the answers are one radio group
  check "<p class=\"text\" id=\"" & qid & "\">" in page, "the question labels"
  check "<ul class=\"opts\" role=\"radiogroup\" aria-labelledby=\"" & qid & "\">" in page, "the radio group"
  check page.split("class=\"opt\" role=\"radio\" aria-checked=\"false\"").len == 3, "two options"
  check "<li class=\"own\" role=\"radio\" aria-checked=\"false\" aria-label=\"Your own answer\" hidden>" in page, "own answer"
  check "<div class=\"n\">Item #1</div>" in page, "the eyebrow"
  check "<nav class=\"end\" aria-label=\"Next item\"><a href=\"index.html\">" in page, "the last item"
  check "<nav class=\"top\" aria-label=\"Items\"><a href=\"index.html\">" in page, "the way out only"
  check "Next" notin page.split("<nav class=\"top\"")[1].split("</nav>")[0], "nothing else at the top"
  check "rel=\"prev\"" notin page, "the only item: no neighbours"
  check "<p class=\"built\">Repo, updated " in index, "the freshness line"
  for s in Section:   # every section, every time
    check "<h2>" & SectionTitles[s] & "</h2>" in page, "section " & SectionTitles[s]
  check "<section id=\"spec_conflicts\" class=\"s z\"><div class=\"sh\"><h2>Contradicts the spec</h2>" &
    "<span class=\"c\">none</span></div></section>" in page, "empty sections stay, saying so"
  # no config: no spec note, no compare button; the helpers speak of the project's users
  check "No Spec line" notin page, "no spec note"
  check "class=\"hitl-acts\"" notin page, "no compare button"
  check "would mean for the project&#x27;s users" in page, "the default users"
  page = readOr(build(example) & "/i1.html")
  check "No Spec line means the spec says nothing on it." in page, "the spec note"
  check bubble() & "Compare with Nim</button>" in page, "the compare button"
  check getEnv("HOME") & "/Projects/Nim/bin/nim r --nimcache:" & tmp() & "/state/hitl/scratch/" &
    Sid.substr(0, 7) & "/cache" in page, "the compare prompt names the scratch folder"
  check "would mean for people writing Nimony code" in page, "the config's users"

block test_lanes:  # test_hitl.py::ReviewTests::test_lanes
  proc lane(b: string): Lane =
    var briefs = initTable[int, Cached]()
    briefs[1] = Cached(brief: briefOf(b))
    laneOf(briefs, 1)
  check lane("""{"open_decisions": [{"question": "q"}], "needs_review": [{"text": "t"}]}""") == laneDecide, "decide"
  check lane("""{"needs_review": [{"text": "t"}]}""") == laneReview, "needs review"
  check lane("""{"spec_conflicts": [{"text": "t"}]}""") == laneReview, "spec conflict"
  check lane("""{"bug_risks": [{"text": "t"}]}""") == laneClear, "bug risks alone"

block test_briefs_and_pages_hold_every_entry:  # test_hitl.py::ReviewTests::test_briefs_and_pages_hold_every_entry
  var risks, qs: seq[string] = @[]
  for i in 0 ..< 5: risks.add "{\"text\": \"risk " & $i & "\", \"source\": \"the diff\"}"
  for i in 0 ..< 4:
    qs.add "{\"question\": \"Q" & $i & "?\", \"options\": [\"yes\", \"no\"], \"recommended\": -1, \"reason\": \"Wait.\", " &
           "\"spec\": \"\", \"source\": \"s\"}"
  let b = briefOf("{\"summary\": \"s\", \"open_decisions\": [" & qs.join(", ") & "], \"bug_risks\": [" &
                  risks.join(", ") & "], \"more\": {\"bug_risks\": 2}}")
  check b.bug_risks.len == 5 and b.open_decisions.len == 4, "no cap"
  var briefs = initTable[int, Cached]()
  briefs[63] = Cached(brief: b)
  check "<span class=\"sub\">4 decisions</span>" in card(63, "T", cardSub(briefs, 63, laneDecide)), "the exact count"
  check "<span class=\"sub\">No brief yet</span>" in card(63, "T", cardSub(initTable[int, Cached](), 63, laneReview)), "no brief"
  check "<span class=\"sub\"></span>" in card(63, "T", cardSub(briefs, 63, laneClear)), "no status"
  let cfg = readConfig(tmp() & "/nowhere", "").get(Config())
  let s = sectionHtml("bug_risks", "Could cause more bugs", 5, entriesHtml(b.bug_risks))
  check "<span class=\"c\">5</span>" in s, "the count"
  check s.split("<p class=\"text\">risk ").len == 6, "every entry"
  check "more not shown" notin s, "nothing hidden"
  let page = decisionsHtml(b.open_decisions, cfg, 63, "t", "h")
  check page.split("<li class=\"q\"").len == 5, "every decision"
  check "data-ref=\"t\" data-brief=\"h\"" in page, "the facts the page shows"
  check "Suggested</span><span" notin page, "none recommended: no option marked"
  check "<p class=\"rec\"><span class=\"l\">Suggested</span>Wait.</p>" in page, "the reason alone"

block test_brief_parse_keeps_known_sections:  # test_hitl.py::ReviewTests::test_brief_parse_keeps_known_sections
  let b = briefOf("""{"summary": "s", "bug_risks": [{"text": "t"}], "extra": 1}""")
  check b.summary == "s" and b.bug_risks.len == 1 and b.bug_risks[0].text == "t" and
    b.open_decisions.len == 0, "the summary and the lists"
  check "extra" notin toJson(b).get(""), "unknown keys are dropped"

block test_markdown_subset:  # test_hitl.py::ReviewTests::test_markdown_subset
  let h = markdown("# T\n\nA `x<y` and **b**.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```nim\necho 1\n```")
  check "<h2>T</h2>" in h, "heading"
  check "<code>x&lt;y</code>" in h, "code span"
  check "<td>1</td>" in h, "table"
  check "<pre class=\"code\" data-lang=\"nim\"><code>echo 1</code></pre>" in h, "code block"

block test_the_script_passes_its_config_on:  # test_hitl.py::ConfigTests::test_the_script_passes_its_config_on
  resetState()
  let dir = tmp() & "/script-out"
  discard cli(["--config=" & example, "review", "--out=" & dir], Solo)
  writeText(ledgerPath(SessionId(Solo)), """{"items": [{"id": 1, "title": "T", "sources": []}], "seen": {}}""")
  discard cli(["--config=" & example, "review", "--out=" & dir], Solo)
  check "Compare with Nim</button>" in readOr(dir & "/i1.html"), "--config reaches the pages"

block test_single_agent_session_pages:  # test_hitl.py::WorkItemTests::test_single_agent_session (its page part)
  resetState()
  fakeModel("""{"split": [{"title": "Parser accepts empty input", "handles": ["C1", "T1"]},
                          {"title": "Quotes are escaped", "handles": ["C2", "T1", "T2"]}]}""")
  discard cli(["brief"], Solo)
  let dir = tmp() & "/solo-out"
  discard cli(["review", "--out=" & dir], Solo)
  check fileExists(dir & "/i1.html") and fileExists(dir & "/i2.html"), "a page per item"

tearDown()
