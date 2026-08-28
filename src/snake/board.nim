## The grid. Integer arithmetic only: no float literal, no division operator
## and no square root appears anywhere in this file, and
## the test suite greps for all three (design note
## §Sim module → Determinism).

type
  Dir* = enum
    ## Wire order. The replay's one direction byte per seat per turn is this
    ## ordinal; 255 means "already dead".
    dUp = "up"
    dRight = "right"
    dDown = "down"
    dLeft = "left"

  Cell* = object
    x*, y*: int

  Board* = object
    w*, h*: int
    wrap*: bool
    cellPx*: int

const
  DirOrder* = [dUp, dRight, dDown, dLeft]
  DeadDirByte* = 255'u8
  DefaultCellPx* = 32

proc cell*(x, y: int): Cell = Cell(x: x, y: y)

proc `==`*(a, b: Cell): bool = a.x == b.x and a.y == b.y

proc initBoard*(w, h: int, wrap: bool, cellPx = DefaultCellPx): Board =
  Board(w: max(1, w), h: max(1, h), wrap: wrap, cellPx: max(1, cellPx))

proc cells*(board: Board): int = board.w * board.h

proc inBounds*(board: Board, c: Cell): bool =
  c.x >= 0 and c.y >= 0 and c.x < board.w and c.y < board.h

proc cellIndex*(board: Board, c: Cell): int =
  ## Row-major index. Callers must have checked `inBounds` first.
  c.y * board.w + c.x

proc cellAt*(board: Board, index: int): Cell =
  cell(index mod board.w, index div board.w)

proc delta*(d: Dir): Cell =
  ## x grows RIGHT and y grows DOWN, so `up` is y minus one.
  case d
  of dUp: cell(0, -1)
  of dRight: cell(1, 0)
  of dDown: cell(0, 1)
  of dLeft: cell(-1, 0)

proc opposite*(d: Dir): Dir =
  case d
  of dUp: dDown
  of dRight: dLeft
  of dDown: dUp
  of dLeft: dRight

proc step*(board: Board, c: Cell, d: Dir): tuple[cell: Cell, offBoard: bool] =
  ## One move. On a wrapping board the target is taken modulo the dimensions
  ## and `offBoard` is never true; on a walled board a target outside the
  ## rectangle is returned as-is with `offBoard` set, and the resolver kills
  ## the snake for it.
  let
    step = d.delta()
    nx = c.x + step.x
    ny = c.y + step.y
  if board.wrap:
    var
      wx = nx mod board.w
      wy = ny mod board.h
    if wx < 0: wx = wx + board.w
    if wy < 0: wy = wy + board.h
    (cell(wx, wy), false)
  else:
    (cell(nx, ny), not board.inBounds(cell(nx, ny)))

proc dirBetween*(board: Board, fromCell, toCell: Cell): tuple[ok: bool, dir: Dir] =
  ## The direction that steps `fromCell` onto `toCell`, if one exists.
  for d in DirOrder:
    let moved = board.step(fromCell, d)
    if not moved.offBoard and moved.cell == toCell:
      return (true, d)
  (false, dUp)

proc spawnAnchors*(board: Board): array[4, Cell] =
  ## The four spawn anchors are DERIVED from the dimensions, not authored, so
  ## a new board size needs no new data file.
  let
    lx = board.w div 4
    ly = board.h div 4
    rx = board.w - 1 - lx
    ry = board.h - 1 - ly
  [cell(lx, ly), cell(rx, ly), cell(lx, ry), cell(rx, ry)]

proc towardCentre*(board: Board, c: Cell): Dir =
  ## The axis with the larger absolute delta toward the board centre, x
  ## winning a tie. Used for a spawned snake's `last_dir`, so on turn 1 a
  ## snake is already pointing into the board.
  let
    cx = board.w div 2
    cy = board.h div 2
    dx = cx - c.x
    dy = cy - c.y
    ax = abs(dx)
    ay = abs(dy)
  if ax >= ay:
    if dx >= 0: dRight else: dLeft
  else:
    if dy >= 0: dDown else: dUp

proc parseDir*(text: string): tuple[ok: bool, dir: Dir] =
  ## Tolerant: case-insensitive, with the one-letter, compass and
  ## hyphen-or-space spellings a model actually emits normalised away.
  var key = ""
  for ch in text:
    if ch in {'A' .. 'Z'}:
      key.add(chr(ord(ch) + 32))
    elif ch in {'a' .. 'z'}:
      key.add(ch)
  case key
  of "up", "u", "north", "n", "top", "moveup", "goup": (true, dUp)
  of "right", "r", "east", "e", "moveright", "goright": (true, dRight)
  of "down", "d", "south", "s", "bottom", "movedown", "godown": (true, dDown)
  of "left", "l", "west", "w", "moveleft", "goleft": (true, dLeft)
  else: (false, dUp)
