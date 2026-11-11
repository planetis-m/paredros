## The project's optional settings (README, "Config"): a value, loaded once
## and passed down; every key may be left out.

import std/[syncio, strutils, os, envvars, json, opt, result, algorithm]

type
  Compare* = object
    ## The compare action: a button on the page and what the companion is told.
    label*, prompt*: string
    allow*: seq[string]      ## the commands the companion may run for it
  Config* = object
    spec*: string            ## the spec the code must agree with; "" for none
    reader*: string          ## who the briefs are written for
    users*: string           ## who the project's users are
    compare*: Opt[Compare]   ## none: no compare action

proc defaults*(): Config =
  ## The config when no file says otherwise.
  Config(spec: "", reader: "a developer of this project", users: "the project's users",
         compare: none[Compare]())

proc load*(cwd: string; path = ""): Result[Config, string] =
  ## The config in `path` (--config), else .paredros.json in the session's working
  ## directory (cwd "" is the current one), else the defaults. The error says
  ## why a file is refused.
  let p = if path.len > 0: path
          else: (if cwd.len > 0: cwd else: ".") & "/.paredros.json"
  if not fileExists(p):
    return if path.len > 0: err[Config, string]("no config file " & p)
           else: ok[Config, string](defaults())
  let text = try: readFile(p) except: ""
  # GAP: the reason a file is not JSON is std/json's text ("p(1, 11) Error:
  # ..."), because that is the only message std/json gives (README,
  # Limitations).
  var raw = parseJson(text, p)
  if raw.hasError: return err[Config, string]("cannot read " & p & ": " & raw.errorMsg)
  let top = raw.root
  var cmp = top    # the compare object; top itself until one is found
  var hasCmp = false
  if top.kind == JObject:
    for k, v in pairs(top):
      if k == "compare":
        hasCmp = v.kind != JNull
        cmp = v
  if top.kind != JObject or (hasCmp and cmp.kind != JObject):
    return err[Config, string](p & " must hold one object, and compare an object")
  # the first unknown key in sorted order, the top level's before compare's
  var bad: seq[string] = @[]
  for k, v in pairs(top):
    if k notin ["spec", "reader", "users", "compare"]: bad.add k
  if bad.len == 0 and hasCmp:
    for k, v in pairs(cmp):
      if k notin ["label", "prompt", "allow"]: bad.add k
  if bad.len > 0:
    bad.sort()
    return err[Config, string]("unknown key '" & bad[0] & "' in " & p)
  var cfg = defaults()
  for k, v in pairs(top):
    case k
    of "spec": cfg.spec = v.getStr
    of "reader": cfg.reader = v.getStr
    of "users": cfg.users = v.getStr
    else: discard
  if hasCmp:
    var c = Compare(label: "", prompt: "", allow: @[])
    for k, v in pairs(cmp):
      case k
      of "label": c.label = v.getStr
      of "prompt": c.prompt = v.getStr
      of "allow":
        if v.kind == JArray:
          for x in items(v): c.allow.add x.getStr
      else: discard
    if c.label.len == 0 or c.prompt.len == 0:
      return err[Config, string]("compare in " & p & " needs a label and a prompt")
    cfg.compare = some(c)
  result = ok[Config, string](cfg)

proc expand*(text, scratch: string): string =
  ## A compare text with {scratch} and {home} filled in.
  text.replace("{scratch}", scratch).replace("{home}", getEnv("HOME"))
