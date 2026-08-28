## Bounded, legal orders on the scripted baselines; the fallback path is the
## coil proc; the reply validator repairs rather than rejects.

import std/[json, strutils, unicode]
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

# Tolerant JSON extraction: markdown fences and prose survive.
block:
  let fenced = "Sure!\n```json\n{\"dir\":\"up\"}\n```\nGood luck."
  c.check(extractJsonObject(fenced){"dir"}.getStr() == "up",
    "a fenced reply is recovered")

# 27 -- the shipped tunables equal the recorded sweep, and coil beats forager.
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

  # The ladder: coil's mean score over the recorded 24-episode ladder beats
  # forager's, by a margin the sweep pinned.
  var coilTotal = 0
  var foragerTotal = 0
  var episodes = 0
  for seed in 1 .. 24:
    var config = defaultGameConfig()
    config.seed = seed * 977
    config.maxTurns = 50
    config.turnSpacingMs = 0
    let played = runScriptedEpisode(config, [blCoil, blForager, blCoil, blForager])
    let permille = played.episode.scorePermille()
    coilTotal = coilTotal + permille[0] + permille[2]
    foragerTotal = foragerTotal + permille[1] + permille[3]
    inc episodes
  let margin = float(coilTotal - foragerTotal) / float(episodes * 2 * 1000)
  echo "coil vs forager margin over the 24-episode ladder: ", margin
  c.check(margin > 0.0,
    "coil out-survives forager over the recorded ladder (margin " &
    $margin & ")")

c.report()
