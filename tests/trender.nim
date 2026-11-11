## HTML, escaped by default (test_hitl.py RenderTests).

import std/[strutils, assertions, rex, opt]
import ../hitl/render

const Markdown = [  # (source, HTML): the subset, and what stays as written
  ("# T", "<h2>T</h2>"),                                         # the page owns h1
  ("## Title ##", "<h3>Title</h3>"),
  ("#hashtag", "<p>#hashtag</p>"),
  ("A `x<y` and **b**.", "<p>A <code>x&lt;y</code> and <strong>b</strong>.</p>"),
  ("use `a*b*c` and `**kw`", "<p>use <code>a*b*c</code> and <code>**kw</code></p>"),
  ("**use `x` now**", "<p><strong>use <code>x</code> now</strong></p>"),
  ("``a ` b``", "<p><code>a ` b</code></p>"),
  ("a ` b", "<p>a ` b</p>"),
  (r"\*not em\*", "<p>*not em*</p>"),
  ("snake_case and __init__", "<p>snake_case and __init__</p>"),
  ("2 * 3 * 4", "<p>2 * 3 * 4</p>"),
  ("[spec](https://x.org/a_(b))", "<p><a href=\"https://x.org/a_(b)\">spec</a></p>"),
  ("[`foo`](https://x.org)", "<p><a href=\"https://x.org\"><code>foo</code></a></p>"),
  ("see https://x.org/a.", "<p>see <a href=\"https://x.org/a\">https://x.org/a</a>.</p>"),
  ("<https://x.org/a>", "<p><a href=\"https://x.org/a\">https://x.org/a</a></p>"),
  ("[x](javascript:alert(1))", "<p>[x](javascript:alert(1))</p>"),     # only http(s) links
  ("a <script>x</script>", "<p>a &lt;script&gt;x&lt;/script&gt;</p>"),
  ("[x](https://x.org/\"onmouseover=\"a)",
   "<p><a href=\"https://x.org/&quot;onmouseover=&quot;a\">x</a></p>"),
  ("line one\nline two", "<p>line one line two</p>"),
  ("- a\n  - b\n    - c\n- d",
   "<ul><li>a<ul><li>b<ul><li>c</li></ul></li></ul></li><li>d</li></ul>"),
  ("3. three\n4. four", "<ol start=\"3\"><li>three</li><li>four</li></ol>"),
  ("1. one\n  - sub\n2. two", "<ol><li>one<ul><li>sub</li></ul></li><li>two</li></ol>"),
  ("- a\n\n- b", "<ul><li><p>a</p></li><li><p>b</p></li></ul>"),
  ("- run:\n  ```sh\n  ls\n  ```",
   "<ul><li>run:<pre class=\"code\" data-lang=\"sh\"><code>ls</code></pre></li></ul>"),
  ("- a\ncontinued", "<ul><li>a continued</li></ul>"),
  ("```nim\necho 1\n```", "<pre class=\"code\" data-lang=\"nim\"><code>echo 1</code></pre>"),
  ("  ```\n  x\n  ```", "<pre class=\"code\" data-lang=\"\"><code>x</code></pre>"),
  ("```\nno end", "<pre class=\"code\" data-lang=\"\"><code>no end</code></pre>"),
  ("~~~\n```x```\n~~~", "<pre class=\"code\" data-lang=\"\"><code>```x```</code></pre>"),
  ("| a | b |\n|---|---|\n| 1 | 2 |",
   "<div class=\"table\"><table><thead><tr><th>a</th><th>b</th></tr></thead>" &
   "<tbody><tr><td>1</td><td>2</td></tr></tbody></table></div>"),
  ("a | b\n--|--\n1 | 2",
   "<div class=\"table\"><table><thead><tr><th>a</th><th>b</th></tr></thead>" &
   "<tbody><tr><td>1</td><td>2</td></tr></tbody></table></div>"),
  ("| a | b |\n|---|---|\n| `x|y` | 2 |", "<td><code>x|y</code></td><td>2</td>"),
  ("| a | b |\n|---|---|\n| x\\|y | 2 |", "<td>x|y</td><td>2</td>"),
  ("| a | b |\n|---|---|\n| 1 |", "<td>1</td><td></td>"),
  ("a | b\nplain", "<p>a | b plain</p>"),
  ("before\n| not a table\nafter", "<p>before | not a table after</p>"),
  ("a\n\n---\n\nb", "<p>a</p>\n<hr>\n<p>b</p>"),
  ("> **x** and `y`\n> - item",
   "<blockquote><p><strong>x</strong> and <code>y</code></p>\n<ul><li>item</li></ul></blockquote>"),
]

block markdown_subset:  # RenderTests.test_markdown_subset
  for (src, want) in Markdown:
    let got = $markdown(src)
    # a table cell case names only the cells
    assert (if want.startsWith("<td>"): want in got else: got == want), src & " -> " & got

block text_is_escaped_unless_it_is_markup:  # RenderTests.test_text_is_escaped_unless_it_is_markup
  let p = tag("p", [attr("title", "\"x\""), attr("hidden", true), attr("id", none[string]())],
              "<b>", tag("i", [], "&"))
  assert $p == "<p title=\"&quot;x&quot;\" hidden>&lt;b&gt;<i>&amp;</i></p>",
    "attributes and text escaped, markup kept"
  assert $join([toHtml("<"), raw("<br>")]) == "&lt;<br>", "join escapes text"
  assert $tag("td", [], 0) == "<td>0</td>", "a number"

type Diffed = object
  ## What a rendered diff shows (RenderTests.diffed).
  n: int                          # files
  paths: seq[string]              # the paths of the shown files
  stats: seq[(string, string)]    # each file's (added, removed)
  rows: seq[string]               # each table row, every tag a `|`
  html: string

let
  tagRe = re"<[^>]+>"
  pathRe = re"""class=\"path\">([^<]*)"""
  statRe = re"<ins>([^<]*)</ins>\ <del>([^<]*)</del>"

proc groups(s: string; r: Regex): seq[seq[string]] =
  ## The groups of every match of r in s, left to right (Python's findall).
  result = @[]
  var caps: seq[Capture] = @[]
  var (a, b) = findBounds(s, r, caps, 0)
  while a >= 0:
    result.add captureTexts(s, caps)
    (a, b) = findBounds(s, r, caps, b + 1)

proc diffed(d: string; limit = 600_000): Diffed =
  ## The rendered diff, taken apart for the asserts.
  let (h, n) = diff(d, limit)
  let html = $h
  result = Diffed(n: n, paths: @[], stats: @[], rows: @[], html: html)
  let pieces = html.split("<tr")
  for k in 1 ..< pieces.len:   # every row starts a piece and ends inside it
    let row = "<tr" & pieces[k].substr(0, pieces[k].find("</tr>") + len("</tr>") - 1)
    result.rows.add row.replace(tagRe, "|")
  for g in groups(html, pathRe): result.paths.add g[0]
  for g in groups(html, statRe): result.stats.add (g[0], g[1])

block diff_reads_hunks_by_their_counts:  # RenderTests.test_diff_reads_hunks_by_their_counts
  # a removed "-- x" and an added "++ x" look like the ---/+++ header lines
  var d = diffed("diff --git a/q.sql b/q.sql\n--- a/q.sql\n+++ b/q.sql\n" &
                 "@@ -1,3 +1,3 @@\n a\n--- x\n+++ y\n b\n")
  assert d.n == 1 and d.paths == @["q.sql"] and d.stats == @[("+1", "−1")], "one file, one change"
  assert "|2||||−||-- x|" in d.rows[2], d.rows[2]
  assert "||2||+||++ y|" in d.rows[3], d.rows[3]
  d = diffed("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a<\n" &
             "\\ No newline at end of file\n+b\n")
  assert d.stats == @[("+1", "−1")], "\"\\ No newline\" is no line"
  assert "|1||||−||a&lt;|" in d.rows[1], d.rows[1]

block diff_names_files_and_says_what_has_no_lines:
  # RenderTests.test_diff_names_files_and_says_what_has_no_lines
  const cases = [
    ("diff --git a/x b/y.txt b/x b/y.txt\n--- a/x b/y.txt\n+++ b/x b/y.txt\n@@ -1 +1 @@\n-1\n+2\n",
     "x b/y.txt", ""),
    ("diff --git \"a/\\303\\251.txt\" \"b/\\303\\251.txt\"\n--- \"a/\\303\\251.txt\"\n" &
     "+++ \"b/\\303\\251.txt\"\n@@ -1 +1 @@\n-a\n+b\n", "é.txt", ""),
    ("diff --git a/old.nim b/new.nim\nsimilarity index 100%\n" &
     "rename from old.nim\nrename to new.nim\n",
     "new.nim", "Renamed from old.nim"),
    ("diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n", "run.sh",
     "Now executable"),
    ("diff --git a/i.ico b/i.ico\nnew file mode 100644\n" &
     "Binary files /dev/null and b/i.ico differ\n",
     "i.ico", "Binary file"),
    ("diff --git a/g b/g\ndeleted file mode 100644\n--- a/g\n+++ /dev/null\n@@ -1 +0,0 @@\n-a\n",
     "g", ""),
  ]
  for (text, path, note) in cases:
    let d = diffed(text)
    assert d.paths == @[path], path & ": " & d.paths.join(", ")
    if note.len > 0: assert note in d.rows[0], path & ": " & d.rows[0]

block a_large_diff_names_what_it_does_not_show:
  # RenderTests.test_a_large_diff_names_what_it_does_not_show
  var big = ""
  for i in 0 ..< 5:
    big.add "diff --git a/f" & $i & " b/f" & $i & "\n--- a/f" & $i & "\n+++ b/f" & $i &
      "\n@@ -1 +1 @@\n-" & 'x'.repeat(50) & "\n+" & 'y'.repeat(50) & "\n"
  let d = diffed(big, limit = 300)
  assert d.n == 5 and d.paths == @["f0", "f1"], "whole files, never cut inside one"
  assert "3 more files not shown" in d.html, "the rest are counted"
