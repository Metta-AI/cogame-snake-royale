## A forked ctf endcard silently ships paintbot's vocabulary: nothing in the
## starter's tests, in viewer_smoke.mjs or in the label manifest covers
## spectator chrome strings. This test is what enforces the re-labelings.

import std/[strutils]
import helpers

var c = newChecker("test_snake_endcard_labels")

proc stripComments(text: string): string =
  ## Drops HTML comments, CSS block comments and JS line comments, so a scar
  ## note that MENTIONS the old vocabulary is not a finding.
  var kept = ""
  var i = 0
  while i < text.len:
    if text.continuesWith("<!--", i):
      let close = text.find("-->", i)
      i = if close < 0: text.len else: close + 3
    elif text.continuesWith("/*", i):
      let close = text.find("*/", i)
      i = if close < 0: text.len else: close + 2
    elif text.continuesWith("//", i) and (i == 0 or text[i - 1] notin {':', '/'}):
      let close = text.find('\n', i)
      i = if close < 0: text.len else: close
    else:
      kept.add(text[i])
      inc i
  kept

proc scannable(text: string): string =
  ## `#killfeed` is one of the element ids the design note lists as KEPT, so
  ## the inherited id and the chrome alias that reads it are not paintbot
  ## VOCABULARY -- they are the match feed's own name. Everything else in the
  ## forbidden list is a string a spectator can read.
  stripComments(text).replace("killfeed", "matchfeed")

let page = scannable(readFile("client/replay_broadcast.html"))
let core = scannable(readFile("client/broadcast_core.js"))

const Forbidden = ["Lives", "LIVES", "Clstr", "Cap<", "flag", "heart",
                   "paint", "hopper", "hill", "POV", "spray", "grenade",
                   "med kit", "kill", "HP pips", "RED", "BLUE"]

for word in Forbidden:
  c.check(word notin page,
    "paintbot vocabulary in the page, outside comments: " & word)
  c.check(word notin core,
    "paintbot vocabulary in the renderer, outside comments: " & word)

## Each re-mapped string is pinned by its EXACT number of occurrences, not by
## `>= 1`: a second copy is how a rename half-lands (the markup relabelled and
## the JS that overwrites it left behind, or the other way round). Where a
## string legitimately appears twice -- once in the markup, once in the script
## that rewrites it -- the count says so.
const Replacements = [
  ("<span>Cog</span>", 1), ("<span>Place</span>", 1),
  ("<span>Turns</span>", 1), ("<span>Length</span>", 1),
  ("<span>Ate</span>", 1), ("<span>Soft</span>", 1),
  ("Coiling up", 2),                  ## the markup and the locker-room script
  ("Before the first move", 2),       ## the markup and renderClockLine
  ("showing recorded moves", 2),      ## the markup and renderMismatch
  ("deaths / head-ons / winner on the timeline ahead of the playhead (o)", 1),
  (">LENGTH<", 1),
  ("len-label", 5),                   ## the plate, the CSS and the .tiny rules
  ("hp-label", 5)]

let raw = readFile("client/replay_broadcast.html")
for (replacement, want) in Replacements:
  let count = raw.count(replacement)
  c.check(count == want,
    "the re-mapped string " & replacement & " appears " & $count &
    " times, expected " & $want)

c.report()
