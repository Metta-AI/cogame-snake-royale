## The board art manifest.
##
## `coworld-ctf`'s `rig_art.nim` bakes its rig segments server-side into the
## sprite protocol. This fork draws the grid in the browser, so the bake is
## the browser's: this module is the SINGLE list of the shipped sprite files,
## shared by `Dockerfile.replay-viewer`'s asset assertions, the viewer's
## preloader (through `wire_constants`) and `tests/test_snake_art.nim`.
##
## Every sprite is a nano-banana render of the Softmax cog
## (`scripts/art/source/snakes_sheet.png`, `tails_sheet.png`), split by
## `scripts/art/split_snake_sheet.py`. Nothing here is a procedural rig.

import roster

const
  SnakePieces* = ["head_u", "head_r", "head_d", "head_l", "body", "corner",
                  "tail"]
  ExtraSprites* = ["food_apple", "wreck"]

proc snakeSpriteFiles*(): seq[string] =
  for colour in Colours:
    for piece in SnakePieces:
      result.add("snake_" & colour & "_" & piece & ".png")
  for extra in ExtraSprites:
    result.add(extra & ".png")

proc allArtFiles*(): seq[string] =
  result = snakeSpriteFiles()
  result.add("arena_floor.png")
  result.add("pallete.png")
  result.add("font.ttf")
