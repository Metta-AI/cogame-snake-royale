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

proc runScriptedEpisode*(config: GameConfig,
                         kinds: array[Seats, Baseline]): ScriptedEpisode =
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
      let order = scriptedOrder(episode.state, slot, kinds[slot])
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

proc allCoil*(): array[Seats, Baseline] =
  for slot in 0 ..< Seats:
    result[slot] = blCoil

proc certificationSeats*(): array[Seats, Baseline] =
  ## The certification fixture seats coil, forager, coil, forager.
  [blCoil, blForager, blCoil, blForager]
