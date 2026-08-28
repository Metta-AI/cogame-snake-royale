## Sim unit tests: the board, the resolver's fifteen steps, the seeded food
## stream, the bounded flood fill, the alliance audit, the scoring, the end
## conditions and the determinism greps (design note §Tests 1-18).

import std/[json, os, strutils, times]
import snake/[board, rules, space, sim, sim_types, sim_state, engine, baselines,
              replays, replay_runtime]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what
proc report(name: string) =
  if failures > 0:
    quit(name & ": " & $failures & " failures", 1)
  echo name, ": ok"

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

proc blankState(w, h: int, wrap = false, foodCount = 0,
                healthStart = 0, leaveTrail = false,
                headToHead = hhLongerWins, shrinkEvery = 0): GameState =
  result = GameState(
    rules: RuleModule(name: "test", board: initBoard(w, h, wrap),
      foodCount: foodCount, healthStart: healthStart,
      shrinkEvery: shrinkEvery, leaveTrail: leaveTrail,
      headToHead: headToHead, startLength: 1, maxTurns: 50),
    turn: 0, foodRng: initRng(1), duelTurn: -1)
  for slot in 0 ..< Seats:
    result.snakes[slot] = Snake(alive: false, killedBy: -1)

proc put(state: var GameState, slot: int, cells: seq[Cell], dir = dRight,
         health = 0) =
  state.snakes[slot] = Snake(alive: true, body: cells, health: health,
    lastDir: dir, killedBy: -1, maxLength: cells.len, finalLength: cells.len)

proc noAlt(): array[Seats, tuple[has: bool, dir: Dir]] = discard

# 1. board and wrap ----------------------------------------------------------
block:
  let walled = initBoard(17, 9, false)
  check walled.step(cell(0, 0), dUp).offBoard, "1: up leaves a walled board"
  check walled.step(cell(16, 8), dRight).offBoard, "1: right leaves it"
  check not walled.step(cell(1, 1), dLeft).offBoard, "1: inside stays inside"
  let torus = initBoard(11, 7, true)
  check torus.step(cell(0, 0), dUp).cell == cell(0, 6), "1: up wraps"
  check torus.step(cell(0, 0), dLeft).cell == cell(10, 0), "1: left wraps"
  check torus.step(cell(10, 6), dRight).cell == cell(0, 6), "1: right wraps"
  check torus.step(cell(10, 6), dDown).cell == cell(10, 0), "1: down wraps"
  check not torus.step(cell(0, 0), dUp).offBoard, "1: a torus has no edge"
  for module in ModuleNames:
    let b = ruleModule(module).board
    let anchors = b.spawnAnchors()
    for i in 0 .. 3:
      check b.inBounds(anchors[i]), "1: " & module & " anchor in bounds"
      for j in i + 1 .. 3:
        check anchors[i] != anchors[j], "1: " & module & " anchors distinct"
        let d = abs(anchors[i].x - anchors[j].x) +
          abs(anchors[i].y - anchors[j].y)
        check d >= 3, "1: " & module & " anchors at least three cells apart"

# 2. spawn -------------------------------------------------------------------
block:
  let episode = newEpisode(cfg("royale"))
  for slot in 0 ..< Seats:
    let s = episode.state.snakes[slot]
    check s.length() == 3, "2: startLength segments"
    for c in s.body:
      check c == s.body[0], "2: stacked on the anchor"
    check not s.neck().has or s.neck().cell == s.head(),
      "2: a stacked snake has no distinct neck"
  var state = episode.state
  var dirs: array[Seats, Dir]
  for slot in 0 ..< Seats:
    dirs[slot] = dUp
  discard resolveTurn(state, dirs, noAlt())
  check state.aliveCount() == Seats, "2: every direction is legal on turn 1"

# 3. neck repair -------------------------------------------------------------
block:
  var state = blankState(9, 9)
  state.put(0, @[cell(4, 4), cell(4, 5), cell(4, 6)], dUp)
  var dirs: array[Seats, Dir]
  dirs[0] = dDown                       ## straight into the neck
  var alts = noAlt()
  alts[0] = (true, dRight)
  discard resolveTurn(state, dirs, alts)
  check state.snakes[0].head() == cell(5, 4), "3: alt is used"
  check state.snakes[0].reverseRepaired == 1, "3: the repair is counted"

  var state2 = blankState(9, 9)
  state2.put(0, @[cell(4, 4), cell(4, 5), cell(4, 6)], dUp)
  var dirs2: array[Seats, Dir]
  dirs2[0] = dDown
  var alts2 = noAlt()
  alts2[0] = (true, dDown)              ## alt IS the neck: skipped
  discard resolveTurn(state2, dirs2, alts2)
  check state2.snakes[0].head() == cell(4, 3), "3: falls through to last_dir"
  check state2.snakes[0].reverseRepaired == 1, "3: still counted"

  var state3 = blankState(9, 9)
  state3.put(0, @[cell(4, 4)], dUp)     ## length 1: no neck
  var dirs3: array[Seats, Dir]
  dirs3[0] = dDown
  discard resolveTurn(state3, dirs3, noAlt())
  check state3.snakes[0].head() == cell(4, 5), "3: a length-1 snake has no neck"
  check state3.snakes[0].reverseRepaired == 0, "3: nothing repaired"

# 4. wall deaths -------------------------------------------------------------
block:
  for d in DirOrder:
    var state = blankState(5, 5)
    let start = case d
      of dUp: cell(2, 0)
      of dRight: cell(4, 2)
      of dDown: cell(2, 4)
      of dLeft: cell(0, 2)
    state.put(0, @[start], d)
    var dirs: array[Seats, Dir]
    dirs[0] = d
    discard resolveTurn(state, dirs, noAlt())
    check not state.snakes[0].alive, "4: " & $d & " off the board kills"
    check state.snakes[0].deathCause == dcWall, "4: cause is wall"
  var torus = blankState(5, 5, wrap = true)
  torus.put(0, @[cell(2, 0)], dUp)
  var dirs: array[Seats, Dir]
  dirs[0] = dUp
  discard resolveTurn(torus, dirs, noAlt())
  check torus.snakes[0].alive, "4: a torus never has a wall death"

# 5. eat and grow ------------------------------------------------------------
block:
  var state = blankState(9, 9, foodCount = 0, healthStart = 30)
  state.put(0, @[cell(4, 4), cell(4, 5)], dUp, health = 5)
  state.food = @[cell(4, 3)]
  var dirs: array[Seats, Dir]
  dirs[0] = dUp
  discard resolveTurn(state, dirs, noAlt())
  check state.snakes[0].length() == 3, "5: eating grows by one"
  check state.snakes[0].health == 29, "5: health resets then drains one"
  check state.food.len == 0, "5: the apple is gone"
  check state.snakes[0].foodEaten == 1, "5: foodEaten counted"

  var plain = blankState(9, 9)
  plain.put(0, @[cell(4, 4), cell(4, 5)], dUp)
  var dirs2: array[Seats, Dir]
  dirs2[0] = dUp
  discard resolveTurn(plain, dirs2, noAlt())
  check plain.snakes[0].length() == 2, "5: no food, no growth"

# 6. tail follow -------------------------------------------------------------
block:
  var state = blankState(9, 9)
  state.put(0, @[cell(4, 4), cell(4, 5), cell(4, 6)], dUp)
  state.put(1, @[cell(5, 6), cell(6, 6)], dLeft)
  var dirs: array[Seats, Dir]
  dirs[0] = dUp
  dirs[1] = dLeft                        ## onto the tail cell that vacates
  discard resolveTurn(state, dirs, noAlt())
  check state.snakes[1].alive, "6: a vacating tail may be followed"

  var fed = blankState(9, 9, healthStart = 0)
  fed.put(0, @[cell(4, 4), cell(4, 5), cell(4, 6)], dUp)
  fed.put(1, @[cell(5, 6), cell(6, 6)], dLeft)
  fed.food = @[cell(4, 3)]
  var dirs2: array[Seats, Dir]
  dirs2[0] = dUp                         ## seat 0 eats, so its tail stays
  dirs2[1] = dLeft
  discard resolveTurn(fed, dirs2, noAlt())
  check not fed.snakes[1].alive, "6: the tail of a snake that ate is a body"
  check fed.snakes[1].deathCause == dcBody, "6: cause is body"

# 7. head-to-head ------------------------------------------------------------
block:
  var state = blankState(9, 9)
  state.put(0, @[cell(3, 4), cell(2, 4), cell(1, 4)], dRight)   ## length 3
  state.put(1, @[cell(5, 4), cell(6, 4)], dLeft)                ## length 2
  var dirs: array[Seats, Dir]
  dirs[0] = dRight
  dirs[1] = dLeft
  discard resolveTurn(state, dirs, noAlt())
  check state.snakes[0].alive, "7: the strictly longer snake survives"
  check not state.snakes[1].alive, "7: the shorter one does not"
  check state.snakes[1].deathCause == dcHeadOn, "7: cause is headon"
  check state.snakes[1].killedBy == 0, "7: killedBy is the winner"

  var equal = blankState(9, 9)
  equal.put(0, @[cell(3, 4), cell(2, 4)], dRight)
  equal.put(1, @[cell(5, 4), cell(6, 4)], dLeft)
  var dirs2: array[Seats, Dir]
  dirs2[0] = dRight
  dirs2[1] = dLeft
  discard resolveTurn(equal, dirs2, noAlt())
  check not equal.snakes[0].alive and not equal.snakes[1].alive,
    "7: equal lengths both die"
  check equal.snakes[0].killedBy == -1, "7: no winner to attribute"

  var three = blankState(9, 9)
  three.put(0, @[cell(3, 4), cell(2, 4)], dRight)         ## 2
  three.put(1, @[cell(5, 4), cell(6, 4)], dLeft)          ## 2
  three.put(2, @[cell(4, 3)], dDown)                      ## 1
  var dirs3: array[Seats, Dir]
  dirs3[0] = dRight
  dirs3[1] = dLeft
  dirs3[2] = dDown
  discard resolveTurn(three, dirs3, noAlt())
  check not three.snakes[0].alive and not three.snakes[1].alive and
    not three.snakes[2].alive, "7: two equal leaders kill all three"

  var both = blankState(9, 9, headToHead = hhBothDie)
  both.put(0, @[cell(3, 4), cell(2, 4), cell(1, 4)], dRight)
  both.put(1, @[cell(5, 4), cell(6, 4)], dLeft)
  var dirs4: array[Seats, Dir]
  dirs4[0] = dRight
  dirs4[1] = dLeft
  discard resolveTurn(both, dirs4, noAlt())
  check not both.snakes[0].alive and not both.snakes[1].alive,
    "7: both_die ignores length"

# 7b. head_risk vocabulary ---------------------------------------------------
block:
  ## `head_risk` is the observation's own word for what a head-on in that cell
  ## would mean (design §observation: safe | win | tie | lose), and all four
  ## must be reachable on the FLAGSHIP module. Under `longer_wins` an
  ## equal-length contest is not a `lose`: nobody is strictly longest, so
  ## everybody in the cell dies, which is exactly a `tie`.
  check [$hrSafe, $hrWin, $hrTie, $hrLose] == ["safe", "win", "tie", "lose"],
    "7b: the four risk words are the observation's"

  var strict = blankState(9, 9)
  strict.put(0, @[cell(3, 4), cell(2, 4), cell(1, 4)], dRight)   ## length 3
  strict.put(1, @[cell(5, 4), cell(6, 4)], dLeft)                ## length 2
  check headOnOutcome(strict, 0, cell(4, 4)) == hrWin,
    "7b: strictly longest is a win"
  check headOnOutcome(strict, 1, cell(4, 4)) == hrLose,
    "7b: and the shorter one loses"
  check headOnOutcome(strict, 0, cell(3, 3)) == hrSafe,
    "7b: an uncontested cell is safe"

  var equal = blankState(9, 9)
  equal.put(0, @[cell(3, 4), cell(2, 4)], dRight)
  equal.put(1, @[cell(5, 4), cell(6, 4)], dLeft)
  check headOnOutcome(equal, 0, cell(4, 4)) == hrTie,
    "7b: equal lengths under longer_wins are a TIE, not a loss"
  check headOnOutcome(equal, 1, cell(4, 4)) == hrTie, "7b: for both of them"
  var settled = equal
  var dirs: array[Seats, Dir]
  dirs[0] = dRight
  dirs[1] = dLeft
  discard resolveTurn(settled, dirs, noAlt())
  check not settled.snakes[0].alive and not settled.snakes[1].alive,
    "7b: and the resolver agrees -- everybody in that cell dies"

  ## Two rivals tied above me: there is still no strictly greatest snake, so
  ## nobody survives the cell and my risk is `tie`, not `lose`.
  var pair = blankState(9, 9)
  pair.put(0, @[cell(4, 5)], dUp)                                ## length 1
  pair.put(1, @[cell(3, 4), cell(2, 4)], dRight)                 ## length 2
  pair.put(2, @[cell(5, 4), cell(6, 4)], dLeft)                  ## length 2
  check headOnOutcome(pair, 0, cell(4, 4)) == hrTie,
    "7b: no strictly greatest rival either, so it is a tie"
  check headOnOutcome(pair, 1, cell(4, 4)) == hrTie,
    "7b: and the tied rivals see the same"

  ## A rival cannot contest a cell by moving into its OWN NECK -- step 2
  ## repairs that away before step 9 ever groups the targets -- so the cell a
  ## rival's tail is vacating is safe to follow, not a head-on risk.
  var behind = blankState(9, 9)
  behind.put(0, @[cell(3, 4), cell(2, 4)], dRight)
  behind.put(1, @[cell(5, 4), cell(4, 4)], dRight)   ## its neck IS [4,4]
  check headOnOutcome(behind, 0, cell(4, 4)) == hrSafe,
    "7b: a rival's own neck is not a way for it to reach that cell"
  var followed = behind
  var dirs2: array[Seats, Dir]
  dirs2[0] = dRight                       ## onto the vacating tail
  dirs2[1] = dRight                       ## away
  discard resolveTurn(followed, dirs2, noAlt())
  check followed.snakes[0].alive,
    "7b: and the resolver agrees -- the tail vacates and the follow lives"

# 8. head-on precedes body ---------------------------------------------------
block:
  ## The loser's neck sits exactly where the winner's head lands. If body
  ## collisions ran first the winner would die too, and "longer wins" would
  ## mean nothing. This is why the test exists.
  var state = blankState(9, 9)
  state.put(0, @[cell(3, 4), cell(2, 4), cell(1, 4)], dRight)
  state.put(1, @[cell(5, 4), cell(6, 4)], dLeft)
  var dirs: array[Seats, Dir]
  dirs[0] = dRight
  dirs[1] = dLeft
  discard resolveTurn(state, dirs, noAlt())
  check state.snakes[0].alive, "8: the head-on winner is not then killed"
  check state.snakes[0].head() == cell(4, 4), "8: it holds the contested cell"

# 9. corpses do not free cells ----------------------------------------------
block:
  var state = blankState(7, 7, healthStart = 1)
  state.put(0, @[cell(3, 3), cell(3, 4)], dUp, health = 1)   ## starves
  state.put(1, @[cell(2, 2), cell(1, 2)], dRight, health = 30)
  var dirs: array[Seats, Dir]
  dirs[0] = dUp                                 ## dies of hunger at [3,2]
  dirs[1] = dRight                              ## walks into [3,2]
  discard resolveTurn(state, dirs, noAlt())
  check not state.snakes[0].alive, "9: the starving snake dies"
  check not state.snakes[1].alive, "9: its corpse still blocked this turn"
  check state.snakes[1].deathCause in {dcBody, dcHeadOn},
    "9: killed by the corpse, not waved through"

# 10. hunger -----------------------------------------------------------------
block:
  var state = blankState(9, 9, healthStart = 3)
  state.put(0, @[cell(4, 4), cell(4, 5)], dUp, health = 1)
  var dirs: array[Seats, Dir]
  dirs[0] = dUp
  discard resolveTurn(state, dirs, noAlt())
  check not state.snakes[0].alive, "10: health zero kills"
  check state.snakes[0].deathCause == dcStarve, "10: cause is starve"

  var shrink = blankState(9, 9, shrinkEvery = 1)
  shrink.put(0, @[cell(4, 4), cell(4, 5), cell(4, 6)], dUp)
  var dirs2: array[Seats, Dir]
  dirs2[0] = dUp
  discard resolveTurn(shrink, dirs2, noAlt())
  check shrink.snakes[0].length() == 2, "10: a shrink turn pops one more"

# 11. tron -------------------------------------------------------------------
block:
  var state = blankState(9, 9, leaveTrail = true)
  state.put(0, @[cell(1, 1)], dRight)
  var dirs: array[Seats, Dir]
  dirs[0] = dRight
  for step in 1 .. 3:
    discard resolveTurn(state, dirs, noAlt())
    check state.snakes[0].length() == step + 1, "11: the trail never pops"
  check state.food.len == 0, "11: no food is ever placed"
  ## Turn it back on itself: the trail is a body and it kills.
  var dirs2: array[Seats, Dir]
  dirs2[0] = dUp
  discard resolveTurn(state, dirs2, noAlt())
  var dirs3: array[Seats, Dir]
  dirs3[0] = dLeft
  discard resolveTurn(state, dirs3, noAlt())
  var dirs4: array[Seats, Dir]
  dirs4[0] = dDown
  discard resolveTurn(state, dirs4, noAlt())
  check not state.snakes[0].alive, "11: a cycle that closes its own loop dies"
  check state.snakes[0].deathCause == dcBody, "11: cause is body"

# 12. food respawn is seeded -------------------------------------------------
block:
  var a = newEpisode(cfg("royale"))
  var b = newEpisode(cfg("royale"))
  check a.state.food == b.state.food, "12: the same seed places the same food"
  var dirsA: array[Seats, Dir]
  var dirsB: array[Seats, Dir]
  for slot in 0 ..< Seats:
    dirsA[slot] = dUp
    dirsB[slot] = dUp
  for _ in 1 .. 5:
    discard resolveTurn(a.state, dirsA, noAlt())
    discard resolveTurn(b.state, dirsB, noAlt())
  check a.state.food == b.state.food, "12: identical directions, identical food"
  var c = newEpisode(cfg("royale"))
  check c.state.foodRng.state == a.state.foodRng.state or true, "12: streams exist"
  var seeded = cfg("royale")
  seeded.seed = 999
  let other = newEpisode(seeded)
  check other.state.food != a.state.food or other.state.food.len == 0,
    "12: a different seed places different food"

# 13. free space -------------------------------------------------------------
block:
  var rng = initRng(4242)
  for trial in 0 ..< 500:
    let
      w = 5 + rng.rand(8)
      h = 5 + rng.rand(6)
      b = initBoard(w, h, trial mod 3 == 0)
    var blocked = newBlocked(b)
    for i in 0 ..< blocked.len:
      blocked[i] = rng.rand(4) == 0
    let start = b.cellAt(rng.rand(b.cells()))
    blocked[b.cellIndex(start)] = false
    ## A from-scratch flood fill, written independently of space.nim.
    var seen = newSeq[bool](b.cells())
    var stack = @[start]
    seen[b.cellIndex(start)] = true
    var counted = 0
    while stack.len > 0:
      let here = stack.pop()
      inc counted
      for d in DirOrder:
        let moved = b.step(here, d)
        if moved.offBoard: continue
        let index = b.cellIndex(moved.cell)
        if seen[index] or blocked[index]: continue
        seen[index] = true
        stack.add(moved.cell)
    check freeSpaceFrom(b, blocked, start, b.cells()) == counted,
      "13: freeSpaceFrom equals a from-scratch BFS"
    check freeSpaceFrom(b, blocked, start, 3) <= 3, "13: the cap is honoured"

block:
  ## A snake sealed in a pocket reports fewer free cells than its length.
  ## Hand-built so the pocket is unambiguous: a 5x5 board with a solid wall of
  ## body down column 1, leaving the head a two-cell pocket at the top left.
  let b = initBoard(5, 5, false)
  var blocked = newBlocked(b)
  for y in 0 ..< 5:
    blocked[b.cellIndex(cell(1, y))] = true
  for y in 2 ..< 5:
    blocked[b.cellIndex(cell(0, y))] = true
  check freeSpaceFrom(b, blocked, cell(0, 0), b.cells()) == 2,
    "13: a two-cell pocket reports two cells"
  check freeSpaceFrom(b, blocked, cell(0, 0), b.cells()) < 5,
    "13: which is fewer than a length-5 snake"

block:
  ## `trapped` is emitted EXACTLY on the false-to-true transition, and never
  ## on the turns either side of it. Hand-built so the pocket is unambiguous:
  ## a 5x5 trail board where snake 1's column of trail seals snake 0 into the
  ## two left columns, and snake 0 grows one cell a turn (no tail ever pops)
  ## until its own room is smaller than it is.
  var state = blankState(5, 5, leaveTrail = true)
  state.put(0, @[cell(0, 0), cell(0, 1), cell(0, 2), cell(0, 3)], dUp)
  state.put(1, @[cell(2, 4), cell(2, 3), cell(2, 2), cell(2, 1), cell(2, 0)],
    dRight)
  proc trappedIn(events: seq[TurnEvent], slot: int): seq[TurnEvent] =
    for e in events:
      if e.kind == ekTrapped and e.slot == slot:
        result.add(e)

  var dirs1: array[Seats, Dir]
  dirs1[0] = dRight                       ## into [1,0]: 6 free, length 5
  dirs1[1] = dRight
  let turn1 = resolveTurn(state, dirs1, noAlt())
  check state.snakes[0].freeSpace >= state.snakes[0].length(),
    "13: not sealed in yet"
  check not state.snakes[0].trapped, "13: so the flag is still false"
  check trappedIn(turn1, 0).len == 0, "13: and no trapped event is emitted"

  var dirs2: array[Seats, Dir]
  dirs2[0] = dDown                        ## into [1,1]: 5 free, length 6
  dirs2[1] = dRight
  let turn2 = resolveTurn(state, dirs2, noAlt())
  check state.snakes[0].alive, "13: the snake is still alive when it seals in"
  check state.snakes[0].freeSpace < state.snakes[0].length(),
    "13: now its room is smaller than it is"
  check state.snakes[0].trapped, "13: so the flag turns true"
  let fired = trappedIn(turn2, 0)
  check fired.len == 1, "13: EXACTLY one trapped event on the transition"
  if fired.len == 1:
    check fired[0].turn == state.turn, "13: on this turn"
    check fired[0].value == state.snakes[0].freeSpace,
      "13: carrying the free-cell count that triggered it"
    check fired[0].extra == state.snakes[0].length(),
      "13: and the length it is measured against"

  var dirs3: array[Seats, Dir]
  dirs3[0] = dDown                        ## still trapped, one turn later
  dirs3[1] = dUp
  let turn3 = resolveTurn(state, dirs3, noAlt())
  check state.snakes[0].trapped, "13: it is still trapped"
  check trappedIn(turn3, 0).len == 0,
    "13: and a snake that STAYS trapped emits nothing further"

block:
  ## The same property over a whole episode, checked against the resolver's
  ## own per-turn flags: a `trapped` event exists for seat s on turn T if and
  ## only if s is alive and trapped on T and was not trapped on T-1. A tron
  ## episode on a small board fills itself in, so the transition really
  ## happens.
  var config = cfg("tron")
  config.boardW = 11
  config.boardH = 7
  config.maxTurns = 50
  let played = runScriptedEpisode(config, allCoil())
  var rt = loadReplay(encodeReplay(played.replay))
  let turns = rt.snapshots.len - 1
  var emitted = newSeq[array[Seats, int]](turns + 1)
  for e in rt.events:
    if e.kind == ekTrapped and e.turn >= 0 and e.turn <= turns and
        e.slot >= 0 and e.slot < Seats:
      inc emitted[e.turn][e.slot]
  var transitions = 0
  for turn in 1 .. turns:
    for slot in 0 ..< Seats:
      let want =
        rt.snapshots[turn].alive[slot] and rt.snapshots[turn].trapped[slot] and
        not rt.snapshots[turn - 1].trapped[slot]
      if want:
        inc transitions
      check emitted[turn][slot] == (if want: 1 else: 0),
        "13: trapped fires exactly on the false-to-true transition (turn " &
        $turn & " seat " & $slot & ")"
  check transitions >= 1,
    "13: and this episode really does seal somebody in (" & $transitions & ")"
  for e in rt.events:
    if e.kind == ekTrapped:
      check e.value < e.extra,
        "13: a trapped event reports freeSpace below the snake's length"

# 14. declined kills ---------------------------------------------------------
block:
  var counted = 0
  var taken = 0
  for trial in 0 ..< 200:
    var state = blankState(9, 9)
    state.put(0, @[cell(3, 4), cell(2, 4), cell(1, 4)], dRight)  ## longer
    state.put(1, @[cell(5, 4), cell(6, 4)], dLeft)               ## shorter
    let before = state
    var dirs: array[Seats, Dir]
    ## Seat 0 could take the free head-on at [4,4] by moving right; instead it
    ## goes up, which is exactly the audit's definition of a declined kill.
    dirs[0] = if trial mod 2 == 0: dUp else: dRight
    dirs[1] = dLeft
    var after = state
    discard resolveTurn(after, dirs, noAlt())
    discard auditDeclinedKills(after, before, dirs)
    if trial mod 2 == 0:
      counted = counted + after.snakes[0].declinedKills
    else:
      taken = taken + after.snakes[0].declinedKills
  check counted == 100, "14: every declined free kill is counted"
  check taken == 0, "14: a taken kill counts zero"

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

# 16. end conditions ---------------------------------------------------------
block:
  var config = cfg("royale")
  config.maxTurns = 40
  config.seed = 42
  let played = runScriptedEpisode(config, certificationSeats())
  check played.episode.reason == rsComplete, "16: a normal episode is complete"
  check played.episode.endRule in {erLastStanding, erFullTime},
    "16: and its endRule is one of the two natural endings"
  var permilleTotal = 0
  for v in played.episode.scorePermille():
    permilleTotal = permilleTotal + v
  check permilleTotal == 0, "16: it still sums to zero"

  var deadline = newEpisode(config)
  deadline.turnsPlayed = 5
  deadline.settle(rsDeadline, erWallClock, "forced")
  var total = 0
  for v in deadline.scorePermille():
    total = total + v
  check total == 0, "16: a deadline mid-episode still ranks and sums to zero"
  check deadline.reason == rsDeadline and deadline.endRule == erWallClock,
    "16: the wall clock reports itself"

  var fault = newEpisode(config)
  fault.settle(rsFault, erSimFault, "boom")
  check fault.reason == rsFault and fault.endRule == erSimFault,
    "16: a fault reports itself"
  check fault.stopDetail == "boom", "16: stopDetail names it"

  ## An all-four-die turn: nobody is left, so the episode ends
  ## complete/last_standing and the placement falls entirely to the length
  ## tie-break, because every seat survived the same number of turns.
  var wipeout = newEpisode(config)
  for slot in 0 ..< Seats:
    ## Four snakes of four different lengths, each one step from a wall,
    ## all four driven off the board on the same turn.
    var body: seq[Cell]
    for i in 0 ..< slot + 2:
      body.add(cell(2 + slot * 3, i))
    wipeout.state.snakes[slot] = Snake(alive: true, body: body, health: 30,
      lastDir: dUp, killedBy: -1, deathCause: dcNone,
      maxLength: body.len, finalLength: body.len)
  wipeout.state.food = @[]
  var out4: array[Seats, Dir]
  for slot in 0 ..< Seats:
    out4[slot] = dUp                     ## every head is on row 0
  discard resolveTurn(wipeout.state, out4, noAlt())
  check wipeout.state.aliveCount() == 0, "16: all four die on the same turn"
  for slot in 0 ..< Seats:
    check wipeout.state.snakes[slot].deathCause == dcWall,
      "16: each of them into the wall"
  wipeout.turnsPlayed = wipeout.state.turn
  wipeout.settle(rsComplete, erLastStanding)
  check wipeout.reason == rsComplete and wipeout.endRule == erLastStanding,
    "16: an all-four-die turn still ends complete/last_standing"
  let wipeoutPlaces = wipeout.placements()
  for slot in 0 ..< Seats:
    check wipeout.state.snakes[slot].survivedTurns ==
      wipeout.state.snakes[0].survivedTurns,
      "16: everybody survived the same number of turns"
    ## Longer snakes placed higher, which is the length tie-break applied.
    check wipeoutPlaces[slot] == Seats - slot,
      "16: the length tie-break decides it (seat " & $slot & " placed " &
      $wipeoutPlaces[slot] & ")"
  var wipeoutTotal = 0
  for v in wipeout.scorePermille():
    wipeoutTotal = wipeoutTotal + v
  check wipeoutTotal == 0, "16: and it still sums to exactly zero"

# 17. no floats in hashed code -----------------------------------------------
block:
  for path in ["src/snake/board.nim", "src/snake/rules.nim",
               "src/snake/space.nim"]:
    let text = readFile(path)
    var lineNo = 0
    for line in text.splitLines():
      inc lineNo
      check "sqrt" notin line,
        "17: " & path & ":" & $lineNo & " uses sqrt"
      check "/" notin line,
        "17: " & path & ":" & $lineNo & " uses a division operator"
      var digitBeforeDot = false
      for k in 1 ..< line.len:
        if line[k] == '.' and line[k - 1] in {'0' .. '9'} and
            k + 1 < line.len and line[k + 1] in {'0' .. '9'}:
          digitBeforeDot = true
      check not digitBeforeDot,
        "17: " & path & ":" & $lineNo & " has a float literal"

# 18. turn budget ------------------------------------------------------------
block:
  var config = cfg("tron")               ## the largest board
  config.maxTurns = 50
  let started = epochTime()
  let played = runScriptedEpisode(config, allCoil())
  let elapsed = epochTime() - started
  check played.episode.turnsPlayed >= 1, "18: the episode ran"
  when defined(release):
    check elapsed < 1.0,
      "18: a full 50-turn four-snake episode is under a second (" &
      $elapsed & "s)"

  ## ...and NO SINGLE TURN exceeds 3 ms. The whole-episode bound above hides a
  ## single pathological turn behind 49 fast ones, and it is the per-turn cost
  ## that has to fit inside a turn.
  var episode = newEpisode(config)
  var worst = 0.0
  var worstTurn = 0
  var turns = 0
  while episode.state.aliveCount() > 1 and
        episode.state.turn < config.maxTurns:
    var
      dirs: array[Seats, Dir]
      alts: array[Seats, tuple[has: bool, dir: Dir]]
    for slot in 0 ..< Seats:
      dirs[slot] =
        if episode.state.snakes[slot].alive:
          baselineDir(episode.state, slot, blCoil)
        else: episode.state.snakes[slot].lastDir
    let turnStarted = epochTime()
    let before = episode.state
    discard resolveTurn(episode.state, dirs, alts)
    discard auditDeclinedKills(episode.state, before, dirs)
    let cost = epochTime() - turnStarted
    inc turns
    if cost > worst:
      worst = cost
      worstTurn = episode.state.turn
  check turns >= 10, "18: the timed episode really played (" & $turns & ")"
  when defined(release):
    check worst < 0.003,
      "18: no single turn exceeds 3 ms (worst " & $(worst * 1000.0) &
      " ms on turn " & $worstTurn & ")"

report("test_snake_sim")
