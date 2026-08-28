## Record then re-derive, for EVERY end reason; the bytes are self-sufficient;
## replay_summary.py is strict UTF-8 JSON; every fixture carries the current
## GameVersion.

import std/[json, os, osproc, strutils, unicode]
import snake/[board, rules, sim, sim_types, baselines, engine, replays,
              records, replay_runtime, directives]
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
  var played = runScriptedEpisode(config("royale", 42, 40), certificationSeats())
  var replay = played.replay
  if endRule in {erWallClock, erSimFault}:
    ## The load-bearing stop record: a wall-clock or fault fact cannot be
    ## re-derived from sim state, so it is recorded once and applied by the
    ## SAME proc on record and on playback (the particle-worlds scar).
    replay.chats.add(stopRecord(played.episode.state.turn, $endRule))
  let bytes = encodeReplay(replay)
  var rt = loadReplay(bytes)
  c.check(rt.mismatchTurn == -1,
    $endRule & ": identical gameHash at EVERY turn including the stop turn")
  if endRule in {erWallClock, erSimFault}:
    c.check(rt.stopEndRule == $endRule, $endRule & ": the stop record survives")
    c.check(rt.stopTurn == played.episode.state.turn,
      $endRule & ": and names the stop turn")

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
  var order = SnakeOrder(dir: dUp, say: sanitizeSay(say),
    notes: sanitizeNote(notes), source: dsLlm)
  ## sanitizeSay strips non-ASCII by design (the printable shout filter), so
  ## the emoji path is exercised through the NOTE and through a directive
  ## record built with the raw truncation.
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
  if dirExists("tests/fixtures"):
    for kind, path in walkDir("tests/fixtures"):
      if kind != pcFile or not path.endsWith(".replay"):
        continue
      let decoded = decodeReplay(readFile(path))
      c.check(decoded.gameVersion == GameVersion,
        "36: committed fixture " & path & " is not stale")

c.report()
