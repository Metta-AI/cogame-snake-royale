## The broadcast packet: one JSON frame the viewer draws, and the chrome
## document the page's classic scorebug / clock / transport / scrubber /
## endcard read.
##
## `coworld-ctf` smuggles its chrome JSON through a reserved sprite label on
## the binary sprite channel; this fork carries it as a field of the same
## frame packet, for the same reason: the chrome must survive every playback
## path (live serve and hosted static replay) rather than riding a separate
## interactive text channel that a recorded stream never replays.
##
## `stepEvents` derives the broadcast events from state deltas during
## playback, so they cost no replay bytes and are identical live and in
## replay.

import std/[json, tables]
import board, rules, sim, sim_types, events, labels, replay_runtime

proc cellsJson(cells: seq[Cell]): JsonNode =
  result = newJArray()
  for c in cells:
    result.add(%[c.x, c.y])

proc placeOf(rt: ReplayRuntime, turn, slot: int): int =
  ## Live placement: alive snakes rank above dead ones, then by length.
  let snap = rt.snapshots[turn]
  result = 1
  for other in 0 ..< Seats:
    if other == slot:
      continue
    let better =
      if snap.alive[other] != snap.alive[slot]: snap.alive[other]
      elif snap.length[other] != snap.length[slot]:
        snap.length[other] > snap.length[slot]
      else: other < slot
    if better:
      inc result

proc stepEvents*(rt: ReplayRuntime, turn: int): seq[TurnEvent] =
  ## Every event whose turn is exactly `turn`.
  for e in rt.events:
    if e.turn == turn:
      result.add(e)

proc chromeJson*(rt: ReplayRuntime, turn: int): JsonNode =
  ## The classic broadcast chrome document. Field names are the starter's, so
  ## `chrome_common.js` -- copied BYTE-FOR-BYTE -- reads it unchanged:
  ## `t`/`st`/`mx`/`mt` are the timeline, `ph` the phase, `sp`/`pl`/`lp`/`sk`/
  ## `ff`/`en` the transport, `roster` the seats, `beats` the up-front
  ## scrubber timeline, `lulls` the quiet spans and `lead` the momentum
  ## series.
  let
    snap = rt.snapshots[turn]
    turns = rt.snapshots.len - 1
  var roster = newJArray()
  for slot in 0 ..< Seats:
    roster.add(%*{
      "s": slot,
      "name": rt.names[slot],
      "alias": cogAlias(slot),
      "colour": rt.colours[slot],
      "alive": snap.alive[slot],
      "len": snap.length[slot],
      "hp": snap.health[slot],
      "free": snap.freeSpace[slot],
      "trapped": snap.trapped[slot],
      "place": placeOf(rt, turn, slot),
      "kind": rt.policyKinds[slot],
      "fallback": rt.fallbackTurns.len > 0 and rt.policyKinds[slot] == "llm"
    })
  var beats = newJArray()
  for b in rt.beats:
    beats.add(%*{"t": b.turn, "k": b.kind, "slot": b.slot, "label": b.label})
  var lulls = newJArray()
  for span in rt.lulls:
    lulls.add(%[span[0], span[1]])
  var leadPts = newJArray()
  for turnIndex, series in rt.lengthSeries:
    var row = newJArray()
    row.add(%turnIndex)
    for slot in 0 ..< Seats:
      row.add(%series[slot])
    leadPts.add(row)
  var feed = newJArray()
  for e in stepEvents(rt, turn):
    let row = feedRow(rt.episode, e)
    if row.len > 0:
      feed.add(%*{"k": $e.kind, "slot": e.slot, "row": row})
  let phase =
    if turn == 0: "lobby"
    elif turn >= turns: "gameover"
    else: "playing"
  result = %*{
    "t": turn,
    "st": 0,
    "mx": max(1, turns),
    "mt": rt.config.maxTurns,
    "turn": turn,
    "turns": turns,
    "ph": phase,
    "lob": 0,
    "sp": rt.displaySpeed(),
    "pl": rt.playback.playing,
    "lp": rt.playback.loop,
    "sk": rt.playback.skipLulls,
    "ff": rt.playback.fastForward,
    "en": true,
    "over": turn >= turns,
    "alive": snap.aliveCount,
    "module": rt.config.module,
    "moduleLine": rt.episode.moduleLine(),
    "boardW": rt.config.boardW,
    "boardH": rt.config.boardH,
    "wrap": rt.config.wrap,
    "duel": rt.duelTurn,
    "mismatch": rt.mismatchTurn,
    "roster": roster,
    "beats": beats,
    "lulls": lulls,
    "lead": {"teams": ["s0", "s1", "s2", "s3"], "pts": leadPts},
    "feed": feed,
    "results": (if rt.resultsJson.len > 0: parseJson(rt.resultsJson)
                else: newJNull())
  }

proc framePacket*(rt: ReplayRuntime): string =
  ## One drawn frame. `alpha` is the interpolation phase inside the turn; the
  ## renderer glides a head from its previous cell to its current one over the
  ## turn instead of teleporting.
  let
    perTurn = max(1, rt.playback.framesPerTurn)
    turn = rt.turnAt(rt.playback.frame)
    within = rt.playback.frame - turn * perTurn
    snap = rt.snapshots[turn]
    prev = rt.snapshots[max(0, turn - 1)]
  var alpha = 1000
  if turn > 0 and within < perTurn:
    alpha = (within * 1000) div perTurn
  var snakes = newJArray()
  for slot in 0 ..< Seats:
    snakes.add(%*{
      "slot": slot,
      "alias": cogAlias(slot),
      "name": rt.names[slot],
      "colour": rt.colours[slot],
      "alive": snap.alive[slot],
      "body": cellsJson(snap.bodies[slot]),
      "prev": cellsJson(prev.bodies[slot]),
      "length": snap.length[slot],
      "health": snap.health[slot],
      "free": snap.freeSpace[slot],
      "trapped": snap.trapped[slot],
      "ate": snap.ate[slot],
      "dir": int(snap.dirs[slot]),
      "died": (not snap.alive[slot]) and prev.alive[slot]
    })
  var bubbles = newJArray()
  for slot in 0 ..< Seats:
    for back in 0 ..< max(1, rt.config.sayTurns):
      let key = (turn - back) * Seats + slot
      if rt.says.hasKey(key) and snap.bodies[slot].len > 0:
        bubbles.add(%*{
          "slot": slot,
          "text": rt.says[key],
          "x": snap.bodies[slot][0].x,
          "y": snap.bodies[slot][0].y
        })
        break
  var flashes = newJArray()
  for e in stepEvents(rt, turn):
    if e.kind in {ekHeadOn, ekEat, ekDeath}:
      flashes.add(%*{"k": $e.kind, "x": e.at.x, "y": e.at.y, "slot": e.slot})
  $(%*{
    "protocol": ProtocolName,
    "board": {"w": rt.config.boardW, "h": rt.config.boardH,
              "wrap": rt.config.wrap, "cellPx": DefaultCellPx,
              "trail": rt.config.leaveTrail},
    "alpha": alpha,
    "snakes": snakes,
    "food": cellsJson(snap.food),
    "bubbles": bubbles,
    "flashes": flashes,
    "chrome": chromeJson(rt, turn)
  })
