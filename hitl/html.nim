## What the page templates need besides themselves: HTML escaping, the
## markdown subset agents write, source lines without clock times, the lanes of
## the index, the files and hunks of a diff, and the glue that lets the
## stdtmpl templates emit no line breaks.

import std/[strutils, parseutils, opt]
import items

proc esc*(s: string): string =
  ## Text as HTML, quotes included, so it may stand in an attribute too.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#x27;"
    else: result.add c

proc plural*(n: int; word: string): string =
  $n & " " & word & (if n != 1: "s" else: "")

# ------------------------------------------------------------ template glue
# stdtmpl ends every data line with "\n"; the pages have no line breaks. The
# templates run with `conc = " &~ "`, `toString = "val"` and `emit = "put
# result,"`: a literal piece loses its line-end newline, a value from ${...} is
# kept byte for byte.

type
  Val* = distinct string   ## a substituted value
  Html* = distinct string  ## the pieces joined so far

proc lit(s: string): string {.inline.} =
  if s.endsWith('\n'): s.substr(0, s.len - 2) else: s
proc val*(s: string): Val {.inline.} = Val(s)
proc val*(n: int): Val {.inline.} = Val($n)
proc val*(id: ItemId): Val {.inline.} = Val($id)
proc `&~`*(a, b: string): Html {.inline.} = Html(lit(a) & lit(b))
proc `&~`*(a: string; b: Val): Html {.inline.} = Html(lit(a) & string(b))
proc `&~`*(a: Html; b: string): Html {.inline.} = Html(string(a) & lit(b))
proc `&~`*(a: Html; b: Val): Html {.inline.} = Html(string(a) & string(b))
proc put*(r: var string; s: string) {.inline.} = r.add lit(s)
proc put*(r: var string; s: Html) {.inline.} = r.add string(s)

# ------------------------------------------------------- lanes and sections

const SectionTitles*: array[Section, string] = [
  "Decisions for you", "Contradicts the spec", "Needs another review",
  "Could cause more bugs", "Decisions made"]

type Lane* = enum   ## an item goes into the first lane that applies; the order never changes
  laneDecide = "decide", laneReview = "review", laneClear = "clear"

const LaneTitles*: array[Lane, string] = ["Waiting for your decision", "Needs another review", "Nothing open"]

proc laneOf*(brief: Opt[Cached]): Lane =
  ## Without a brief, an item needs reading first.
  case brief
  of None: result = laneReview
  of Some(c):
    if c.brief.decisions.len > 0: result = laneDecide
    elif c.brief.count(secSpecConflicts) > 0 or c.brief.count(secNeedsReview) > 0: result = laneReview
    else: result = laneClear

proc cardStatus*(brief: Opt[Cached]): string =
  ## A card's status line: the exact number of decisions, in the decision lane only.
  case brief
  of None: result = "No brief yet"
  of Some(c): result = if laneOf(brief) == laneDecide: plural(c.brief.decisions.len, "decision") else: ""

# --------------------------------------------------------------------- diffs

type
  DiffFile* = object
    path*: string
    rows*: seq[string]   ## the lines after its header
    added*, removed*: int
  Hunk* = object
    old*, new*: int      ## the first line's number in the old and the new file
    title*: string       ## what follows the second "@@"

proc diffFiles*(diff: string): seq[DiffFile] =
  ## The diff's files, each with its lines.
  const Headers = ["index ", "--- ", "+++ ", "similarity ", "rename ", "new file", "deleted file",
                   "old mode", "new mode"]
  result = @[]
  for line in diff.splitLines:
    if line.startsWith("diff --git "):   # diff --git a/<old> b/<new>
      let b = line.find(" b/", len("diff --git a/") + 1)
      result.add DiffFile(path: (if b > 0: line.substr(b + 3) else: line), rows: @[])
    elif result.len > 0:
      var header = false
      for h in Headers:
        if line.startsWith(h): header = true
      if not header:
        result[^1].rows.add line
        if line.startsWith("+"): inc result[^1].added
        elif line.startsWith("-"): inc result[^1].removed

proc lineRange(line: string; k: var int; first: var BiggestInt): bool =
  ## "12" or "12,7" at k: the first line's number; k moves past it.
  let n = parseBiggestInt(line.toOpenArray(k, line.high), first)
  if n > 0:
    k += n
    if line.continuesWith(",", k):
      var count: BiggestInt = 0
      let m = parseBiggestInt(line.toOpenArray(k + 1, line.high), count)
      if m > 0: k += 1 + m
  n > 0

proc hunk*(line: string): Opt[Hunk] =
  ## A hunk header, "@@ -12,7 +12,9 @@ proc a()", else none.
  result = none[Hunk]()
  var old, new: BiggestInt = 0
  var k = len("@@ -")
  if line.startsWith("@@ -") and lineRange(line, k, old) and line.continuesWith(" +", k):
    k += 2
    if lineRange(line, k, new) and line.continuesWith(" @@", k):
      result = some(Hunk(old: int(old), new: int(new), title: line.substr(k + 3)))

# ------------------------------------------------------------------ inline
# Inline markdown, applied in order to escaped text outside code spans: bold,
# emphasis, links, then bare URLs. A word character is an ASCII letter, digit
# or `_`, or any byte of a non-ASCII character.

proc isWord(c: char): bool {.inline.} = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}

proc closing(s: string; mark: string; start: int; ok: proc (s: string; j: int): bool {.nimcall.}): int =
  ## Where the span that starts at `start` closes: the first j after it, on
  ## its line, where `mark` begins and ok(s, j) holds; -1 if none.
  result = -1
  var j = start
  while j < s.len and s[j] != '\n' and result < 0:
    if j > start and s.continuesWith(mark, j) and ok(s, j): result = j
    inc j

proc anyEnd(s: string; j: int): bool = true

proc emEnd(s: string; j: int): bool =
  not (s[j-1] in Whitespace) and (j + 1 >= s.len or not (isWord(s[j+1]) or s[j+1] == '*'))

proc bold(s: string): string =
  ## **text** on one line: <strong>
  result = ""
  var i = 0
  while i < s.len:
    let close = if s.continuesWith("**", i): closing(s, "**", i + 2, anyEnd) else: -1
    if close > 0:
      result.add "<strong>" & s.substr(i + 2, close - 1) & "</strong>"
      i = close + 2
    else:
      result.add s[i]
      inc i

proc em(s: string): string =
  ## *text* on one line, the stars not touching words or spaces inside: <em>
  result = ""
  var i = 0
  while i < s.len:
    let opens = s[i] == '*' and (i == 0 or not (isWord(s[i-1]) or s[i-1] == '*')) and
                i + 1 < s.len and s[i+1] notin Whitespace
    let close = if opens: closing(s, "*", i + 1, emEnd) else: -1
    if close > 0:
      result.add "<em>" & s.substr(i + 1, close - 1) & "</em>"
      i = close + 1
    else:
      result.add s[i]
      inc i

proc urlEnd(s: string; start: int; stop: set[char]): int =
  ## The end of `http(s)://` and one or more characters not in `stop`, or -1.
  result = -1
  for scheme in ["https://", "http://"]:
    if result < 0 and s.continuesWith(scheme, start):
      var k = start + scheme.len
      while k < s.len and s[k] notin stop: inc k
      if k > start + scheme.len: result = k

proc links(s: string): string =
  ## [text](http...) : <a>
  result = ""
  var i: Natural = 0
  while i < s.len:
    var close, e = -1
    if s[i] == '[': close = s.find(']', i + 1)
    if close > i + 1 and s.continuesWith("(", close + 1): e = urlEnd(s, close + 2, Whitespace + {')'})
    if e > 0 and e < s.len and s[e] == ')':
      result.add "<a href=\"" & s.substr(close + 2, e - 1) & "\">" & s.substr(i + 1, close - 1) & "</a>"
      i = e + 1
    else:
      result.add s[i]
      inc i

proc autolinks(s: string): string =
  ## A bare http(s) URL, not just after a quote, '>' or '=': <a>
  result = ""
  var i = 0
  while i < s.len:
    let e = if i == 0 or s[i-1] notin {'"', '\'', '>', '='}: urlEnd(s, i, Whitespace + {'<', ')'})
            else: -1
    if e > 0:
      let url = s.substr(i, e - 1)
      result.add "<a href=\"" & url & "\">" & url & "</a>"
      i = e
    else:
      result.add s[i]
      inc i

proc inline*(text: string): string =
  ## Escaped text with code spans, bold, emphasis and links.
  let s = esc(text)
  result = ""
  var plain = ""
  var i: Natural = 0
  while i < s.len:
    var close = -1
    if s[i] == '`': close = s.find('`', i + 1)
    if close > i + 1:
      result.add autolinks(links(em(bold(plain))))
      result.add "<code>" & s.substr(i + 1, close - 1) & "</code>"
      plain = ""
      i = close + 1
    else:
      plain.add s[i]
      inc i
  result.add autolinks(links(em(bold(plain))))

# ---------------------------------------------------------------- markdown

proc heading(line: string; text: var string): int =
  ## The level of a "## Title" line (its text in `text`), else 0.
  var n = 0
  while n < line.len and line[n] == '#': inc n
  result = 0
  if n in 1..6 and n < line.len and line[n] in Whitespace:
    text = line.substr(n).strip(trailing = false)
    result = n

type ListItem = object
  indent: int     ## the spaces before the marker
  ordered: bool   ## "1." rather than "-" or "*"
  text: string

proc listItem(line: string): Opt[ListItem] =
  ## A "- item", "* item" or "1. item" line.
  result = none[ListItem]()
  let indent = line.len - line.strip(trailing = false).len
  var k = indent
  var ordered = false
  if k < line.len and line[k] in {'-', '*'}: inc k
  else:
    while k < line.len and line[k] in Digits: inc k
    if k > indent and line.continuesWith(".", k):
      inc k
      ordered = true
    else: k = indent
  if k > indent and k < line.len and line[k] in Whitespace:
    result = some(ListItem(indent: indent, ordered: ordered, text: line.substr(k).strip(trailing = false)))

proc isTableRule(line: string): bool =
  ## |---|:--:| and the like.
  line.len > 1 and line[0] == '|' and line.substr(1).allCharsInSet(Whitespace + {':', '|', '-'})

proc cells(line: string): seq[string] =
  result = @[]
  for c in line.strip.strip(chars = {'|'}).split('|'): result.add c.strip

proc startsBlock(line: string): bool =
  var text = ""
  heading(line, text) > 0 or line.startsWith("```") or line.startsWith("|") or
    line.startsWith(">") or listItem(line).isSome

proc markdown*(src: string): string =
  ## The subset agents write: headings, paragraphs, lists, tables, quotes, code.
  let lines = src.replace("\r", "").split('\n')
  var parts: seq[string] = @[]
  var i = 0
  while i < lines.len:
    let line = lines[i]
    var text = ""
    let level = heading(line, text)
    let item = listItem(line)
    if line.startsWith("```"):
      var j = i + 1
      while j < lines.len and not lines[j].startsWith("```"): inc j
      parts.add "<pre class=\"code\" data-lang=\"" & esc(line.substr(3).strip) & "\"><code>" &
        esc(lines[i + 1 ..< min(j, lines.len)].join("\n")) & "</code></pre>"
      i = j + 1
    elif level > 0:
      let h = $min(level + 1, 6)   # the page owns h1
      parts.add "<h" & h & ">" & inline(text) & "</h" & h & ">"
      inc i
    elif line.startsWith("|") and i + 1 < lines.len and isTableRule(lines[i + 1]):
      var t = "<div class=\"table\"><table><thead><tr>"
      for c in cells(line): t.add "<th>" & inline(c) & "</th>"
      t.add "</tr></thead><tbody>"
      i += 2
      while i < lines.len and lines[i].startsWith("|"):
        t.add "<tr>"
        for c in cells(lines[i]): t.add "<td>" & inline(c) & "</td>"
        t.add "</tr>"
        inc i
      parts.add t & "</tbody></table></div>"
    elif item.isSome:
      let first = item.get(ListItem())
      let tag = if first.ordered: "ol" else: "ul"
      var h = "<" & tag & ">"
      var items: seq[ListItem] = @[]
      while i < lines.len and (listItem(lines[i]).isSome or
          (items.len > 0 and lines[i].startsWith("  ") and not lines[i].isEmptyOrWhitespace)):
        let x = listItem(lines[i])
        if x.isSome: items.add x.get(ListItem())
        else: items[^1].text.add " " & lines[i].strip   # a continuation line
        inc i
      var nested = false
      for x in items:
        if x.indent > first.indent and not nested: h.add "<ul>"
        if x.indent <= first.indent and nested: h.add "</ul>"
        nested = x.indent > first.indent
        h.add "<li>" & inline(x.text) & "</li>"
      if nested: h.add "</ul>"
      parts.add h & "</" & tag & ">"
    elif line.startsWith(">"):
      var quote: seq[string] = @[]
      while i < lines.len and lines[i].startsWith(">"):
        quote.add lines[i].strip(trailing = false, chars = {'>'}).strip
        inc i
      parts.add "<blockquote>" & markdown(quote.join("\n")) & "</blockquote>"
    elif line.isEmptyOrWhitespace: inc i
    else:
      var para: seq[string] = @[]
      while i < lines.len and not lines[i].isEmptyOrWhitespace and (para.len == 0 or not startsBlock(lines[i])):
        para.add lines[i].strip
        inc i
      parts.add "<p>" & inline(para.join(" ")) & "</p>"
  parts.join("\n")

# --------------------------------------------------------------- source lines
# A brief's source names its evidence ("the fixer's report 10:01"); the page
# shows it without clock times, which DESIGN.md keeps off the pages.

const Months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

proc skipSpaces(s: string; k: int): int =
  result = k
  while result < s.len and s[result] in Whitespace: inc result

proc clockEnd(s: string; d: int): int =
  ## The end of a time at d ("9:05", "17:57:03"), not inside a word, number or path; -1 if none.
  proc free(s: string; e: int): bool = e >= s.len or not (isWord(s[e]) or s[e] == ':')
  result = -1
  if d < s.len and s[d] in Digits and (d == 0 or not (isWord(s[d-1]) or s[d-1] in {':', '.', '/', '-'})):
    var k = d
    while k < s.len and k - d < 2 and s[k] in Digits: inc k
    if s.continuesWith(":", k) and k + 2 < s.len and s[k + 1] in Digits and s[k + 2] in Digits:
      let mm = k + 3
      if mm + 2 < s.len and s[mm] == ':' and s[mm + 1] in Digits and s[mm + 2] in Digits and free(s, mm + 3):
        result = mm + 3
      elif free(s, mm): result = mm

proc dateEnd(s: string; k: int): int =
  ## Where the time starts after a date at k ("Nov 9, ", "Sept. 9 "), or -1.
  result = -1
  var month = false
  for m in Months:
    if s.continuesWith(m, k): month = true
  if month and (k == 0 or not isWord(s[k-1])):
    var j = k + 3
    while j < s.len and s[j] in {'a'..'z'}: inc j
    if s.continuesWith(".", j): inc j
    let day = skipSpaces(s, j)
    var digits = 0
    while day + digits < s.len and s[day + digits] in Digits: inc digits
    if day > j:
      for n in countdown(min(digits, 2), 1):   # a one- or two-digit day
        var e = day + n
        if result < 0 and not (e < s.len and s[e] in Digits):
          if s.continuesWith(",", e): inc e
          let t = skipSpaces(s, e)
          if t > e and clockEnd(s, t) >= 0: result = t

proc clockMatch(s: string; i: int): int =
  ## The end of "at 17:57", "on Nov 9 17:57", "Nov 9 17:57" or "17:57" at i, or -1.
  result = -1
  if (s.continuesWith("at", i) or s.continuesWith("on", i)) and (i == 0 or not isWord(s[i-1])):
    let t = skipSpaces(s, i + 2)
    if t > i + 2:
      let d = dateEnd(s, t)
      result = clockEnd(s, if d >= 0: d else: t)
  if result < 0:
    let d = dateEnd(s, i)
    result = clockEnd(s, if d >= 0: d else: i)

proc untimed*(src: string): string =
  ## The evidence pointer without its clock times: "fixer 10:01" -> "fixer".
  var s = ""
  var i = 0
  while i < src.len:   # the times, with "at"/"on" and a date before them
    let e = clockMatch(src, i)
    if e > i: i = e
    else:
      s.add src[i]
      inc i
  var t = ""
  i = 0
  while i < s.len:     # "()" and "[]" they leave
    let k = if s[i] in {'(', '['}: skipSpaces(s, i + 1) else: -1
    if k >= 0 and k < s.len and s[k] == (if s[i] == '(': ')' else: ']'): i = k + 1
    else:
      t.add s[i]
      inc i
  var u = ""
  i = 0
  while i < t.len:     # spaces before ',', ';' and ')'
    let k = skipSpaces(t, i)
    if k > i and k < t.len and t[k] in {',', ';', ')'}: i = k
    elif k > i:
      u.add t.substr(i, k - 1)
      i = k
    else:
      u.add t[i]
      inc i
  var v = ""
  i = 0
  while i < u.len:     # an opener or separator right before a separator or ')'
    let k = if u[i] in {'(', ',', ';'}: skipSpaces(u, i + 1) else: -1
    if k >= 0 and k < u.len and u[k] in {',', ';', ')'}: i = k
    else:
      v.add u[i]
      inc i
  var w = ""
  i = 0
  while i < v.len:     # runs of spaces as one
    let k = skipSpaces(v, i)
    if k - i >= 2:
      w.add ' '
      i = k
    else:
      w.add v[i]
      inc i
  var parts: seq[string] = @[]
  for p in w.split(';'):   # each part once
    let q = p.strip(chars = {' ', ','})
    if q.len > 0 and q notin parts: parts.add q
  parts.join("; ")
