## The decision layer: the per-turn loop that asks every live seat which
## direction its snake takes next, and always has an answer.
##
## Forked from `coworld-ctf`'s `src/ctf/decide.nim`, keeping the whole
## per-turn loop shape: the budget guard, the rate floor, the TWO PARALLEL
## BATCHES with `attempt1Ms` / `retryMs` / `turnBudgetMs`, the throttle
## fail-fast, the final fallback ladder and its `cause` enum, and the exact
## `falling back` log phrase phase 60 greps. Only `seatViewJson`, the parse
## call and the fallback baseline change.
##
## Cadence: one batch per turn, four calls in it -- Snake Royale is a
## SIMULTANEOUS-decision game, so querying seats one after another would
## quadruple the wall clock for no gain. At most two batches per turn
## (attempt + retry).
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, and the whole turn is
## wrapped in a monotonic `turnBudgetMs` deadline. A provider throttle with no
## other candidate model skips the retry outright (it cannot land) and fails
## fast to the scripted layer for that turn. On a second failure the seat
## plays the `coil` scripted direction and a `fallback` record names the
## cause.

import std/[json, monotimes, os, strutils, times]
import curly
import sim, directives, baselines, control, llm, records
export records

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field
    ## -- or never registers at all -- is `coil`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: array[Seats, SeatPolicy]
    orders*: array[Seats, SnakeOrder]
    haveOrder*: array[Seats, bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool               ## the budget guard fired; scripted from here
    records*: seq[string]

proc initDecisionEngine*(config: GameConfig): DecisionEngine =
  result.client = newLlmClient(config)
  for slot in 0 ..< Seats:
    result.seats[slot].baseline = blCoil
    result.seats[slot].label = "coil"

proc policyKind*(engine: DecisionEngine, slot: int): string =
  if engine.seats[slot].isLlm: "llm" else: "scripted"

# ---------------------------------------------------------------------------
#  The per-seat observation
# ---------------------------------------------------------------------------

proc snakeJson(episode: Episode, slot: int, includeBody: bool): JsonNode =
  let s = episode.state.snakes[slot]
  var body = newJArray()
  if includeBody:
    for c in s.body:
      body.add(%[c.x, c.y])
  let h = s.head()
  %*{
    "id": cogAlias(slot),
    "colour": episode.colour(slot),
    "alive": s.alive,
    "head": [h.x, h.y],
    "body": body,
    "length": s.length(),
    "health": s.health,
    "last_dir": $s.lastDir,
    "free_space": s.freeSpace,
    "food_eaten": s.foodEaten,
    "death_turn": s.deathTurn,
    "death_cause": $s.deathCause
  }

proc seatViewJson*(episode: Episode, slot: int): string =
  ## Everything this seat may legitimately know. The idea pins PERFECT
  ## INFORMATION, so the whole board is here -- but never another seat's real
  ## policy name, never another seat's `notes`, never any seat's pending
  ## direction for this turn, never the future of the food stream and never
  ## `spawnDeal`.
  let
    state = episode.state
    b = state.rules.board
    s = state.snakes[slot]
  var snakes = newJArray()
  for other in 0 ..< Seats:
    if other == slot:
      continue
    snakes.add(snakeJson(episode, other, includeBody = true))
  var food = newJArray()
  for f in state.food:
    food.add(%[f.x, f.y])
  var moves = newJArray()
  for d in DirOrder:
    let moved = b.step(s.head(), d)
    var
      legal = not moved.offBoard
      kind = bkNone
      isFood = false
      free = 0
      risk = hrSafe
    if not moved.offBoard:
      kind = bodyKindAt(state, slot, moved.cell)
      if willOccupy(state, slot, moved.cell):
        legal = false
      let n = s.neck()
      if n.has and moved.cell == n.cell:
        legal = false
        kind = bkSelf
      for f in state.food:
        if f == moved.cell:
          isFood = true
          break
      if legal:
        free = freeSpaceAfter(episode.state, slot, moved.cell, b.cells())
        risk = headOnOutcome(episode.state, slot, moved.cell)
    moves.add(%*{
      "dir": $d,
      "to": [moved.cell.x, moved.cell.y],
      "legal": legal,
      "wall": moved.offBoard,
      "body": $kind,
      "food": isFood,
      "head_risk": $risk,
      "free_space": free
    })
  var said = newJArray()
  for other in 0 ..< Seats:
    if other == slot or not state.snakes[other].alive:
      continue
    if episode.seats[other].sayTurnsLeft > 0 and
        episode.seats[other].say.len > 0:
      said.add(%*{"id": cogAlias(other), "text": episode.seats[other].say})
  $(%*{
    "module": state.rules.name,
    "board": {"w": b.w, "h": b.h, "wrap": b.wrap},
    "turn": state.turn,
    "max_turns": state.rules.maxTurns,
    "turns_left": max(0, state.rules.maxTurns - state.turn),
    "alive": state.aliveCount(),
    "rules": {
      "head_to_head": $state.rules.headToHead,
      "food_count": state.rules.foodCount,
      "health_start": state.rules.healthStart,
      "shrink_every": state.rules.shrinkEvery,
      "leave_trail": state.rules.leaveTrail
    },
    "you": snakeJson(episode, slot, includeBody = true),
    "snakes": snakes,
    "food": food,
    "moves": moves,
    "said": said,
    "your_notes": episode.seats[slot].notes
  })

proc legalMask*(episode: Episode, slot: int): array[4, bool] =
  let
    state = episode.state
    b = state.rules.board
    s = state.snakes[slot]
  for i, d in DirOrder:
    let moved = b.step(s.head(), d)
    var ok = not moved.offBoard
    if ok and willOccupy(state, slot, moved.cell):
      ok = false
    let n = s.neck()
    if ok and n.has and moved.cell == n.cell:
      ok = false
    result[i] = ok

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc turn*(engine: var DecisionEngine, episode: var Episode,
           elapsedSeconds: int): seq[string] =
  ## Runs ONE decision turn and installs each live seat's order. Returns the
  ## replay chat records this turn produced. Never raises: every failure path
  ## ends in a legal direction.
  let
    turnIndex = episode.state.turn + 1
    budget = initDuration(milliseconds = max(1, episode.config.turnBudgetMs))
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k+1.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun -----------------------
  if not engine.llmOff:
    let turnSeconds = episode.config.turnBudgetSeconds()
    if elapsedSeconds + 2 * turnSeconds >
        episode.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(turnIndex,
        max(0, episode.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "snake-royale: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  for slot in 0 ..< Seats:
    if not episode.state.snakes[slot].alive:
      engine.haveOrder[slot] = false
      continue                        ## dead seats are never queried again
    if engine.seats[slot].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(slot)
    elif engine.seats[slot].isLlm:
      ## An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
      ## scripted policy. Recording it is what makes `llmTurns 0 /
      ## fallbackTurns N` countable rather than silently zero.
      engine.orders[slot] = fallbackOrder(episode.state, slot)
      engine.haveOrder[slot] = true
      inc episode.seats[slot].fallbackTurns
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(turnIndex, slot, 1, cause,
        "the LLM is unavailable for this turn; playing coil"))
      echo "snake-royale llm: seat ", slot, " falling back to coil (", cause,
        ") on turn ", turnIndex
    else:
      engine.orders[slot] = scriptedOrder(episode.state, slot,
        engine.seats[slot].baseline)
      engine.haveOrder[slot] = true

  # --- the rate floor -------------------------------------------------------
  # The Bedrock sidecar caps 30 requests per minute PER EPISODE. Holding the
  # START of consecutive batches `turnSpacingMs` apart pins four seats at
  # 4 x 60 div 9 = 26.7 requests per minute. The cert fixture sets it to 0, so
  # offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and episode.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < episode.config.turnSpacingMs:
      sleep(episode.config.turnSpacingMs - since)
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # The per-turn budget covers the CALLS, not the wait in front of them.
  # `turnBudgetMs` is sized for attempt 1 + the retry + slack (6 + 3 + 2 s,
  # design note §Cadence), and `sim_config` now refuses a value that does not
  # cover both attempts. Starting the clock ABOVE the rate floor spent
  # `turnSpacingMs - L(k-1)` of it before the first request went out, so in
  # steady state -- batch starts held 9 s apart, a batch measuring ~4 s -- only
  # 6 s of the 11 s was left, exactly attempt 1's own deadline, and a seat that
  # failed attempt 1 was pre-empted at the deadline check below instead of
  # entering the retry batch the design's D3 makes unconditional.
  let turnStart = getMonoTime()
  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for slot in open:
        result.add(fallbackRecord(turnIndex, slot, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: episode.config.attempt1Ms else: episode.config.retryMs
    var batch: RequestBatch
    for slot in open:
      var user = episode.seatViewJson(slot)
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{', naming one " &
          "\"dir\".")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[slot].prompt, user))
      batch.post(request.url, request.headers, request.body, $slot)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS -- and sim_config REJECTS a
    # sub-second value, so the floor below is an identity: 6000 -> 6 s,
    # 3000 -> 3 s, worst case 9 s inside the 11 s turnBudgetMs cap.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, slot in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        var order = parseSnakeOrder(extractJsonObject(text),
          episode.state.snakes[slot].lastDir, episode.legalMask(slot))
        order.source = dsLlm
        order.latencyMs = latency
        if order.repaired:
          inc episode.seats[slot].ordersRejected
        engine.orders[slot] = order
        engine.haveOrder[slot] = true
        inc episode.seats[slot].llmTurns
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          cause = "throttled"
        result.add(fallbackRecord(turnIndex, slot, attempt + 1, cause,
          error.msg))
        ## `will retry` -- NEVER `falling back`: only a genuine fallback may
        ## say that, because phase 60 greps the game log for it.
        echo "snake-royale llm: seat ", slot, " attempt ", attempt + 1,
          " failed, will retry: ", error.msg
        stillOpen.add(slot)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way.
      echo "snake-royale llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays coil for this turn -------------------------
  for slot in open:
    engine.orders[slot] = fallbackOrder(episode.state, slot)
    engine.haveOrder[slot] = true
    inc episode.seats[slot].fallbackTurns
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(turnIndex, slot, 2, cause,
      "seat fell back to the coil direction"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "snake-royale llm: seat ", slot, " falling back to coil (", cause,
      ") on turn ", turnIndex
