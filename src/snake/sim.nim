## `import snake/sim` sees everything the sim is made of -- the starter's rule.
##
## The COMMANDER layer (`directives`, `llm`, `baselines`, `control`, `decide`)
## is deliberately NOT re-exported here: the wasm replay module compiles this
## file and must not drag in curl.

import std/[algorithm, json, math, unicode]
import board, rules, space, sim_state, sim_config, sim_types, roster, upstream
export board, rules, space, sim_state, sim_config, sim_types, roster, upstream

type
  SeatInfo* = object
    name*: string               ## the REAL policy name -- spectator side only
    token*: string
    joined*: bool
    registered*: bool
    dead*: bool                 ## never registered, or never answered
    policyKind*: string         ## llm | scripted
    policyLabel*: string
    baseline*: string
    llmTurns*: int
    fallbackTurns*: int
    ordersRejected*: int
    saidTurns*: int
    say*: string
    sayTurnsLeft*: int
    notes*: string

  EndRule* = enum
    erLastStanding = "last_standing"
    erFullTime = "full_time"
    erWallClock = "wall_clock"
    erSimFault = "sim_fault"
    erHostError = "host_error"

  EndReason* = enum
    rsComplete = "complete"
    rsDeadline = "deadline"
    rsFault = "fault"

  Episode* = object
    ## Everything one episode is. The server drives it; the replay runtime
    ## re-derives it from the recorded seed and direction bytes alone.
    config*: GameConfig
    state*: GameState
    seats*: array[Seats, SeatInfo]
    spawnDeal*: seq[int]
    events*: seq[TurnEvent]
    over*: bool
    reason*: EndReason
    endRule*: EndRule
    stopDetail*: string
    turnsPlayed*: int
    crossPlay*: bool

proc cutRunes*(text: string, limit: int): string =
  ## Rune-boundary truncation for the one string this module records itself
  ## (`stopDetail`). Every other capped field goes through
  ## `src/snake/directives.nim`'s `truncateRunes`; both cut on a RUNE
  ## boundary, never a byte index.
  if limit <= 0: return ""
  if text.runeLen <= limit: return text
  text.runeSubStr(0, limit)

proc drawSpawnDeal*(seed: int): seq[int] =
  ## Drawn from the seeded SETUP stream, BEFORE any seat connects, so nothing
  ## a policy does can shift it and no seat can learn "I am always the
  ## top-left snake" (the idea's anti-collusion ask).
  var rng = initRng(seed)
  rng.shuffled(@[0, 1, 2, 3])

proc newEpisode*(config: GameConfig): Episode =
  result.config = config
  result.spawnDeal = drawSpawnDeal(config.seed)
  let built = initGameState(rulesFromConfig(config), config.seed,
    result.spawnDeal)
  result.state = built.state
  result.events = built.events
  result.reason = rsComplete
  result.endRule = erFullTime
  for slot in 0 ..< Seats:
    result.seats[slot].name =
      if slot < config.playerNames.len and config.playerNames[slot].len > 0:
        config.playerNames[slot]
      else:
        defaultPlayerName(slot)
    result.seats[slot].token =
      if slot < config.tokens.len: config.tokens[slot] else: ""
    result.seats[slot].policyKind = "scripted"
    result.seats[slot].baseline = "coil"
    result.seats[slot].policyLabel = "coil"

proc alias*(episode: Episode, slot: int): string = cogAlias(slot)
proc colour*(episode: Episode, slot: int): string =
  colourOf(episode.spawnDeal, slot)

proc moduleLine*(episode: Episode): string =
  ## The one-line module summary the clock caption and the endcard show.
  let r = episode.state.rules
  result = r.name & " · " & $r.board.w & "×" & $r.board.h & " · " &
    (if r.board.wrap: "torus" else: "walls") & " · food " & $r.foodCount &
    " · health " & (if r.healthStart > 0: "on" else: "off")

# ---------------------------------------------------------------------------
#  Scoring: a placement vector, not a winner.
# ---------------------------------------------------------------------------

proc scoreKey*(episode: Episode, slot: int): array[3, int] =
  [episode.state.snakes[slot].survivedTurns,
   episode.state.snakes[slot].finalLength,
   episode.state.snakes[slot].foodEaten]

proc placements*(episode: Episode): array[Seats, int] =
  ## Places 1..4, descending by (survivedTurns, finalLength, foodEaten). Seats
  ## with an identical key SHARE a place -- that is a genuine tie.
  var order: seq[int] = @[]
  for slot in 0 ..< Seats:
    order.add(slot)
  order.sort(proc (a, b: int): int =
    let
      ka = episode.scoreKey(a)
      kb = episode.scoreKey(b)
    for i in 0 .. 2:
      if ka[i] != kb[i]:
        return kb[i] - ka[i]
    a - b)
  var place = 1
  var index = 0
  while index < order.len:
    var span = 1
    while index + span < order.len and
        episode.scoreKey(order[index + span]) == episode.scoreKey(order[index]):
      inc span
    for k in 0 ..< span:
      result[order[index + k]] = place
    place = place + span
    index = index + span

proc scorePermille*(episode: Episode): array[Seats, int] =
  ## A tied group occupying places p .. p+k-1 splits that slice EXACTLY, with
  ## `floorDiv` / `floorMod` -- never Nim's `div`, which truncates toward zero
  ## and would lose a permille on a negative slice, breaking the exact zero
  ## sum the league ranks on.
  let place = episode.placements()
  var handled: array[Seats, bool]
  for slot in 0 ..< Seats:
    if handled[slot]:
      continue
    var group: seq[int] = @[]
    for other in 0 ..< Seats:
      if place[other] == place[slot]:
        group.add(other)
        handled[other] = true
    group.sort(proc (a, b: int): int = a - b)   ## ascending slot order
    var total = 0
    for k in 0 ..< group.len:
      total = total + PlacementPermille[place[slot] - 1 + k]
    let
      base = floorDiv(total, group.len)
      rem = floorMod(total, group.len)
    for k, member in group:
      result[member] = base + (if k < rem: 1 else: 0)

proc snakeResultsJson*(episode: Episode): string =
  ## The closed results schema. Adding a key means updating this proc, the
  ## manifest's `results_schema` and `tools/ci/docker_smoke.sh`'s expected-key
  ## set IN THE SAME COMMIT -- Coworld schemas are closed and undeclared keys
  ## are dropped.
  let
    place = episode.placements()
    permille = episode.scorePermille()
  var
    names = newJArray()
    aliases = newJArray()
    colours = newJArray()
    scores = newJArray()
    win = newJArray()
    places = newJArray()
    survived = newJArray()
    deathTurn = newJArray()
    deathCause = newJArray()
    killedBy = newJArray()
    finalLength = newJArray()
    maxLength = newJArray()
    foodEaten = newJArray()
    declined = newJArray()
    trapped = newJArray()
    reversed = newJArray()
    saidTurns = newJArray()
    kinds = newJArray()
    llmTurns = newJArray()
    fallbacks = newJArray()
    rejected = newJArray()
    deadSeats = newJArray()
  for slot in 0 ..< Seats:
    let s = episode.state.snakes[slot]
    names.add(%episode.seats[slot].name)
    aliases.add(%cogAlias(slot))
    colours.add(%episode.colour(slot))
    scores.add(%(permille[slot].float / 1000.0))
    win.add(%(place[slot] == 1))
    places.add(%place[slot])
    survived.add(%s.survivedTurns)
    deathTurn.add(%s.deathTurn)
    deathCause.add(%($s.deathCause))
    killedBy.add(%s.killedBy)
    finalLength.add(%s.finalLength)
    maxLength.add(%s.maxLength)
    foodEaten.add(%s.foodEaten)
    declined.add(%s.declinedKills)
    trapped.add(%s.trappedTurns)
    reversed.add(%s.reverseRepaired)
    saidTurns.add(%episode.seats[slot].saidTurns)
    kinds.add(%episode.seats[slot].policyKind)
    llmTurns.add(%episode.seats[slot].llmTurns)
    fallbacks.add(%episode.seats[slot].fallbackTurns)
    rejected.add(%episode.seats[slot].ordersRejected)
    deadSeats.add(%episode.seats[slot].dead)
  $(%*{
    "names": names,
    "aliases": aliases,
    "colours": colours,
    "scores": scores,
    "win": win,
    "place": places,
    "reason": $episode.reason,
    "endRule": $episode.endRule,
    "module": episode.state.rules.name,
    "turnsPlayed": episode.turnsPlayed,
    "survivedTurns": survived,
    "deathTurn": deathTurn,
    "deathCause": deathCause,
    "killedBy": killedBy,
    "finalLength": finalLength,
    "maxLength": maxLength,
    "foodEaten": foodEaten,
    "declinedKills": declined,
    "trappedTurns": trapped,
    "reverseRepaired": reversed,
    "saidTurns": saidTurns,
    "policyKinds": kinds,
    "crossPlay": episode.crossPlay,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbacks,
    "ordersRejected": rejected,
    "deadSeats": deadSeats,
    "seed": episode.config.seed,
    "stopDetail": episode.stopDetail.cutRunes(MaxStopDetailRunes)
  })

proc settle*(episode: var Episode, reason: EndReason, endRule: EndRule,
             detail = "") =
  episode.reason = reason
  episode.endRule = endRule
  if detail.len > 0:
    episode.stopDetail = detail
  episode.over = true
  var kinds: array[2, bool]
  for slot in 0 ..< Seats:
    if episode.seats[slot].policyKind == "llm": kinds[0] = true
    else: kinds[1] = true
  episode.crossPlay = kinds[0] and kinds[1]
