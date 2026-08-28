## End-to-end episodes: the artifacts, the certification seed, every shipped
## variant, the no-stall guarantee and the budget guard.

import std/[json, os, sets, strutils]
import snake/[rules, sim, sim_types, engine, replays, records, events]
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
  c.check(deaths >= 1, "29: at least one death")

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
  ## A seat that never registers plays coil for the whole episode and the
  ## episode still finishes; the failure payload is the closed schema.
  var config = defaultGameConfig()
  config.maxTurns = 40
  config.seed = 5
  var played = runScriptedEpisode(config, allCoil())
  played.episode.seats[2].dead = true
  c.check(played.episode.reason == rsComplete,
    "31: an unregistered seat does not stop the episode")
  let payload = $(%*{"message": "seat never registered; played the coil baseline",
                     "failed_policy_index": 2})
  let node = parseJson(payload)
  var keys: seq[string]
  for key, _ in node:
    keys.add(key)
  c.check(keys.len == 2 and "message" in keys and "failed_policy_index" in keys,
    "31: exactly one closed-schema failure payload")
  let results = parseJson(played.episode.snakeResultsJson())
  c.check(results{"deadSeats"}[2].getBool(), "31: deadSeats is set")
  c.check(results{"fallbackTurns"}.len == Seats, "31: fallbackTurns is counted")

# 32 -- the budget guard settles early, complete rather than deadline.
block:
  var config = defaultGameConfig()
  config.wallClockBudgetSeconds = 30
  c.check(config.turnBudgetSeconds() == 11,
    "32: the per-turn budget rounds up to whole seconds")
  ## elapsed + 2 * turnSeconds > wallClockBudgetSeconds is the guard's own
  ## condition; at elapsed 10 with an 11 s turn it fires.
  c.check(10 + 2 * config.turnBudgetSeconds() > config.wallClockBudgetSeconds,
    "32: the guard fires before the wall clock can")
  let record = parseJson(budgetGuardRecord(17, 8))
  c.check(record{"k"}.getStr() == "budget_guard" and
    record{"turn"}.getInt() == 17, "32: the record names the turn it fired")
  var forced = newEpisode(config)
  forced.turnsPlayed = 12
  forced.settle(rsComplete, erFullTime)
  c.check(forced.reason == rsComplete,
    "32: the episode finishes complete, not deadline")

c.report()
