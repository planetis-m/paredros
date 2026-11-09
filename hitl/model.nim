## The work items and what they are made of, shared by review.nim (which
## collects them) and pages.nim (which renders them); and the small rules the
## pages apply to them: the lanes and the diff's files.

import std/[strutils, tables, opt]
import core, store

type
  Turn* = object   ## what the human typed and everything the session said until the next one
    key*, time*, human*: string
    texts*: seq[string]
  Commit* = object
    key*, sha*, repo*, common*, subject*: string
    time*: int
    parents*: seq[string]
    agent*: Opt[string]   ## the key of the agent that made it
  Sources* = object
    recs*: seq[Rec]
    turns*: seq[Turn]
    agents*: seq[Agent]
    commits*: seq[Commit]
  Code* = object   ## an item's current code
    commits*, earlier*: seq[Commit]
    tip*, diff*: string
  WorkItem* = object
    n*: int
    title*: string
    turns*: seq[Turn]
    agents*: seq[Agent]
    code*: Code
  Collected* = object
    session*: SessionId
    cwd*, repo*, generated*: string
    config*: Config
    sources*: Sources
    items*: seq[WorkItem]

proc key*(a: Agent): string = "agent:" & a.id

# --------------------------------------------------------------------- lanes

type Lane* = enum   ## an item goes into the first lane that applies; the order never changes
  laneDecide = "decide", laneReview = "review", laneClear = "clear"

const LaneTitles*: array[Lane, string] = ["Waiting for your decision", "Needs another review", "Nothing open"]

proc laneOf*(briefs: Table[int, Cached]; n: int): Lane =
  ## No brief yet: it needs reading first.
  if n notin briefs: return laneReview
  let b = briefs.getOrDefault(n, Cached()).brief
  if b.open_decisions.len > 0: laneDecide
  elif b.spec_conflicts.len > 0 or b.needs_review.len > 0: laneReview
  else: laneClear

proc cardSub*(briefs: Table[int, Cached]; n: int; lane: Lane): string =
  ## A card's status line: the exact number of decisions, in the decision lane only.
  if n notin briefs: "No brief yet"
  elif lane == laneDecide:
    let k = briefs.getOrDefault(n, Cached()).brief.open_decisions.len
    $k & " decision" & (if k != 1: "s" else: "")
  else: ""

# ---------------------------------------------------------------------- diffs

type DiffFile* = object
  path*: string
  rows*: seq[string]
  added*, removed*: int

proc pyLines*(s: string): seq[string] =
  ## str.splitlines(): also splits at \v, \f, \x1c-\x1e, U+0085, U+2028 and U+2029.
  result = @[]
  var cur = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    var brk = 0
    if c == '\r': brk = (if i + 1 < s.len and s[i + 1] == '\n': 2 else: 1)
    elif c in {'\n', '\v', '\f', '\x1c', '\x1d', '\x1e'}: brk = 1
    elif c == '\xC2' and i + 1 < s.len and s[i + 1] == '\x85': brk = 2
    elif c == '\xE2' and i + 2 < s.len and s[i + 1] == '\x80' and s[i + 2] in {'\xA8', '\xA9'}: brk = 3
    if brk > 0:
      result.add cur
      cur = ""
      i += brk
    else:
      cur.add c
      inc i
  if cur.len > 0: result.add cur

proc diffFiles*(diff: string): seq[DiffFile] =
  ## The diff's files, each with the lines after its header.
  result = @[]
  for line in pyLines(diff):
    if line.startsWith("diff --git "):
      # diff --git a/(.+?) b/(.+)$
      var path = line
      if line.startsWith("diff --git a/"):
        for at in len("diff --git a/") + 1 ..< line.len - 3:   # (.+?) b/(.+): the first " b/" with text after it
          if line.continuesWith(" b/", at):
            path = line.substr(at + 3)
            break
      result.add DiffFile(path: path)
      continue
    if result.len == 0: continue
    var skip = false
    for h in ["index ", "--- ", "+++ ", "similarity ", "rename ", "new file", "deleted file", "old mode", "new mode"]:
      if line.startsWith(h): skip = true
    if skip: continue
    result[^1].rows.add line
    if line.startsWith("+"): inc result[^1].added
    elif line.startsWith("-"): inc result[^1].removed

proc hunkHeader*(line: string; old, new, rest: var string): bool =
  ## ^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$
  proc digits(s: string; k: var int; dest: var string): bool =
    let start = k
    while k < s.len and s[k] in Digits: inc k
    dest = s.substr(start, k - 1)
    k > start
  var k = 0
  if not line.startsWith("@@ -"): return false
  k = 4
  var skipped = ""
  if not digits(line, k, old): return false
  if k < line.len and line[k] == ',':
    inc k
    if not digits(line, k, skipped): return false
  if not line.continuesWith(" +", k): return false
  k += 2
  if not digits(line, k, new): return false
  if k < line.len and line[k] == ',':
    inc k
    if not digits(line, k, skipped): return false
  if not line.continuesWith(" @@", k): return false
  rest = line.substr(k + 3)
  true
