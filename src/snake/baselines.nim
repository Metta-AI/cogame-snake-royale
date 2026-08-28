## The two scripted baselines, `coil` and `forager`.
##
## Both emit the SAME object an LLM emits (`{"dir","alt","say","notes"}`), on
## the same cadence, so the two policy kinds are strictly comparable and one
## validator covers both -- which is what makes the bounded-orders test in
## `tests/test_snake_control.nim` meaningful. Both are PURE FUNCTIONS of the
## board state with no RNG.
##
## Every predicate here is the RESOLVER's own (`willOccupy`, `headOnOutcome`,
## `freeSpaceAfter`, `freeSpaceFrom`, `bfsDist`), so a direction the baseline
## scores minus-infinity is exactly a direction the resolver would have killed
## the snake for. That is what stops a second copy of the rules appearing.

import std/strutils
import board, rules, space, directives

type
  Baseline* = enum
    blCoil = "coil"
    blForager = "forager"

  Tunables* = object
    spaceWeight*: int
    spaceCap*: int              ## multiples of the snake's own length
    headRiskPenalty*: int
    killBonus*: int
    foodWeight*: int
    hungerThreshold*: int

const
  NegInfinity* = low(int) div 4
  StraightBonus* = 40
  HungryFoodBonus* = 300
  DistanceCap* = 99

  ## THE SWEPT PICK, not a guess. `tools/tune_baselines.nim --sweep` plays a
  ## fixed 24-episode ladder over a bounded matrix and prints each candidate's
  ## margin; these are the numbers that won it, recorded in
  ## `tools/ci/baseline_tuning.json` and asserted by
  ## `tests/test_snake_control.nim`.
  ##
  ## The ladder is SEAT-MIRRORED (`engine.ladderTotals`): each seed is played
  ## twice with the two baselines swapped between the seat pairs, because the
  ## four spawn anchors are not equally good and an unmirrored ladder scores
  ## two IDENTICAL players 0.222 apart. Mirrored, this pick beats `forager` by
  ## +0.1805 -- a measurement of the players, not of the seats.
  ##
  ## `spaceCap` is measured in multiples of the snake's own length and is
  ## bounded above by the BFS cap (`4 * length`): a larger value cannot
  ## discriminate, and a smaller one saturates so early that every legal
  ## direction ties and the snake just goes straight into a wall -- which is
  ## exactly how the first guessed pick lost the ladder 1.21 to 0.
  CoilTunables* = Tunables(spaceWeight: 100, spaceCap: 2,
    headRiskPenalty: 900, killBonus: 120, foodWeight: 100,
    hungerThreshold: 12)
  ForagerTunables* = Tunables(spaceWeight: 40, spaceCap: 1,
    headRiskPenalty: 500, killBonus: 60, foodWeight: 40,
    hungerThreshold: 999)

proc parseBaseline*(text: string): Baseline =
  ## Anything unrecognised is the published default -- the starter's rule.
  case text.strip().toLowerAscii()
  of "forager": blForager
  else: blCoil

proc tunablesFor*(kind: Baseline): Tunables =
  case kind
  of blCoil: CoilTunables
  of blForager: ForagerTunables

proc scoreDir*(state: GameState, slot: int, d: Dir,
               tuning: Tunables): int =
  ## The shared skeleton (design note §The two scripted baselines). Returns
  ## `NegInfinity` for a direction that is the neck, leaves a walled board, or
  ## walks into a body segment that is still there after the tails pop.
  let
    b = state.rules.board
    snake = state.snakes[slot]
    length = snake.length()
    n = snake.neck()
  let moved = b.step(snake.head(), d)
  if n.has and not moved.offBoard and moved.cell == n.cell:
    return NegInfinity
  if moved.offBoard:
    return NegInfinity
  if willOccupy(state, slot, moved.cell):
    return NegInfinity
  let
    cap = max(1, 4 * length)
    space = freeSpaceAfter(state, slot, moved.cell, cap)
    risk = headOnOutcome(state, slot, moved.cell)
  result = tuning.spaceWeight * min(space, tuning.spaceCap * length)
  if risk in {hrLose, hrTie}:
    result = result - tuning.headRiskPenalty
  elif risk == hrWin:
    result = result + tuning.killBonus
  if state.rules.foodCount > 0 and state.food.len > 0:
    var nearest = DistanceCap
    let blocked = state.occupancy(includeTails = false)
    for f in state.food:
      let distance = bfsDist(b, blocked, moved.cell, f, DistanceCap)
      if distance < nearest:
        nearest = distance
    result = result - tuning.foodWeight * nearest
    for f in state.food:
      if f == moved.cell and
          (state.rules.healthStart == 0 or
           snake.health <= tuning.hungerThreshold):
        result = result + HungryFoodBonus
        break
  if d == snake.lastDir:
    result = result + StraightBonus

proc baselineDirWith*(state: GameState, slot: int, tuning: Tunables): Dir =
  ## The highest-scoring direction, ties broken by the fixed wire order
  ## up, right, down, left. If EVERY direction scores minus-infinity the snake
  ## returns `last_dir` and dies -- which is the correct outcome for a
  ## sealed-in snake, and is never an unactuated seat.
  var
    best = NegInfinity
    chosen = state.snakes[slot].lastDir
    found = false
  for d in DirOrder:
    let score = scoreDir(state, slot, d, tuning)
    if score == NegInfinity:
      continue
    if not found or score > best:
      best = score
      chosen = d
      found = true
  chosen

proc baselineDir*(state: GameState, slot: int, kind: Baseline): Dir =
  baselineDirWith(state, slot, tunablesFor(kind))

proc scriptedOrderWith*(state: GameState, slot: int,
                        tuning: Tunables): SnakeOrder =
  ## The scripted policy's whole reply. Neither baseline ever emits `say` or
  ## `notes` -- which is why the viewer's text chrome needs the renderer
  ## fixture (`tools/ci/renderer_fixture.html`): a CI replay contains no LLM
  ## text at all.
  result.dir = baselineDirWith(state, slot, tuning)
  result.hasAlt = false
  result.say = ""
  result.notes = ""
  result.source = dsScripted
  result.fromReply = true

proc scriptedOrder*(state: GameState, slot: int, kind: Baseline): SnakeOrder =
  scriptedOrderWith(state, slot, tunablesFor(kind))
