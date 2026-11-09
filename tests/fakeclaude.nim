## A stand-in for `claude -p`, built as `claude` and put first on PATH by the
## tests (test_hitl.py's fake_model). It records each call's argv and stdin in
## $FAKE_LOG and answers from the plan in $FAKE_PLAN:
## - `raw`: printed as it is (the whole `--output-format json` answer);
## - else the split prompt gets items as `split` says: each entry names a new
##   item's title (or an existing item's `id`) and the handles to put in it,
##   `"C*"` meaning every commit; `housekeeping` handles are left out;
## - any other prompt gets `brief` as its answer (default `{"summary": "s"}`),
##   with the session id `fork-<call number>`, after `sleepMs` milliseconds.

import std/[syncio, strutils, os, paths, dirs, envvars, opt, result]
import kroki

type
  PlanItem = object
    title: string
    id: int
    handles: seq[string]
  Plan = object
    raw: string
    split: seq[PlanItem]
    housekeeping: seq[string]
    brief: RawJson
    sleepMs: int
  Item = object
    id: int
    title: string
    sources: seq[string]
  SplitAnswer = object
    items: seq[Item]
    housekeeping: seq[string]
  SplitOut = object
    result: string
    structured_output: SplitAnswer

proc wanted(h: string; list: seq[string]): bool = h in list or (h[0] & "*") in list

proc main() =
  let prompt = try: stdin.readAll() except: ""
  var argv: seq[string] = @[]
  for i in 1 .. paramCount(): argv.add paramStr(i)
  let log = getEnv("FAKE_LOG")
  var n = 0
  if log.len > 0:
    try:
      createDir(path(log))
      while fileExists(log & "/call-" & $n & ".prompt"): inc n
      writeFile(log & "/call-" & $n & ".prompt", prompt)
      writeFile(log & "/call-" & $n & ".argv", toJson(argv).get("[]"))
    except: quit "fake claude: cannot write the log"
  let planText = try: readFile(getEnv("FAKE_PLAN")) except: "{}"
  let plan = fromJson(planText, Plan).get(Plan())
  if plan.raw.len > 0:
    stdout.write plan.raw & "\n"
    return
  if prompt.startsWith("You sort the material"):
    var handles: seq[string] = @[]
    let at = prompt.find("Material:")
    for line in prompt.substr(max(at, 0)).splitLines:
      let sp = line.find(' ')
      if sp > 1 and line[0] in {'T', 'A', 'C'} and line.substr(1, sp - 1).allCharsInSet(Digits):
        handles.add line.substr(0, sp - 1)
    var answer = SplitAnswer()
    for h in handles:
      if wanted(h, plan.housekeeping): answer.housekeeping.add h
    for p in plan.split:
      var hs: seq[string] = @[]
      for h in handles:
        if wanted(h, p.handles): hs.add h
      answer.items.add Item(id: p.id, title: (if p.id == 0: p.title else: ""), sources: hs)
    stdout.write toJson(SplitOut(result: "ok", structured_output: answer)).get("{}") & "\n"
  else:
    let b = if string(plan.brief).len > 0: string(plan.brief) else: "{\"summary\": \"s\"}"
    if plan.sleepMs > 0: sleep(plan.sleepMs)
    stdout.write "{\"result\": \"ok\", \"session_id\": \"fork-" & $n & "\", \"structured_output\": " & b & "}\n"

main()
