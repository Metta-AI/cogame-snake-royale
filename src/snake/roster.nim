## Two name spaces, kept apart on purpose.
##
## Forked from `coworld-ctf`'s `src/ctf/roster.nim` with teams deleted: a seat
## in a free-for-all is its own side, so `slots` is gone from the runtime
## config and `cogAlias(slot)` returns `COG-<identity>` from the starter's
## identity array.
##
## IN-GAME a snake is `COG-alpha` .. `COG-delta` and a colour. Those aliases
## are the only names in an observation, a prompt, a reply, a `say`, a feed row
## or a board label. The seats' REAL policy names live only in
## `results.names`, in the replay's join records, and in the viewer's scorebug
## plates and endcard. `tests/test_snake_identity_privacy.nim` asserts no real
## name reaches a seat.

import sim_types

const
  IdentityNames* = ["alpha", "beta", "gamma", "delta"]
  Colours* = ["amber", "teal", "violet", "lime"]
  ColourHex* = ["#e8a33d", "#2fb3a8", "#8a5cd6", "#8ec63f"]

proc cogAlias*(slot: int): string =
  if slot < 0 or slot >= IdentityNames.len:
    return "COG-?"
  "COG-" & IdentityNames[slot]

proc colourOf*(spawnDeal: seq[int], slot: int): string =
  ## Colours follow `spawnDeal`, not the seat index, so a spectator can follow
  ## a policy while an agent cannot infer one from its own colour.
  if slot < 0 or slot >= spawnDeal.len:
    return Colours[0]
  Colours[spawnDeal[slot] mod Colours.len]

proc colourHexOf*(spawnDeal: seq[int], slot: int): string =
  if slot < 0 or slot >= spawnDeal.len:
    return ColourHex[0]
  ColourHex[spawnDeal[slot] mod ColourHex.len]

proc defaultPlayerName*(slot: int): string =
  "Cog" & $(slot + 1)

proc seatCount*(config: GameConfig): int =
  max(1, min(Seats, config.numAgents))
