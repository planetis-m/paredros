## HTML for the pages, escaped by default.
##
## Text becomes HTML only through this module. A value is escaped unless it is
## `Html`: markup this module built from escaped parts, or a constant marked
## with `raw`. `tag` builds an element, `inline` and `markdown` render the
## Markdown subset below, `diff` renders a unified diff.
##
## The Markdown subset, as agents and the model write it:
## - blocks: paragraphs; `#` headings (one level down: the page owns h1);
##   fenced code (``` or ~~~, indented up to 3 spaces; an unclosed fence runs
##   to the end); lists (`-`, `*`, `+`, `1.`, `1)`), nested by indentation, an
##   ordered list keeping its first number; tables (the outer pipes optional;
##   a `|` inside a code span or written `\|` stays in its cell); block
##   quotes; `---` rules;
## - inline: code spans (any run of backticks), backslash escapes, links to
##   http(s) URLs (one level of parentheses in the URL; the link text is
##   inline Markdown), bare and <angled> http(s) URLs, **strong** and
##   *emphasis*.
## Anything else is shown as written: text is never half-parsed.
##
## The patterns are std/rex's, which reads a pattern deterministically and
## takes the longest match: where render.py's pattern leans on backtracking,
## the one here is written so that one reading is the one Python takes.

import std/[strutils, parseutils, unicode, rex, opt]
import state

type
  Html* = distinct string
    ## Markup built from escaped parts; inserted as is.
  Attr* = object
    ## One attribute of a tag: `name="value"`, the name alone, or nothing.
    name: string
    value: Opt[string]   # none: left out
    bare: bool           # written as its name alone

proc `$`*(h: Html): string =
  ## The markup as a string.
  string(h)

proc raw*(markup: string): Html =
  ## A constant piece of markup written in the code (an icon), trusted as is.
  Html(markup)

proc esc(s: string): string =
  ## Text for HTML content or an attribute value: <, >, & and quotes escaped
  ## (Python's html.escape).
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#x27;"
    else: result.add c

proc toHtml*(s: string): Html =
  ## Text as HTML: escaped.
  Html(esc(s))

proc toHtml*(h: Html): Html =
  ## Markup stays as it is.
  h

proc toHtml*(n: int): Html =
  ## A number as HTML.
  Html($n)

proc toHtml*(parts: openArray[Html]): Html =
  ## Several pieces of markup as one.
  var s = ""
  for p in parts: s.add string(p)
  result = Html(s)

proc attr*(name, value: string): Attr =
  ## `name="value"`, the value escaped.
  Attr(name: name, value: some(value), bare: false)

proc attr*(name: string; value: int): Attr =
  ## `name="value"` for a number.
  Attr(name: name, value: some($value), bare: false)

proc attr*(name: string; value: Opt[string]): Attr =
  ## `name="value"`, or nothing when the value is none.
  Attr(name: name, value: value, bare: false)

proc attr*(name: string; on: bool): Attr =
  ## The name alone (`hidden`) when on, else nothing.
  Attr(name: name, value: (if on: some("") else: none[string]()), bare: on)

const Void = ["br", "hr", "img", "input", "link", "meta"]

proc tag*(name: string; attrs: openArray[Attr] = []; children: varargs[Html, toHtml]): Html =
  ## <name attrs>children</name>. Attribute values and text children are
  ## escaped; an element in `Void` has no children and no end tag.
  var s = "<" & name
  for a in attrs:
    if a.bare: s.add " " & a.name
    elif a.value.isSome: s.add " " & a.name & "=\"" & esc(a.value.get("")) & "\""
  s.add ">"
  if name notin Void:
    for c in children: s.add string(c)
    s.add "</" & name & ">"
  result = Html(s)

proc join*(parts: openArray[Html]; sep = ""): Html =
  ## Several pieces as one, `sep` (text, escaped) between them.
  var s = ""
  for i, p in parts:
    if i > 0: s.add esc(sep)
    s.add string(p)
  result = Html(s)

# ------------------------------------------------------------------- helpers

proc pyStrip(s: string; leading = true; trailing = true): string =
  ## Python's str.strip(): Unicode white space, not only ASCII.
  # GAP: \x1c..\x1f are not stripped, because std/unicode's white space list
  # leaves out the separators Python's str.isspace() counts.
  unicode.strip(s, leading, trailing)

proc blank(s: string): bool =
  ## Python's `not s.strip()`.
  pyStrip(s).len == 0

proc indent(line: string): int =
  ## The spaces at the start of a line.
  result = 0
  while result < line.len and line[result] == ' ': inc result

proc number(s: string): int =
  ## Python's int() of a run of digits a pattern has checked.
  var n: BiggestInt = 0
  discard parseBiggestInt(s, n)
  result = int(n)

proc octal(s: string): int =
  ## Python's int(s, 8) of the octal digits git writes.
  result = 0
  for c in s: result = result * 8 + (ord(c) - ord('0'))

# -------------------------------------------------------------------- inline

const
  Punct = {'!'..'/', ':'..'@', '['..'`', '{'..'~'}
  UrlEnd = {'.', ',', ';', ':', '!', '?', '\'', '"'}   # ends a sentence, not a bare URL
  SlotOpen = "\u{E000}"    # a set-aside piece's number goes between the two
  SlotClose = "\u{E001}"

# GAP: `\s` is ASCII white space and control characters, Python's is Unicode
# white space, so a URL or emphasis can run over a non-breaking space, because
# std/rex has no Unicode classes.
let
  link = re"\[((?:[^\[\]`]|`[^`]*`)+)\]\((https?://[^\s<>()]*(?:\([^\s<>()]*\)[^\s<>()]*)*)\)"
  bareUrl = re"https?://[^\s<>()]*(?:\([^\s<>()]*\)[^\s<>()]*)*"   # one level of parentheses
  angled = re"<(https?://[^\s<>]+)>"
  ticks = re"`+"
  # GAP: the text of **strong** and *emphasis* holds no `*` (Python's `**a*b**`
  # is strong, here it stays as written), and *emphasis* may touch another `*`
  # (`**a*` gets one), because std/rex has no lazy repeats and no lookaround:
  # Python's `\*\*(?=\S)(.+?)(?<=\S)\*\*` and `(?<![\w*])\*(?=[^\s*])(.+?)
  # (?<=[^\s*])\*(?![\w*])` are written without them, `\B` standing for "no
  # word character before or after", and `\w` there takes every non-ASCII
  # character for a word character.
  strong = re"\*\*([^*\s](?:\s*[^*\s])*)\*\*"
  em = re"\B\*([^*\s](?:\s*[^*\s])*)\*\B"

proc alnumBefore(text: string; i: int): bool =
  ## Is the character before byte `i` a letter or a digit?
  # GAP: a non-ASCII digit (Python's str.isalnum()) is not one, because
  # std/unicode has no digit test.
  let (r, _) = lastRune(text, i - 1)
  result = text[i - 1] in {'a'..'z', 'A'..'Z', '0'..'9'} or (text[i - 1] >= '\x80' and isAlpha(r))

proc inline*(text: string): Html =
  ## One line of inline Markdown as HTML. Code spans, escapes and links are set
  ## aside first, so emphasis never reaches into them; the rest is escaped.
  let text = text.replace(SlotOpen, "").replace(SlotClose, "")
  var slots: seq[Html] = @[]
  var output = ""
  var caps: seq[Capture] = @[]
  var i = 0
  while i < text.len:
    let c = text[i]
    var piece = none[Html]()   # what is set aside at i, if anything
    var used = 1               # and how many bytes it or the text takes
    if c == '\\' and i + 1 < text.len and text[i + 1] in Punct:
      piece = some(toHtml($text[i + 1]))
      used = 2
    elif c == '`':
      let run = matchLen(text, ticks, i)
      # the first run of exactly as many backticks closes the span
      var close = -1
      for (a, b) in findAll(text, ticks, i + run):
        if close < 0 and b - a + 1 == run: close = a
      if close >= 0:
        var code = text.substr(i + run, close - 1).replace("\n", " ")
        if code.len > 2 and code[0] == ' ' and code[^1] == ' ' and not blank(code):
          code = code.substr(1, code.len - 2)
        piece = some(tag("code", [], code))
        used = close + run - i
      else:   # no closing run: the backticks are text
        used = run
    elif c == '[':
      let n = matchLen(text, link, caps, i)
      if n >= 0:
        piece = some(tag("a", [attr("href", capture(text, caps, 1))],
                         inline(capture(text, caps, 0))))
        used = n
    elif c == '<':
      let n = matchLen(text, angled, caps, i)
      if n >= 0:
        let url = capture(text, caps, 0)
        piece = some(tag("a", [attr("href", url)], url))
        used = n
    elif c in {'h', 'H'} and (i == 0 or not alnumBefore(text, i)):
      let n = matchLen(text, bareUrl, i)
      let url = if n < 0: ""
                else: text.substr(i, i + n - 1).strip(leading = false, chars = UrlEnd)
      if url.len > 0 and url.substr(url.find("//") + 2).len > 0:
        piece = some(tag("a", [attr("href", url)], url))
        used = url.len
    case piece
    of Some(h):
      output.add SlotOpen & $slots.len & SlotClose
      slots.add h
    of None:
      output.add text.substr(i, i + used - 1)
    i += used
  var s = subGroup(subGroup(esc(output), strong, "<strong>", "</strong>"), em, "<em>", "</em>")
  # the set-aside pieces back in their slots
  var html = ""
  var k = s.find(SlotOpen)
  while k >= 0:
    let e = s.find(SlotClose, k)
    html.add s.substr(0, k - 1) & string(slots[number(s.substr(k + SlotOpen.len, e - 1))])
    s = s.substr(e + SlotClose.len)
    k = s.find(SlotOpen)
  result = Html(html & s)

# -------------------------------------------------------------------- blocks

let
  # Python's `^( {0,3})(`{3,}|~{3,})[ \t]*([^`\s]*)[^`]*$`, the parts read
  # by `fenceParts`: as a language, `[ \t]*([^`\s]*)[^`]*` is `[^`]*`, and
  # std/rex has no `{3,}`
  fenceLine = re"[ ]{0,3}(?:```+|~~~)[^`]*"
  # Python's `^ {0,3}(#{1,6})(?:[ \t]+(.*?))??(?:[ \t]+#+)?[ \t]*$`: the
  # closing #s are taken off by `headingText`
  headingLine = re"[ ]{0,3}(#{1,6})(?:[ \t](.*))?"
  # Python's `^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$`, without the back
  # reference: three of the same character or more, white space between
  ruleLine = re"[ ]{0,3}(?:(?:-[ \t]*){2}(?:-[ \t]*)+|(?:\*[ \t]*){2}(?:\*[ \t]*)+|(?:_[ \t]*){2}(?:_[ \t]*)+)"
  # Python's `^( *)([-*+]|(\d{1,9})[.)])(?:( +)(.*)|)$`; the number is read
  # from the marker, as std/rex numbers a group inside another after it.
  # GAP: `\d` is ASCII digits, Python's any Unicode digit, because std/rex
  # has no Unicode classes.
  itemLine = re"([ ]*)([-*+]|\d{1,9}[.)])(?:([ ]+)([^ ].*)?)?"
  quoteLine = re"[ ]{0,3}>[ ]?"   # the longest match takes the space
  # a yes or no, so the readings the check refuses do not matter
  delimLine = re(r"[ ]{0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*",
                 {reExtended, reAllowEvil})

proc fenceParts(line: string; ind: var int; fence, lang: var string) =
  ## The indent, the fence and the language of a line `fenceLine` matches.
  ind = indent(line)
  var k = ind
  while k < line.len and line[k] == line[ind]: inc k
  fence = line.substr(ind, k - 1)
  while k < line.len and line[k] in {' ', '\t'}: inc k
  # the `\s` GAP above: Python's language also ends at Unicode white space
  lang = line.substr(k, k + skipUntil(line, Whitespace + {'`'}, k) - 1)

proc headingText(rest: string): string =
  ## A heading's text: `rest` without its closing #s and white space.
  result = rest.strip(chars = {' ', '\t'})
  let hashes = result.len - result.strip(leading = false, chars = {'#'}).len
  if hashes > 0 and (hashes == result.len or result[result.len - hashes - 1] in {' ', '\t'}):
    result = result.substr(0, result.len - hashes - 1).strip(leading = false, chars = {' ', '\t'})

proc closing(fence: string): Regex =
  ## The line that closes the code block `fence` opened: as many fence
  ## characters or more, and nothing else.
  result = default(Regex)
  var err = ""   # none: a fence is backticks or tildes, never a bad pattern
  discard tryRe("[ ]{0,3}" & fence & fence[0] & "*[ \\t]*", result, err)

proc cells(line: string): seq[string] =
  ## A table row's cells: split at `|`, but not inside a code span or after a
  ## backslash.
  var s = pyStrip(line)
  result = @[]
  var cur = ""
  var i = 0
  var tick = 0   # the length of the open code span's backtick run; 0 outside one
  if s.startsWith("|"): s = s.substr(1)
  while i < s.len:
    let c = s[i]
    if c == '\\' and i + 1 < s.len and s[i + 1] == '|' and tick == 0:
      cur.add '|'
      i += 2
    elif c == '`':
      let run = matchLen(s, ticks, i)
      tick = if tick == run: 0 elif tick > 0: tick else: run
      cur.add '`'.repeat(run)
      i += run
    else:
      if c == '|' and tick == 0:
        result.add pyStrip(cur)
        cur = ""
      else:
        cur.add c
      inc i
  let last = pyStrip(cur)
  if last.len > 0 or not pyStrip(s, leading = false).endsWith("|"):
    result.add last

proc isTable(lines: seq[string]; i: int): bool =
  ## Do lines[i] and the line after start a table: a header and a delimiter
  ## row with as many cells?
  i + 1 < lines.len and '|' in lines[i] and '|' in lines[i + 1] and
    fullMatch(lines[i + 1], delimLine) and cells(lines[i + 1]).len == cells(lines[i]).len

proc isItem(line: string; caps: var seq[Capture]): bool =
  ## Is the line a list item with text after its marker?
  fullMatch(line, itemLine, caps) and capture(line, caps, 2).len > 0

proc startsBlock(lines: seq[string]; i: int): bool =
  ## Does lines[i] start a block other than a paragraph?
  var caps: seq[Capture] = @[]
  let line = lines[i]
  fullMatch(line, fenceLine) or fullMatch(line, headingLine) or fullMatch(line, ruleLine) or
    match(line, quoteLine) or isItem(line, caps) or isTable(lines, i)

proc blocks(lines: seq[string]; tight = false): seq[Html]

proc list(lines: seq[string]; i: var int): Html =
  ## The list starting at lines[i]: its items, each item's lines rendered as
  ## blocks, so nesting, code and quotes inside items work. `i` moves past it.
  var caps: seq[Capture] = @[]
  discard fullMatch(lines[i], itemLine, caps)
  let base = capture(lines[i], caps, 0).len
  let marker = capture(lines[i], caps, 1)
  let ordered = marker[0] in Digits
  let first = if ordered: number(marker.substr(0, marker.len - 2)) else: 1
  # the marker's last character: `-`, `*`, `+`, or what follows the number
  let kind = marker[^1]
  var items: seq[seq[string]] = @[]
  var loose = false
  while i < lines.len and isItem(lines[i], caps) and capture(lines[i], caps, 0).len == base and
      capture(lines[i], caps, 1)[^1] == kind:
    let width = base + capture(lines[i], caps, 1).len + capture(lines[i], caps, 2).len
    var body = @[capture(lines[i], caps, 3)]
    inc i
    while i < lines.len:
      let ln = lines[i]
      if blank(ln):
        var j = i
        while j < lines.len and blank(lines[j]): inc j
        if j < lines.len and indent(lines[j]) > base:
          # a blank line inside the item: the list is loose
          for k in i ..< j: body.add ""
          loose = true
          i = j
        else:
          break
      elif indent(ln) > base:
        body.add ln.substr(min(indent(ln), width))
        inc i
      elif not blank(body[^1]) and not startsBlock(lines, i):
        body.add pyStrip(ln)   # a lazy continuation of the item's paragraph
        inc i
      else:
        break
    var next = i
    while next < lines.len and blank(lines[next]): inc next
    if next > i and next < lines.len and fullMatch(lines[next], itemLine) and
        indent(lines[next]) == base:
      loose = true   # a blank line between items
      i = next
    items.add body
  var lis: seq[Html] = @[]
  for body in items:
    lis.add tag("li", [], join(blocks(body, tight = not loose), if loose: "\n" else: ""))
  result = tag(if ordered: "ol" else: "ul",
               [attr("start", if first != 1: some($first) else: none[string]())], lis)

proc blocks(lines: seq[string]; tight = false): seq[Html] =
  ## The lines as HTML blocks; `tight` (a tight list's item) leaves a
  ## paragraph without its <p>.
  result = @[]
  var caps: seq[Capture] = @[]
  var i = 0
  while i < lines.len:
    let line = lines[i]
    if blank(line):
      inc i
    elif fullMatch(line, fenceLine):
      var ind = 0
      var fence, lang = ""
      fenceParts(line, ind, fence, lang)
      let close = closing(fence)
      var body: seq[string] = @[]
      inc i
      while i < lines.len and not fullMatch(lines[i], close):
        body.add lines[i].substr(min(ind, indent(lines[i])))
        inc i
      inc i
      result.add tag("pre", [attr("class", "code"), attr("data-lang", lang)],
                     tag("code", [], body.join("\n")))
    elif fullMatch(line, headingLine, caps):
      let level = min(capture(line, caps, 0).len + 1, 6)
      result.add tag("h" & $level, [], inline(headingText(capture(line, caps, 1))))
      inc i
    elif fullMatch(line, ruleLine):
      result.add tag("hr")
      inc i
    elif match(line, quoteLine):
      var quote: seq[string] = @[]
      while i < lines.len and match(lines[i], quoteLine):
        quote.add lines[i].substr(matchLen(lines[i], quoteLine))
        inc i
      result.add tag("blockquote", [], join(blocks(quote), "\n"))
    elif isTable(lines, i):
      let head = cells(line)
      i += 2
      var ths: seq[Html] = @[]
      for c in head: ths.add tag("th", [], inline(c))
      var rows: seq[Html] = @[]
      while i < lines.len and not blank(lines[i]) and '|' in lines[i] and
          not fullMatch(lines[i], fenceLine):
        let row = cells(lines[i])
        var tds: seq[Html] = @[]
        for k in 0 ..< head.len:   # as many cells as the header has
          tds.add tag("td", [], inline(if k < row.len: row[k] else: ""))
        rows.add tag("tr", [], tds)
        inc i
      result.add tag("div", [attr("class", "table")],
                     tag("table", [], tag("thead", [], tag("tr", [], ths)), tag("tbody", [], rows)))
    elif isItem(line, caps):
      result.add list(lines, i)
    else:
      var para = @[pyStrip(line)]
      inc i
      while i < lines.len and not blank(lines[i]) and not startsBlock(lines, i):
        para.add pyStrip(lines[i])
        inc i
      let text = inline(para.join(" "))
      result.add(if tight: text else: tag("p", [], text))

proc markdown*(src: string): Html =
  ## Markdown in the subset above as HTML blocks, one per line.
  let lines = src.replace("\r\n", "\n").replace("\r", "\n").replace("\t", "    ").split('\n')
  result = join(blocks(lines), "\n")

# --------------------------------------------------------------------- diffs

proc svg*(paths: string; size = 16; stroke = "1.6"; cls = ""): Html =
  ## An inline icon: constant path data written in the code. `stroke` is
  ## written as given.
  let c = if cls.len > 0: " class=\"" & cls & "\"" else: ""
  raw("<svg" & c & " width=\"" & $size & "\" height=\"" & $size &
      "\" viewBox=\"0 0 20 20\" aria-hidden=\"true\" fill=\"none\" stroke=\"currentColor\" " &
      "stroke-width=\"" & stroke & "\" stroke-linecap=\"round\" stroke-linejoin=\"round\">" &
      paths & "</svg>")

let
  chev = svg("<path d=\"M7.5 4.5L13 10l-5.5 5.5\"/>", 16, "2", "chev")
  hunkLine = re"@@\ -(\d+)(?:,(\d+))?\ \+(\d+)(?:,(\d+))?\ @@(.*)"
  quotedPath = re"""\"(?:[^\"\\]|\\.)*\""""

proc gitPath(p: string): string =
  ## A path as git writes it in a diff header: C-quoted when it holds unusual
  ## characters (octal bytes for non-ASCII), and without its a/ or b/ side.
  var p = p
  if p.len > 1 and p[0] == '"' and p[^1] == '"':
    # GAP: bytes that are not UTF-8 stay as they are, where Python's
    # decode("utf-8", "replace") writes U+FFFD, because std/unicode has no
    # decoding with replacement.
    var output = ""
    let s = p.substr(1, p.len - 2)
    var i = 0
    while i < s.len:
      if s[i] == '\\' and i + 1 < s.len:
        let e = s[i + 1]
        if e in {'0'..'7'}:
          output.add char(octal(s.substr(i + 1, i + 3)) and 0xFF)
          i += 4
        else:
          case e
          of 'n': output.add '\n'
          of 't': output.add '\t'
          of 'a': output.add '\a'
          of 'b': output.add '\b'
          of 'f': output.add '\f'
          of 'v': output.add '\v'
          of 'r': output.add '\r'
          else: output.add e   # \\ and \", and any other character as itself
          i += 2
      else:
        output.add s[i]
        inc i
    p = output
  result = if p.startsWith("a/") or p.startsWith("b/"): p.substr(2) else: p

proc headerPath(rest: string): string =
  ## The path from `diff --git a/P b/P` when no ---/+++ or rename line names it
  ## (a mode change, a binary file): both sides are the same path.
  let rest = pyStrip(rest)
  if rest.startsWith("\""):
    # an unclosed quote, which git does not write, is taken whole (Python fails)
    let n = matchLen(rest, quotedPath)
    return gitPath(if n >= 0: rest.substr(0, n - 1) else: rest)
  let half = (rest.len - 1) div 2
  result = if rest.substr(0, half - 1) == "a/" & rest.substr(half + 3) and
              rest.substr(half, half + 2) == " b/": rest.substr(2, half - 1)
           else: rest

proc modeNote(old, new: string): string =
  ## What a mode change means: executable or not, else both modes.
  proc exec(m: string): int = octal(m.substr(max(m.len - 3, 0))) and 0o111
  if old.substr(0, old.len - 4) == new.substr(0, new.len - 4) and exec(old) != exec(new):
    result = if exec(new) != 0: "Now executable" else: "No longer executable"
  else:
    result = "Mode " & old & " → " & new

proc noteRow(text: Html): Html =
  ## A row with a note (a hunk's title, a rename) in its last cell.
  tag("tr", [attr("class", "hunk")], tag("td"), tag("td"), tag("td"), tag("td", [], text))

type DiffFile = object
  ## A file of a diff, as it is read.
  path: string
  rows: seq[Html]
  notes: seq[string]
  added, removed: int   # its lines added and removed
  old, new: int         # the next line's number on each side
  mode: string          # the old mode, once a line names it
  shown: bool           # within the limit

proc diff*(text: string; limit = 600_000): (Html, int) =
  ## A unified diff (git diff), one fold per file, every file closed. Returns
  ## the HTML and the number of files. A file's header runs to its first
  ## hunk; inside a hunk the counts in `@@ -a,b +c,d @@` say how many lines
  ## follow, and each is read by its first character only, so no content
  ## line is taken for a header. Renames, mode changes and binary files get a
  ## note row. Past `limit` characters of diff, the rest of the files are
  ## counted and named as not shown, never cut mid-file.
  var files: seq[DiffFile] = @[]
  var f = DiffFile(rows: @[], notes: @[])   # the file being read; in files once the next starts
  var started = false                       # has a file started?
  var caps: seq[Capture] = @[]
  var leftOld, leftNew, used = 0
  for whole in text.split('\n'):
    let line = if whole.endsWith('\r'): whole.substr(0, whole.len - 2) else: whole
    used += runeLen(line) + 1   # characters, as Python counts them
    if leftOld > 0 or leftNew > 0:   # inside a hunk
      let c = line.substr(0, 0)
      if c == "\\":
        discard   # "\ No newline at end of file"
      elif not f.shown:   # past the limit: count the lines, build nothing
        if c != "+": dec leftOld
        if c != "-": dec leftNew
      elif c == "+":
        f.rows.add tag("tr", [attr("class", "add")], tag("td"), tag("td", [], f.new),
                       tag("td", [attr("class", "sig")], "+"), tag("td", [], line.substr(1)))
        inc f.new
        inc f.added
        dec leftNew
      elif c == "-":
        f.rows.add tag("tr", [attr("class", "rem")], tag("td", [], f.old), tag("td"),
                       tag("td", [attr("class", "sig")], "−"), tag("td", [], line.substr(1)))
        inc f.old
        inc f.removed
        dec leftOld
      else:
        f.rows.add tag("tr", [], tag("td", [], f.old), tag("td", [], f.new),
                       tag("td", [attr("class", "sig")]), tag("td", [], line.substr(1)))
        inc f.old
        inc f.new
        dec leftOld
        dec leftNew
    elif line.startsWith("diff --git "):
      if started: files.add f
      f = DiffFile(path: headerPath(line.substr(11)), rows: @[], notes: @[], shown: used <= limit)
      started = true
    elif not started:
      discard   # before the first file
    elif fullMatch(line, hunkLine, caps):
      f.old = number(capture(line, caps, 0))
      f.new = number(capture(line, caps, 2))
      leftOld = if capture(line, caps, 1).len == 0: 1 else: number(capture(line, caps, 1))
      leftNew = if capture(line, caps, 3).len == 0: 1 else: number(capture(line, caps, 3))
      let title = pyStrip(capture(line, caps, 4))
      f.rows.add noteRow(if title.len > 0: toHtml(title) else: raw("&nbsp;"))
    elif line.startsWith("+++ ") and line.substr(4) != "/dev/null":
      f.path = gitPath(line.substr(4))
    elif line.startsWith("--- ") and line.substr(4) != "/dev/null":
      f.path = gitPath(line.substr(4))
    elif line.startsWith("rename from "):
      f.notes.add "Renamed from " & gitPath(line.substr(12))
    elif line.startsWith("rename to "):
      f.path = gitPath(line.substr(10))
    elif line.startsWith("old mode "):
      f.mode = line.substr(9)
    elif line.startsWith("new mode ") and f.mode.len > 0:
      f.notes.add modeNote(f.mode, line.substr(9))
    elif line.startsWith("Binary files "):
      f.notes.add "Binary file"
  if started: files.add f
  var folds: seq[Html] = @[]
  var hidden = 0
  for x in files:
    if x.shown:
      var notes: seq[Html] = @[]
      for n in x.notes: notes.add noteRow(toHtml(n))
      folds.add tag("details", [attr("class", "file")],
                    tag("summary", [], chev, tag("span", [attr("class", "path")], x.path),
                        tag("span", [attr("class", "stat")], tag("ins", [], "+" & $x.added), " ",
                            tag("del", [], "−" & $x.removed))),
                    tag("div", [attr("class", "scroll")],
                        tag("table", [attr("class", "diff")], notes, x.rows)))
    else:
      inc hidden
  if hidden > 0:
    folds.add tag("p", [attr("class", "nocode")], $hidden & " more " &
                  (if hidden == 1: "file" else: "files") &
                  " not shown: the change is too large to show here.")
  result = (join(folds, "\n"), files.len)
