## Record one replay fixture. Driven by tools/record_fixture.sh, which owns
## the three recipes.
##
##   nim r --path:src tools/record_fixture.nim <out> <module> <seed> <maxTurns>

import std/[os, strutils]
import snake/[rules, sim, sim_types, engine, replays]

when isMainModule:
  let args = commandLineParams()
  if args.len != 4:
    quit("usage: record_fixture <out> <module> <seed> <maxTurns>", 1)
  var config = defaultGameConfig()
  config.module = normalizedModule(args[1])
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
  config.seed = parseInt(args[2])
  config.maxTurns = parseInt(args[3])
  config.turnSpacingMs = 0
  let played = runScriptedEpisode(config, certificationSeats())
  createDir(args[0].parentDir())
  writeFile(args[0], encodeReplay(played.replay))
  echo "wrote ", args[0], " (", played.replay.turns.len, " turns, ",
    getFileSize(args[0]), " bytes)"
