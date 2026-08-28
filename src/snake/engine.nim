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
                             coil, forager: Tunables): ScriptedEpisode =
  ## One episode, every seat scripted. Returns the settled episode, the replay
  ## the server would have written, and every event the turn loop emitted.
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

  var endRule = erFullTime
  while episode.state.aliveCount() > 1 and
        episode.state.turn < config.maxTurns:
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
  if episode.state.aliveCount() <= 1:
    endRule = erLastStanding
  episode.turnsPlayed = episode.state.turn
  for slot in 0 ..< Seats:
    if episode.state.snakes[slot].alive:
      episode.state.snakes[slot].survivedTurns = episode.turnsPlayed
  episode.settle(rsComplete, endRule)
  events.add(TurnEvent(kind: ekGameOver, turn: episode.turnsPlayed, slot: -1,
    other: -1, text: $endRule))
  events.add(TurnEvent(kind: ekEnd, turn: episode.turnsPlayed, slot: -1,
    other: -1, text: $rsComplete))
  replay.chats.add(resultRecord(episode))
  ScriptedEpisode(episode: episode, replay: replay, events: events)

proc runScriptedEpisode*(config: GameConfig,
                         kinds: array[Seats, Baseline]): ScriptedEpisode =
  runScriptedEpisodeWith(config, kinds, CoilTunables, ForagerTunables)

type
  LadderTotals* = object
    ## The recorded 24-episode ladder: eight seeds on each of the three rule
    ## modules, seated coil, forager, coil, forager. One implementation, so
    ## `tools/tune_baselines.nim` and `tests/test_snake_control.nim` can never
    ## measure two different things.
    coilPermille*, foragerPermille*: int
    coilTurns*, foragerTurns*: int
    perModule*: array[3, tuple[coilPermille, foragerPermille,
                               coilTurns, foragerTurns: int]]

const
  LadderModules* = ["royale", "geese", "tron"]
  LadderSeeds* = 8
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
      let played = runScriptedEpisodeWith(
        ladderConfig(module, seed * LadderSeedStride),
        [blCoil, blForager, blCoil, blForager], coil, forager)
      let permille = played.episode.scorePermille()
      let snakes = played.episode.state.snakes
      result.perModule[index].coilPermille += permille[0] + permille[2]
      result.perModule[index].foragerPermille += permille[1] + permille[3]
      result.perModule[index].coilTurns +=
        snakes[0].survivedTurns + snakes[2].survivedTurns
      result.perModule[index].foragerTurns +=
        snakes[1].survivedTurns + snakes[3].survivedTurns
    result.coilPermille += result.perModule[index].coilPermille
    result.foragerPermille += result.perModule[index].foragerPermille
    result.coilTurns += result.perModule[index].coilTurns
    result.foragerTurns += result.perModule[index].foragerTurns

proc ladderMargin*(totals: LadderTotals): float =
  ## The mean score difference per seat, over the whole ladder.
  float(totals.coilPermille - totals.foragerPermille) /
    float(LadderModules.len * LadderSeeds * 2 * 1000)

proc allCoil*(): array[Seats, Baseline] =
  for slot in 0 ..< Seats:
    result[slot] = blCoil

proc certificationSeats*(): array[Seats, Baseline] =
  ## The certification fixture seats coil, forager, coil, forager.
  [blCoil, blForager, blCoil, blForager]
