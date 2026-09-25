## Numeric decision bridge for the same visible Snake Royale orders used by players.
## nim c -d:release --path:src -o:snake-numeric-bridge src/snake/numeric_bridge.nim

import std/[hashes, json]
import sim, decide, baselines, directives

when isMainModule:
  import std/[os, strutils]

const ChoiceCount* = 4

var
  episode: Episode
  decisionId: int
  learnerSeat: int
  variant = "royale"

proc values*(view: JsonNode): JsonNode =
  result = newJArray()
  for name in ["royale", "geese", "tron"]:
    result.add(%(if view["module"].getStr() == name: 1 else: 0))
  for name in ["w", "h"]: result.add(view["board"][name])
  result.add(%(if view["board"]["wrap"].getBool(): 1 else: 0))
  for name in ["turn", "max_turns", "turns_left", "alive"]: result.add(view[name])
  for name in ["health", "length", "free_space"]: result.add(view["you"][name])
  for move in view["moves"]:
    result.add(%(if move["legal"].getBool(): 1 else: 0))
    result.add(move["free_space"])
    result.add(%(if move["food"].getBool(): 1 else: 0))
  var cells: array[31 * 21, array[10, int]]
  let width = view["board"]["w"].getInt()
  let height = view["board"]["h"].getInt()
  for y in 0 ..< height:
    for x in 0 ..< width:
      cells[y * 31 + x][0] = 1
  for food in view["food"]:
    cells[food[1].getInt() * 31 + food[0].getInt()][1] = 1
  var snakes = @[view["you"]]
  for snake in view["snakes"]: snakes.add(snake)
  for index, snake in snakes:
    if not snake["alive"].getBool(): continue
    for part in snake["body"]:
      cells[part[1].getInt() * 31 + part[0].getInt()][2 + index] = 1
    let head = snake["head"]
    cells[head[1].getInt() * 31 + head[0].getInt()][6 + index] = 1
  for cell in cells:
    for channel in cell: result.add(%channel)

proc candidates*(view: JsonNode): JsonNode =
  result = newJArray()
  var anyLegal = false
  for move in view["moves"]:
    if move["legal"].getBool(): anyLegal = true
  for index in 0 ..< view["moves"].len:
    let move = view["moves"][index]
    result.add(if anyLegal and not move["legal"].getBool():
      newJNull() else: %*{"choice": index})

proc currentDecision(): JsonNode =
  let view = parseJson(episode.seatViewJson(learnerSeat))
  %*{"kind": "decision", "game": "snake-royale",
    "decision_id": decisionId, "seat": learnerSeat, "engine_seat": learnerSeat,
    "turn": episode.state.turn, "semantic_view": view, "inbox": [],
    "messages": [{"role": "user", "content": $view}],
    "speech_messages": [], "action_schema": {"type": "object",
      "properties": {"choice": {"type": "integer", "minimum": 0,
        "maximum": ChoiceCount - 1}}, "required": ["choice"]},
    "typed_question": newJNull()}

proc reset(request: JsonNode): JsonNode =
  doAssert request["players"].getInt() == Seats
  var config = defaultGameConfig()
  config.module = variant
  config.seed = int(hash(request["seed"].getStr()) and hash(high(int)))
  config.update($( %*{"module": variant, "seed": config.seed}))
  episode = newEpisode(config)
  decisionId = 0
  currentDecision()

proc step(request: JsonNode): JsonNode =
  if request["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(request["response"].getStr())
  let choice = action["choice"].getInt()
  let legal = candidates(parseJson(episode.seatViewJson(learnerSeat)))
  doAssert choice in 0 ..< ChoiceCount and legal[choice].kind != JNull
  var firstTurn = true
  while episode.state.aliveCount() > 1 and episode.state.turn < episode.config.maxTurns:
    var
      dirs: array[Seats, Dir]
      alts: array[Seats, tuple[has: bool, dir: Dir]]
    for slot in 0 ..< Seats:
      dirs[slot] = if slot == learnerSeat and firstTurn:
        DirOrder[choice]
      else:
        scriptedOrder(episode.state, slot, blCoil).dir
    discard resolveTurn(episode.state, dirs, alts)
    firstTurn = false
    if episode.state.snakes[learnerSeat].alive: break
  inc decisionId
  if episode.state.aliveCount() <= 1 or episode.state.turn >= episode.config.maxTurns:
    episode.turnsPlayed = episode.state.turn
    for slot in 0 ..< Seats:
      if episode.state.snakes[slot].alive:
        episode.state.snakes[slot].survivedTurns = episode.turnsPlayed
    episode.settle(rsComplete,
      if episode.state.aliveCount() <= 1: erLastStanding else: erFullTime)
    var scores = newJObject()
    for slot, score in episode.scorePermille(): scores[$slot] = %score
    return %*{"kind": "accepted", "action": action,
      "observation": {"kind": "terminal", "scores": scores}}
  %*{"kind": "accepted", "action": action, "observation": currentDecision()}

when isMainModule:
  if paramCount() notin 0 .. 2:
    quit("usage: snake-numeric-bridge [royale|geese|tron] [seat]", 1)
  if paramCount() >= 1: variant = paramStr(1)
  if paramCount() == 2: learnerSeat = parseInt(paramStr(2))
  doAssert variant in ["royale", "geese", "tron"]
  doAssert learnerSeat in 0 ..< Seats
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request)
      of "encode": %*{"decision_id": decisionId,
        "values": values(parseJson(episode.seatViewJson(learnerSeat))),
        "actions": candidates(parseJson(episode.seatViewJson(learnerSeat)))}
      of "teacher":
        let order = scriptedOrder(episode.state, learnerSeat, blCoil)
        %*{"response": $(%*{"choice": ord(order.dir)})}
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
