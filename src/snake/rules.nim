## One engine, three named presets of the same eight switches, and the
## resolver that implements the design note's fifteen resolution steps
## verbatim.
##
## `willOccupy` and `headOnOutcome` have exactly ONE implementation each and
## are called by the resolver, the observation builder, both scripted
## baselines, the reply validator and the viewer pre-scan, so no consumer can
## disagree with the rules (the escrow 2026-08-23 lesson: precompute the legal
## choice set with the same predicate the validator applies).
##
## Integer arithmetic only: no float literal, no division operator and no
## square root appears in this file (design note §Sim module -> Determinism).

import board, space, sim_state, sim_types, upstream

type
  DeathCause* = enum
    dcNone = ""
    dcWall = "wall"
    dcBody = "body"
    dcHeadOn = "headon"
    dcStarve = "starve"

  HeadOnRule* = enum
    hhLongerWins = "longer_wins"
    hhBothDie = "both_die"

  HeadRisk* = enum
    hrSafe = "safe"
    hrWin = "win"
    hrTie = "tie"
    hrLose = "lose"

  BodyKind* = enum
    bkNone = "none"
    bkSelf = "self"
    bkOther = "other"
    bkTail = "tail"

  RuleModule* = object
    name*: string
    board*: Board
    foodCount*: int
    healthStart*: int
    shrinkEvery*: int
    leaveTrail*: bool
    headToHead*: HeadOnRule
    startLength*: int
    maxTurns*: int

  Snake* = object
    alive*: bool
    body*: seq[Cell]            ## head first
    health*: int
    lastDir*: Dir
    ate*: bool
    foodEaten*: int
    maxLength*: int
    freeSpace*: int
    finalLength*: int
    trapped*: bool
    trappedTurns*: int
    declinedKills*: int
    reverseRepaired*: int
    deathTurn*: int
    deathCause*: DeathCause
    killedBy*: int
    survivedTurns*: int

  EventKind* = enum
    ekGameStart = "gamestart"
    ekSpawn = "spawn"
    ekTurn = "turn"
    ekMove = "move"
    ekSay = "say"
    ekEat = "eat"
    ekFoodSpawn = "foodspawn"
    ekShrink = "shrink"
    ekHeadOn = "headon"
    ekDeath = "death"
    ekTrapped = "trapped"
    ekDecline = "decline"
    ekDuel = "duel"
    ekFallback = "fallback"
    ekGameOver = "gameover"
    ekEnd = "end"

  TurnEvent* = object
    kind*: EventKind
    turn*: int
    slot*: int
    other*: int
    at*: Cell
    value*: int
    extra*: int
    text*: string

  GameState* = object
    rules*: RuleModule
    snakes*: array[Seats, Snake]
    food*: seq[Cell]
    foodRng*: Rng
    turn*: int
    gameHash*: uint64
    duelTurn*: int

const
  ModuleNames* = ["royale", "geese", "tron"]

proc ruleModule*(name: string): RuleModule =
  ## The three shipped presets. Every switch is also independently settable in
  ## a `game_config`; the manifest test asserts each shipped
  ## variant's config really constructs the module it names.
  case name
  of "geese":
    RuleModule(name: "geese",
      board: initBoard(GeeseBoardW, GeeseBoardH, true),
      foodCount: GeeseFoodCount, healthStart: 0,
      shrinkEvery: GeeseShrinkEvery, leaveTrail: false,
      headToHead: hhBothDie, startLength: RoyaleStartLength, maxTurns: 50)
  of "tron":
    RuleModule(name: "tron",
      board: initBoard(21, 9, false),
      foodCount: TronFoodCount, healthStart: 0, shrinkEvery: 0,
      leaveTrail: true, headToHead: hhBothDie,
      startLength: TronStartLength, maxTurns: 50)
  else:
    RuleModule(name: "royale",
      board: initBoard(17, 9, false),
      foodCount: 3, healthStart: RoyaleHealthStart, shrinkEvery: 0,
      leaveTrail: false, headToHead: hhLongerWins,
      startLength: RoyaleStartLength, maxTurns: 50)

proc rulesFromConfig*(config: GameConfig): RuleModule =
  result = ruleModule(config.module)
  result.board = initBoard(config.boardW, config.boardH, config.wrap)
  result.foodCount = max(0, config.foodCount)
  result.healthStart = max(0, config.healthStart)
  result.shrinkEvery = max(0, config.shrinkEvery)
  result.leaveTrail = config.leaveTrail
  result.headToHead =
    if config.headToHead == $hhBothDie: hhBothDie else: hhLongerWins
  result.startLength = max(1, config.startLength)
  result.maxTurns = max(1, config.maxTurns)

# ---------------------------------------------------------------------------
#  Occupancy predicates. ONE implementation each.
# ---------------------------------------------------------------------------

proc length*(s: Snake): int = s.body.len

proc head*(s: Snake): Cell =
  if s.body.len > 0: s.body[0] else: cell(0, 0)

proc neck*(s: Snake): tuple[has: bool, cell: Cell] =
  if s.body.len > 1: (true, s.body[1]) else: (false, cell(0, 0))

proc occupancy*(state: GameState, includeTails: bool): Blocked =
  ## Every live snake's segments. With `includeTails` false the LAST segment
  ## of every snake that is not leaving a trail is treated as free, which is
  ## Battlesnake's follow-the-vacating-tail rule.
  result = newBlocked(state.rules.board)
  for s in state.snakes:
    if not s.alive:
      continue
    let last = s.body.len - 1
    for i, c in s.body:
      if not includeTails and not state.rules.leaveTrail and
          i == last and s.body.len > 1:
        continue
      if state.rules.board.inBounds(c):
        result[state.rules.board.cellIndex(c)] = true

proc ownerAt*(state: GameState, c: Cell): int =
  ## Which live snake occupies `c`, or minus one.
  for slot in 0 ..< Seats:
    if not state.snakes[slot].alive:
      continue
    for seg in state.snakes[slot].body:
      if seg == c:
        return slot
  -1

proc bodyKindAt*(state: GameState, mover: int, c: Cell): BodyKind =
  ## What is in `c` from `mover`'s point of view, in the observation's
  ## vocabulary. `tail` is a cell that vacates this turn.
  for slot in 0 ..< Seats:
    if not state.snakes[slot].alive:
      continue
    let body = state.snakes[slot].body
    for i, seg in body:
      if seg == c:
        if i == body.len - 1 and body.len > 1 and not state.rules.leaveTrail:
          return bkTail
        return if slot == mover: bkSelf else: bkOther
  bkNone

proc willOccupy*(state: GameState, mover: int, c: Cell): bool =
  ## THE occupancy predicate. True when a head entering `c` this turn would
  ## meet a body segment that is still there after the tails pop.
  bodyKindAt(state, mover, c) in {bkSelf, bkOther}

proc headOnOutcome*(state: GameState, mover: int, target: Cell): HeadRisk =
  ## What a head-on in `target` would mean for `mover`, by this board's rule.
  ## A rival can contest `target` when its head is one legal step away -- its
  ## own neck does not count, because step 2 repairs a neck move away before
  ## step 9 ever groups the targets.
  ##
  ## The four outcomes are the resolver's own, so the observation, the system
  ## prompt and both baselines read the same vocabulary: `win` is "I am
  ## strictly the longest here and everybody else in the cell dies", `lose` is
  ## "exactly one rival is strictly longer and it lives, I do not", and `tie`
  ## is "nobody is strictly longest, so everyone in the cell dies" -- which is
  ## every equal-length contest under `longer_wins`, not just `both_die`.
  var
    contested = false
    myLength = state.snakes[mover].length()
    longestOther = 0
    longestCount = 0
  for c in state.food:
    if c == target:
      inc myLength
      break
  for slot in 0 ..< Seats:
    if slot == mover or not state.snakes[slot].alive:
      continue
    var canReach = false
    let n = state.snakes[slot].neck()
    for d in DirOrder:
      let moved = state.rules.board.step(state.snakes[slot].head(), d)
      if moved.offBoard:
        continue
      if n.has and moved.cell == n.cell:
        continue
      if moved.cell == target:
        canReach = true
        break
    if not canReach:
      continue
    contested = true
    var theirLength = state.snakes[slot].length()
    for c in state.food:
      if c == target:
        inc theirLength
        break
    if theirLength > longestOther:
      longestOther = theirLength
      longestCount = 1
    elif theirLength == longestOther:
      inc longestCount
  if not contested:
    return hrSafe
  if state.rules.headToHead == hhBothDie:
    return hrTie
  if myLength > longestOther: hrWin
  elif myLength == longestOther: hrTie      ## no strict greatest: all die
  elif longestCount > 1: hrTie              ## nor is there one among them
  else: hrLose

proc freeSpaceAfter*(state: GameState, mover: int, target: Cell,
                     cap: int): int =
  ## Reachable cells from `target` once the mover's own head has entered it.
  var blocked = state.occupancy(includeTails = false)
  let b = state.rules.board
  if b.inBounds(target):
    blocked[b.cellIndex(target)] = false
  freeSpaceFrom(b, blocked, target, cap)

# ---------------------------------------------------------------------------
#  Setup
# ---------------------------------------------------------------------------

proc spawnFood(state: var GameState, events: var seq[TurnEvent]) =
  ## Design step 12. Drawn uniformly from `foodRng` over the free cells; the
  ## stream is separate from `setupRng`, so a change to seat behaviour can
  ## never shift the food draw.
  let b = state.rules.board
  while state.food.len < state.rules.foodCount:
    var free: seq[Cell]
    let blocked = state.occupancy(includeTails = true)
    for index in 0 ..< b.cells():
      if blocked[index]:
        continue
      let c = b.cellAt(index)
      var taken = false
      for f in state.food:
        if f == c:
          taken = true
          break
      if not taken:
        free.add(c)
    if free.len == 0:
      return
    let pick = free[state.foodRng.rand(free.len)]
    state.food.add(pick)
    events.add(TurnEvent(kind: ekFoodSpawn, turn: state.turn, slot: -1,
      other: -1, at: pick))

proc foldState*(state: GameState): uint64 =
  ## The per-turn integrity hash: bodies, food, health, alive flags, turn and
  ## the food-RNG state. The viewer checks the chain and shows `#mmwarn` on a
  ## divergence.
  result = newHash()
  result.fold(state.turn)
  for slot in 0 ..< Seats:
    let s = state.snakes[slot]
    result.fold(if s.alive: 1 else: 0)
    result.fold(s.health)
    result.fold(s.body.len)
    for c in s.body:
      result.fold(c.x)
      result.fold(c.y)
  result.fold(state.food.len)
  for c in state.food:
    result.fold(c.x)
    result.fold(c.y)
  result.fold(int(state.foodRng.state and 0x3FFFFFFF'u64))

proc initGameState*(rules: RuleModule, seed: int, spawnDeal: seq[int]):
    tuple[state: GameState, events: seq[TurnEvent]] =
  ## Every snake starts `startLength` segments stacked on its anchor cell
  ## (Battlesnake's convention), with `last_dir` toward the board centre. On
  ## turn 1 there is no neck, so all four directions are legal.
  var state = GameState(rules: rules, turn: 0,
    foodRng: initRng(seed xor FoodStreamXor), duelTurn: -1)
  let anchors = rules.board.spawnAnchors()
  var events: seq[TurnEvent]
  events.add(TurnEvent(kind: ekGameStart, turn: 0, slot: -1, other: -1,
    text: rules.name))
  for slot in 0 ..< Seats:
    let anchor = anchors[spawnDeal[slot] mod anchors.len]
    var s = Snake(alive: true, health: rules.healthStart,
      lastDir: rules.board.towardCentre(anchor), deathCause: dcNone,
      killedBy: -1, deathTurn: 0, survivedTurns: 0)
    for _ in 0 ..< rules.startLength:
      s.body.add(anchor)
    s.maxLength = s.body.len
    s.finalLength = s.body.len
    state.snakes[slot] = s
    events.add(TurnEvent(kind: ekSpawn, turn: 0, slot: slot, other: -1,
      at: anchor, value: spawnDeal[slot]))
  state.spawnFood(events)
  state.gameHash = state.foldState()
  (state, events)

proc aliveCount*(state: GameState): int =
  for s in state.snakes:
    if s.alive:
      inc result

# ---------------------------------------------------------------------------
#  The resolver: design note §Turn structure, steps 1 to 15, in order.
# ---------------------------------------------------------------------------

proc resolveTurn*(state: var GameState, dirs: array[Seats, Dir],
                  alts: array[Seats, tuple[has: bool, dir: Dir]]):
    seq[TurnEvent] =
  let b = state.rules.board
  var events: seq[TurnEvent]

  # 1. turn += 1
  inc state.turn
  events.add(TurnEvent(kind: ekTurn, turn: state.turn, slot: -1, other: -1,
    value: state.aliveCount()))

  # 2. Neck repair.
  var chosen: array[Seats, Dir]
  for slot in 0 ..< Seats:
    var d = dirs[slot]
    if not state.snakes[slot].alive:
      chosen[slot] = d
      continue
    let n = state.snakes[slot].neck()
    if n.has:
      let moved = b.step(state.snakes[slot].head(), d)
      if not moved.offBoard and moved.cell == n.cell:
        var repaired = state.snakes[slot].lastDir
        if alts[slot].has:
          let altMoved = b.step(state.snakes[slot].head(), alts[slot].dir)
          if altMoved.offBoard or altMoved.cell != n.cell:
            repaired = alts[slot].dir
        d = repaired
        inc state.snakes[slot].reverseRepaired
    chosen[slot] = d

  # 3. Targets. 4. Wall deaths.
  var
    targets: array[Seats, Cell]
    offBoard: array[Seats, bool]
    dying: array[Seats, bool]
    cause: array[Seats, DeathCause]
    killer: array[Seats, int]
  for slot in 0 ..< Seats:
    killer[slot] = -1
    if not state.snakes[slot].alive:
      continue
    let moved = b.step(state.snakes[slot].head(), chosen[slot])
    targets[slot] = moved.cell
    offBoard[slot] = moved.offBoard
    state.snakes[slot].lastDir = chosen[slot]
    if moved.offBoard:
      dying[slot] = true
      cause[slot] = dcWall
    else:
      events.add(TurnEvent(kind: ekMove, turn: state.turn, slot: slot,
        other: -1, at: moved.cell, value: ord(chosen[slot])))

  # 5. Heads move. 6. Eat. 7. Tails.
  for slot in 0 ..< Seats:
    if not state.snakes[slot].alive or dying[slot]:
      continue
    state.snakes[slot].ate = false
    state.snakes[slot].body.insert(targets[slot], 0)
    var eaten = -1
    for i, f in state.food:
      if f == targets[slot]:
        eaten = i
        break
    if eaten >= 0:
      state.food.delete(eaten)
      state.snakes[slot].ate = true
      state.snakes[slot].health = state.rules.healthStart
      inc state.snakes[slot].foodEaten
      events.add(TurnEvent(kind: ekEat, turn: state.turn, slot: slot,
        other: -1, at: targets[slot],
        value: state.snakes[slot].length(),
        extra: state.snakes[slot].health))
  for slot in 0 ..< Seats:
    if not state.snakes[slot].alive or dying[slot]:
      continue
    if not state.rules.leaveTrail and not state.snakes[slot].ate:
      if state.snakes[slot].body.len > 0:
        state.snakes[slot].body.setLen(state.snakes[slot].body.len - 1)

  # 8. Hunger.
  if state.rules.healthStart > 0:
    for slot in 0 ..< Seats:
      if not state.snakes[slot].alive or dying[slot]:
        continue
      dec state.snakes[slot].health
      if state.snakes[slot].health <= 0:
        dying[slot] = true
        cause[slot] = dcStarve
  if state.rules.shrinkEvery > 0 and
      state.turn mod state.rules.shrinkEvery == 0:
    for slot in 0 ..< Seats:
      if not state.snakes[slot].alive or dying[slot]:
        continue
      if state.snakes[slot].body.len > 0:
        state.snakes[slot].body.setLen(state.snakes[slot].body.len - 1)
        events.add(TurnEvent(kind: ekShrink, turn: state.turn, slot: slot,
          other: -1, value: state.snakes[slot].length(), text: "hunger"))
      if state.snakes[slot].body.len == 0:
        dying[slot] = true
        cause[slot] = dcStarve

  # 9. Head-to-head, BEFORE body collisions: without that ordering the winner
  #    would immediately be killed by the loser's neck.
  for slot in 0 ..< Seats:
    if not state.snakes[slot].alive or dying[slot]:
      continue
    var group = @[slot]
    for other in slot + 1 ..< Seats:
      if state.snakes[other].alive and not dying[other] and
          targets[other] == targets[slot]:
        group.add(other)
    if group.len < 2:
      continue
    var
      best = -1
      bestLength = -1
      ties = 0
    for member in group:
      let l = state.snakes[member].length()
      if l > bestLength:
        bestLength = l
        best = member
        ties = 1
      elif l == bestLength:
        inc ties
    let winner =
      if state.rules.headToHead == hhLongerWins and ties == 1: best else: -1
    events.add(TurnEvent(kind: ekHeadOn, turn: state.turn, slot: group[0],
      other: winner, at: targets[slot], value: group.len))
    for member in group:
      if member == winner:
        continue
      dying[member] = true
      cause[member] = dcHeadOn
      killer[member] = winner

  # 10. Body collisions, against occupancy frozen after steps 5 to 9. A snake
  #     killed in step 4, 8 or 9 STILL occupies the board for this test.
  var blocked = newBlocked(b)
  var owner = newSeq[int](b.cells())
  for i in 0 ..< owner.len:
    owner[i] = -1
  for slot in 0 ..< Seats:
    if not state.snakes[slot].alive:
      continue
    for i, c in state.snakes[slot].body:
      if not b.inBounds(c):
        continue
      let index = b.cellIndex(c)
      if i == 0 and not (dying[slot] and cause[slot] != dcHeadOn):
        ## A LIVE head is not an obstacle to anybody: two live heads in one
        ## cell were already settled by step 9. A snake killed in step 4, 8 or
        ## 9 DOES still occupy the board here -- its corpse must not
        ## retroactively free a cell another snake was already committed to --
        ## with exactly one exception: the head cell of a head-on LOSER, which
        ## the winner legitimately holds. Without that exception the winner
        ## would die on the loser's corpse and `longer_wins` would mean
        ## nothing, which is the outcome the step ordering exists to prevent.
        continue
      blocked[index] = true
      owner[index] = slot
  var hitBody: array[Seats, bool]
  for slot in 0 ..< Seats:
    if not state.snakes[slot].alive or dying[slot]:
      continue
    let h = state.snakes[slot].head()
    if not b.inBounds(h):
      continue
    let index = b.cellIndex(h)
    if blocked[index]:
      hitBody[slot] = true
      killer[slot] = owner[index]
    else:
      ## Own body beyond the head.
      for i in 1 ..< state.snakes[slot].body.len:
        if state.snakes[slot].body[i] == h:
          hitBody[slot] = true
          killer[slot] = slot
          break
  for slot in 0 ..< Seats:
    if hitBody[slot]:
      dying[slot] = true
      cause[slot] = dcBody

  # 11. Remove the dead.
  for slot in 0 ..< Seats:
    if not state.snakes[slot].alive or not dying[slot]:
      continue
    let finalLength = state.snakes[slot].length()
    state.snakes[slot].finalLength = finalLength
    state.snakes[slot].maxLength = max(state.snakes[slot].maxLength, finalLength)
    state.snakes[slot].alive = false
    state.snakes[slot].deathTurn = state.turn
    state.snakes[slot].deathCause = cause[slot]
    state.snakes[slot].killedBy = killer[slot]
    state.snakes[slot].survivedTurns = state.turn - 1
    state.snakes[slot].body.setLen(0)
    state.snakes[slot].freeSpace = 0
    state.snakes[slot].trapped = false
    events.add(TurnEvent(kind: ekDeath, turn: state.turn, slot: slot,
      other: killer[slot], value: finalLength, text: $cause[slot]))

  # 12. Food respawn.
  state.spawnFood(events)

  # 13. Derived measurements: free space, the trapped flag, the alliance
  #     audit. Recorded and drawn, never scored.
  let freeBlocked = state.occupancy(includeTails = false)
  for slot in 0 ..< Seats:
    if not state.snakes[slot].alive:
      continue
    let l = state.snakes[slot].length()
    state.snakes[slot].maxLength = max(state.snakes[slot].maxLength, l)
    state.snakes[slot].finalLength = l
    state.snakes[slot].survivedTurns = state.turn
    var reach = freeBlocked
    let h = state.snakes[slot].head()
    if b.inBounds(h):
      reach[b.cellIndex(h)] = false
    let free = freeSpaceFrom(b, reach, h, b.cells())
    state.snakes[slot].freeSpace = free
    let nowTrapped = free < l
    if nowTrapped:
      inc state.snakes[slot].trappedTurns
      if not state.snakes[slot].trapped:
        events.add(TurnEvent(kind: ekTrapped, turn: state.turn, slot: slot,
          other: -1, at: h, value: free, extra: l))
    state.snakes[slot].trapped = nowTrapped

  # 14. The hash folds over the whole board state.
  state.gameHash = state.foldState()

  # 15. End evaluation is the caller's (the server loop, and the replay
  #     runtime on playback); the
  #     duel beat is emitted here because it is a state fact.
  if state.duelTurn < 0 and state.aliveCount() == 2:
    state.duelTurn = state.turn
    events.add(TurnEvent(kind: ekDuel, turn: state.turn, slot: -1, other: -1,
      value: 2))
  events

proc auditDeclinedKills*(state: var GameState, before: GameState,
                         chosen: array[Seats, Dir]): seq[TurnEvent] =
  ## The alliance audit (design note §The alliance audit). Counts the turns on
  ## which a seat had a FREE KILL and did not take it: some direction was
  ## legal, its target was reachable by exactly one opponent's head, the
  ## head-on outcome was `win`, the move's free space was at least the seat's
  ## own length, and the seat moved somewhere else. Computed with the same
  ## `headOnOutcome` and `freeSpaceAfter` procs the resolver uses, so it can
  ## never disagree with the rules. It is NOT in `scores`.
  for slot in 0 ..< Seats:
    if not before.snakes[slot].alive:
      continue
    let myLength = before.snakes[slot].length()
    for d in DirOrder:
      if d == chosen[slot]:
        continue
      let moved = before.rules.board.step(before.snakes[slot].head(), d)
      if moved.offBoard or willOccupy(before, slot, moved.cell):
        continue
      var contenders = 0
      for other in 0 ..< Seats:
        if other == slot or not before.snakes[other].alive:
          continue
        for od in DirOrder:
          let om = before.rules.board.step(before.snakes[other].head(), od)
          if not om.offBoard and om.cell == moved.cell:
            inc contenders
            break
      if contenders != 1:
        continue
      if headOnOutcome(before, slot, moved.cell) != hrWin:
        continue
      if freeSpaceAfter(before, slot, moved.cell, before.rules.board.cells()) <
          myLength:
        continue
      inc state.snakes[slot].declinedKills
      result.add(TurnEvent(kind: ekDecline, turn: state.turn, slot: slot,
        other: -1, at: moved.cell))
      break
