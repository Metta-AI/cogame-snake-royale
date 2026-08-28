## Bounded, legal orders on the scripted baselines; the fallback path is the
## coil proc; the reply validator repairs rather than rejects.

import std/[json, math, strutils, unicode]
import snake/[board, rules, space, sim, sim_types, sim_state, baselines,
              control, directives, engine]
import helpers

var c = newChecker("test_snake_control")

proc randomState(rng: var Rng, trial: int): GameState =
  let module = ModuleNames[trial mod ModuleNames.len]
  var rules = ruleModule(module)
  result = GameState(rules: rules, turn: trial, foodRng: initRng(trial),
    duelTurn: -1)
  let b = rules.board
  var used = newSeq[bool](b.cells())
  for slot in 0 ..< Seats:
    var snake = Snake(alive: rng.rand(10) > 0, killedBy: -1, lastDir: dRight,
      health: 1 + rng.rand(30))
    if snake.alive:
      let length = 1 + rng.rand(20)
      var head = b.cellAt(rng.rand(b.cells()))
      var guard = 0
      while used[b.cellIndex(head)] and guard < 40:
        head = b.cellAt(rng.rand(b.cells()))
        inc guard
      var here = head
      for i in 0 ..< length:
        if used[b.cellIndex(here)] and i > 0:
          break
        used[b.cellIndex(here)] = true
        snake.body.add(here)
        var stepped = false
        for _ in 0 .. 3:
          let d = DirOrder[rng.rand(4)]
          let moved = b.step(here, d)
          if not moved.offBoard and not used[b.cellIndex(moved.cell)]:
            here = moved.cell
            stepped = true
            break
        if not stepped:
          break
      snake.lastDir = DirOrder[rng.rand(4)]
      snake.maxLength = snake.body.len
      snake.finalLength = snake.body.len
    result.snakes[slot] = snake
  if rules.foodCount > 0:
    for _ in 0 ..< rules.foodCount:
      let f = b.cellAt(rng.rand(b.cells()))
      if not used[b.cellIndex(f)]:
        result.food.add(f)

var rng = initRng(90210)
var states: seq[GameState]
for trial in 0 ..< 500:
  states.add(randomState(rng, trial))

# 22 / 23 / 24 -- bounded, never unactuated, and agreeing with the resolver.
for kind in [blCoil, blForager]:
  for state in states:
    for slot in 0 ..< Seats:
      if not state.snakes[slot].alive or state.snakes[slot].body.len == 0:
        continue
      let order = scriptedOrder(state, slot, kind)
      c.check(ord(order.dir) >= 0 and ord(order.dir) < DirOrder.len,
        $kind & ": dir is in the enum")
      c.check(not order.hasAlt, $kind & ": no alt is proposed")
      c.check(order.say.len == 0 and order.notes.len == 0,
        $kind & ": a baseline never says anything")
      c.check(($order.directiveRecord(1, slot, cogAlias(slot), "")).len <= 1024,
        $kind & ": the serialised directive is bounded")
      let neck = state.snakes[slot].neck()
      if neck.has:
        let moved = state.rules.board.step(state.snakes[slot].head(), order.dir)
        var namedNeck = not moved.offBoard and moved.cell == neck.cell
        ## The sealed case is the one exception the design names: with every
        ## direction fatal the snake returns last_dir and dies rather than the
        ## loop stalling.
        var anyLegal = false
        for d in DirOrder:
          if scoreDir(state, slot, d, tunablesFor(kind)) != NegInfinity:
            anyLegal = true
        if anyLegal:
          c.check(not namedNeck, $kind & ": never proposes the neck")
      ## The baseline's minus-infinity set is exactly the resolver's illegal
      ## set: the predicates are the same procs, which is what stops a second
      ## copy of the rules appearing.
      for d in DirOrder:
        let scored = scoreDir(state, slot, d, tunablesFor(kind))
        let moved = state.rules.board.step(state.snakes[slot].head(), d)
        let isNeck = neck.has and not moved.offBoard and moved.cell == neck.cell
        let fatal = moved.offBoard or
          (not moved.offBoard and willOccupy(state, slot, moved.cell))
        if scored == NegInfinity:
          c.check(fatal or isNeck,
            $kind & ": a rejected direction is one the resolver kills for")
        else:
          c.check(not fatal, $kind & ": an accepted direction is survivable")

# 25 -- the fallback path and the coil baseline resolve to the same proc.
for state in states[0 ..< 60]:
  for slot in 0 ..< Seats:
    if not state.snakes[slot].alive or state.snakes[slot].body.len == 0:
      continue
    c.check(fallbackDir(state, slot) == baselineDir(state, slot, blCoil),
      "the fallback IS the coil proc")
    c.check(fallbackOrder(state, slot).dir ==
      scriptedOrder(state, slot, blCoil).dir,
      "the fallback order IS the coil order")
    c.check(FallbackBaseline == blCoil, "and it is named as such")

# 26 -- reply validation.
block:
  var legal: array[4, bool]
  for i in 0 .. 3: legal[i] = i != 0
  let full = parseSnakeOrder(parseJson(
    """{"dir":"LEFT","alt":"Up","say":"north lane","notes":"a\nb"}"""),
    dRight, legal)
  c.check(full.dir == dLeft, "dir is case-insensitive")
  c.check(full.hasAlt and full.alt == dUp, "alt parses")
  c.check(full.notes == "a b", "notes collapse newlines")
  for spelling in ["u", "north", "UP", " up ", "Move-Up", "move up"]:
    let node = %*{"dir": spelling}
    c.check(parseSnakeOrder(node, dRight, legal).dir == dUp,
      "tolerated spelling: " & spelling)
  let only = parseSnakeOrder(parseJson("""{"dir":"down"}"""), dRight, legal)
  c.check(only.dir == dDown and not only.hasAlt, "a reply with only dir is fine")
  let repaired = parseSnakeOrder(parseJson("""{"dir":"sideways","alt":"left"}"""),
    dRight, legal)
  c.check(repaired.dir == dLeft and repaired.repaired,
    "an unknown dir falls to alt and is counted")
  let toLast = parseSnakeOrder(parseJson("""{"dir":"sideways"}"""), dRight, legal)
  c.check(toLast.dir == dRight, "then to last_dir")
  var noneLegal: array[4, bool]
  for i in 0 .. 3: noneLegal[i] = i == 2
  let toFirstLegal = parseSnakeOrder(parseJson("""{"dir":"???"}"""), dUp, noneLegal)
  c.check(toFirstLegal.dir == dDown,
    "then to the first legal direction in wire order")
  var raised = false
  try:
    discard parseSnakeOrder(parseJson("[1,2,3]"), dUp, legal)
  except DirectiveError:
    raised = true
  c.check(raised, "a non-object is rejected")

  # Rune-boundary truncation with a 4-byte emoji sitting exactly on each cap.
  let emoji = "\u{1F600}"
  var saySrc = ""
  for _ in 0 ..< MaxSayRunes + 4:
    saySrc.add("a")
  saySrc = saySrc[0 ..< MaxSayRunes - 1] & emoji & "bbbb"
  let cut = truncateRunes(saySrc, MaxSayRunes)
  c.check(cut.runeLen == MaxSayRunes, "say cuts at exactly the rune cap")
  c.check(cut.validateUtf8() == -1, "and the cut is valid UTF-8")
  var noteSrc = ""
  for _ in 0 ..< MaxNoteRunes - 1:
    noteSrc.add("n")
  noteSrc.add(emoji)
  noteSrc.add(emoji)
  let noteCut = sanitizeNote(noteSrc)
  c.check(noteCut.runeLen == MaxNoteRunes, "notes cut at exactly the rune cap")
  c.check(noteCut.validateUtf8() == -1, "and stay valid UTF-8")
  c.check(sanitizeSay("{control}").find('{') < 0,
    "a shout can never start with a brace")
  c.check(MaxReplyBytes == 4096, "the reply read is capped at 4096 bytes")
  ## ...and the cap is APPLIED, not merely declared. A reply that buries its
  ## JSON past the cap is cut, and one that puts it inside the cap survives.
  block:
    var prose = ""
    for _ in 0 ..< MaxReplyBytes:
      prose.add("x")
    let buried = prose & """{"dir":"up"}"""
    c.check(buried.len > MaxReplyBytes, "the sample really exceeds the cap")
    c.check(boundedReply(buried).len == MaxReplyBytes,
      "a reply longer than the cap is cut to it")
    var raised = false
    try:
      discard extractJsonObject(boundedReply(buried))
    except DirectiveError:
      raised = true
    c.check(raised, "so JSON buried past the cap is not read at all")
    let inside = """{"dir":"up"}""" & prose
    c.check(extractJsonObject(boundedReply(inside)){"dir"}.getStr() == "up",
      "and a reply whose object is inside the cap still parses")
    ## The cut lands on a rune boundary: a 4-byte emoji straddling byte 4096
    ## must not be sliced in half.
    var straddle = ""
    for _ in 0 ..< MaxReplyBytes - 2:
      straddle.add("y")
    for _ in 0 ..< 8:
      straddle.add("\u{1F600}")
    let cut = boundedReply(straddle)
    c.check(cut.len <= MaxReplyBytes, "the cut never exceeds the cap")
    c.check(cut.validateUtf8() == -1,
      "and it is still valid UTF-8 (cut at " & $cut.len & " bytes)")
    c.check(readFile("src/snake/decide.nim").contains("boundedReply("),
      "and the decision path reads every reply through it")

# Tolerant JSON extraction: markdown fences and prose survive.
block:
  let fenced = "Sure!\n```json\n{\"dir\":\"up\"}\n```\nGood luck."
  c.check(extractJsonObject(fenced){"dir"}.getStr() == "up",
    "a fenced reply is recovered")

# 27 -- the shipped tunables ARE the swept pick, and the ladder still
#       reproduces the numbers that pick was recorded with.
block:
  let tuning = parseJson(readFile("tools/ci/baseline_tuning.json"))
  for (name, want) in [("coil", CoilTunables), ("forager", ForagerTunables)]:
    let node = tuning{"baselines"}{name}
    c.check(not node.isNil, name & " is in the recorded sweep")
    if node.isNil: continue
    c.check(node{"spaceWeight"}.getInt == want.spaceWeight, name & " spaceWeight")
    c.check(node{"spaceCap"}.getInt == want.spaceCap, name & " spaceCap")
    c.check(node{"headRiskPenalty"}.getInt == want.headRiskPenalty,
      name & " headRiskPenalty")
    c.check(node{"killBonus"}.getInt == want.killBonus, name & " killBonus")
    c.check(node{"foodWeight"}.getInt == want.foodWeight, name & " foodWeight")
    c.check(node{"hungerThreshold"}.getInt == want.hungerThreshold,
      name & " hungerThreshold")

  ## The ladder is the regression pin. Four seeds on each of the three rule
  ## modules, each played TWICE with the two baselines swapped between the
  ## seat pairs -- 24 episodes -- measured through the SAME `ladderTotals`
  ## proc `tools/tune_baselines.nim --check` uses, so the test and the sweep
  ## can never measure two different things. Any change to the rules, to the
  ## scoring or to either baseline moves these integers.
  let totals = ladderTotals(CoilTunables, ForagerTunables)
  let measured = tuning{"measured"}{"total"}
  echo "ladder: coilPermille=", totals.coilPermille,
    " foragerPermille=", totals.foragerPermille,
    " coilTurns=", totals.coilTurns, " foragerTurns=", totals.foragerTurns,
    " margin=", ladderMargin(totals)
  c.check(totals.coilPermille == measured{"coilPermille"}.getInt(),
    "the ladder reproduces the recorded coil score")
  c.check(totals.foragerPermille == measured{"foragerPermille"}.getInt(),
    "the ladder reproduces the recorded forager score")
  c.check(totals.coilTurns == measured{"coilTurns"}.getInt(),
    "the ladder reproduces the recorded coil survival")
  c.check(totals.foragerTurns == measured{"foragerTurns"}.getInt(),
    "the ladder reproduces the recorded forager survival")
  for index, module in LadderModules:
    let per = tuning{"measured"}{"perModule"}{module}
    c.check(totals.perModule[index].coilPermille ==
      per{"coilPermille"}.getInt(), module & ": coil score")
    c.check(totals.perModule[index].foragerPermille ==
      per{"foragerPermille"}.getInt(), module & ": forager score")

  ## The seat mirror is what makes the margin a measurement of the PLAYERS:
  ## the four spawn anchors are not equally good, so two identical players
  ## must score exactly 0.0 on this ladder. They do -- and coil, the cert
  ## player, the per-turn fallback and the default for an unregistered seat,
  ## beats forager on it.
  let mirrorControl = ladderTotals(ForagerTunables, ForagerTunables)
  c.check(ladderMargin(mirrorControl) == 0.0,
    "the ladder is seat-balanced: an identical pair scores exactly 0 (got " &
    $ladderMargin(mirrorControl) & ")")
  let margin = ladderMargin(totals)
  c.check(margin > 0.0,
    "coil out-scores forager over the recorded ladder (margin " &
    $margin & ")")
  ## The two baselines must also play DIFFERENTLY -- a filler that is a copy
  ## of the other filler tells a champion nothing. The scores are zero-sum per
  ## episode, so a materially non-zero margin is what separation looks like.
  c.check(abs(margin) >= 0.05,
    "coil and forager are materially different players (margin " &
    $margin & ")")
  c.check(totals.coilPermille + totals.foragerPermille == 0,
    "and every ladder episode is exactly zero sum")
  ## And it is not one lucky module: coil takes all three.
  for index, module in LadderModules:
    c.check(totals.perModule[index].coilPermille > 0,
      "coil wins the " & module & " ladder")

c.report()
