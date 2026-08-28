## Real art, not placeholders: every board sprite is a nano-banana render of
## the Softmax cog, one kit per colourway, committed alongside the source
## sheet and the split script.

import std/[os, strutils]
import snake/[roster, snake_art]
import helpers

var c = newChecker("test_snake_art")

for name in snakeSpriteFiles():
  let path = "data" / name
  c.check(fileExists(path), "the sprite is committed: " & name)
  if fileExists(path):
    c.check(getFileSize(path) > 1000,
      name & " is a real render, not a placeholder")

c.check(fileExists("scripts/art/source/snakes_sheet.png"),
  "the source sheet is committed")
c.check(fileExists("scripts/art/source/tails_sheet.png"),
  "the second source sheet is committed")
c.check(fileExists("scripts/art/split_snake_sheet.py"),
  "the split script is committed")

let script = readFile("scripts/art/split_snake_sheet.py")
c.check("gemini-2.5-flash-image" in script,
  "the script names the model that made the sheets")
c.check("nano-banana" in script, "and says where they came from")

# One kit per colourway, so roles read at board scale without labels.
for colour in Colours:
  for piece in SnakePieces:
    c.check(fileExists("data" / ("snake_" & colour & "_" & piece & ".png")),
      colour & " has a " & piece)

c.check(fileExists("data/food_apple.png"), "the apple")
c.check(fileExists("data/wreck.png"), "and the dead-snake wreck")

# The viewer's preloader and the bundle's asset list agree with this module.
let core = readFile("client/broadcast_core.js")
for piece in SnakePieces:
  c.check(("'" & piece & "'") in core, "the renderer preloads " & piece)
let dockerfile = readFile("Dockerfile.replay-viewer")
for name in snakeSpriteFiles():
  c.check(name in dockerfile, "the bundle ships " & name)

c.report()
