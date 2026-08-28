## Replaying an episode from the recorded bytes alone.
##
## The wasm viewer and the game's own local `/client/replay` route both drive
## this: decode the replay, rebuild the `GameConfig` from the recorded config
## document, and re-run `resolveTurn` over the recorded direction bytes. The
## per-turn `gameHash` is checked against the recorded chain, and the first
## divergent turn is what the viewer's `#mmwarn` reports.
##
## The load-time PRE-SCAN runs the whole episode once, headlessly, and records
## the per-turn length series, the per-turn alive count, the duel turn, every
## beat turn and the lull spans -- which is what lets the length ribbon, the
## momentum graph and the scrubber beats draw at FULL WIDTH on the first frame
## instead of growing in.

import std/[json, strutils, tables]
import board, rules, sim, sim_types, replays, events, directives

type
  Snapshot* = object
    turn*: int
    bodies*: array[Seats, seq[Cell]]
    alive*: array[Seats, bool]
    health*: array[Seats, int]
    length*: array[Seats, int]
    freeSpace*: array[Seats, int]
    trapped*: array[Seats, bool]
    ate*: array[Seats, bool]
    deathTurn*: array[Seats, int]
    deathCause*: array[Seats, string]
    food*: seq[Cell]
    aliveCount*: int
    hash*: uint64
    dirs*: array[Seats, uint8]

  Beat* = object
    turn*: int
    kind*: string
    slot*: int
    label*: string

  Playback* = object
    playing*: bool
    speed*: int
    loop*: bool
    skipLulls*: bool
    fastForward*: bool
    frame*: int                 ## absolute render frame
    framesPerTurn*: int

  ReplayRuntime* = object
    replay*: Replay
    config*: GameConfig
    episode*: Episode
    snapshots*: seq[Snapshot]
    events*: seq[TurnEvent]
    beats*: seq[Beat]
    lulls*: seq[array[2, int]]
    lengthSeries*: seq[array[Seats, int]]
    aliveSeries*: seq[int]
    says*: Table[int, string]   ## (turn * Seats + slot) -> text
    fallbackTurns*: seq[int]
    duelTurn*: int
    mismatchTurn*: int
    resultsJson*: string
    playback*: Playback
    names*: array[Seats, string]
    colours*: array[Seats, string]
    policyKinds*: array[Seats, string]
    stopTurn*: int
    stopEndRule*: string

const LullSpanTurns* = 6

proc snapshotOf(episode: Episode, dirs: array[Seats, uint8]): Snapshot =
  result.turn = episode.state.turn
  for slot in 0 ..< Seats:
    let s = episode.state.snakes[slot]
    result.bodies[slot] = s.body
    result.alive[slot] = s.alive
    result.health[slot] = s.health
    result.length[slot] = s.length()
    result.freeSpace[slot] = s.freeSpace
    result.trapped[slot] = s.trapped
    result.ate[slot] = s.ate
    result.deathTurn[slot] = s.deathTurn
    result.deathCause[slot] = $s.deathCause
    result.dirs[slot] = dirs[slot]
  result.food = episode.state.food
  result.aliveCount = episode.state.aliveCount()
  result.hash = episode.state.gameHash

proc beatLabel(kind: string, slot, value: int): string =
  case kind
  of "eat": cogAlias(slot) & " eats — length " & $value & " — click to jump here"
  of "headon": "Head-on — click to jump here"
  of "death": cogAlias(slot) & " is out — click to jump here"
  of "trapped": cogAlias(slot) & " is trapped — click to jump here"
  of "duel": "Two snakes left — half speed — click to jump here"
  of "fallback": cogAlias(slot) & " missed the call — click to jump here"
  of "gameover": "Last snake standing — click to jump here"
  else: kind

proc ingestChats(rt: var ReplayRuntime) =
  for record in rt.replay.chats:
    if record.len == 0 or record[0] != '{':
      continue
    var node: JsonNode
    try:
      node = parseJson(record)
    except CatchableError:
      continue
    case node{"k"}.getStr()
    of "directive":
      let
        turn = node{"turn"}.getInt(0)
        slot = node{"slot"}.getInt(-1)
        say = node{"say"}.getStr()
      if slot >= 0 and slot < Seats and say.len > 0:
        rt.says[turn * Seats + slot] = say
    of "fallback":
      rt.fallbackTurns.add(node{"turn"}.getInt(0))
    of "register":
      let slot = node{"slot"}.getInt(-1)
      if slot >= 0 and slot < Seats:
        rt.policyKinds[slot] = node{"kind"}.getStr("scripted")
    of "stop":
      rt.stopTurn = node{"turn"}.getInt(0)
      rt.stopEndRule = node{"endRule"}.getStr("wall_clock")
    of "result":
      rt.resultsJson = $node{"results"}
    else:
      discard

proc preScan*(rt: var ReplayRuntime) =
  ## Re-simulate the whole episode once, headlessly. Under a millisecond in
  ## wasm: at most fifty turns of four snakes of integer work plus one bounded
  ## flood fill each.
  rt.episode = newEpisode(rt.config)
  rt.mismatchTurn = -1
  rt.duelTurn = -1
  var zero: array[Seats, uint8]
  for slot in 0 ..< Seats:
    zero[slot] = DeadDirByte
  rt.snapshots.add(snapshotOf(rt.episode, zero))
  var lengths: array[Seats, int]
  for slot in 0 ..< Seats:
    lengths[slot] = rt.episode.state.snakes[slot].length()
  rt.lengthSeries.add(lengths)
  rt.aliveSeries.add(rt.episode.state.aliveCount())

  for index, recorded in rt.replay.turns:
    var
      dirs: array[Seats, Dir]
      alts: array[Seats, tuple[has: bool, dir: Dir]]
    for slot in 0 ..< Seats:
      let byte = recorded.dirs[slot]
      dirs[slot] =
        if byte < uint8(DirOrder.len): DirOrder[int(byte)]
        else: rt.episode.state.snakes[slot].lastDir
    let before = rt.episode.state
    var turnEvents = resolveTurn(rt.episode.state, dirs, alts)
    turnEvents.add(auditDeclinedKills(rt.episode.state, before, dirs))
    for slot in 0 ..< Seats:
      let key = (index + 1) * Seats + slot
      if rt.says.hasKey(key):
        turnEvents.add(TurnEvent(kind: ekSay, turn: index + 1, slot: slot,
          other: -1, at: rt.episode.state.snakes[slot].head(),
          text: rt.says[key]))
    rt.events.add(turnEvents)
    if rt.mismatchTurn < 0 and rt.episode.state.gameHash != recorded.hash:
      rt.mismatchTurn = index + 1
    rt.snapshots.add(snapshotOf(rt.episode, recorded.dirs))
    var series: array[Seats, int]
    for slot in 0 ..< Seats:
      series[slot] = rt.episode.state.snakes[slot].length()
    rt.lengthSeries.add(series)
    rt.aliveSeries.add(rt.episode.state.aliveCount())
    if rt.duelTurn < 0 and rt.episode.state.aliveCount() == 2:
      rt.duelTurn = index + 1

  rt.episode.turnsPlayed = rt.replay.turns.len

  # Beats: eat only for a snake's FIRST apple and for any apple that makes it
  # the longest snake, so a fifty-turn scrubber stays readable.
  var firstEat: array[Seats, bool]
  for e in rt.events:
    if not isBeatKind(e.kind):
      continue
    if e.kind == ekEat:
      var longest = true
      for other in 0 ..< Seats:
        if other != e.slot and
            rt.lengthSeries[min(e.turn, rt.lengthSeries.len - 1)][other] >=
              e.value:
          longest = false
          break
      if firstEat[e.slot] and not longest:
        continue
      firstEat[e.slot] = true
    rt.beats.add(Beat(turn: e.turn, kind: $e.kind, slot: e.slot,
      label: beatLabel($e.kind, e.slot, e.value)))
  for turn in rt.fallbackTurns:
    rt.beats.add(Beat(turn: turn, kind: "fallback", slot: -1,
      label: beatLabel("fallback", 0, 0)))
  rt.beats.add(Beat(turn: rt.replay.turns.len, kind: "gameover", slot: -1,
    label: beatLabel("gameover", 0, 0)))

  # Lulls: six consecutive turns with no eat, headon, death, trapped or
  # decline event.
  var loud = newSeq[bool](rt.replay.turns.len + 2)
  for e in rt.events:
    if e.kind in {ekEat, ekHeadOn, ekDeath, ekTrapped, ekDecline} and
        e.turn < loud.len:
      loud[e.turn] = true
  var run = 0
  for turn in 0 ..< loud.len:
    if loud[turn]:
      if run >= LullSpanTurns:
        rt.lulls.add([turn - run, turn - 1])
      run = 0
    else:
      inc run
  if run >= LullSpanTurns:
    rt.lulls.add([loud.len - run, loud.len - 1])

proc loadReplay*(bytes: string): ReplayRuntime =
  result.replay = decodeReplay(bytes)
  result.config = configOf(result.replay)
  for slot in 0 ..< Seats:
    result.names[slot] = defaultPlayerName(slot)
    result.policyKinds[slot] = "scripted"
  for join in result.replay.joins:
    if join.slot >= 0 and join.slot < Seats:
      result.names[join.slot] = join.name
  let node = parseJson(result.replay.configJson)
  let colours = node{"colours"}
  for slot in 0 ..< Seats:
    result.colours[slot] =
      if not colours.isNil and slot < colours.len: colours[slot].getStr()
      else: Colours[slot]
  result.stopTurn = -1
  result.says = initTable[int, string]()
  result.ingestChats()
  result.playback = Playback(playing: true, speed: 1, loop: false,
    skipLulls: false, frame: 0,
    framesPerTurn: max(1, result.config.renderFramesPerTurn))
  result.preScan()

proc totalFrames*(rt: ReplayRuntime): int =
  max(1, (rt.snapshots.len - 1) * rt.playback.framesPerTurn + 1)

proc turnAt*(rt: ReplayRuntime, frame: int): int =
  min(rt.snapshots.len - 1, frame div rt.playback.framesPerTurn)

proc duelActive*(rt: ReplayRuntime, turn: int): bool =
  rt.duelTurn >= 0 and turn >= rt.duelTurn

proc framesPerTurnAt*(rt: ReplayRuntime, turn: int): int =
  ## Duel slow-mo: from the pre-scan's duel turn the block doubles the frames
  ## per turn, i.e. half speed.
  if rt.duelActive(turn): rt.playback.framesPerTurn * 2
  else: rt.playback.framesPerTurn

proc inLull*(rt: ReplayRuntime, turn: int): bool =
  for span in rt.lulls:
    if turn >= span[0] and turn <= span[1]:
      return true
  false

proc advance*(rt: var ReplayRuntime) =
  ## One render frame of playback.
  if not rt.playback.playing:
    return
  let last = rt.totalFrames() - 1
  var step = max(1, rt.playback.speed)
  rt.playback.fastForward = false
  if rt.playback.skipLulls and rt.inLull(rt.turnAt(rt.playback.frame)):
    step = step * 4
    rt.playback.fastForward = true
  rt.playback.frame = rt.playback.frame + step
  if rt.playback.frame >= last:
    if rt.playback.loop:
      rt.playback.frame = 0
    else:
      rt.playback.frame = last
      rt.playback.playing = false

proc seekFraction*(rt: var ReplayRuntime, fraction: float) =
  let last = rt.totalFrames() - 1
  var f = fraction
  if f < 0.0: f = 0.0
  if f > 1.0: f = 1.0
  rt.playback.frame = int(f * last.float)

proc command*(rt: var ReplayRuntime, text: string) =
  ## The transport commands the chrome sends down the same channel the native
  ## client uses.
  if text.len == 0:
    return
  case text[0]
  of ' ': rt.playback.playing = not rt.playback.playing
  of ',': rt.playback.frame = 0
  of 'b': rt.playback.frame = max(0, rt.playback.frame -
            rt.playback.framesPerTurn)
  of '.': rt.playback.frame = min(rt.totalFrames() - 1,
            rt.playback.frame + ReplayFps * 5)
  of 'e': rt.playback.frame = rt.totalFrames() - 1
  of 'r': rt.playback.loop = not rt.playback.loop
  of 'f': rt.playback.skipLulls = not rt.playback.skipLulls
  of '1': rt.playback.speed = 1
  of '2': rt.playback.speed = 2
  of '3': rt.playback.speed = 3
  of '4': rt.playback.speed = 4
  of '8': rt.playback.speed = 8
  of '6': rt.playback.speed = 16
  of 's':
    let parts = text.split(':')
    if parts.len == 2:
      try:
        rt.seekFraction(parseFloat(parts[1]))
      except CatchableError:
        discard
  else: discard
