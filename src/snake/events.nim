## The closed event vocabulary, the beat kinds, and the tier-2 JSON-lines
## analysis stream.
##
## Two vocabularies, deliberately:
##
## * `EventKind` (rules.nim) is the BROADCAST set -- a closed enum of sixteen
##   kinds that `stepEvents` derives from state deltas at playback, so the feed
##   and the scrubber cost no replay bytes. `tests/test_snake_events.nim`
##   asserts the emitted set is exactly those sixteen.
## * `SimEventKind` here is the TIER-2 ANALYSIS set the design note's §Record
##   and event vocabulary C specifies for `COGAME_EVENTS_URI`: fourteen kinds,
##   with the wire key for each, following the starter's `key()` shape. It is
##   the broadcast set minus `gamestart`, `spawn` and `end` -- which say
##   nothing the replay config and the results document do not already say --
##   plus `directive`, which the sim cannot derive because it is a fact about
##   the DECISION, not about the board.

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

type
  SimEventKind* = enum
    ## Design note §Record and event vocabulary C, in its order.
    seTurnStart, seMove, seEat, seFoodSpawn, seShrink, seHeadOn, seDeath,
    seTrapped, seDecline, seDuel, seSay, seDirective, seFallback, seGameOver

  DirectiveEvent* = object
    ## One seat's installed order for one turn. Not a board fact, so no
    ## `TurnEvent` carries it; the decision layer hands these to the stream.
    turn*, slot*: int
    alias*, source*, dir*: string
    latencyMs*: int
    repaired*: bool

proc key*(kind: SimEventKind): string =
  ## The JSON event key for one tier-2 kind (the starter's `key()` shape).
  case kind
  of seTurnStart: "turn"
  of seMove: "move"
  of seEat: "eat"
  of seFoodSpawn: "foodspawn"
  of seShrink: "shrink"
  of seHeadOn: "headon"
  of seDeath: "death"
  of seTrapped: "trapped"
  of seDecline: "decline"
  of seDuel: "duel"
  of seSay: "say"
  of seDirective: "directive"
  of seFallback: "fallback"
  of seGameOver: "gameover"

proc simKindOf*(kind: EventKind): tuple[carried: bool, sim: SimEventKind] =
  ## Which tier-2 kind a broadcast event becomes, if any.
  case kind
  of ekTurn: (true, seTurnStart)
  of ekMove: (true, seMove)
  of ekEat: (true, seEat)
  of ekFoodSpawn: (true, seFoodSpawn)
  of ekShrink: (true, seShrink)
  of ekHeadOn: (true, seHeadOn)
  of ekDeath: (true, seDeath)
  of ekTrapped: (true, seTrapped)
  of ekDecline: (true, seDecline)
  of ekDuel: (true, seDuel)
  of ekSay: (true, seSay)
  of ekFallback: (true, seFallback)
  of ekGameOver: (true, seGameOver)
  of ekGameStart, ekSpawn, ekEnd: (false, seTurnStart)

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

proc directiveJson*(d: DirectiveEvent): JsonNode =
  %*{"k": key(seDirective), "t": d.turn, "slot": d.slot, "alias": d.alias,
     "source": d.source, "dir": d.dir, "latency_ms": d.latencyMs,
     "repaired": d.repaired}

proc eventsJsonl*(events: seq[TurnEvent], turns: int,
                  gameVersion: string,
                  directives: seq[DirectiveEvent] = @[]): string =
  ## `COGAME_EVENTS_URI` gets one JSON object per line, in turn order, with the
  ## mandatory trailing summary row. A turn's directives come before that
  ## turn's board events, because the decision precedes the resolution.
  var lines: seq[string]
  var next = 0
  var carried = 0
  for e in events:
    while next < directives.len and directives[next].turn <= e.turn:
      lines.add($directiveJson(directives[next]))
      inc next
    let mapped = simKindOf(e.kind)
    if not mapped.carried:
      continue
    inc carried
    var row = eventJson(e)
    row["k"] = %key(mapped.sim)
    lines.add($row)
  while next < directives.len:
    lines.add($directiveJson(directives[next]))
    inc next
  lines.add($(%*{
    "type": "summary", "turns": turns,
    "events": carried + directives.len,
    "gameVersion": gameVersion}))
  lines.join("\n") & "\n"
