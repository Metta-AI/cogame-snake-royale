## Scoring: the placement vector is exactly zero-sum for every tie shape, the
## places are the design note's three-key ranking, and `win[s]` is
## `place[s] == 1` (design note §Scoring, numbered test 15).
##
## The note names THIS file for the assertion; it lived inside
## tests/test_snake_sim.nim's numbered block 15, which is where the note's
## §Tests list puts it. One copy, in the file the note points at, imported by
## the sim shard so both readings hold.

import std/json
import snake/[board, rules, sim, sim_types, sim_state]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

proc cfg(module: string): GameConfig =
  result = defaultGameConfig()
  result.seed = 7
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

# 15. scoring ----------------------------------------------------------------
block:
  var rng = initRng(31337)
  for trial in 0 ..< 1000:
    var episode = newEpisode(cfg("royale"))
    for slot in 0 ..< Seats:
      let shape = trial mod 5
      episode.state.snakes[slot].survivedTurns =
        case shape
        of 0: rng.rand(40)                       ## random
        of 1: (if slot < 2: 10 else: rng.rand(9))## 2-way tie at the top
        of 2: (if slot < 3: 10 else: 1)          ## 3-way tie
        of 3: 10                                 ## 4-way tie
        else: (if slot == 0: 10 else: 4)         ## 3-way tie in places 2-4
      episode.state.snakes[slot].finalLength =
        if shape == 0: rng.rand(12) else: 3
      episode.state.snakes[slot].foodEaten =
        if shape == 0: rng.rand(6) else: 0
    let permille = episode.scorePermille()
    var total = 0
    for slot in 0 ..< Seats:
      total = total + permille[slot]
      check permille[slot] >= -1000 and permille[slot] <= 1000,
        "15: scorePermille stays in range"
    check total == 0, "15: the four scores sum to EXACTLY zero"
    let place = episode.placements()
    ## An INDEPENDENT ranking, written here from the design note's own three
    ## keys, compared against the sim's: `results.win` is literally
    ## `place == 1` in sim.nim, so comparing those two to each other proves
    ## nothing. This compares the PLACES.
    var wanted: array[Seats, int]
    for slot in 0 ..< Seats:
      var above = 0
      for other in 0 ..< Seats:
        if other == slot:
          continue
        let
          a = episode.state.snakes[other]
          b = episode.state.snakes[slot]
        let better =
          if a.survivedTurns != b.survivedTurns:
            a.survivedTurns > b.survivedTurns
          elif a.finalLength != b.finalLength: a.finalLength > b.finalLength
          else: a.foodEaten > b.foodEaten
        if better:
          inc above
      wanted[slot] = above + 1
    for slot in 0 ..< Seats:
      check place[slot] == wanted[slot],
        "15: place is the three-key ranking (seat " & $slot & ": " &
        $place[slot] & " vs " & $wanted[slot] & ")"
    ## A tied group really SHARES its place, and a better key really outranks.
    for a in 0 ..< Seats:
      for b in 0 ..< Seats:
        let sa = episode.state.snakes[a]
        let sb = episode.state.snakes[b]
        if (sa.survivedTurns, sa.finalLength, sa.foodEaten) ==
            (sb.survivedTurns, sb.finalLength, sb.foodEaten):
          check place[a] == place[b], "15: an identical key shares a place"
          check permille[a] == permille[b] or
            abs(permille[a] - permille[b]) == 1,
            "15: and splits its slice within one permille"
        elif place[a] < place[b]:
          check permille[a] >= permille[b],
            "15: a better place never pays less"
    ## win[s] == (place[s] == 1), read off the results document the league
    ## reads, not off the same expression that produced it.
    let results = parseJson(episode.snakeResultsJson())
    for slot in 0 ..< Seats:
      check results{"win"}[slot].getBool() == (wanted[slot] == 1),
        "15: results.win is the independent place == 1"
      check results{"place"}[slot].getInt() == wanted[slot],
        "15: and results.place is the independent ranking"

if failures > 0:
  quit("test_snake_scoring: " & $failures & " failures", 1)
echo "test_snake_scoring: ok"
