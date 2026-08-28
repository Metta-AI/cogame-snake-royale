## Parsing the runtime `game_config` into a `GameConfig`.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_config.nim`. Every key here is a
## declared property of `coworld_manifest_template.json`'s `config_schema`;
## unknown keys are ignored rather than fatal, and out-of-range values are
## clamped rather than rejected, because a config that fails to parse is an
## episode that never starts.
##
## `attempt1Ms` and `retryMs` are REJECTED below one second: curly hands the
## deadline to CURLOPT_TIMEOUT, whose granularity is whole seconds, so a
## sub-second value is not the deadline it claims to be (the starter's 0.1.2
## scar).

import std/[json, strutils]
import rules, sim_types

proc getIntOr(node: JsonNode, key: string, fallback: int): int =
  let value = node{key}
  if value.isNil:
    return fallback
  case value.kind
  of JInt: int(value.getBiggestInt())
  of JFloat: int(value.getFloat())
  of JString:
    try: parseInt(value.getStr().strip()) except CatchableError: fallback
  else: fallback

proc getBoolOr(node: JsonNode, key: string, fallback: bool): bool =
  let value = node{key}
  if value.isNil:
    return fallback
  case value.kind
  of JBool: value.getBool()
  of JInt: value.getBiggestInt() != 0
  of JString: value.getStr().strip().toLowerAscii() in ["1", "true", "yes"]
  else: fallback

proc getStrOr(node: JsonNode, key, fallback: string): string =
  let value = node{key}
  if value.isNil or value.kind != JString: fallback else: value.getStr()

proc update*(config: var GameConfig, raw: string) =
  ## Applies one `game_config` document. Raises `SnakeError` only on a value
  ## that would silently change what the deadlines mean.
  if raw.strip().len == 0:
    return
  var node: JsonNode
  try:
    node = parseJson(raw)
  except CatchableError as error:
    raise newException(SnakeError, "game config is not JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(SnakeError, "game config is not a JSON object")

  config.module = normalizedModule(node.getStrOr("module", config.module))
  let preset = ruleModule(config.module)
  config.boardW = preset.board.w
  config.boardH = preset.board.h
  config.wrap = preset.board.wrap
  config.foodCount = preset.foodCount
  config.healthStart = preset.healthStart
  config.shrinkEvery = preset.shrinkEvery
  config.leaveTrail = preset.leaveTrail
  config.headToHead = $preset.headToHead
  config.startLength = preset.startLength
  config.maxTurns = preset.maxTurns

  config.seed = node.getIntOr("seed", config.seed)
  config.boardW = clamp(node.getIntOr("boardW", config.boardW), 7, 31)
  config.boardH = clamp(node.getIntOr("boardH", config.boardH), 5, 21)
  config.wrap = node.getBoolOr("wrap", config.wrap)
  config.foodCount = clamp(node.getIntOr("foodCount", config.foodCount), 0, 8)
  config.healthStart = clamp(
    node.getIntOr("healthStart", config.healthStart), 0, 200)
  config.shrinkEvery = clamp(
    node.getIntOr("shrinkEvery", config.shrinkEvery), 0, 200)
  config.leaveTrail = node.getBoolOr("leaveTrail", config.leaveTrail)
  let h2h = node.getStrOr("headToHead", config.headToHead).strip()
  config.headToHead = if h2h == $hhBothDie: $hhBothDie else: $hhLongerWins
  config.startLength = clamp(
    node.getIntOr("startLength", config.startLength), 1, 5)
  config.maxTurns = clamp(node.getIntOr("maxTurns", config.maxTurns), 5, 200)
  config.renderFramesPerTurn = clamp(
    node.getIntOr("renderFramesPerTurn", config.renderFramesPerTurn), 1, 48)
  config.sayTurns = clamp(node.getIntOr("sayTurns", config.sayTurns), 0, 8)
  config.numAgents = clamp(node.getIntOr("num_agents", config.numAgents), 1, Seats)
  config.minPlayers = clamp(
    node.getIntOr("minPlayers", config.minPlayers), 1, Seats)
  config.fastMode = node.getBoolOr("fastMode", config.fastMode)
  config.showPlayerLabels = node.getBoolOr(
    "showPlayerLabels", config.showPlayerLabels)
  config.attempt1Ms = node.getIntOr("attempt1Ms", config.attempt1Ms)
  config.retryMs = node.getIntOr("retryMs", config.retryMs)
  config.turnBudgetMs = node.getIntOr("turnBudgetMs", config.turnBudgetMs)
  config.turnSpacingMs = max(0, node.getIntOr("turnSpacingMs", config.turnSpacingMs))
  config.wallClockBudgetSeconds = max(1, node.getIntOr(
    "wallClockBudgetSeconds", config.wallClockBudgetSeconds))
  config.lobbyJoinTimeoutSeconds = max(1, node.getIntOr(
    "lobbyJoinTimeoutSeconds", config.lobbyJoinTimeoutSeconds))
  config.gameOverTurns = max(0, node.getIntOr(
    "gameOverTurns", config.gameOverTurns))
  config.model = node.getStrOr("model", config.model)
  config.maxOutputTokens = max(1, node.getIntOr(
    "maxOutputTokens", config.maxOutputTokens))

  if config.attempt1Ms < 1000 or config.retryMs < 1000 or
      config.attempt1Ms mod 1000 != 0 or config.retryMs mod 1000 != 0:
    raise newException(SnakeError,
      "attempt1Ms and retryMs must be a WHOLE number of seconds and at " &
      "least 1000 ms (got " & $config.attempt1Ms & " and " &
      $config.retryMs & "): curly hands the deadline to CURLOPT_TIMEOUT, " &
      "whose granularity is whole seconds, so anything else is not the " &
      "deadline it claims to be. 0.1.2 shipped 4500 and really ran with 4 s.")
  if config.turnBudgetMs < config.attempt1Ms:
    config.turnBudgetMs = config.attempt1Ms + config.retryMs

  config.playerNames = @[]
  let players = node{"players"}
  if not players.isNil and players.kind == JArray:
    for entry in players:
      if entry.kind == JObject:
        config.playerNames.add(entry.getStrOr("name", ""))
      elif entry.kind == JString:
        config.playerNames.add(entry.getStr())
  config.tokens = @[]
  let tokens = node{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    for entry in tokens:
      if entry.kind == JString:
        config.tokens.add(entry.getStr())
