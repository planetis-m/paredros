## The files the brief component owns: the work-item ledger and the cached
## briefs, under $STATE/briefs/<s>/. Kept apart from briefs.nim because the
## review side reads them too, and Nim modules cannot import in a cycle.

import std/[syncio, os, tables, opt, result]
import kroki
import core

type
  Section* = enum   ## the five lists of a brief, in page order
    secOpenDecisions = "open_decisions", secSpecConflicts = "spec_conflicts",
    secNeedsReview = "needs_review", secBugRisks = "bug_risks", secDecisionsMade = "decisions_made"
  Decision* = object
    question*, reason*, spec*, source*: string
    options*: seq[string]
    recommended*: Opt[int]  ## the recommended option's index; none or -1 for none
  Entry* = object
    text*, why*, source*: string
  Brief* = object   ## the summary and the five lists, as the page reads them
    summary*: string
    open_decisions*: seq[Decision]
    spec_conflicts*, needs_review*, bug_risks*, decisions_made*: seq[Entry]
  Cached* = object  ## $STATE/briefs/<s>/i<N>.json
    inputs*, generated*, model*: string
    brief*: Brief
  LedgerItem* = object
    id*: int
    title*: string
    sources*: seq[string]
  Ledger* = object  ## $STATE/briefs/<s>/items.json
    items*: seq[LedgerItem]
    seen*: Table[string, int]

const SectionTitles*: array[Section, string] = [
  "Decisions for you", "Contradicts the spec", "Needs another review",
  "Could cause more bugs", "Decisions made"]

proc entries*(b: Brief; s: Section): seq[Entry] =
  ## The list of a section other than the decisions.
  case s
  of secOpenDecisions: newSeq[Entry]()
  of secSpecConflicts: b.spec_conflicts
  of secNeedsReview: b.needs_review
  of secBugRisks: b.bug_risks
  of secDecisionsMade: b.decisions_made

proc count*(b: Brief; s: Section): int =
  if s == secOpenDecisions: b.open_decisions.len else: b.entries(s).len

proc writeJson*(path, json: string) =
  ## Atomic: a page build never reads a half-written file.
  ensureDir(parentDir(path))
  writeAtomic(path, json)

proc ledgerPath*(sid: SessionId): string = state(skBriefs, sid) & "/items.json"
proc cachePath*(sid: SessionId; n: int): string = state(skBriefs, sid) & "/i" & $n & ".json"

proc loadLedger*(sid: SessionId): Ledger =
  let t = readText(ledgerPath(sid))
  if t.isNone: return Ledger(items: @[], seen: initTable[string, int]())
  fromJson(t.get(""), Ledger).get(Ledger(items: @[], seen: initTable[string, int]()))

proc saveLedger*(sid: SessionId; led: Ledger) =
  case toJson(led)
  of Ok(s): writeJson(ledgerPath(sid), s)
  of Err(e): die("hitl: cannot write the ledger: " & $e)

proc load*(sid: SessionId; n: int): Opt[Cached] =
  ## The cached brief of item n, if there is a readable one.
  let t = readText(cachePath(sid, n))
  if t.isNone: return none[Cached]()
  case fromJson(t.get(""), Cached)
  of Ok(c): result = some(c)
  of Err(_): result = none[Cached]()

proc save*(sid: SessionId; n: int; c: Cached) =
  case toJson(c)
  of Ok(s): writeJson(cachePath(sid, n), s)
  of Err(e): die("hitl: cannot write a brief: " & $e)
