## The page build: every work item's page, the index, the pages' CSS and JS,
## and the code tips the server's stale marks read. Writes only into the
## output directory, each file atomically; deletes only the pages of items
## that are gone.

import std/[syncio, strutils, os, dirs, files, paths, opt, result, times]
import kroki
import core, items, html, pages

# Known issue: bug-reports/enum-from-one-invalid-array-index-type - std/times'
# Month starts at 1, and `array[Month, string]` is refused; indexed by ordinal.
const MonthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

proc freshness(repo: string; built: DateTime): string =
  ## "Nimony, updated 17:57": the project's directory name and the time of the
  ## build, with the date when that is not today.
  result = extractFilename(repo).capitalizeAscii & ", updated "
  let today = local(getTime())
  if built.year != today.year or built.month != today.month or built.monthday != today.monthday:
    result.add MonthNames[ord(built.month) - 1] & " " & $built.monthday & " "
  result.add align($built.hour, 2, '0') & ":" & align($built.minute, 2, '0')

proc pageItem(name: string): Opt[ItemId] =
  ## The item of a page file name, "i63.html".
  result = none[ItemId]()
  let digits = name.substr(1, name.len - len(".html") - 1)
  if name.startsWith("i") and name.endsWith(".html") and digits.len > 0 and digits.allCharsInSet(Digits):
    try: result = some(ItemId(parseInt(digits)))
    except: discard

proc build*(desk: Desk; outDir: string): string {.raises.} =
  ## Writes the pages into outDir and returns the index's path.
  let items = workItems(desk, sources(desk.transcript))
  var ids: seq[ItemId] = @[]
  var briefs: seq[Opt[Cached]] = @[]
  for it in items:
    ids.add it.id
    briefs.add loadBrief(desk.id, it.id)
  createDir(paths.path(outDir))
  for (kind, p) in walkDir(paths.path(outDir)):
    let item = pageItem(extractFilename($p))
    if item.isSome and item.get(ItemId(0)) notin ids: removeFile(p)
  for at, it in items:
    writeAtomic(outDir & "/i" & $it.id & ".html", itemPage(items, at, desk, briefs[at]))
  for (kind, p) in walkDir(paths.path(appDir() & "/static")):   # beside the pages, so file mode works too
    writeAtomic(outDir & "/" & extractFilename($p), readFile($p))
  writeAtomic(outDir & "/tips.json", toJson(tips(items)).get("[]"))
  result = outDir & "/index.html"
  writeAtomic(result, indexPage(items, briefs, freshness(desk.repo, local(getTime()))))

proc builtTips*(outDir: string): Opt[seq[ItemTip]] =
  ## The items' code tips as the last build found them.
  case fromJson(readText(outDir & "/tips.json").get(""), seq[ItemTip])
  of Ok(tips): result = some(tips)
  of Err(_): result = none[seq[ItemTip]]()
