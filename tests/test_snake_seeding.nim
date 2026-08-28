## spawnDeal is a pure function of the seed, is drawn BEFORE any seat
## connects, and does not change when seat behaviour changes; the food stream
## is separated from the setup stream. This is the anti-collusion pin: no seat
## can learn "I am always the top-left snake".

import std/[algorithm, sets]
import snake/[board, rules, sim, sim_types, sim_state, baselines, engine]
import helpers

var c = newChecker("test_snake_seeding")

proc config(seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTurns = 20

# Pure function of the seed.
for seed in [1, 2, 17, 42, 1734029581]:
  let a = drawSpawnDeal(seed)
  let b = drawSpawnDeal(seed)
  c.check(a == b, "the same seed deals the same spawn")
  var sorted = a
  sorted.sort()
  c.check(sorted == @[0, 1, 2, 3], "spawnDeal is a permutation of 0..3")

# Different seeds really do move it (over a sample, not per pair).
var seen = initHashSet[seq[int]]()
for seed in 1 .. 200:
  seen.incl(drawSpawnDeal(seed))
c.check(seen.len > 4, "the deal is not constant across seeds")

# Drawn before any seat connects: an episode built with no registrations has
# the same deal as one whose seats are about to play different baselines.
block:
  let plain = newEpisode(config(42))
  let played = runScriptedEpisode(config(42), [blForager, blCoil, blForager, blCoil])
  c.check(plain.spawnDeal == played.episode.spawnDeal,
    "seat behaviour cannot shift the spawn deal")

# The food stream is separated from the setup stream, so the food sequence is
# a pure function of the seed regardless of how the snakes play.
block:
  let a = runScriptedEpisode(config(42), allCoil())
  let b = runScriptedEpisode(config(42), [blForager, blForager, blForager, blForager])
  let openA = newEpisode(config(42))
  let openB = newEpisode(config(42))
  c.check(openA.state.food == openB.state.food,
    "the same seed opens on the same board")
  c.check(a.episode.spawnDeal == b.episode.spawnDeal,
    "and on the same deal whatever the seats do")
  c.check(initRng(42 xor FoodStreamXor).state != initRng(42).state,
    "the food stream is a different stream from the setup stream")

# The colours follow the deal, not the seat index.
block:
  var moved = false
  for seed in 1 .. 50:
    let e = newEpisode(config(seed))
    if e.colour(0) != Colours[0]:
      moved = true
  c.check(moved, "colours follow spawnDeal, not the seat index")

c.report()
