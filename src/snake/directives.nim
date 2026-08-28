## The reply schema: what a commander (LLM or scripted) may say, how a reply
## is parsed TOLERANTLY, and how an illegal reply is REPAIRED instead of
## rejected. There is no reply that leaves a snake unactuated.
##
## Lifted from `coworld-ctf`'s `src/ctf/directives.nim`: `truncateRunes`,
## `sanitizeSay`, `sanitizeNote` and `extractJsonObject` are that file's,
## verbatim, including the `{` and `}` exclusion in `sanitizeSay` (the replay
## chat stream tells a control record from a shout by a leading brace). Only
## the `Intent` enum and `CogOrder` are replaced, by `SnakeOrder`.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES (Unicode
## codepoints) and every truncation lands on a rune boundary (`runeLen` /
## `runeSubStr`). Slicing a string by BYTE index anywhere on the path to the
## replay is forbidden: a byte-truncated multi-byte character renders fine in
## a browser and then fails a strict UTF-8 parser, which is exactly the class
## of bug that makes a replay unreadable to everything except the one viewer
## that happened to be lenient.

import std/[json, strutils, unicode]
import board, sim_types

type
  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  SnakeOrder* = object
    ## One seat's whole order for one turn. One direction, and nothing else.
    dir*: Dir
    hasAlt*: bool
    alt*: Dir
    say*: string                ## <= MaxSayRunes, sanitized; PUBLIC
    notes*: string              ## <= MaxNoteRunes, private, handed back
    source*: DirectiveSource
    latencyMs*: int
    repaired*: bool             ## a field did not validate and was repaired
    fromReply*: bool

  DirectiveError* = object of ValueError

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## The public one-line channel: capped at MaxSayRunes on a rune boundary
  ## FIRST, then run through the starter's printable-ASCII shout sanitiser.
  ## Doing it in that order means the rune cut never leaves half a codepoint
  ## for the ASCII filter to smear.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    # Braces are excluded deliberately: the replay chat stream carries the
    # control records as JSON objects and tells them apart from a snake's
    # shout by a leading '{'. A shout that could start with one would make
    # that discrimination ambiguous.
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The seat's private line, handed back to it next turn. Newlines collapse
  ## to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readDir(node: JsonNode): tuple[ok: bool, dir: Dir] =
  if node.isNil:
    return (false, dUp)
  case node.kind
  of JString: parseDir(node.getStr())
  of JInt:
    let value = int(node.getBiggestInt())
    if value >= 0 and value < DirOrder.len: (true, DirOrder[value])
    else: (false, dUp)
  else: (false, dUp)

proc parseSnakeOrder*(payload: JsonNode, lastDir: Dir,
                      legal: openArray[bool]): SnakeOrder =
  ## Turns one parsed reply into a legal order, REPAIRING every field the
  ## schema bounds rather than rejecting the reply:
  ##
  ## * `dir`   unparseable or absent -> `alt`, then `last_dir`, then the first
  ##           legal direction in the wire order up, right, down, left;
  ## * `alt`   absent or unparseable -> skipped in the ladder;
  ## * `say`   truncated to MaxSayRunes on a RUNE boundary, then the printable
  ##           shout filter;
  ## * `notes` newlines collapsed, then truncated to MaxNoteRunes on a RUNE
  ##           boundary.
  ##
  ## Raises `DirectiveError` only when the payload is not an object at all --
  ## the one condition the retry and then the scripted fallback exist for.
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result.source = dsLlm
  result.fromReply = true
  let
    wanted = readDir(payload{"dir"})
    alt = readDir(payload{"alt"})
  result.hasAlt = alt.ok
  result.alt = alt.dir
  if wanted.ok:
    result.dir = wanted.dir
  else:
    result.repaired = true
    if alt.ok:
      result.dir = alt.dir
    else:
      result.dir = lastDir
      var firstLegal = -1
      for i, d in DirOrder:
        if i < legal.len and legal[i]:
          firstLegal = i
          break
      if firstLegal >= 0 and ord(lastDir) < legal.len and
          not legal[ord(lastDir)]:
        result.dir = DirOrder[firstLegal]
  result.say = sanitizeSay(payload{"say"}.getStr())
  result.notes = sanitizeNote(payload{"notes"}.getStr())

proc directiveRecord*(order: SnakeOrder, turn, slot: int,
                      alias, viewJson: string): JsonNode =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED fields only: it drives the broadcast feed and
  ## tools/replay_summary.py and can never affect the simulation.
  var node = %*{
    "k": "directive",
    "turn": turn,
    "slot": slot,
    "alias": alias,
    "source": $order.source,
    "latency_ms": order.latencyMs,
    "dir": $order.dir,
    "repaired": order.repaired,
    "say": order.say
  }
  if order.hasAlt:
    node["alt"] = %($order.alt)
  else:
    node["alt"] = newJNull()
  if viewJson.len > 0:
    node["view"] = %viewJson
  node

proc boundedDirectiveRecord*(order: SnakeOrder, turn, slot: int,
                             alias, viewJson: string): string =
  ## The serialized directive record, guaranteed <= MaxDirectiveRunes. The
  ## view is the only unbounded-in-practice field, so it is the one that is
  ## dropped; every cut still lands on a rune boundary. NEVER cut the
  ## SERIALIZED string -- that would emit broken JSON, which is the exact
  ## failure the rune rule exists to prevent.
  result = $order.directiveRecord(turn, slot, alias, viewJson)
  if result.runeLen <= MaxDirectiveRunes:
    return
  result = $order.directiveRecord(turn, slot, alias, "")
  var trimmed = order
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 12:
    inc guard
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 4))
    trimmed.notes = trimmed.notes.truncateRunes(
      max(0, trimmed.notes.runeLen - 16))
    result = $trimmed.directiveRecord(turn, slot, alias, "")
