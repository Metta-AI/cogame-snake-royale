## Bounded reachability on the grid: one BFS, four callers.
##
## `freeSpaceFrom` is what the resolver records as `freeSpace`, what the
## observation reports as a move's `free_space`, what both scripted baselines
## score on, and what the alliance audit tests. One implementation means no
## consumer can disagree with the rules. Integer arithmetic only: no float
## literal, no division operator and no square root (design note
## §Sim module → Determinism).

import board

type
  Blocked* = seq[bool]
    ## Row-major occupancy over the board, `true` where a segment sits.

proc newBlocked*(b: Board): Blocked =
  newSeq[bool](b.cells())

proc freeSpaceFrom*(b: Board, blocked: Blocked, start: Cell, cap: int): int =
  ## How many cells a head at `start` could still reach, counting `start`
  ## itself, stopping once `cap` is reached. A snake whose own length exceeds
  ## this is sealing itself in.
  if not b.inBounds(start) or blocked[b.cellIndex(start)]:
    return 0
  if cap <= 0:
    return 0
  var
    seen = newSeq[bool](b.cells())
    queue = newSeqOfCap[Cell](b.cells())
    head = 0
    found = 0
  seen[b.cellIndex(start)] = true
  queue.add(start)
  while head < queue.len:
    let here = queue[head]
    inc head
    inc found
    if found >= cap:
      return cap
    for d in DirOrder:
      let moved = b.step(here, d)
      if moved.offBoard:
        continue
      let index = b.cellIndex(moved.cell)
      if seen[index] or blocked[index]:
        continue
      seen[index] = true
      queue.add(moved.cell)
  found

proc bfsDist*(b: Board, blocked: Blocked, fromCell, toCell: Cell,
              cap: int): int =
  ## Shortest walk from `fromCell` to `toCell` through free cells, or `cap`
  ## when there is none inside the cap. `toCell` itself may be blocked (food
  ## never is, but a target cell under a tail is a legal question to ask).
  if fromCell == toCell:
    return 0
  var
    dist = newSeq[int](b.cells())
    queue = newSeqOfCap[Cell](b.cells())
    head = 0
  for i in 0 ..< dist.len:
    dist[i] = -1
  dist[b.cellIndex(fromCell)] = 0
  queue.add(fromCell)
  while head < queue.len:
    let here = queue[head]
    inc head
    let base = dist[b.cellIndex(here)]
    if base >= cap:
      return cap
    for d in DirOrder:
      let moved = b.step(here, d)
      if moved.offBoard:
        continue
      let index = b.cellIndex(moved.cell)
      if dist[index] >= 0:
        continue
      if moved.cell == toCell:
        return base + 1
      if blocked[index]:
        continue
      dist[index] = base + 1
      queue.add(moved.cell)
  cap
