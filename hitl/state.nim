## hitl's own files: where each session's state lives, how files are written,
## and the companion forks.

import std/[syncio, strutils, os, paths, dirs, files, envvars]
import std/crypto/sysrand

proc outDir*(): string =
  ## hitl's state directory: $XDG_STATE_HOME/hitl, else ~/.local/state/hitl.
  # Read on every call, not once: the tests point it at a temp directory.
  getEnv("XDG_STATE_HOME", getEnv("HOME") & "/.local/state") & "/hitl"

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

# ---------------------------------------------------------------- companions

proc companionIds*(): seq[string] =
  ## The session ids of the companion forks made so far.
  try:
    result = readFile(outDir() & "/companions").splitWhitespace()
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
