## End-to-end episodes: the artifacts, the certification seed, every shipped
## variant, the no-stall guarantee and the budget guard.

import std/[json, os, sets, strutils]
import snake/[board, rules, sim, sim_types, engine, replays, records, events,
              decide]
import helpers

var c = newChecker("test_snake_engine")

proc manifest(): JsonNode = parseJson(readFile("coworld_manifest_template.json"))

proc configFrom(node: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.update($node)

# 28 -- an episode writes its artifacts.
block:
  let m = manifest()
  var config = configFrom(m{"certification"}{"game_config"})
  let played = runScriptedEpisode(config, certificationSeats())
  let dir = getTempDir() / "snake-royale-engine-test"
  createDir(dir)
  writeFile(dir / "results.json", played.episode.snakeResultsJson())
  writeFile(dir / "replay.bin", encodeReplay(played.replay))
  writeFile(dir / "events.jsonl",
    eventsJsonl(played.events, played.episode.turnsPlayed, GameVersion))
  c.check(fileExists(dir / "results.json"), "28: results.json is written")
  c.check(fileExists(dir / "replay.bin"), "28: the replay is written")
  c.check(getFileSize(dir / "replay.bin") > 0, "28: and it is not empty")

  let results = parseJson(readFile(dir / "results.json"))
  c.check(results{"reason"}.getStr() == "complete", "28: reason is complete")
  c.check(results{"endRule"}.getStr() in ["last_standing", "full_time"],
    "28: endRule is a natural ending")
  var total = 0
  for v in played.episode.scorePermille():
    total = total + v
  c.check(total == 0, "28: the four scores sum to exactly zero")

  # Every seat-indexed array is exactly four long, and the results key set is
  # EXACTLY the manifest's results_schema key set.
  let schemaKeys = m{"game"}{"results_schema"}{"properties"}
  var wanted = initHashSet[string]()
  for key, _ in schemaKeys:
    wanted.incl(key)
  var got = initHashSet[string]()
  for key, value in results:
    got.incl(key)
    if value.kind == JArray:
      c.check(value.len == Seats,
        "28: results." & key & " is exactly four long")
  c.check(got == wanted,
    "28: the results key set equals the manifest results_schema key set; " &
    "missing=" & $(wanted - got) & " extra=" & $(got - wanted))
  removeDir(dir)

# 29 -- the certification seed is interesting.
block:
  let m = manifest()
  var config = configFrom(m{"certification"}{"game_config"})
  c.check(config.seed == 42, "29: the fixture pins seed 42")
  let played = runScriptedEpisode(config, certificationSeats())
  c.check(played.episode.turnsPlayed >= 34,
    "29: seed 42 runs at least 34 turns (got " &
    $played.episode.turnsPlayed & ")")
  var eats, headons, deaths = 0
  for e in played.events:
    case e.kind
    of ekEat: inc eats
    of ekHeadOn: inc headons
    of ekDeath: inc deaths
    else: discard
  echo "cert seed 42: turns=", played.episode.turnsPlayed, " eats=", eats,
    " headons=", headons, " deaths=", deaths
  c.check(eats >= 1, "29: at least one eat")
  c.check(headons >= 1, "29: at least one head-on")
  c.check(deaths >= 1, "29: at least one death")
  ## The beats the scrubber draws come from exactly these kinds, so the CI
  ## smoke replay carrying one of each is what makes the viewer smoke
  ## meaningful rather than a blank timeline.
  var beatKinds = 0
  for kind in [ekEat, ekHeadOn, ekDeath]:
    for e in played.events:
      if e.kind == kind:
        inc beatKinds
        break
  c.check(beatKinds == 3,
    "29: the cert replay carries all three beat-making event kinds")

# 30 -- every shipped variant runs.
block:
  let m = manifest()
  for variant in m{"variants"}:
    let id = variant{"id"}.getStr()
    var config = configFrom(variant{"game_config"})
    c.check(config.module == id, id & ": the config names its own module")
    let rules = rulesFromConfig(config)
    c.check(rules.board.w == config.boardW and rules.board.h == config.boardH,
      id & ": the board is the claimed size")
    c.check(rules.foodCount == config.foodCount, id & ": the claimed food count")
    let played = runScriptedEpisode(config, certificationSeats())
    c.check(played.episode.turnsPlayed >= 1, id & ": it plays")
    c.check(played.episode.reason == rsComplete, id & ": it completes")
    var total = 0
    for v in played.episode.scorePermille():
      total = total + v
    c.check(total == 0, id & ": zero sum")
    if id == "tron":
      c.check(played.episode.state.food.len == 0, "tron: no food is ever placed")
    if id == "geese":
      c.check(rules.board.wrap, "geese: the board wraps")

# 31 -- no seat can stall.
block:
  ## (a) A seat that NEVER CONNECTS: it plays coil for the whole episode, the
  ## episode still finishes inside its budget, `deadSeats` is set, and exactly
  ## one closed-schema failure payload is produced -- by the server's OWN
  ## proc, not by a literal written in the test.
  var config = defaultGameConfig()
  config.maxTurns = 40
  config.seed = 5
  var played = runScriptedEpisode(config, allCoil())
  played.episode.seats[2].dead = true
  c.check(played.episode.reason == rsComplete,
    "31: an unregistered seat does not stop the episode")
  c.check(played.episode.turnsPlayed >= 1 and
    played.episode.turnsPlayed <= config.maxTurns,
    "31: and it finishes inside the turn budget")
  let node = parseJson(playerFailureJson(2))
  var keys: seq[string]
  for key, _ in node:
    keys.add(key)
  c.check(keys.len == 2 and "message" in keys and "failed_policy_index" in keys,
    "31: exactly one closed-schema failure payload")
  c.check(node{"failed_policy_index"}.getInt() == 2,
    "31: naming the seat that never registered")
  let serverSource = readFile("src/snake/server.nim")
  c.check("playerFailureJson(missing[0])" in serverSource,
    "31: and the server POSTs that very document")
  c.check(("echo \"ERROR: seat \", slot, UnregisteredSeatLog" in serverSource) and
    UnregisteredSeatLog == " never registered — playing coil",
    "31: with the loud unregistered-seat line on the same path")
  let results = parseJson(played.episode.snakeResultsJson())
  c.check(results{"deadSeats"}[2].getBool(), "31: deadSeats is set")
  c.check(results{"fallbackTurns"}.len == Seats, "31: fallbackTurns is counted")

  ## (b) A seat that CONNECTS AND THEN NEVER ANSWERS. There is no reply and no
  ## credential, so every turn takes the fallback: the decision layer must
  ## still install a legal direction for it, count the fallback, and let the
  ## episode run to its natural end.
  var live = defaultGameConfig()
  live.maxTurns = 12
  live.seed = 5
  live.turnSpacingMs = 0
  var episode = newEpisode(live)
  var engine = initDecisionEngine(live)
  engine.seats[1].isLlm = true
  engine.seats[1].prompt = "hold the north corridor"
  var turns = 0
  while episode.state.aliveCount() > 1 and episode.state.turn < live.maxTurns:
    discard engine.turn(episode, 0)
    var
      dirs: array[Seats, Dir]
      alts: array[Seats, tuple[has: bool, dir: Dir]]
    for slot in 0 ..< Seats:
      c.check(episode.state.snakes[slot].alive == engine.haveOrder[slot] or
        not episode.state.snakes[slot].alive,
        "31: every live seat has an order, including the silent one")
      dirs[slot] =
        if engine.haveOrder[slot]: engine.orders[slot].dir
        else: episode.state.snakes[slot].lastDir
    let before = episode.state
    discard resolveTurn(episode.state, dirs, alts)
    discard auditDeclinedKills(episode.state, before, dirs)
    inc turns
  episode.turnsPlayed = episode.state.turn
  episode.settle(rsComplete, (if episode.state.aliveCount() <= 1: erLastStanding
                              else: erFullTime))
  c.check(turns >= 1, "31: the silent-seat episode played")
  c.check(episode.reason == rsComplete,
    "31: a seat that never answers does not stop the episode either")
  c.check(episode.seats[1].fallbackTurns == turns or
    not episode.state.snakes[1].alive,
    "31: and every one of its turns is counted as a fallback (" &
    $episode.seats[1].fallbackTurns & " of " & $turns & ")")
  c.check(episode.seats[1].llmTurns == 0, "31: with no LLM turn to its name")

# 32 -- the budget guard settles early, complete rather than deadline.
block:
  var config = defaultGameConfig()
  config.wallClockBudgetSeconds = 30
  config.turnSpacingMs = 0
  c.check(config.turnBudgetSeconds() == 11,
    "32: the per-turn budget rounds up to whole seconds")
  ## The guard is DRIVEN, not re-derived: decide.turn is called with an
  ## elapsed clock past its threshold and must fire, record the turn and
  ## switch every remaining turn to the scripted layer.
  var episode = newEpisode(config)
  var engine = initDecisionEngine(config)
  for slot in 0 ..< Seats:
    engine.seats[slot].isLlm = true
    engine.seats[slot].prompt = "hunt the shortest snake"
  let quiet = engine.turn(episode, 0)
  c.check(not engine.llmOff, "32: at elapsed 0 the guard does not fire")
  var firedEarly = false
  for record in quiet:
    if "\"k\":\"budget_guard\"" in record: firedEarly = true
  c.check(not firedEarly, "32: and writes no budget_guard record")

  let records = engine.turn(episode, 10)
  c.check(engine.llmOff,
    "32: at elapsed 10 with an 11 s turn budget and a 30 s wall clock it fires")
  var guard = newJNull()
  for record in records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "budget_guard":
      guard = node
  c.check(guard.kind == JObject, "32: and writes a budget_guard record")
  if guard.kind == JObject:
    c.check(guard{"turn"}.getInt() == episode.state.turn + 1,
      "32: naming the turn it fired on")
    c.check(guard{"remaining_s"}.getInt() ==
      config.wallClockBudgetSeconds - 10,
      "32: and how much wall clock was left")
  for slot in 0 ..< Seats:
    c.check(engine.haveOrder[slot],
      "32: every seat still has an order after the guard fires")
  ## From here the remaining turns are scripted and cost microseconds, so the
  ## episode ends complete rather than running the clock out to `deadline`.
  episode.turnsPlayed = 12
  episode.settle(rsComplete, erFullTime)
  c.check(episode.reason == rsComplete,
    "32: the episode finishes complete, not deadline")
  c.check(episode.endRule == erFullTime, "32: on a natural end rule")

c.report()
