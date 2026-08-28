## Re-simulate from the replay's seed and recorded direction bytes alone, on a
## fresh sim: identical final turn, bodies, food, health, alive flags and
## per-turn gameHash.

import snake/[board, rules, sim, sim_types, replays, replay_runtime, engine,
              baselines]
import helpers

var c = newChecker("test_snake_determinism")

proc config(module: string, seed: int): GameConfig =
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
  result.maxTurns = 40
  result.seed = seed
  result.turnSpacingMs = 0

for (module, seed) in [("royale", 42), ("geese", 7), ("tron", 13)]:
  let played = runScriptedEpisode(config(module, seed), certificationSeats())
  let bytes = encodeReplay(played.replay)
  var rt = loadReplay(bytes)
  c.check(rt.mismatchTurn == -1,
    module & ": the re-derived hash chain matches at EVERY turn")
  c.check(rt.snapshots.len == played.replay.turns.len + 1,
    module & ": one snapshot per recorded turn plus the opening")
  let last = rt.snapshots[^1]
  for slot in 0 ..< Seats:
    c.check(last.alive[slot] == played.episode.state.snakes[slot].alive,
      module & ": alive flags agree")
    c.check(last.bodies[slot] == played.episode.state.snakes[slot].body,
      module & ": bodies agree")
    c.check(last.health[slot] == played.episode.state.snakes[slot].health,
      module & ": health agrees")
  c.check(last.food == played.episode.state.food,
    module & ": the re-derived food is identical")
  c.check(last.hash == played.episode.state.gameHash,
    module & ": the final hash is identical")

c.report()
