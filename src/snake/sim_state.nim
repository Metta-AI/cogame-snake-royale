## Two integer RNG streams and the per-turn state hash.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_state.nim`: the same 64-bit
## xorshift generator and the same separate-stream convention. `setupRng` is
## seeded with the episode seed and draws `spawnDeal` BEFORE any seat
## connects; `foodRng` is seeded `seed xor 0x5EED` and draws every food cell.
## Separating them is what makes the food sequence a pure function of the seed
## regardless of how the snakes play.

type
  Rng* = object
    state*: uint64

const FoodStreamXor* = 0x5EED

proc initRng*(seed: int): Rng =
  ## Splitmix-style avalanche on the seed so two nearby seeds do not produce
  ## two nearby streams. Never zero: a zero state is a xorshift fixed point.
  var x = uint64(seed) * 0x9E3779B97F4A7C15'u64 + 0x1234567890ABCDEF'u64
  x = (x xor (x shr 30)) * 0xBF58476D1CE4E5B9'u64
  x = (x xor (x shr 27)) * 0x94D049BB133111EB'u64
  x = x xor (x shr 31)
  if x == 0: x = 0x9E3779B97F4A7C15'u64
  Rng(state: x)

proc next*(rng: var Rng): uint64 =
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rng.state = x
  x

proc rand*(rng: var Rng, bound: int): int =
  ## Uniform in `0 ..< bound` for a positive bound.
  if bound <= 1:
    return 0
  int(rng.next() mod uint64(bound))

proc shuffled*(rng: var Rng, values: seq[int]): seq[int] =
  ## Fisher-Yates. `spawnDeal` is exactly this over `[0, 1, 2, 3]`.
  result = values
  var i = result.len - 1
  while i > 0:
    let j = rng.rand(i + 1)
    swap(result[i], result[j])
    dec i

proc fold*(hash: var uint64, value: int) =
  ## FNV-style fold. The per-turn `gameHash` is this over the whole board
  ## state; the viewer checks the chain and warns on divergence.
  hash = hash xor uint64(value + 0x9E37)
  hash = hash * 0x100000001B3'u64
  hash = hash xor (hash shr 29)

proc newHash*(): uint64 = 0xCBF29CE484222325'u64
