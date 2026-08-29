## Record then re-derive, for EVERY end reason; the bytes are self-sufficient;
## replay_summary.py is strict UTF-8 JSON; every fixture carries the current
## GameVersion.

import std/[json, os, osproc, strutils, unicode]
import snake/[board, rules, sim, sim_types, engine, baselines, replays,
              records, replay_runtime, directives, wire_constants]
import helpers

var c = newChecker("test_snake_replay")

proc config(module: string, seed, maxTurns: int): GameConfig =
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
  result.seed = seed
  result.maxTurns = maxTurns
  result.turnSpacingMs = 0

# 33 -- record then re-derive, every end reason.
for endRule in [erLastStanding, erFullTime, erWallClock, erSimFault]:
  ## The abnormal endings are RECORDED, not simulated after the fact: the
  ## episode's own loop is cut at turn 12 and settles `deadline`/`wall_clock`
  ## or `fault`/`sim_fault`, writing the stop record through the same proc the
  ## server writes it with. So the replay really ends where the stop says it
  ## does, which is what makes "identical gameHash at every turn INCLUDING the
  ## stop turn" a claim about a stopped episode (the particle-worlds scar).
  let
    stopAt = (if endRule in {erWallClock, erSimFault}: 12 else: 0)
    reason =
      case endRule
      of erWallClock: rsDeadline
      of erSimFault: rsFault
      else: rsComplete
  var played = runScriptedEpisodeWith(config("royale", 42, 40),
    certificationSeats(), CoilTunables, ForagerTunables,
    stopAfterTurn = stopAt, stopReason = reason, stopEndRule = endRule)
  let bytes = encodeReplay(played.replay)
  var rt = loadReplay(bytes)
  c.check(rt.mismatchTurn == -1,
    $endRule & ": identical gameHash at EVERY turn including the stop turn")
  if endRule in {erWallClock, erSimFault}:
    c.check(played.episode.reason == reason,
      $endRule & ": the episode really settled " & $reason)
    c.check(played.episode.endRule == endRule,
      $endRule & ": with that endRule")
    c.check(played.replay.turns.len == 12,
      $endRule & ": and the recorded turns stop where the loop did (" &
      $played.replay.turns.len & ")")
    c.check(rt.stopEndRule == $endRule, $endRule & ": the stop record survives")
    c.check(rt.stopTurn == played.episode.state.turn,
      $endRule & ": and names the stop turn")
    c.check(rt.snapshots.len - 1 == rt.stopTurn,
      $endRule & ": the re-derivation ends on that same turn")
    let results = parseJson(played.episode.snakeResultsJson())
    c.check(results{"reason"}.getStr() == $reason,
      $endRule & ": and the results document says so")
    var total = 0
    for v in played.episode.scorePermille():
      total = total + v
    c.check(total == 0,
      $endRule & ": a stopped episode still ranks and still sums to zero")
  else:
    c.check(played.episode.reason == rsComplete,
      $endRule & ": a natural ending is complete")

# 33b -- the transport's `s:<tick>` is a TICK, on the axis the chrome draws.
block:
  ## `seekToFraction` in client/replay_broadcast.html sends an absolute turn
  ## (`st + round(frac * (mx - st))`), which is the starter's wire word. A
  ## runtime that read it as a FRACTION clamped every non-zero click to 1.0,
  ## landed on the last frame and RAISED the endcard (`over` is
  ## `turn >= turns`) instead of dismissing it.
  let played = runScriptedEpisode(config("royale", 42, 40), certificationSeats())
  var rt = loadReplay(encodeReplay(played.replay))
  let turns = rt.snapshots.len - 1
  c.check(turns >= 10, "33b: the fixture is long enough to scrub")
  let midway = turns div 2
  rt.command("s:" & $midway)
  c.check(rt.turnAt(rt.playback.frame) == midway,
    "33b: s:<tick> lands on that turn (got " &
    $rt.turnAt(rt.playback.frame) & " of " & $turns & ")")
  c.check(rt.turnAt(rt.playback.frame) < turns,
    "33b: a midway seek is NOT the last turn, so the endcard comes down")
  rt.command("s:0")
  c.check(rt.playback.frame == 0, "33b: s:0 is the first frame")
  rt.command("s:" & $(turns + 500))
  c.check(rt.turnAt(rt.playback.frame) == turns,
    "33b: a tick past the end clamps to the last turn")
  rt.command("s:-3")
  c.check(rt.playback.frame == 0, "33b: a negative tick clamps to zero")
  let page = readFile("client/replay_broadcast.html")
  c.check("send('s:' + (st + Math.round(frac * (mx - st))))" in page,
    "33b: and the page still sends the tick the runtime now parses")

# 33c -- the duel banner's claim is true: the playhead really does halve.
block:
  ## `client/replay_broadcast.html` announces `DUEL — half speed` from the
  ## pre-scan's duel turn. `framesPerTurnAt` doubles the frames per turn there
  ## and had no caller, so the banner was the only thing that changed.
  let played = runScriptedEpisode(config("royale", 42, 40), certificationSeats())
  var rt = loadReplay(encodeReplay(played.replay))
  let turns = rt.snapshots.len - 1
  c.check(turns >= 12, "33c: the fixture is long enough")
  rt.duelTurn = 6
  c.check(not rt.duelActive(5), "33c: before the duel turn, normal speed")
  c.check(rt.duelActive(6) and rt.duelActive(7), "33c: from it, slow-mo")
  c.check(rt.framesPerTurnAt(5) == rt.playback.framesPerTurn,
    "33c: a normal turn takes renderFramesPerTurn frames")
  c.check(rt.framesPerTurnAt(6) == rt.playback.framesPerTurn * 2,
    "33c: a duel turn takes twice as many")

  rt.seekTurn(2)
  rt.playback.playing = true
  let beforeFrame = rt.playback.frame
  for _ in 1 .. 8:
    rt.advance()
  let normal = rt.playback.frame - beforeFrame
  c.check(normal == 8, "33c: eight frames of normal playback advance eight")

  rt.seekTurn(8)                       ## inside the duel
  let duelFrom = rt.playback.frame
  for _ in 1 .. 8:
    rt.advance()
  let slow = rt.playback.frame - duelFrom
  c.check(slow == 4,
    "33c: eight frames inside the duel advance FOUR -- half speed (got " &
    $slow & ")")
  c.check(rt.turnAt(rt.playback.frame) >= 8,
    "33c: and the playhead is still on the turn axis the scrubber draws")

# 33d -- the 0.5x chip is a real half-rate playback, not just a label.
block:
  ## The transport's slowest multiplier. `advance` walks an INTEGER frame axis
  ## (the scrubber, `s:<tick>` and every beat button are 1:1 with it), so half
  ## speed has to fall out of the sub-frame accumulator: the whole ratio is
  ## kept in half frames and `halfSpeed` is the one un-doubled numerator.
  let played = runScriptedEpisode(config("royale", 42, 40), certificationSeats())
  var rt = loadReplay(encodeReplay(played.replay))
  c.check(rt.snapshots.len - 1 >= 12, "33d: the fixture is long enough")
  ## The duel's own doubling is a SECOND rate multiplier on the same axis, so
  ## it is switched off here and re-armed deliberately at the end of the block.
  rt.duelTurn = -1
  c.check(not rt.playback.halfSpeed and rt.displaySpeed() == 1.0,
    "33d: playback opens at 1x, not half")

  rt.command("5")
  c.check(rt.playback.halfSpeed and rt.displaySpeed() == 0.5,
    "33d: '5' selects half speed, and the packet's sp says 0.5")
  rt.seekTurn(2)
  rt.playback.playing = true
  let halfFrom = rt.playback.frame
  for _ in 1 .. 8:
    rt.advance()
  c.check(rt.playback.frame - halfFrom == 4,
    "33d: eight render frames at 0.5x advance FOUR (got " &
    $(rt.playback.frame - halfFrom) & ")")

  ## Every whole multiplier clears it, and lands on exactly the frame count it
  ## landed on before the accumulator was re-scaled.
  for (cmd, want) in [("1", 1), ("2", 2), ("3", 3), ("4", 4), ("8", 8),
                      ("6", 16)]:
    rt.command(cmd)
    c.check(not rt.playback.halfSpeed and rt.playback.speed == want and
      rt.displaySpeed() == float(want),
      "33d: '" & cmd & "' is " & $want & "x and clears half speed")
    rt.seekTurn(2)
    let from2 = rt.playback.frame
    for _ in 1 .. 4:
      rt.advance()
    c.check(rt.playback.frame - from2 == 4 * want,
      "33d: four frames at " & $want & "x advance " & $(4 * want) & " (got " &
      $(rt.playback.frame - from2) & ")")

  ## Half speed COMPOSES with the duel's own doubling rather than fighting it:
  ## inside the duel a turn already takes twice its frames, so 0.5x is a
  ## quarter rate.
  rt.command("5")
  rt.duelTurn = 6
  rt.seekTurn(8)
  let duelFrom = rt.playback.frame
  for _ in 1 .. 8:
    rt.advance()
  c.check(rt.playback.frame - duelFrom == 2,
    "33d: eight frames at 0.5x inside the duel advance TWO (got " &
    $(rt.playback.frame - duelFrom) & ")")

  ## And the browser end of the same wire: the engine emits 0.5 in `speeds`,
  ## the page builds the chip the shared chrome cannot, and Space still pauses.
  let wire = WireConstantsJs
  c.check("speeds:[0.5,1,2,3,4,8,16]" in wire,
    "33d: the wire block emits 0.5 at the head of speeds (got " & wire & ")")
  let page = readFile("client/replay_broadcast.html")
  let chipClick =
    "halfChip.addEventListener('click', function () { CTX.send('5'); });"
  c.check(chipClick in page,
    "33d: the page's 0.5x chip sends the engine's own command char")
  c.check("halfChip.classList.toggle('on', s.sp === 0.5)" in page,
    "33d: and lights itself from the frame packet's sp")
  c.check("if (k === ' ') { ev.preventDefault(); togglePlay(); }" in page,
    "33d: Space pauses on the shipped page, and does not scroll it")

# 34 -- the replay is self-sufficient.
block:
  let played = runScriptedEpisode(config("geese", 7, 40), certificationSeats())
  let bytes = encodeReplay(played.replay)
  let decoded = decodeReplay(bytes)
  let node = parseJson(decoded.configJson)
  c.check(decoded.gameName == GameName, "34: the game name is in the bytes")
  c.check(decoded.gameVersion == GameVersion, "34: and the game version")
  c.check(node{"seed"}.getInt() == 7, "34: and the seed")
  c.check(node{"module"}.getStr() == "geese", "34: and the module")
  c.check(node{"board"}{"w"}.getInt() == 11 and
    node{"board"}{"h"}.getInt() == 7 and node{"board"}{"wrap"}.getBool(),
    "34: and the whole board document")
  c.check(node{"spawnDeal"}.len == Seats, "34: and spawnDeal")
  c.check(node{"spawnAnchors"}.len == Seats, "34: and the derived anchors")
  c.check(node{"aliases"}.len == Seats, "34: and the aliases")
  c.check(node{"colours"}.len == Seats, "34: and the colours")
  c.check(node{"policyKinds"}.len == Seats, "34: and the policy kinds")
  c.check(decoded.joins.len == Seats, "34: and the seat names")
  c.check(decoded.turns.len == played.replay.turns.len,
    "34: every direction byte")
  var sawResult = false
  var sawRegister = false
  for record in decoded.chats:
    if record.startsWith("{\"k\":\"result\""): sawResult = true
    if "\"k\":\"register\"" in record: sawRegister = true
  c.check(sawResult, "34: the result record is in the bytes")
  c.check(sawRegister, "34: and every register record")
  # Nothing under data/ is consulted to render: the runtime re-derives from
  # the bytes alone.
  var rt = loadReplay(bytes)
  c.check(rt.snapshots.len > 1, "34: the bytes alone re-simulate")

# 35 -- replay_summary.py is strict UTF-8 JSON.
block:
  var played = runScriptedEpisode(config("royale", 42, 20), certificationSeats())
  ## Fill every capped field to EXACTLY its cap with 4-byte emoji.
  var say = ""
  for _ in 0 ..< MaxSayRunes:
    say.add("\u{1F600}")
  var notes = ""
  for _ in 0 ..< MaxNoteRunes:
    notes.add("\u{1F600}")
  ## sanitizeSay strips non-ASCII by design (the printable shout filter), so
  ## the emoji path is exercised through the NOTE and through a directive
  ## record built with the raw rune truncation.
  doAssert sanitizeSay(say).len == 0
  doAssert sanitizeNote(notes).runeLen == MaxNoteRunes
  var replay = played.replay
  replay.chats.add($(%*{
    "k": "directive", "turn": 1, "slot": 0, "alias": cogAlias(0),
    "source": "llm", "latency_ms": 12, "dir": "up", "repaired": false,
    "say": truncateRunes(say, MaxSayRunes),
    "notes": truncateRunes(notes, MaxNoteRunes)}))
  let path = getTempDir() / "snake-royale-summary.replay"
  writeFile(path, encodeReplay(replay))
  let (output, code) = execCmdEx("python3 tools/replay_summary.py " & path)
  c.check(code == 0, "35: replay_summary.py exits 0")
  c.check(output.validateUtf8() == -1, "35: its output is valid UTF-8")
  var parsed: JsonNode
  try:
    parsed = parseJson(output)
  except CatchableError:
    c.check(false, "35: its output parses as JSON")
    parsed = newJObject()
  c.check(parsed{"protocol"}.getStr() == "snake-royale/v1",
    "35: protocol is snake-royale/v1")
  c.check(parsed{"results"}{"reason"}.getStr() == "complete",
    "35: the results ride in the bytes")
  c.check("\\ud" notin output.toLowerAscii(),
    "35: no lone surrogate in the output")
  removeFile(path)

# 36 -- every recorded replay carries the current GameVersion.
block:
  ## The fixture RECIPES are the source of truth (the starter's fixture-recipe
  ## discipline): one per rule module, re-recorded by tools/record_fixture.sh
  ## on every GameVersion bump. The sweep below records each recipe and
  ## asserts the version it carries, and then sweeps any fixture that IS
  ## committed under tests/fixtures/ for a stale one.
  const Recipes = [("royale", 42, 40), ("geese", 7, 40), ("tron", 13, 40)]
  for (module, seed, turns) in Recipes:
    let played = runScriptedEpisode(config(module, seed, turns),
      certificationSeats())
    let decoded = decodeReplay(encodeReplay(played.replay))
    c.check(decoded.gameVersion == GameVersion,
      "36: " & module & " carries GameVersion " & GameVersion)
    c.check(decoded.gameName == GameName, "36: " & module & " is this game")
    var rt = loadReplay(encodeReplay(played.replay))
    c.check(rt.mismatchTurn == -1, "36: " & module & " re-derives cleanly")
  let recipeScript = readFile("tools/record_fixture.sh")
  for (module, seed, _) in Recipes:
    c.check(module in recipeScript and $seed in recipeScript,
      "36: tools/record_fixture.sh carries the " & module & " recipe")
  ## The three fixtures are COMMITTED, and tools/wasm_replay_smoke.cjs runs
  ## the exact emitted wasm module over them in ci.yml's wasm-viewer job --
  ## wasm32-only failures (integer traps, address-space exhaustion) are
  ## invisible to these 64-bit shards. Here they are checked natively: the
  ## version they carry, and that they still re-derive against the CURRENT
  ## rules. A rules change that leaves them behind fails here, which is the
  ## re-record signal.
  c.check(dirExists("tests/fixtures"), "36: tests/fixtures is committed")
  var found = 0
  for kind, path in walkDir("tests/fixtures"):
    if kind != pcFile or not path.endsWith(".replay"):
      continue
    inc found
    let bytes = readFile(path)
    let decoded = decodeReplay(bytes)
    c.check(decoded.gameVersion == GameVersion,
      "36: committed fixture " & path & " is not stale")
    c.check(decoded.gameName == GameName,
      "36: committed fixture " & path & " is this game")
    var rt = loadReplay(bytes)
    c.check(rt.mismatchTurn == -1,
      "36: committed fixture " & path & " still re-derives under the " &
      "current rules (mismatch at turn " & $rt.mismatchTurn & "); " &
      "re-record with tools/record_fixture.sh")
    c.check(rt.replay.turns.len >= 10,
      "36: committed fixture " & path & " has turns to replay")
  c.check(found == 3,
    "36: all three module fixtures are committed (found " & $found & ")")
  let workflow = readFile(".github/workflows/ci.yml")
  c.check("wasm_replay_smoke.cjs" in workflow,
    "36: and ci.yml runs the wasm module over them")

c.report()
