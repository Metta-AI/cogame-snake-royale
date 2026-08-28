## The control layer: the single proc every unactuated seat resolves to.
##
## The per-turn FALLBACK path and the published `coil` baseline resolve to the
## SAME proc, so they cannot drift; `tests/test_snake_control.nim` asserts it.
## Forked from `coworld-ctf`'s `src/ctf/control.nim`, which held the same
## invariant for `holdline`.

import rules, baselines, directives

const FallbackBaseline* = blCoil
  ## `coil` is the survival heuristic: the certification player, the per-turn
  ## fallback, the default for an unregistered seat, and filler #1.

proc fallbackOrder*(state: GameState, slot: int): SnakeOrder =
  ## The order a seat plays when its LLM call could not be used this turn.
  result = scriptedOrder(state, slot, FallbackBaseline)
  result.source = dsFallback

proc fallbackDir*(state: GameState, slot: int): Dir =
  baselineDir(state, slot, FallbackBaseline)
