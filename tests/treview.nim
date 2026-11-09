## The pages (test_hitl.py ReviewTests, ConfigTests.test_the_script_passes_its_config_on
## and the page part of WorkItemTests.test_single_agent_session). The draft and
## companion tests of ReviewTests are in tdrafts.

import std/[strutils, os, envvars, assertions]
import kroki
import fixtures
import ../hitl/[core, items, html, pages, review]

setUp()
let example = (try: os.getCurrentDir() except: ".") & "/examples/nimony.hitl.json"

proc buildPages(sid: string; config = none[string]()): string =
  ## Builds the pages of a fixture session into a fresh directory; returns it.
  result = tmp() & "/out-" & sid.substr(0, 7)
  try: discard build(deskOf(sid, config), result)
  except: quit "the build failed"

proc briefOf(json: string): Brief = fromJson(json, Brief).get(Brief())

block the_page_script_parses:  # ReviewTests.test_the_page_script_parses
  let node = run(Job(argv: @["node", "--check", "static/hitl.js"], timeoutMs: 60_000))
  if node.started:
    assert node.code == 0, "hitl.js parses: " & node.errors

block build_shows_brief_code_and_sources:  # ReviewTests.test_build_shows_brief_code_and_sources
  resetState()
  var dir = buildPages(Sid)
  assert "No work items yet" in readOr(dir & "/index.html"), "no items yet"
  fakeModel("""{"split": [{"title": "Field defaults that are calls", "handles": ["A*", "C*"]}]}""")
  discard cli(["brief"])
  try:
    saveBrief(SessionId(Sid), ItemId(1), Cached(inputs: "x", brief: briefOf("""{
      "summary": "The default is typed in sem.",
      "open_decisions": [{"question": "Allow a call as a field default?", "options": ["yes", "no"],
                          "recommended": 0, "reason": "Nim 2 allows it.", "source": "fixer 10:01"}],
      "spec_conflicts": [], "needs_review": [{"text": "changed after review", "source": "diff"}],
      "bug_risks": [], "decisions_made": []}""")))
  except: quit "cannot save the brief"
  dir = buildPages(Sid)
  let index = readOr(dir & "/index.html")
  var page = readOr(dir & "/i1.html")
  assert "The default is **typed**" notin page, "agent prose stays off the page"
  assert """<tr class="add"><td></td><td>1</td><td class="sig">+</td><td>proc a() =</td></tr>""" in page, "the diff"
  assert "PR" notin page, "no logistics"
  let decide = index.split("id=\"lane-decide\"")[1].split("id=\"lane-review\"")[0]
  let did = $decisionId("Allow a call as a field default?")
  assert "<a class=\"card\" href=\"i1.html\">" in decide, "the card in the decision lane"
  assert "<span class=\"sub\">1 decision</span>" in decide, "its count"
  assert "Could cause more bugs" notin index, "no other counts"
  assert "Copy all" notin index, "no Copy all"
  assert "<span class=\"mark\">Suggested</span><span class=\"why\">Nim 2 allows it.</span>" in page, "the suggestion"
  assert readOr(dir & "/hitl.js") == readOr("static/hitl.js"), "the script beside the pages"
  assert "<link rel=\"stylesheet\" href=\"hitl.css\">" in page, "the stylesheet"
  assert "<p class=\"src\">From fixer</p>" in page, "no clock times"
  let qid = "q1-" & did   # the answers are one radio group
  assert "<p class=\"text\" id=\"" & qid & "\">" in page, "the question labels"
  assert "<ul class=\"opts\" role=\"radiogroup\" aria-labelledby=\"" & qid & "\">" in page, "the radio group"
  assert page.split("class=\"opt\" role=\"radio\" aria-checked=\"false\"").len == 3, "two options"
  assert "<li class=\"own\" role=\"radio\" aria-checked=\"false\" aria-label=\"Your own answer\" hidden>" in page,
    "own answer"
  assert "<div class=\"n\">Item #1</div>" in page, "the eyebrow"
  assert "<nav class=\"end\" aria-label=\"Next item\"><a href=\"index.html\">" in page, "the last item"
  assert "<nav class=\"top\" aria-label=\"Items\"><a href=\"index.html\">" in page, "the way out only"
  assert "Next" notin page.split("<nav class=\"top\"")[1].split("</nav>")[0], "nothing else at the top"
  assert "rel=\"prev\"" notin page, "the only item: no neighbours"
  assert "<p class=\"built\">Repo, updated " in index, "the freshness line"
  for s in Section:   # every section, every time
    assert "<h2>" & SectionTitles[s] & "</h2>" in page, "section " & SectionTitles[s]
  assert "<section id=\"spec_conflicts\" class=\"s z\"><div class=\"sh\"><h2>Contradicts the spec</h2>" &
    "<span class=\"c\">none</span></div></section>" in page, "empty sections stay, saying so"
  # no config: no spec note, no compare button; the helpers speak of the project's users
  assert "No Spec line" notin page, "no spec note"
  assert "class=\"hitl-acts\"" notin page, "no compare button"
  assert "would mean for the project&#x27;s users" in page, "the default users"
  page = readOr(buildPages(Sid, some(example)) & "/i1.html")
  assert "No Spec line means the spec says nothing on it." in page, "the spec note"
  assert bubble() & "Compare with Nim</button>" in page, "the compare button"
  assert getEnv("HOME") & "/Projects/Nim/bin/nim r --nimcache:" & tmp() & "/state/hitl/scratch/" &
    Sid.substr(0, 7) & "/cache" in page, "the compare prompt names the scratch folder"
  assert "would mean for people writing Nimony code" in page, "the config's users"

block lanes:  # ReviewTests.test_lanes
  proc lane(json: string): Lane = laneOf(some(Cached(brief: briefOf(json))))
  assert lane("""{"open_decisions": [{"question": "q"}], "needs_review": [{"text": "t"}]}""") == laneDecide, "decide"
  assert lane("""{"needs_review": [{"text": "t"}]}""") == laneReview, "needs review"
  assert lane("""{"spec_conflicts": [{"text": "t"}]}""") == laneReview, "spec conflict"
  assert lane("""{"bug_risks": [{"text": "t"}]}""") == laneClear, "bug risks alone"
  assert laneOf(none[Cached]()) == laneReview, "no brief yet"

block briefs_and_pages_hold_every_entry:  # ReviewTests.test_briefs_and_pages_hold_every_entry
  var risks, qs: seq[string] = @[]
  for i in 0 ..< 5: risks.add "{\"text\": \"risk " & $i & "\", \"source\": \"the diff\"}"
  for i in 0 ..< 4:
    qs.add "{\"question\": \"Q" & $i & "?\", \"options\": [\"yes\", \"no\"], \"recommended\": -1, " &
           "\"reason\": \"Wait.\", \"spec\": \"\", \"source\": \"s\"}"
  let b = briefOf("{\"summary\": \"s\", \"open_decisions\": [" & qs.join(", ") & "], \"bug_risks\": [" &
                  risks.join(", ") & "], \"more\": {\"bug_risks\": 2}}")
  assert b.entries[secBugRisks].len == 5 and b.decisions.len == 4, "no cap"
  let id = ItemId(63)
  assert "<span class=\"sub\">4 decisions</span>" in card(id, "T", cardStatus(some(Cached(brief: b)))), "the exact count"
  assert "<span class=\"sub\">No brief yet</span>" in card(id, "T", cardStatus(none[Cached]())), "no brief"
  assert "<span class=\"sub\"></span>" in card(id, "T", cardStatus(some(Cached(brief: briefOf("{}"))))), "no status"
  let s = sectionHtml("bug_risks", "Could cause more bugs", 5, entriesHtml(b.entries[secBugRisks]))
  assert "<span class=\"c\">5</span>" in s, "the count"
  assert s.split("<p class=\"text\">risk ").len == 6, "every entry"
  assert "more not shown" notin s, "nothing hidden"
  let page = decisionsHtml(b.decisions, Config(), id, "t", "h")
  assert page.split("<li class=\"q\"").len == 5, "every decision"
  assert "data-ref=\"t\" data-brief=\"h\"" in page, "the facts the page shows"
  assert "Suggested</span><span" notin page, "none recommended: no option marked"
  assert "<p class=\"rec\"><span class=\"l\">Suggested</span>Wait.</p>" in page, "the reason alone"

block brief_parse_keeps_known_sections:  # ReviewTests.test_brief_parse_keeps_known_sections
  let b = briefOf("""{"summary": "s", "bug_risks": [{"text": "t"}], "extra": 1}""")
  assert b.summary == "s" and b.entries[secBugRisks].len == 1 and b.entries[secBugRisks][0].text == "t" and
    b.decisions.len == 0, "the summary and the lists"
  assert "extra" notin toJson(b).get(""), "unknown keys are dropped"

block markdown_subset:  # ReviewTests.test_markdown_subset
  let h = markdown("# T\n\nA `x<y` and **b**.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```nim\necho 1\n```")
  assert "<h2>T</h2>" in h, "heading"
  assert "<code>x&lt;y</code>" in h, "code span"
  assert "<td>1</td>" in h, "table"
  assert "<pre class=\"code\" data-lang=\"nim\"><code>echo 1</code></pre>" in h, "code block"

block the_config_reaches_the_pages:  # ConfigTests.test_the_script_passes_its_config_on
  resetState()
  writeText(stateDir(sdBriefs, SessionId(Solo)) & "/items.json",
            """{"items": [{"id": 1, "title": "T", "sources": []}], "seen": {}}""")
  assert "Compare with Nim</button>" in readOr(buildPages(Solo, some(example)) & "/i1.html"),
    "--config reaches the pages"

block single_agent_session_pages:  # WorkItemTests.test_single_agent_session (its page part)
  resetState()
  fakeModel("""{"split": [{"title": "Parser accepts empty input", "handles": ["C1", "T1"]},
                          {"title": "Quotes are escaped", "handles": ["C2", "T1", "T2"]}]}""")
  discard cli(["brief"], Solo)
  let dir = buildPages(Solo)
  assert fileExists(dir & "/i1.html") and fileExists(dir & "/i2.html"), "a page per item"
  assert "<link rel=\"next\" href=\"i2.html\">" in readOr(dir & "/i1.html"), "the next item"
  assert "<link rel=\"prev\" href=\"i1.html\">" in readOr(dir & "/i2.html"), "the previous item"

tearDown()
