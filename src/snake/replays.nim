## The binary `COWLDSNK` replay: the starter's format, retargeted.
##
## `coworld-ctf`'s `replays.nim` writes a binary `COWLD…` stream of recorded
## inputs plus a per-tick hash; this fork keeps exactly that shape. The static
## wasm viewer parses these bytes and re-simulates with the SAME sim module,
## so everything the viewer needs is in the file and no server is contacted
## except S3 for it.
##
## Layout (little-endian; `str` is a u32 length followed by that many bytes):
##
##   magic "COWLDSNK"        8 bytes
##   u32   format version
##   str   game name         "snake-royale"
##   str   game version
##   str   config JSON       seed, module, the whole board document, the
##                           cadence constants, spawnDeal, spawnAnchors,
##                           players[].name (REAL names), aliases, colours
##   u32   join count        then per join: u32 slot, str name, str token
##   u32   turn count        then per turn: 4 direction bytes (0..3, 255 =
##                           already dead) and a u64 gameHash
##   u32   chat count        then per record: str
##
## FOOD IS NOT RECORDED and does not need to be: `foodRng` is a pure function
## of the seed and the resolution order, so the wasm module re-derives every
## apple and the per-turn `gameHash` proves it.

import std/json
import board, sim, sim_types

type
  ReplayTurn* = object
    dirs*: array[Seats, uint8]
    hash*: uint64

  Replay* = object
    gameName*: string
    gameVersion*: string
    configJson*: string
    joins*: seq[tuple[slot: int, name, token: string]]
    turns*: seq[ReplayTurn]
    chats*: seq[string]

proc putU32(buffer: var string, value: uint32) =
  buffer.add(chr(int(value and 0xFF'u32)))
  buffer.add(chr(int((value shr 8) and 0xFF'u32)))
  buffer.add(chr(int((value shr 16) and 0xFF'u32)))
  buffer.add(chr(int((value shr 24) and 0xFF'u32)))

proc putU64(buffer: var string, value: uint64) =
  putU32(buffer, uint32(value and 0xFFFFFFFF'u64))
  putU32(buffer, uint32((value shr 32) and 0xFFFFFFFF'u64))

proc putStr(buffer: var string, value: string) =
  putU32(buffer, uint32(value.len))
  buffer.add(value)

type Reader = object
  data: string
  pos: int

proc need(reader: var Reader, count: int) =
  if reader.pos + count > reader.data.len:
    raise newException(SnakeError, "replay truncated")

proc getU32(reader: var Reader): uint32 =
  reader.need(4)
  result = uint32(ord(reader.data[reader.pos])) or
    (uint32(ord(reader.data[reader.pos + 1])) shl 8) or
    (uint32(ord(reader.data[reader.pos + 2])) shl 16) or
    (uint32(ord(reader.data[reader.pos + 3])) shl 24)
  reader.pos += 4

proc getU64(reader: var Reader): uint64 =
  let lo = reader.getU32()
  let hi = reader.getU32()
  uint64(lo) or (uint64(hi) shl 32)

proc getStr(reader: var Reader): string =
  let length = int(reader.getU32())
  reader.need(length)
  result = reader.data[reader.pos ..< reader.pos + length]
  reader.pos += length

proc replayConfigJson*(episode: Episode): string =
  ## The self-sufficient config document. `players[].name` carries the REAL
  ## policy names -- spectator side only; a seat never sees this.
  let
    b = episode.state.rules.board
    r = episode.state.rules
  var
    players = newJArray()
    aliases = newJArray()
    colours = newJArray()
    kinds = newJArray()
    deal = newJArray()
    anchors = newJArray()
  for slot in 0 ..< Seats:
    players.add(%*{"name": episode.seats[slot].name})
    aliases.add(%cogAlias(slot))
    colours.add(%episode.colour(slot))
    kinds.add(%episode.seats[slot].policyKind)
    deal.add(%episode.spawnDeal[slot])
  for a in b.spawnAnchors():
    anchors.add(%[a.x, a.y])
  $(%*{
    "protocol": ProtocolName,
    "seed": episode.config.seed,
    "module": r.name,
    "board": {"w": b.w, "h": b.h, "wrap": b.wrap, "cellPx": b.cellPx},
    "foodCount": r.foodCount,
    "healthStart": r.healthStart,
    "shrinkEvery": r.shrinkEvery,
    "leaveTrail": r.leaveTrail,
    "headToHead": $r.headToHead,
    "startLength": r.startLength,
    "maxTurns": r.maxTurns,
    "num_agents": Seats,
    "spawnDeal": deal,
    "spawnAnchors": anchors,
    "players": players,
    "aliases": aliases,
    "colours": colours,
    "policyKinds": kinds,
    "attempt1Ms": episode.config.attempt1Ms,
    "retryMs": episode.config.retryMs,
    "turnBudgetMs": episode.config.turnBudgetMs,
    "turnSpacingMs": episode.config.turnSpacingMs,
    "renderFramesPerTurn": episode.config.renderFramesPerTurn,
    "sayTurns": episode.config.sayTurns,
    "fastMode": episode.config.fastMode,
    "showPlayerLabels": episode.config.showPlayerLabels
  })

proc encodeReplay*(replay: Replay): string =
  result = ReplayMagic
  putU32(result, uint32(ReplayFormatVersion))
  putStr(result, replay.gameName)
  putStr(result, replay.gameVersion)
  putStr(result, replay.configJson)
  putU32(result, uint32(replay.joins.len))
  for join in replay.joins:
    putU32(result, uint32(join.slot))
    putStr(result, join.name)
    putStr(result, join.token)
  putU32(result, uint32(replay.turns.len))
  for t in replay.turns:
    for slot in 0 ..< Seats:
      result.add(chr(int(t.dirs[slot])))
    putU64(result, t.hash)
  putU32(result, uint32(replay.chats.len))
  for record in replay.chats:
    putStr(result, record)

proc decodeReplay*(bytes: string): Replay =
  if bytes.len < ReplayMagic.len or
      bytes[0 ..< ReplayMagic.len] != ReplayMagic:
    raise newException(SnakeError,
      "not a snake-royale replay: bad magic (expected " & ReplayMagic & ")")
  var reader = Reader(data: bytes, pos: ReplayMagic.len)
  let version = int(reader.getU32())
  if version != ReplayFormatVersion:
    raise newException(SnakeError,
      "replay format version " & $version & " is not " &
      $ReplayFormatVersion)
  result.gameName = reader.getStr()
  result.gameVersion = reader.getStr()
  result.configJson = reader.getStr()
  let joins = int(reader.getU32())
  for _ in 0 ..< joins:
    let slot = int(reader.getU32())
    let name = reader.getStr()
    let token = reader.getStr()
    result.joins.add((slot, name, token))
  let turns = int(reader.getU32())
  for _ in 0 ..< turns:
    var t: ReplayTurn
    reader.need(Seats)
    for slot in 0 ..< Seats:
      t.dirs[slot] = uint8(ord(reader.data[reader.pos + slot]))
    reader.pos += Seats
    t.hash = reader.getU64()
    result.turns.add(t)
  let chats = int(reader.getU32())
  for _ in 0 ..< chats:
    result.chats.add(reader.getStr())

proc configOf*(replay: Replay): GameConfig =
  ## The replay's own config document, rebuilt into a `GameConfig`. Used by
  ## the wasm viewer to re-simulate the episode from the bytes alone.
  result = defaultGameConfig()
  let node = parseJson(replay.configJson)
  result.seed = node{"seed"}.getInt(1)
  result.module = normalizedModule(node{"module"}.getStr("royale"))
  let b = node{"board"}
  if not b.isNil:
    result.boardW = b{"w"}.getInt(17)
    result.boardH = b{"h"}.getInt(9)
    result.wrap = b{"wrap"}.getBool(false)
  result.foodCount = node{"foodCount"}.getInt(3)
  result.healthStart = node{"healthStart"}.getInt(30)
  result.shrinkEvery = node{"shrinkEvery"}.getInt(0)
  result.leaveTrail = node{"leaveTrail"}.getBool(false)
  result.headToHead = node{"headToHead"}.getStr("longer_wins")
  result.startLength = node{"startLength"}.getInt(3)
  result.maxTurns = node{"maxTurns"}.getInt(50)
  result.renderFramesPerTurn = node{"renderFramesPerTurn"}.getInt(12)
  result.sayTurns = node{"sayTurns"}.getInt(2)
  result.showPlayerLabels = node{"showPlayerLabels"}.getBool(false)
  result.playerNames = @[]
  let players = node{"players"}
  if not players.isNil:
    for entry in players:
      result.playerNames.add(entry{"name"}.getStr(""))
