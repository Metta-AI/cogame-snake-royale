## The live `/global` spectator stream.
##
## `coworld-ctf`'s `global.nim` composes the whole board into the bitworld
## sprite protocol; this fork's board is a small integer grid drawn in the
## browser from a JSON frame, so every weapon, paint, flag, hill and
## first-person draw path is deleted with its wire fields (design note
## §Sim module -> The named edits). What survives is the contract: `/global`
## answers with a first message immediately, broadcasts are fire-and-forget so
## a slow viewer can never stall the episode, and the state carries the grid.

import std/json
import board, rules, sim, sim_types

proc liveStateJson*(episode: Episode, playing: bool): string =
  ## The live broadcast state. Same field names as the replay chrome document
  ## so the page has one code path.
  var
    snakes = newJArray()
    roster = newJArray()
    food = newJArray()
  for slot in 0 ..< Seats:
    let s = episode.state.snakes[slot]
    var body = newJArray()
    for c in s.body:
      body.add(%[c.x, c.y])
    snakes.add(%*{
      "slot": slot, "alias": cogAlias(slot), "colour": episode.colour(slot),
      "alive": s.alive, "body": body, "length": s.length(),
      "health": s.health, "free": s.freeSpace, "trapped": s.trapped,
      "dir": ord(s.lastDir)
    })
    roster.add(%*{
      "s": slot, "name": episode.seats[slot].name, "alias": cogAlias(slot),
      "colour": episode.colour(slot), "alive": s.alive, "len": s.length(),
      "hp": s.health, "kind": episode.seats[slot].policyKind
    })
  for c in episode.state.food:
    food.add(%[c.x, c.y])
  $(%*{
    "protocol": ProtocolName,
    "board": {"w": episode.state.rules.board.w,
              "h": episode.state.rules.board.h,
              "wrap": episode.state.rules.board.wrap,
              "cellPx": episode.state.rules.board.cellPx,
              "trail": episode.state.rules.leaveTrail},
    "alpha": 1000,
    "snakes": snakes,
    "food": food,
    "bubbles": newJArray(),
    "flashes": newJArray(),
    "chrome": {
      "t": episode.state.turn,
      "st": 0,
      "mx": max(1, episode.state.rules.maxTurns),
      "mt": episode.state.rules.maxTurns,
      "turn": episode.state.turn,
      "turns": episode.state.rules.maxTurns,
      "ph": (if episode.over: "gameover"
             elif episode.state.turn == 0: "lobby" else: "playing"),
      "lob": 0, "sp": 1, "pl": playing, "lp": false, "sk": false,
      "ff": false, "en": false, "over": episode.over,
      "alive": episode.state.aliveCount(),
      "module": episode.state.rules.name,
      "moduleLine": episode.moduleLine(),
      "boardW": episode.state.rules.board.w,
      "boardH": episode.state.rules.board.h,
      "wrap": episode.state.rules.board.wrap,
      "duel": episode.state.duelTurn,
      "mismatch": -1,
      "roster": roster,
      "beats": newJArray(),
      "lulls": newJArray(),
      "feed": newJArray(),
      "results": newJNull()
    }
  })
