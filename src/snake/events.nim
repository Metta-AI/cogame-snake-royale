## The closed event vocabulary and the tier-2 JSON-lines analysis stream.
##
## `tests/test_snake_events.nim` asserts the emitted set equals EXACTLY the
## sixteen kinds listed here, and that every kind the appended viewer block
## consumes is in it.

import std/[json, strutils]
import rules

const
  AllEventKinds*: array[16, EventKind] = [
    ekGameStart, ekSpawn, ekTurn, ekMove, ekSay, ekEat, ekFoodSpawn,
    ekShrink, ekHeadOn, ekDeath, ekTrapped, ekDecline, ekDuel, ekFallback,
    ekGameOver, ekEnd]

  BeatKinds*: array[7, EventKind] = [
    ekEat, ekHeadOn, ekDeath, ekTrapped, ekDuel, ekFallback, ekGameOver]
    ## The scrubber markers -- the only kinds the appended game block turns
    ## into buttons. `gamestart`, `spawn`, `turn`, `move`, `say`, `foodspawn`,
    ## `shrink`, `decline` and `end` never make beats.

proc isBeatKind*(kind: EventKind): bool =
  for k in BeatKinds:
    if k == kind:
      return true
  false

proc eventJson*(e: TurnEvent): JsonNode =
  result = %*{"k": $e.kind, "t": e.turn}
  if e.slot >= 0: result["slot"] = %e.slot
  if e.other >= 0: result["other"] = %e.other
  if e.value != 0: result["v"] = %e.value
  if e.extra != 0: result["x"] = %e.extra
  if e.text.len > 0: result["text"] = %e.text
  result["at"] = %[e.at.x, e.at.y]

proc eventsJsonl*(events: seq[TurnEvent], turns: int,
                  gameVersion: string): string =
  ## `COGAME_EVENTS_URI` gets one JSON object per line, with the mandatory
  ## trailing summary row.
  var lines: seq[string]
  for e in events:
    lines.add($eventJson(e))
  lines.add($(%*{
    "type": "summary", "turns": turns, "events": events.len,
    "gameVersion": gameVersion}))
  lines.join("\n") & "\n"
