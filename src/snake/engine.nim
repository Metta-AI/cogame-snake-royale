## A whole episode, played headlessly on the scripted layer.
##
## The server's own loop (`src/snake/server.nim`) is this loop plus the
## decision engine and the artifact writes; this module is the part that has no
## sockets and no clock, so the tests, `tools/tune_baselines.nim` and the
## fixture recorder all drive the SAME code the server drives rather than a
## second copy of the rules.

import board, rules, sim, sim_types, baselines, directives, records, replays

type
  ScriptedEpisode* = object
    episode*: Episode
    replay*: Replay
    events*: seq[TurnEvent]

proc runScriptedEpisodeWith*(config: GameConfig,
                             kinds: array[Seats, Baseline],
                             coil, forager: Tunables,
                             stopAfterTurn = 0,
                             stopReason = rsComplete,
                             stopEndRule = erFullTime): ScriptedEpisode =
  ## One episode, every seat scripted. Returns the settled episode, the replay
  ## the server would have written, and every event the turn loop emitted.
  ##
  ## `stopAfterTurn > 0` cuts the loop at that turn and settles with the given
  ## reason -- the ABNORMAL endings the server's own loop takes when the wall
  ## clock runs out or the sim faults. It writes the same `stop` record through
  ## the same proc, so a test can RECORD a `wall_clock` or `sim_fault` episode
  ## rather than appending a synthetic record to a healthy one.
  var episode = newEpisode(config)
  var replay = Replay(gameName: GameName, gameVersion: GameVersion)
  var events = episode.events
  for slot in 0 ..< Seats:
    episode.seats[slot].policyKind = "scripted"
    episode.seats[slot].baseline = $kinds[slot]
    episode.seats[slot].policyLabel = $kinds[slot]
    replay.joins.add((slot, episode.seats[slot].name,
      episode.seats[slot].token))
    replay.chats.add(registerRecord(slot, cogAlias(slot), episode.colour(slot),
      $kinds[slot], "scripted", $kinds[slot]))
  replay.configJson = replayConfigJson(episode)

  var
    endRule = erFullTime
    reason = rsComplete
    stopped = false
  while episode.state.aliveCount() > 1 and
        episode.state.turn < config.maxTurns:
    if stopAfterTurn > 0 and episode.state.turn >= stopAfterTurn:
      endRule = stopEndRule
      reason = stopReason
      stopped = true
      replay.chats.add(stopRecord(episode.state.turn, $endRule))
      break
    var
      dirs: array[Seats, Dir]
      alts: array[Seats, tuple[has: bool, dir: Dir]]
      bytes: array[Seats, uint8]
    for slot in 0 ..< Seats:
      if not episode.state.snakes[slot].alive:
        bytes[slot] = DeadDirByte
        dirs[slot] = episode.state.snakes[slot].lastDir
        continue
      let tuning = if kinds[slot] == blCoil: coil else: forager
      let order = scriptedOrderWith(episode.state, slot, tuning)
      dirs[slot] = order.dir
      bytes[slot] = uint8(ord(order.dir))
      replay.chats.add(boundedDirectiveRecord(order, episode.state.turn + 1,
        slot, cogAlias(slot), ""))
    let before = episode.state
    var turnEvents = resolveTurn(episode.state, dirs, alts)
    turnEvents.add(auditDeclinedKills(episode.state, before, dirs))
    events.add(turnEvents)
    replay.turns.add(ReplayTurn(dirs: bytes, hash: episode.state.gameHash))
  if not stopped and episode.state.aliveCount() <= 1:
    endRule = erLastStanding
  episode.turnsPlayed = episode.state.turn
  for slot in 0 ..< Seats:
    if episode.state.snakes[slot].alive:
      episode.state.snakes[slot].survivedTurns = episode.turnsPlayed
  episode.settle(reason, endRule)
  events.add(TurnEvent(kind: ekGameOver, turn: episode.turnsPlayed, slot: -1,
    other: -1, text: $endRule))
  events.add(TurnEvent(kind: ekEnd, turn: episode.turnsPlayed, slot: -1,
    other: -1, text: $reason))
  replay.chats.add(resultRecord(episode))
  ScriptedEpisode(episode: episode, replay: replay, events: events)

proc runScriptedEpisode*(config: GameConfig,
                         kinds: array[Seats, Baseline]): ScriptedEpisode =
  runScriptedEpisodeWith(config, kinds, CoilTunables, ForagerTunables)

type
  LadderTotals* = object
    ## The recorded 24-episode ladder: four seeds on each of the three rule
    ## modules, each seed played TWICE with the two baselines swapped between
    ## the seat pairs. The mirror is what makes the margin a measurement of
    ## the POLICIES: seats 0/2 and seats 1/3 spawn on different anchors, and
    ## on an unmirrored ladder two identical players still score -0.222 apart,
    ## so any margin read off it is mostly seat position. Mirrored, an
    ## identical pair scores exactly 0.0 by construction.
    ## One implementation, so `tools/tune_baselines.nim` and
    ## `tests/test_snake_control.nim` can never measure two different things.
    coilPermille*, foragerPermille*: int
    coilTurns*, foragerTurns*: int
    perModule*: array[3, tuple[coilPermille, foragerPermille,
                               coilTurns, foragerTurns: int]]

const
  LadderModules* = ["royale", "geese", "tron"]
  LadderSeeds* = 4
  LadderSeatings* = 2
  LadderSeedStride* = 977

proc ladderConfig*(module: string, seed: int): GameConfig =
  result = defaultGameConfig()
  result.module = module
  let preset = ruleModule(module)
  result.boardW = preset.board.w
  result.boardH = preset.board.h
  result.wrap = preset.board.wrap
  result.foodCount = preset.foodCount
  result.healthStart = preset.healthStart
  result.shrinkEvery = preset.shrinkEvery
  result.leaveTrail = preset.leaveTrail
  result.headToHead = $preset.headToHead
  result.startLength = preset.startLength
  result.maxTurns = preset.maxTurns
  result.seed = seed
  result.turnSpacingMs = 0

proc ladderTotals*(coil, forager: Tunables): LadderTotals =
  for index, module in LadderModules:
    for seed in 1 .. LadderSeeds:
      let config = ladderConfig(module, seed * LadderSeedStride)
      ## Seating A puts coil on seats 0/2; seating B swaps the pair. The same
      ## board, the same food stream, both ways round.
      for seating in 0 ..< LadderSeatings:
        let kinds =
          if seating == 0: [blCoil, blForager, blCoil, blForager]
          else: [blForager, blCoil, blForager, blCoil]
        let played = runScriptedEpisodeWith(config, kinds, coil, forager)
        let permille = played.episode.scorePermille()
        let snakes = played.episode.state.snakes
        for slot in 0 ..< Seats:
          if kinds[slot] == blCoil:
            result.perModule[index].coilPermille += permille[slot]
            result.perModule[index].coilTurns += snakes[slot].survivedTurns
          else:
            result.perModule[index].foragerPermille += permille[slot]
            result.perModule[index].foragerTurns += snakes[slot].survivedTurns
    result.coilPermille += result.perModule[index].coilPermille
    result.foragerPermille += result.perModule[index].foragerPermille
    result.coilTurns += result.perModule[index].coilTurns
    result.foragerTurns += result.perModule[index].foragerTurns

proc ladderMargin*(totals: LadderTotals): float =
  ## The mean score difference per seat, over the whole ladder.
  float(totals.coilPermille - totals.foragerPermille) /
    float(LadderModules.len * LadderSeeds * LadderSeatings * 2 * 1000)

proc allCoil*(): array[Seats, Baseline] =
  for slot in 0 ..< Seats:
    result[slot] = blCoil

proc certificationSeats*(): array[Seats, Baseline] =
  ## The certification fixture seats coil, forager, coil, forager.
  [blCoil, blForager, blCoil, blForager]
