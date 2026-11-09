## HTML text helpers for the pages and the chat: escaping, the inline and block
## markdown subset agents write (review.py's `inline` and `markdown`), and the
## glue that lets the stdtmpl page templates emit no line breaks.

import std/strutils

proc esc*(s: string): string =
  ## html.escape(s, quote=True)
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
# templates run with `conc = " &~ "`, `tostring = "val"` and `emit = "put
# result,"`: a literal piece loses its line-end newline, a value from ${...} is
# kept byte for byte.

type
  Val* = distinct string   ## a substituted value
  Html* = distinct string  ## the pieces joined so far

proc lit(s: string): string {.inline.} =
  if s.endsWith('\n'): s.substr(0, s.len - 2) else: s
proc val*(s: string): Val {.inline.} = Val(s)
proc val*(n: int): Val {.inline.} = Val($n)
proc `&~`*(a, b: string): Html {.inline.} = Html(lit(a) & lit(b))
proc `&~`*(a: string; b: Val): Html {.inline.} = Html(lit(a) & string(b))
proc `&~`*(a: Html; b: string): Html {.inline.} = Html(string(a) & lit(b))
proc `&~`*(a: Html; b: Val): Html {.inline.} = Html(string(a) & string(b))
proc put*(r: var string; s: string) {.inline.} = r.add lit(s)
proc put*(r: var string; s: Html) {.inline.} = r.add string(s)

# ------------------------------------------------------------------ inline
# review.INLINE, applied in order to escaped text outside code spans. Its
# patterns use lookaround and lazy repeats, which std/rex does not have, so they
# are scanners. A word character is an ASCII letter, digit or `_`, or any byte
# of a non-ASCII character.

proc isWord(c: char): bool {.inline.} = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}
proc isSpace*(c: char): bool {.inline.} = c in {' ', '\t', '\n', '\r', '\f', '\v'}

proc bold(s: string): string =
  ## \*\*(.+?)\*\*  ->  <strong>\1</strong>
  result = ""
  var i = 0
  while i < s.len:
    if i + 1 < s.len and s[i] == '*' and s[i+1] == '*':
      var j = i + 3          # at least one character between
      var found = -1
      while j + 1 < s.len and s[j-1] != '\n':
        if s[j] == '*' and s[j+1] == '*':
          found = j
          break
        inc j
      if found >= 0 and '\n' notin s.substr(i + 2, found - 1):
        result.add "<strong>" & s.substr(i + 2, found - 1) & "</strong>"
        i = found + 2
        continue
    result.add s[i]
    inc i

proc em(s: string): string =
  ## (?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])  ->  <em>\1</em>
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '*' and (i == 0 or not (isWord(s[i-1]) or s[i-1] == '*')) and
        i + 1 < s.len and not isSpace(s[i+1]):
      var j = i + 2
      var found = -1
      while j < s.len and s[j-1] != '\n':
        if s[j] == '*' and not isSpace(s[j-1]) and
            (j + 1 >= s.len or not (isWord(s[j+1]) or s[j+1] == '*')):
          found = j
          break
        inc j
      if found >= 0 and '\n' notin s.substr(i + 1, found - 1):
        result.add "<em>" & s.substr(i + 1, found - 1) & "</em>"
        i = found + 1
        continue
    result.add s[i]
    inc i

proc urlEnd(s: string; start: int; stop: set[char]): int =
  ## The end of `https?://` and one or more characters not in `stop`, or -1.
  var k = start
  if s.continuesWith("https://", k): k += 8
  elif s.continuesWith("http://", k): k += 7
  else: return -1
  let first = k
  while k < s.len and s[k] notin stop: inc k
  result = if k > first: k else: -1

proc links(s: string): string =
  ## \[([^\]]+)\]\((https?://[^)\s]+)\)  ->  <a href="\2">\1</a>
  result = ""
  var i: Natural = 0
  while i < s.len:
    if s[i] == '[':
      let close = s.find(']', i + 1)
      if close > i + 1 and close + 1 < s.len and s[close+1] == '(':
        let e = urlEnd(s, close + 2, {')', ' ', '\t', '\n', '\r', '\f', '\v'})
        if e > 0 and e < s.len and s[e] == ')':
          result.add "<a href=\"" & s.substr(close + 2, e - 1) & "\">" & s.substr(i + 1, close - 1) & "</a>"
          i = e + 1
          continue
    result.add s[i]
    inc i

proc autolinks(s: string): string =
  ## (?<!["'>=])(https?://[^\s<)]+)  ->  <a href="\1">\1</a>
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == 'h' and (i == 0 or s[i-1] notin {'"', '\'', '>', '='}):
      let e = urlEnd(s, i, {'<', ')', ' ', '\t', '\n', '\r', '\f', '\v'})
      if e > 0:
        let u = s.substr(i, e - 1)
        result.add "<a href=\"" & u & "\">" & u & "</a>"
        i = e
        continue
    result.add s[i]
    inc i

proc inline*(text: string): string =
  ## parts = re.split(r"(`[^`]+`)", esc(text)); a part that starts and ends
  ## with a backtick becomes code, the rest goes through the other patterns.
  let s = esc(text)
  var parts: seq[string] = @[]
  var i: Natural = 0
  var plain = ""
  while i < s.len:
    if s[i] == '`':
      let close = s.find('`', i + 1)
      if close > i + 1:
        parts.add plain
        parts.add s.substr(i, close)
        plain = ""
        i = close + 1
        continue
    plain.add s[i]
    inc i
  parts.add plain
  result = ""
  for p in parts:
    if p.len > 1 and p[0] == '`' and p[^1] == '`':
      result.add "<code>" & p.substr(1, p.len - 2) & "</code>"
    else:
      result.add autolinks(links(em(bold(p))))

# ---------------------------------------------------------------- markdown

proc headingLevel(line: string; rest: var string): int =
  ## ^(#{1,6})\s+(.*)$ : the number of #, and the text after the spaces; 0 if none.
  var n = 0
  while n < line.len and line[n] == '#': inc n
  if n < 1 or n > 6 or n >= line.len or not isSpace(line[n]): return 0
  var k = n
  while k < line.len and isSpace(line[k]): inc k
  rest = line.substr(k)
  n

proc listMarker(line: string; indent, textAt: var int; ordered: var bool): bool =
  ## ^(\s*)([-*]|\d+\.)\s+(.*)$
  var k = 0
  while k < line.len and isSpace(line[k]): inc k
  indent = k
  if k < line.len and line[k] in {'-', '*'}:
    ordered = false
    inc k
  elif k < line.len and line[k] in Digits:
    while k < line.len and line[k] in Digits: inc k
    if k >= line.len or line[k] != '.': return false
    ordered = true
    inc k
  else: return false
  if k >= line.len or not isSpace(line[k]): return false
  while k < line.len and isSpace(line[k]): inc k
  textAt = k
  true

proc isListLine(line: string): bool =
  var a, b = 0
  var o = false
  listMarker(line, a, b, o)

proc isTableRule(line: string): bool =
  ## ^\|[\s:|-]+\|?\s*$
  if line.len < 2 or line[0] != '|': return false
  for k in 1 ..< line.len:
    if not (isSpace(line[k]) or line[k] in {':', '|', '-'}): return false
  true

proc cells(line: string): seq[string] =
  ## [c.strip() for c in line.strip().strip("|").split("|")]
  result = @[]
  for c in line.strip.strip(chars = {'|'}).split('|'): result.add c.strip

proc markdown*(src: string): string =
  ## The subset agents write: headings, paragraphs, lists, tables, quotes, code.
  let lines = src.replace("\r", "").split('\n')
  var parts: seq[string] = @[]
  var i = 0
  while i < lines.len:
    let line = lines[i]
    var rest = ""
    if line.startsWith("```"):
      let lang = line.substr(3).strip
      var j = i + 1
      while j < lines.len and not lines[j].startsWith("```"): inc j
      var code: seq[string] = @[]
      for k in i + 1 ..< min(j, lines.len): code.add lines[k]
      parts.add "<pre class=\"code\" data-lang=\"" & esc(lang) & "\"><code>" & esc(code.join("\n")) & "</code></pre>"
      i = j + 1
      continue
    let level = headingLevel(line, rest)
    if level > 0:
      let lvl = min(level + 1, 6)   # the page owns h1
      parts.add "<h" & $lvl & ">" & inline(rest) & "</h" & $lvl & ">"
      inc i
      continue
    if line.startsWith("|") and i + 1 < lines.len and isTableRule(lines[i + 1]):
      var rows: seq[seq[string]] = @[]
      while i < lines.len and lines[i].startsWith("|"):
        rows.add cells(lines[i])
        inc i
      var t = "<div class=\"table\"><table><thead><tr>"
      for c in rows[0]: t.add "<th>" & inline(c) & "</th>"
      t.add "</tr></thead><tbody>"
      for r in 2 ..< rows.len:
        t.add "<tr>"
        for c in rows[r]: t.add "<td>" & inline(c) & "</td>"
        t.add "</tr>"
      parts.add t & "</tbody></table></div>"
      continue
    var indent0, textAt = 0
    var ordered = false
    if listMarker(line, indent0, textAt, ordered):
      var items: seq[(bool, string)] = @[]
      while i < lines.len:
        let ln = lines[i]
        var ind, at = 0
        var o = false
        if listMarker(ln, ind, at, o): items.add (ind > indent0, ln.substr(at))
        elif ln.startsWith("  ") and ln.strip.len > 0 and items.len > 0: items[^1][1].add " " & ln.strip
        else: break
        inc i
      let tag = if ordered: "ol" else: "ul"
      var h = "<" & tag & ">"
      var openSub = false
      for (nested, text) in items:
        if nested and not openSub:
          h.add "<ul>"
          openSub = true
        if not nested and openSub:
          h.add "</ul>"
          openSub = false
        h.add "<li>" & inline(text) & "</li>"
      if openSub: h.add "</ul>"
      parts.add h & "</" & tag & ">"
      continue
    if line.startsWith(">"):
      var quote: seq[string] = @[]
      while i < lines.len and lines[i].startsWith(">"):
        quote.add lines[i].strip(trailing = false, chars = {'>'}).strip
        inc i
      parts.add "<blockquote>" & markdown(quote.join("\n")) & "</blockquote>"
      continue
    if line.strip.len == 0:
      inc i
      continue
    var para: seq[string] = @[]
    while i < lines.len and lines[i].strip.len > 0:
      let l = lines[i]
      var r2 = ""
      if headingLevel(l, r2) > 0 or l.startsWith("```") or l.startsWith("|") or l.startsWith(">") or
          isListLine(l): break
      para.add l.strip
      inc i
    if para.len > 0: parts.add "<p>" & inline(para.join(" ")) & "</p>"
    else: inc i
  parts.join("\n")

# ------------------------------------------------------------------- times

const Months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

proc clockAt(s: string; d: int): int =
  ## The end of `\d{1,2}:\d{2}(?::\d{2})?(?![\w:])` at d, with (?<![\w:./-]) before it; -1 if none.
  if d >= s.len or s[d] notin Digits: return -1
  if d > 0 and (isWord(s[d-1]) or s[d-1] in {':', '.', '/', '-'}): return -1
  var k = d
  while k < s.len and k - d < 2 and s[k] in Digits: inc k
  if k >= s.len or s[k] != ':': return -1
  if k + 2 >= s.len or s[k + 1] notin Digits or s[k + 2] notin Digits: return -1
  let mm = k + 3
  proc freeAfter(s: string; e: int): bool = e >= s.len or not (isWord(s[e]) or s[e] == ':')
  if mm + 2 < s.len and s[mm] == ':' and s[mm + 1] in Digits and s[mm + 2] in Digits and freeAfter(s, mm + 3):
    return mm + 3
  if freeAfter(s, mm): mm else: -1

proc skipSpaces(s: string; k: int): int =
  result = k
  while result < s.len and isSpace(s[result]): inc result

proc monthPart(s: string; k: int): int =
  ## \b(?:Jan|...|Dec)[a-z]*\.?\s+\d{1,2},?\s+ followed by a time; the time's start, or -1.
  if k > 0 and isWord(s[k-1]): return -1
  var hit = false
  for m in Months:
    if s.continuesWith(m, k): hit = true
  if not hit: return -1
  var j = k + 3
  while j < s.len and s[j] in {'a'..'z'}: inc j
  if j < s.len and s[j] == '.': inc j
  let sp = skipSpaces(s, j)
  if sp == j: return -1
  var digits = 0
  while sp + digits < s.len and s[sp + digits] in Digits: inc digits
  for n in countdown(min(digits, 2), 1):   # \d{1,2} backtracks
    var e = sp + n
    if e < s.len and s[e] in Digits: continue
    if e < s.len and s[e] == ',': inc e
    let t = skipSpaces(s, e)
    if t > e and clockAt(s, t) >= 0: return t
  -1

proc clockMatch(s: string; i: int): int =
  ## CLOCK at i: (?:\b(?:at|on)\s+)?(?:<month part>)?<time>; its end or -1.
  if (s.continuesWith("at", i) or s.continuesWith("on", i)) and (i == 0 or not isWord(s[i-1])):
    let t = skipSpaces(s, i + 2)
    if t > i + 2:
      let m = monthPart(s, t)
      if m >= 0: return clockAt(s, m)
      let c = clockAt(s, t)
      if c >= 0: return c
  let m = monthPart(s, i)
  if m >= 0: return clockAt(s, m)
  clockAt(s, i)

proc untimed*(src: string): string =
  ## The evidence pointer without its clock time: "fixer 10:01" -> "fixer".
  var s = ""
  var i = 0
  while i < src.len:   # CLOCK.sub("", s)
    let e = clockMatch(src, i)
    if e > i:
      i = e
      continue
    s.add src[i]
    inc i
  var t = ""   # re.sub(r"\(\s*\)|\[\s*\]", "", s)
  i = 0
  while i < s.len:
    if s[i] in {'(', '['}:
      let close = if s[i] == '(': ')' else: ']'
      let k = skipSpaces(s, i + 1)
      if k < s.len and s[k] == close:
        i = k + 1
        continue
    t.add s[i]
    inc i
  var u = ""   # re.sub(r"\s+([,;)])", r"\1", s)
  i = 0
  while i < t.len:
    if isSpace(t[i]):
      let k = skipSpaces(t, i)
      if k < t.len and t[k] in {',', ';', ')'}:
        i = k
        continue
      u.add t.substr(i, k - 1)
      i = k
      continue
    u.add t[i]
    inc i
  var v = ""   # re.sub(r"([(,;])\s*(?=[,;)])", "", s)
  i = 0
  while i < u.len:
    if u[i] in {'(', ',', ';'}:
      let k = skipSpaces(u, i + 1)
      if k < u.len and u[k] in {',', ';', ')'}:
        i = k
        continue
    v.add u[i]
    inc i
  var w = ""   # re.sub(r"\s{2,}", " ", s)
  i = 0
  while i < v.len:
    if isSpace(v[i]):
      let k = skipSpaces(v, i)
      if k - i >= 2: w.add ' ' else: w.add v[i]
      i = k
      continue
    w.add v[i]
    inc i
  var seen: seq[string] = @[]
  for p in w.split(';'):
    let q = p.strip(chars = {' ', ','})
    if q.len > 0 and q notin seen: seen.add q
  seen.join("; ")
