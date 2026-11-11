## A stand-in for `claude -p`, built as `claude` and put first on PATH by the
## tests: test_paredros.py patches brief.ask_model with fake_model, which Nimony
## cannot do, so this program stands in for the model run.
##
## Each call is recorded in $FAKE_LOG/<n>/ (n counts from 0 in the order the
## calls start): `argv`, its arguments as a JSON array, and `prompt`, its
## stdin. It answers from the plan in $FAKE_PLAN, a JSON object:
## - "raw": printed as it is, whatever the prompt (the whole answer);
## - else the split prompt gets items as "split" says, a list of {"title" (a
##   new item) or "id" (an existing one), "handles"}, a handle "C*" meaning
##   every commit; the handles under "housekeeping" are left out;
## - any other prompt gets "brief", JSON text, as its answer (default
##   {"summary": "s"}).
## A run with the wrong schema for its prompt fails, as fake_model asserts.

import std/[syncio, strutils, os, envvars, cmdline, json]
import std/posix/posix
import ../paredros/[state, brief]

type PlanItem = object
  ## One item of the plan's split.
  id: int
  title: string
  handles: seq[string]

proc wanted(h: string; list: seq[string]): bool =
  ## The handle is listed, or its kind with a "*".
  h in list or (h[0] & "*") in list

proc strings(n: JsonNode): seq[string] =
  ## The strings of a JSON array; none for anything else.
  result = @[]
  if n.kind == JArray:
    for x in items(n): result.add x.getStr

proc main() =
  ## Records the call, then answers it from the plan.
  let prompt = try: readAll(stdin) except: ""
  var argv: seq[string] = @[]
  for i in 1..paramCount(): argv.add paramStr(i)
  let log = getEnv("FAKE_LOG")
  if log.len > 0:
    var dir = log
    discard mkdir(toCString(dir), 0o755)
    var n = 0
    dir = log & "/0"
    while mkdir(toCString(dir), 0o755) != 0:   # mkdir is atomic: one call per n
      inc n
      dir = log & "/" & $n
    try:
      writeFile(log & "/" & $n & "/argv", quote(argv))
      writeFile(log & "/" & $n & "/prompt", prompt)
    except:
      quit "fake claude: cannot write the log"
  var raw, answer = ""
  var split: seq[PlanItem] = @[]
  var housekeeping: seq[string] = @[]
  var plan = parseJson(try: readFile(getEnv("FAKE_PLAN")) except: "{}")
  if not plan.hasError and plan.root.kind == JObject:
    for k, v in pairs(plan.root):
      case k
      of "raw": raw = v.getStr
      of "brief": answer = v.getStr
      of "housekeeping": housekeeping = strings(v)
      of "split":
        for x in items(v):
          var it = PlanItem(id: 0, title: "", handles: @[])
          for f, y in pairs(x):
            if f == "id": it.id = int(y.getInt)
            elif f == "title": it.title = y.getStr
            elif f == "handles": it.handles = strings(y)
          split.add it
      else: discard
  if raw.len > 0:
    stdout.write raw & "\n"
    return
  let at = argv.find("--json-schema")
  let schema = if at >= 0 and at < argv.high: argv[at + 1] else: ""
  if prompt.startsWith("You sort the material"):
    if schema != SplitSchema: quit "fake claude: the split without its schema"
    var handles: seq[string] = @[]
    let material = prompt.find("Material:")
    for line in prompt.substr(max(material, 0)).splitLines:
      let sp = line.find(' ')
      if sp > 1 and line[0] in {'T', 'A', 'C'} and line.substr(1, sp - 1).allCharsInSet(Digits):
        handles.add line.substr(0, sp - 1)
    var items, skipped: seq[string] = @[]
    for h in handles:
      if wanted(h, housekeeping): skipped.add h
    for p in split:
      var hs: seq[string] = @[]
      for h in handles:
        if wanted(h, p.handles): hs.add h
      items.add "{\"id\": " & $p.id & ", \"title\": " & quote(p.title) & ", \"sources\": " &
        quote(hs) & "}"
    stdout.write "{\"result\": \"ok\", \"structured_output\": {\"items\": [" & items.join(", ") &
      "], \"housekeeping\": " & quote(skipped) & "}}\n"
  else:
    if schema != BriefSchema: quit "fake claude: a brief without its schema"
    stdout.write "{\"result\": \"ok\", \"structured_output\": " &
      (if answer.len > 0: answer else: "{\"summary\": \"s\"}") & "}\n"

main()
