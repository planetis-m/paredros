## paredros's own files: where each session's state lives, how files are written,
## the companion forks, and the few text helpers every layer shares.

import std/[syncio, strutils, os, paths, dirs, files, appdirs, json, unicode, rex]
import std/crypto/sysrand

proc home*(): string =
  ## The user's home directory, without a trailing separator.
  $(appdirs.getHomeDir() / path("."))

proc outDir*(): string =
  ## paredros's state directory: paredros in the user's data directory
  ## (std/appdirs: ~/.local/share or $XDG_DATA_HOME on Linux, ~/Library/
  ## Application Support on macOS, %APPDATA% on Windows).
  # Read on every call, not once: the tests point it at a temp directory.
  $(appdirs.getDataDir() / path("paredros"))

proc state*(kind, sid: string): string =
  ## The one place a session's state folder is named: $STATE/<kind>/<first 8
  ## of the id>. kind is review, briefs, directions or scratch.
  outDir() & "/" & kind & "/" & sid.substr(0, 7)

proc writeAtomic*(p, text: string) {.raises.} =
  ## Write a file whole or not at all: a reader never sees half of it. Raises
  ## the ErrorCode of a failed write.
  let tmp = parentDir(p) & "/." & extractFilename(p) & ".tmp"
  writeFile(tmp, text)
  moveFile(path(tmp), path(p))

const
  companionPrompt* = slurp("../companion.md")
    ## The companion's system prompt, built into the binary.
  pageAssets* = [("paredros.css", slurp("../static/paredros.css")),
                 ("paredros.js", slurp("../static/paredros.js"))]
    ## The pages' CSS and JS, built into the binary: (file name, contents).

# ---------------------------------------------------------------------- text

proc collapse*(text: string): string =
  ## The words of text (split at Unicode white space) joined by single spaces.
  # GAP: \x1c..\x1f do not separate words, because std/unicode's white space
  # list leaves out these separators (README, Limitations).
  var words: seq[string] = @[]
  for w in unicode.splitWhitespace(text):
    if w.len > 0: words.add w
  result = words.join(" ")

proc quote*[T](value: T): string =
  ## value (a string, a number, a seq or an object of them) as JSON text, on
  ## one line: std/json's `toJson`, then `$`.
  # GAP: control characters other than \b \f \n \r \t are written raw, which
  # is not JSON, because std/json's `$` does not escape them
  # (bug-reports/104-json-dollar-control-chars-unescaped; README, Limitations).
  var t = toJson(value)
  result = $t

proc subGroup*(s: string; r: Regex; before = "", after = ""): string =
  ## s with every match of r replaced by its first group between before and
  ## after; std/rex's `replace` takes no group.
  result = ""
  var caps: seq[Capture] = @[]
  var i = 0
  var (a, b) = findBounds(s, r, caps, 0)
  while a >= 0:
    result.add s.substr(i, a - 1) & before & capture(s, caps, 0) & after
    i = b + 1
    (a, b) = findBounds(s, r, caps, i)
  result.add s.substr(i)

# ---------------------------------------------------------------- companions

proc companionIds*(): seq[string] =
  ## The session ids of the companion forks made so far.
  try:
    result = strutils.splitWhitespace(readFile(outDir() & "/companions"))
  except:
    result = @[]

proc newCompanionId*(): string {.raises.} =
  ## A session id for a new companion fork, recorded so it is never taken for
  ## the session. Raises the ErrorCode of a failed write.
  var bytes = default(array[16, byte])
  if not urandom(bytes): raise IOError
  # A version 4 uuid (RFC 4122): 16 random bytes with the version and variant
  # bits set; the standard library has no uuid module.
  bytes[6] = (bytes[6] and 0x0f'u8) or 0x40'u8
  bytes[8] = (bytes[8] and 0x3f'u8) or 0x80'u8
  var hex = ""
  for b in bytes: hex.add toHex(b)
  let h = hex.toLowerAscii
  result = h.substr(0, 7) & "-" & h.substr(8, 11) & "-" & h.substr(12, 15) & "-" &
           h.substr(16, 19) & "-" & h.substr(20, 31)
  let p = outDir() & "/companions"
  createDir(path(parentDir(p)))
  var f: File
  if not open(f, p, fmAppend): raise IOError
  try:
    f.write result & "\n"
  finally:
    close(f)
